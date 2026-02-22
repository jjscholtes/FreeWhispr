from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import os
import random
import shutil
import subprocess
import time
import wave
from typing import Callable, Any

from .models import TranscriptSegment, WordToken, BackendInfo, WorkerError, JobRequest
from .reconcile import SpeakerTurn, build_transcript_document
from .exports import write_exports


ProgressCallback = Callable[[str, float, str], None]

_WHISPERCPP_SEGMENT_RE = re.compile(
    r"^\[(?P<start>\d{2}:\d{2}:\d{2}\.\d{3})\s+-->\s+(?P<end>\d{2}:\d{2}:\d{2}\.\d{3})\]\s*(?P<text>.*)$"
)
_WHISPERCPP_LANG_RE = re.compile(r"\blang\s*=\s*([a-z]{2,8})\b", re.IGNORECASE)


def _parse_hms_ms(value: str) -> int:
    hours, minutes, rest = value.split(":")
    seconds, millis = rest.split(".")
    return (
        int(hours) * 3_600_000
        + int(minutes) * 60_000
        + int(seconds) * 1_000
        + int(millis)
    )


def _whispercpp_model_aliases(asr_model: str) -> list[str]:
    normalized = (asr_model or "").strip().lower()
    aliases: dict[str, list[str]] = {
        "turbo": [
            "ggml-large-v3-turbo.bin",
            "ggml-large-v3-turbo-q5_0.bin",
            "ggml-large-v3-turbo-q8_0.bin",
        ],
        "large-v3": [
            "ggml-large-v3.bin",
            "ggml-large-v3-q5_0.bin",
            "ggml-large-v3-q8_0.bin",
        ],
        "medium": [
            "ggml-medium.bin",
            "ggml-medium-q5_0.bin",
        ],
        "base": [
            "ggml-base.bin",
            "ggml-base-q5_0.bin",
        ],
    }
    if Path(asr_model).exists():
        return [asr_model]
    return aliases.get(normalized, [f"ggml-{normalized}.bin"])


def _candidate_whispercpp_model_dirs() -> list[Path]:
    paths: list[Path] = []
    env_dir = (
        os.environ.get("FREEWHISPR_WHISPERCPP_MODEL_DIR")
        or os.environ.get("WHISPERCPP_MODEL_DIR")
    )
    env_model = (
        os.environ.get("FREEWHISPR_WHISPERCPP_MODEL_PATH")
        or os.environ.get("WHISPERCPP_MODEL_PATH")
    )
    if env_model:
        paths.append(Path(env_model).expanduser())
    if env_dir:
        paths.append(Path(env_dir).expanduser())
    paths.extend(
        [
            Path.home() / ".cache" / "whisper.cpp",
            Path.home() / "Library" / "Application Support" / "FreeWhispr" / "models" / "whisper.cpp",
            Path.cwd() / "models" / "whisper.cpp",
            Path.cwd() / "whisper.cpp" / "models",
            Path.cwd() / "vendor" / "whisper.cpp" / "models",
        ]
    )
    deduped: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(path)
    return deduped


def _resolve_whispercpp_model_path(asr_model: str) -> Path | None:
    # Allow passing a direct model path in asrModel (advanced/developer use).
    direct = Path(asr_model).expanduser()
    if direct.exists():
        return direct

    aliases = _whispercpp_model_aliases(asr_model)
    for directory in _candidate_whispercpp_model_dirs():
        if directory.is_file():
            return directory
        for alias in aliases:
            candidate = directory / alias
            if candidate.exists():
                return candidate
    return None


def _resolve_whispercpp_binary() -> Path | None:
    env_bin = (
        os.environ.get("FREEWHISPR_WHISPERCPP_BIN")
        or os.environ.get("WHISPERCPP_BIN")
    )
    if env_bin:
        path = Path(env_bin).expanduser()
        if path.exists():
            return path

    candidates: list[Path] = []
    for name in ("whisper-cli", "whisper-cpp"):
        resolved = shutil.which(name)
        if resolved:
            candidates.append(Path(resolved))
    # Common local builds during development.
    candidates.extend(
        [
            Path.cwd() / "whisper.cpp" / "build" / "bin" / "whisper-cli",
            Path.cwd() / "vendor" / "whisper.cpp" / "build" / "bin" / "whisper-cli",
        ]
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def _parse_whispercpp_segments(stdout: str) -> list[TranscriptSegment]:
    segments: list[TranscriptSegment] = []
    index = 1
    for raw_line in stdout.splitlines():
        line = raw_line.strip()
        match = _WHISPERCPP_SEGMENT_RE.match(line)
        if not match:
            continue
        text = match.group("text").strip()
        if not text:
            continue
        segments.append(
            TranscriptSegment(
                id=f"seg_{index}",
                startMs=_parse_hms_ms(match.group("start")),
                endMs=_parse_hms_ms(match.group("end")),
                speakerId=None,
                text=text,
                confidence=None,
                words=None,
            )
        )
        index += 1
    return segments


def _parse_whispercpp_detected_language(stdout: str, stderr: str, fallback: str) -> str:
    haystack = "\n".join([stdout, stderr])
    match = _WHISPERCPP_LANG_RE.search(haystack)
    if match:
        return match.group(1).lower()
    return fallback


def _looks_like_whispercpp_metal_alloc_error(stderr: str, stdout: str) -> bool:
    haystack = "\n".join([stderr or "", stdout or ""]).lower()
    return (
        "ggml_metal_buffer_init: error" in haystack
        or ("metal" in haystack and "failed to allocate buffer" in haystack)
    )


def _read_wav_duration_ms(path: Path) -> int | None:
    if not path.exists() or path.suffix.lower() != ".wav":
        return None
    try:
        with wave.open(str(path), "rb") as wav:
            frames = wav.getnframes()
            rate = wav.getframerate() or 1
            return int((frames / rate) * 1000)
    except Exception:
        return None


def _simulate_segments(duration_ms: int, language: str) -> list[TranscriptSegment]:
    templates = {
        "nl": [
            "Goedemorgen, zullen we beginnen met de opname?",
            "Ja, laten we eerst de planning doornemen.",
            "Prima, daarna bespreken we de volgende stappen.",
            "Kun je dat nog iets concreter maken?",
            "Ja, ik stuur vandaag nog een samenvatting.",
        ],
        "en": [
            "Thanks for joining, let's start with the main issue.",
            "Sure, the problem started after the deployment last week.",
            "When did you first notice the failures?",
            "We saw elevated error rates on Tuesday morning.",
            "Okay, let's capture the action items before we end.",
        ],
    }
    chosen = templates.get(language, templates["en"])
    total = max(duration_ms, 45_000)
    slot = max(3_000, total // max(5, len(chosen)))
    segments: list[TranscriptSegment] = []
    cursor = 1_000
    for idx, text in enumerate(chosen, start=1):
        seg_len = min(slot, max(2200, len(text) * 55))
        start = cursor
        end = min(total, cursor + seg_len)
        words: list[WordToken] = []
        word_cursor = start
        for token in text.split():
            word_len = max(120, int((end - start) / max(1, len(text.split()))))
            word_end = min(end, word_cursor + word_len)
            words.append(WordToken(startMs=word_cursor, endMs=word_end, text=token, probability=0.9))
            word_cursor = word_end
        segments.append(
            TranscriptSegment(
                id=f"seg_{idx}",
                startMs=start,
                endMs=end,
                speakerId=None,
                text=text,
                confidence=0.9,
                words=words,
            )
        )
        cursor = end + random.randint(400, 1200)
    return segments


def _simulate_turns(segments: list[TranscriptSegment]) -> list[SpeakerTurn]:
    turns: list[SpeakerTurn] = []
    speaker_cycle = ["spk_1", "spk_2"]
    for index, seg in enumerate(segments):
        speaker_id = speaker_cycle[index % len(speaker_cycle)]
        turns.append(SpeakerTurn(speakerId=speaker_id, startMs=seg.startMs, endMs=seg.endMs))
    return turns


@dataclass
class PipelineContext:
    cancel_requested: Callable[[], bool]


class ProcessingPipeline:
    def __init__(self, context: PipelineContext):
        self._ctx = context

    def _check_cancel(self) -> None:
        if self._ctx.cancel_requested():
            raise RuntimeError("JOB_CANCELLED")

    def validate_setup(self) -> dict[str, Any]:
        whispercpp_binary_ok = False
        whispercpp_fast_model_ok = False
        whispercpp_best_model_ok = False
        pyannote_ok = False
        missing: list[str] = []
        if _resolve_whispercpp_binary() is not None:
            whispercpp_binary_ok = True
            whispercpp_fast_model_ok = _resolve_whispercpp_model_path("turbo") is not None
            whispercpp_best_model_ok = _resolve_whispercpp_model_path("large-v3") is not None
        whispercpp_ok = whispercpp_binary_ok and (whispercpp_fast_model_ok or whispercpp_best_model_ok)
        try:
            import pyannote.audio  # type: ignore # noqa: F401

            pyannote_ok = True
        except Exception:
            missing.append("pyannote.audio")
        if not whispercpp_binary_ok:
            missing.append("whisper.cpp")
        elif not (whispercpp_fast_model_ok or whispercpp_best_model_ok):
            missing.append("whisper.cpp-model")
        token_present = bool(os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN"))
        return {
            "pythonVersion": os.sys.version.split()[0],
            "dependencies": {
                "whisperCppAvailable": whispercpp_ok,
                "whisperCppBinaryAvailable": whispercpp_binary_ok,
                "whisperCppTurboModelAvailable": whispercpp_fast_model_ok,
                "whisperCppBestModelAvailable": whispercpp_best_model_ok,
                "pyannoteAvailable": pyannote_ok,
            },
            "diarizationTokenPresent": token_present,
            "status": "ready" if whispercpp_ok else "needs_setup",
            "missingDependencies": missing,
        }

    def capabilities(self) -> dict[str, Any]:
        return {
            "profiles": {
                "fast": {"asrModel": "turbo", "description": "Faster transcription"},
                "best": {"asrModel": "large-v3", "description": "Higher accuracy, slower"},
            },
            "asrBackends": {
                "whisper.cpp": {"description": "whisper.cpp CLI backend"},
            },
            "languages": ["auto", "nl", "en"],
            "features": {
                "diarization": True,
                "wordTimestamps": True,
                "mockPipeline": True,
            },
            "versions": {
                "pipelineVersion": "0.1.0",
            },
        }

    def _real_transcribe(self, request: JobRequest) -> tuple[list[TranscriptSegment], str, BackendInfo]:
        # `asrBackend` is still accepted in payloads for compatibility, but FreeWhispr now
        # standardizes on whisper.cpp and routes all ASR through this backend.
        return self._real_transcribe_whispercpp(request)

    def _real_transcribe_whispercpp(self, request: JobRequest) -> tuple[list[TranscriptSegment], str, BackendInfo]:
        binary = _resolve_whispercpp_binary()
        if binary is None:
            raise RuntimeError("MISSING_WHISPERCPP_BINARY")

        model_path = _resolve_whispercpp_model_path(request.asrModel)
        if model_path is None:
            raise RuntimeError(f"MISSING_WHISPERCPP_MODEL:{request.asrModel}")

        audio_path = Path(request.audioPath)
        if not audio_path.exists():
            raise RuntimeError(f"INPUT_AUDIO_NOT_FOUND:{audio_path}")

        # Initial integration keeps audio requirements strict to avoid hidden conversions.
        # whisper.cpp is happiest with WAV input; the app's recorder already produces WAV.
        if audio_path.suffix.lower() != ".wav":
            raise RuntimeError("WHISPERCPP_WAV_REQUIRED")

        base_cmd = [
            str(binary),
            "-m", str(model_path),
            "-f", str(audio_path),
        ]
        if request.languageMode and request.languageMode != "auto":
            base_cmd.extend(["-l", request.languageMode])
        # Conservative thread defaults; can be tuned later.
        cpu_count = os.cpu_count() or 8
        threads = min(max(cpu_count - 2, 2), 12)
        base_cmd.extend(["-t", str(threads)])

        force_no_gpu = os.environ.get("FREEWHISPR_WHISPERCPP_NO_GPU", "0") == "1"

        def run_whisper(use_gpu: bool) -> subprocess.CompletedProcess[str]:
            cmd = list(base_cmd)
            if not use_gpu:
                cmd.append("--no-gpu")
            return subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=False,
            )

        requested_gpu = not force_no_gpu
        run = run_whisper(use_gpu=requested_gpu)
        used_gpu = requested_gpu

        if run.returncode != 0 and requested_gpu and _looks_like_whispercpp_metal_alloc_error(run.stderr, run.stdout):
            # Automatic fallback for Metal allocation failures on some devices / memory pressure scenarios.
            run = run_whisper(use_gpu=False)
            used_gpu = False

        if run.returncode != 0:
            raise RuntimeError(
                "WHISPERCPP_EXEC_FAILED:"
                + (run.stderr.strip() or run.stdout.strip() or f"exit={run.returncode}")
            )

        segments = _parse_whispercpp_segments(run.stdout)
        if not segments:
            raise RuntimeError("WHISPERCPP_PARSE_FAILED")

        fallback_lang = request.languageMode if request.languageMode != "auto" else "unknown"
        detected_lang = _parse_whispercpp_detected_language(run.stdout, run.stderr, fallback=fallback_lang)
        backend = BackendInfo(
            name="whisper.cpp",
            model=model_path.name,
            metadata={
                "binary": binary.name,
                "threads": str(threads),
                "wordTimestamps": "false",
                "gpuRequested": "true" if requested_gpu else "false",
                "gpuUsed": "true" if used_gpu else "false",
                "gpuFallbackToCpu": "true" if (requested_gpu and not used_gpu) else "false",
            },
        )
        return segments, detected_lang, backend

    def _real_diarize(self, request: JobRequest) -> tuple[list[SpeakerTurn], BackendInfo]:
        token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
        if not token:
            raise RuntimeError("DIARIZATION_AUTH_REQUIRED")
        try:
            from pyannote.audio import Pipeline  # type: ignore
        except Exception as exc:
            raise RuntimeError(f"MISSING_PYANNOTE:{exc}") from exc

        pipe = Pipeline.from_pretrained("pyannote/speaker-diarization-community-1", token=token)
        kwargs: dict[str, Any] = {}
        if request.speakerHints:
            if "min" in request.speakerHints:
                kwargs["min_speakers"] = request.speakerHints["min"]
            if "max" in request.speakerHints:
                kwargs["max_speakers"] = request.speakerHints["max"]
        output = pipe(request.audioPath, **kwargs)
        annotation = output
        diarization_variant = "legacy"
        if hasattr(output, "exclusive_speaker_diarization"):
            annotation = output.exclusive_speaker_diarization
            diarization_variant = "exclusive"
        elif hasattr(output, "speaker_diarization"):
            annotation = output.speaker_diarization
            diarization_variant = "standard"
        turns: list[SpeakerTurn] = []
        for turn, _, speaker in annotation.itertracks(yield_label=True):
            turns.append(
                SpeakerTurn(
                    speakerId=str(speaker).lower().replace(" ", "_"),
                    startMs=int(turn.start * 1000),
                    endMs=int(turn.end * 1000),
                )
            )
        turns.sort(key=lambda t: (t.startMs, t.endMs))
        return turns, BackendInfo(name="pyannote.audio", model="community-1", metadata={"variant": diarization_variant})

    def _mock_process(
        self,
        request: JobRequest,
        progress: ProgressCallback,
    ) -> dict[str, Any]:
        duration_ms = _read_wav_duration_ms(Path(request.audioPath)) or 60_000
        detected_language = "nl" if request.languageMode == "nl" else "en" if request.languageMode == "en" else "en"

        progress("preparing", 0.05, "Preparing job")
        time.sleep(0.05)
        self._check_cancel()

        progress("transcribing", 0.25, f"Transcribing with {request.asrModel}")
        time.sleep(0.05)
        segments = _simulate_segments(duration_ms, detected_language)
        self._check_cancel()

        turns: list[SpeakerTurn] = []
        diar_backend = None
        if request.diarizationEnabled:
            progress("diarizing", 0.6, "Running speaker diarization")
            time.sleep(0.05)
            turns = _simulate_turns(segments)
            diar_backend = BackendInfo(name="pyannote.audio-mock", model="community-1-mock")
            self._check_cancel()

        progress("reconciling", 0.8, "Merging speaker labels")
        time.sleep(0.03)
        document = build_transcript_document(
            session_id=request.sessionId,
            segments=segments,
            turns=turns,
            detected_language=detected_language,
            asr_backend=BackendInfo(name=f"{request.asrBackend}-mock", model=request.asrModel),
            diar_backend=diar_backend,
        )
        self._check_cancel()
        progress("writing_output", 0.95, "Writing transcript files")
        return {"document": document}

    def run_job(self, request: JobRequest, progress: ProgressCallback) -> dict[str, Any]:
        start = time.perf_counter()
        stage_times: dict[str, float] = {}
        warnings: list[str] = []

        def timed(stage_name: str, fn: Callable[[], Any]) -> Any:
            stage_start = time.perf_counter()
            result = fn()
            stage_times[stage_name] = round(time.perf_counter() - stage_start, 4)
            return result

        def emit(stage: str, fraction: float, message: str) -> None:
            progress(stage, fraction, message)

        try:
            if request.mockMode or os.environ.get("VOXSCRIBE_ALLOW_STUB_PIPELINE", "0") == "1":
                result = timed("mock_pipeline", lambda: self._mock_process(request, emit))
            else:
                emit("preparing", 0.05, "Preparing job")
                self._check_cancel()

                emit("transcribing", 0.12, f"Loading Whisper model ({request.asrModel})")
                self._check_cancel()
                segments, detected_language, asr_backend = timed("transcribing", lambda: self._real_transcribe(request))
                emit("transcribing", 0.55, "Transcription complete")
                self._check_cancel()

                turns: list[SpeakerTurn] = []
                diar_backend = None
                if request.diarizationEnabled:
                    emit("diarizing", 0.62, "Loading diarization model")
                    self._check_cancel()
                    turns, diar_backend = timed("diarizing", lambda: self._real_diarize(request))
                    emit("diarizing", 0.8, "Speaker diarization complete")
                    self._check_cancel()
                emit("reconciling", 0.86, "Merging speaker labels")
                self._check_cancel()
                document = timed(
                    "reconciling",
                    lambda: build_transcript_document(
                        session_id=request.sessionId,
                        segments=segments,
                        turns=turns,
                        detected_language=detected_language,
                        asr_backend=asr_backend,
                        diar_backend=diar_backend,
                    ),
                )
                result = {"document": document}

            transcript_dir = Path(request.outputDir) / "transcript"
            emit("writing_output", 0.94, "Writing transcript files")
            export_paths = timed("exports", lambda: write_exports(result["document"], transcript_dir))
            metrics = {
                "pipelineVersion": "0.1.0",
                "jobId": request.jobId,
                "sessionId": request.sessionId,
                "profile": request.profile,
                "asrModel": request.asrModel,
                "languageMode": request.languageMode,
                "stageDurationsSec": stage_times,
                "totalDurationSec": round(time.perf_counter() - start, 4),
                "warnings": warnings,
            }
            return {
                "status": "completed",
                "document": result["document"],
                "exportPaths": export_paths,
                "metrics": metrics,
                "warnings": warnings,
            }
        except RuntimeError as exc:
            msg = str(exc)
            if msg == "JOB_CANCELLED":
                raise
            if msg.startswith("MISSING_PYANNOTE"):
                raise WorkerExecutionError("DIARIZATION_MODEL_UNAVAILABLE", "pyannote.audio dependency is not installed", {"raw": msg})
            if msg == "MISSING_WHISPERCPP_BINARY":
                raise WorkerExecutionError(
                    "MODEL_NOT_INSTALLED",
                    "whisper.cpp binary is not installed or not found in PATH",
                    {"raw": msg},
                )
            if msg.startswith("MISSING_WHISPERCPP_MODEL:"):
                requested = msg.split(":", 1)[1]
                raise WorkerExecutionError(
                    "MODEL_NOT_INSTALLED",
                    f"whisper.cpp model file for '{requested}' was not found",
                    {"raw": msg},
                )
            if msg == "WHISPERCPP_WAV_REQUIRED":
                raise WorkerExecutionError(
                    "UNSUPPORTED_AUDIO_FORMAT",
                    "whisper.cpp backend currently requires WAV input for FreeWhispr v1 integration",
                    {"raw": msg},
                )
            if msg.startswith("WHISPERCPP_EXEC_FAILED:"):
                raise WorkerExecutionError(
                    "TRANSCRIPTION_BACKEND_FAILED",
                    "whisper.cpp failed while transcribing the audio",
                    {"raw": msg},
                )
            if msg == "WHISPERCPP_PARSE_FAILED":
                raise WorkerExecutionError(
                    "UNKNOWN_PROCESSING_ERROR",
                    "whisper.cpp completed but FreeWhispr could not parse its transcript output",
                    {"raw": msg},
                )
            if msg == "DIARIZATION_AUTH_REQUIRED":
                raise WorkerExecutionError("DIARIZATION_AUTH_REQUIRED", "Hugging Face token is required for diarization")
            raise


class WorkerExecutionError(Exception):
    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}

    def to_worker_error(self) -> WorkerError:
        return WorkerError(code=self.code, message=self.message, details=self.details or None)
