from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import importlib.util
import json
import re
import os
import random
import shutil
import subprocess
import tempfile
import time
import wave
from typing import Callable, Any

from .models import (
    TranscriptSegment,
    WordToken,
    BackendInfo,
    WorkerError,
    JobRequest,
    Speaker,
    TranscriptDocument,
    SCHEMA_VERSION,
    now_ms,
)
from .reconcile import SpeakerTurn, build_transcript_document
from .exports import write_exports, write_json_export


ProgressCallback = Callable[[str, float, str], None]

_WHISPERCPP_SEGMENT_RE = re.compile(
    r"^\[(?P<start>\d{2}:\d{2}:\d{2}\.\d{3})\s+-->\s+(?P<end>\d{2}:\d{2}:\d{2}\.\d{3})\]\s*(?P<text>.*)$"
)
_WHISPERCPP_LANG_RE = re.compile(r"\blang\s*=\s*([a-z]{2,8})\b", re.IGNORECASE)
_WHISPERCPP_SPECIAL_TOKEN_RE = re.compile(r"^\[[^\]]+\]$")

_PYANNOTE_PIPELINE_CACHE: dict[str, Any] = {}
_WHISPERCPP_DISABLE_GPU_AFTER_FAILURE = False


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


def _whispercpp_coreml_encoder_path_for_model(model_path: Path) -> Path:
    base = model_path.with_suffix("")
    # mirror whisper.cpp's internal suffix stripping for quantized model names (e.g. -q5_0)
    suffix = base.name.rsplit("-", 1)
    if len(suffix) == 2:
        tail = suffix[1]
        if len(tail) == 4 and tail[0] == "q" and tail[2] == "_":
            base = base.with_name(suffix[0])
    return base.with_name(base.name + "-encoder.mlmodelc")


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


def _resolve_whispercpp_coreml_model_path(asr_model: str) -> Path | None:
    model_path = _resolve_whispercpp_model_path(asr_model)
    if model_path is None:
        return None
    candidate = _whispercpp_coreml_encoder_path_for_model(model_path)
    return candidate if candidate.exists() else None


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


def _python_module_available(module_name: str) -> bool:
    try:
        return importlib.util.find_spec(module_name) is not None
    except Exception:
        return False


def _parse_whispercpp_json_output(json_path: Path, include_words: bool) -> tuple[list[TranscriptSegment], str]:
    payload = json.loads(json_path.read_text(encoding="utf-8"))
    language = (
        payload.get("result", {}).get("language")
        or payload.get("params", {}).get("language")
        or "unknown"
    )
    segments: list[TranscriptSegment] = []
    for index, raw_seg in enumerate(payload.get("transcription", []) or [], start=1):
        offsets = raw_seg.get("offsets") or {}
        start_ms = int(offsets.get("from", 0) or 0)
        end_ms = int(offsets.get("to", 0) or 0)
        text = str(raw_seg.get("text") or "").strip()
        if not text:
            continue

        words: list[WordToken] | None = None
        token_probs: list[float] = []
        if include_words:
            parsed_words: list[WordToken] = []
            for token in raw_seg.get("tokens") or []:
                token_text_raw = str(token.get("text") or "")
                token_text = token_text_raw.strip()
                if not token_text or _WHISPERCPP_SPECIAL_TOKEN_RE.match(token_text):
                    continue
                token_offsets = token.get("offsets") or {}
                start = token_offsets.get("from")
                end = token_offsets.get("to")
                if start is None or end is None:
                    continue
                probability_raw = token.get("p")
                probability = float(probability_raw) if isinstance(probability_raw, (int, float)) else None
                if probability is not None:
                    token_probs.append(probability)
                parsed_words.append(
                    WordToken(
                        startMs=int(start),
                        endMs=int(end),
                        text=token_text,
                        probability=probability,
                    )
                )
            words = parsed_words or None

        confidence = (sum(token_probs) / len(token_probs)) if token_probs else None
        segments.append(
            TranscriptSegment(
                id=f"seg_{index}",
                startMs=start_ms,
                endMs=end_ms,
                speakerId=None,
                text=text,
                confidence=confidence,
                words=words,
            )
        )
    return segments, str(language).lower()


def _looks_like_whispercpp_metal_alloc_error(stderr: str, stdout: str) -> bool:
    haystack = "\n".join([stderr or "", stdout or ""]).lower()
    return (
        "ggml_metal_buffer_init: error" in haystack
        or ("metal" in haystack and "failed to allocate buffer" in haystack)
    )


def _backend_info_from_dict(data: Any) -> BackendInfo | None:
    if not isinstance(data, dict):
        return None
    name = str(data.get("name", "")).strip()
    if not name:
        return None
    version = str(data["version"]) if data.get("version") is not None else None
    model = str(data["model"]) if data.get("model") is not None else None
    metadata_raw = data.get("metadata")
    metadata: dict[str, Any] | None = None
    if isinstance(metadata_raw, dict):
        metadata = {str(k): v for k, v in metadata_raw.items()}
    return BackendInfo(name=name, version=version, model=model, metadata=metadata)


def _load_existing_transcript_document(path: Path) -> TranscriptDocument:
    raw = json.loads(path.read_text(encoding="utf-8"))
    speakers: list[Speaker] = []
    for item in raw.get("speakers", []) or []:
        if not isinstance(item, dict):
            continue
        speakers.append(
            Speaker(
                id=str(item.get("id", "")),
                defaultLabel=str(item.get("defaultLabel", item.get("displayName") or "Speaker")),
                displayName=(str(item["displayName"]) if item.get("displayName") is not None else None),
                colorHex=str(item.get("colorHex", "#111111")),
                isUserEdited=bool(item.get("isUserEdited", False)),
            )
        )

    segments: list[TranscriptSegment] = []
    for item in raw.get("segments", []) or []:
        if not isinstance(item, dict):
            continue
        words_raw = item.get("words")
        words: list[WordToken] | None = None
        if isinstance(words_raw, list):
            parsed_words: list[WordToken] = []
            for token in words_raw:
                if not isinstance(token, dict):
                    continue
                parsed_words.append(
                    WordToken(
                        startMs=int(token.get("startMs", 0)),
                        endMs=int(token.get("endMs", 0)),
                        text=str(token.get("text", "")),
                        probability=(float(token["probability"]) if token.get("probability") is not None else None),
                        speakerId=(str(token["speakerId"]) if token.get("speakerId") is not None else None),
                    )
                )
            words = parsed_words
        segments.append(
            TranscriptSegment(
                id=str(item.get("id", f"seg_{len(segments)}")),
                startMs=int(item.get("startMs", 0)),
                endMs=int(item.get("endMs", 0)),
                speakerId=(str(item["speakerId"]) if item.get("speakerId") is not None else None),
                text=str(item.get("text", "")),
                confidence=(float(item["confidence"]) if item.get("confidence") is not None else None),
                speakerConfidence=(float(item["speakerConfidence"]) if item.get("speakerConfidence") is not None else None),
                source=str(item.get("source", "machine")),
                words=words,
            )
        )

    stats = raw.get("stats")
    stats_dict = stats if isinstance(stats, dict) else {}

    return TranscriptDocument(
        sessionId=str(raw.get("sessionId", "")),
        speakers=speakers,
        segments=segments,
        sourceLanguage=(str(raw["sourceLanguage"]) if raw.get("sourceLanguage") is not None else None),
        transcriptionBackend=_backend_info_from_dict(raw.get("transcriptionBackend")),
        diarizationBackend=_backend_info_from_dict(raw.get("diarizationBackend")),
        stats={str(k): v for k, v in stats_dict.items()},
        schemaVersion=int(raw.get("schemaVersion", SCHEMA_VERSION)),
        createdAt=int(raw.get("createdAt", now_ms())),
        updatedAt=int(raw.get("updatedAt", now_ms())),
    )


def _preserve_speaker_labels(previous: TranscriptDocument, updated: TranscriptDocument) -> None:
    by_id = {speaker.id: speaker for speaker in previous.speakers}
    by_default = {speaker.defaultLabel: speaker for speaker in previous.speakers}
    for speaker in updated.speakers:
        source = by_id.get(speaker.id) or by_default.get(speaker.defaultLabel)
        if source is None:
            continue
        speaker.displayName = source.displayName
        speaker.isUserEdited = source.isUserEdited
        if source.colorHex:
            speaker.colorHex = source.colorHex


def _resolve_whispercpp_threads(profile: str) -> int:
    raw = os.environ.get("FREEWHISPR_WHISPERCPP_THREADS") or os.environ.get("WHISPERCPP_THREADS")
    if raw:
        try:
            value = int(raw)
            if value > 0:
                return max(1, min(value, 64))
        except ValueError:
            pass
    cpu_count = os.cpu_count() or 8
    if profile == "fast":
        return min(max(cpu_count - 2, 2), 12)
    return min(max(cpu_count - 1, 2), 16)


def _resolve_whispercpp_decode_params(profile: str) -> tuple[int, int]:
    if profile == "fast":
        beam_default, best_default = 1, 1
    else:
        beam_default, best_default = 5, 5

    def _env_int(name: str, fallback: int) -> int:
        raw = os.environ.get(name)
        if not raw:
            return fallback
        try:
            return max(1, min(int(raw), 32))
        except ValueError:
            return fallback

    return (
        _env_int("FREEWHISPR_WHISPERCPP_BEAM_SIZE", beam_default),
        _env_int("FREEWHISPR_WHISPERCPP_BEST_OF", best_default),
    )


def _get_pyannote_pipeline(token: str):
    cache_key = "pyannote/speaker-diarization-community-1"
    cached = _PYANNOTE_PIPELINE_CACHE.get(cache_key)
    if cached is not None:
        return cached
    from pyannote.audio import Pipeline  # type: ignore
    pipe = Pipeline.from_pretrained(cache_key, token=token)
    _PYANNOTE_PIPELINE_CACHE[cache_key] = pipe
    return pipe


def _read_wav_duration_ms(path: Path) -> int | None:
    if not path.exists() or path.suffix.lower() != ".wav":
        return None


def _write_silence_wav(path: Path, duration_ms: int = 900, sample_rate: int = 16000) -> None:
    frames = max(1, int(sample_rate * (duration_ms / 1000.0)))
    silence = b"\x00\x00" * frames  # 16-bit mono PCM silence
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(silence)
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
        whispercpp_fast_coreml_ok = False
        whispercpp_best_coreml_ok = False
        pyannote_ok = False
        missing: list[str] = []
        if _resolve_whispercpp_binary() is not None:
            whispercpp_binary_ok = True
            whispercpp_fast_model_ok = _resolve_whispercpp_model_path("turbo") is not None
            whispercpp_best_model_ok = _resolve_whispercpp_model_path("large-v3") is not None
            whispercpp_fast_coreml_ok = _resolve_whispercpp_coreml_model_path("turbo") is not None
            whispercpp_best_coreml_ok = _resolve_whispercpp_coreml_model_path("large-v3") is not None
        whispercpp_ok = whispercpp_binary_ok and (whispercpp_fast_model_ok or whispercpp_best_model_ok)
        if _python_module_available("pyannote.audio"):
            pyannote_ok = True
        else:
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
                "whisperCppTurboCoreMLAvailable": whispercpp_fast_coreml_ok,
                "whisperCppBestCoreMLAvailable": whispercpp_best_coreml_ok,
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

    def warm_up_models(self, profile: str = "fast", include_diarization: bool = True) -> dict[str, Any]:
        started = time.perf_counter()
        asr_info: dict[str, Any] = {"requested": True, "ok": False}
        diar_info: dict[str, Any] = {"requested": bool(include_diarization), "ok": False}
        warnings: list[str] = []

        normalized_profile = profile if profile in {"fast", "best"} else "fast"
        asr_model = "turbo" if normalized_profile == "fast" else "large-v3"

        with tempfile.TemporaryDirectory(prefix="freewhispr-warmup-") as temp_dir:
            temp_root = Path(temp_dir)
            audio_path = temp_root / "warmup.wav"
            output_dir = temp_root / "out"
            _write_silence_wav(audio_path)

            try:
                _, _, backend = self._real_transcribe(
                    JobRequest(
                        jobId="warmup",
                        sessionId="warmup",
                        audioPath=str(audio_path),
                        outputDir=str(output_dir),
                        languageMode="en",
                        profile=normalized_profile,
                        asrBackend="whisper.cpp",
                        asrModel=asr_model,
                        diarizationEnabled=False,
                        wordTimestamps=False,
                        mockMode=False,
                    )
                )
                asr_info["ok"] = True
                asr_info["backend"] = backend.to_dict()
            except Exception as exc:
                asr_info["error"] = str(exc)

        if include_diarization:
            token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
            if not token:
                diar_info["error"] = "HF token missing"
            elif not _python_module_available("pyannote.audio"):
                diar_info["error"] = "pyannote.audio missing"
            else:
                diar_started = time.perf_counter()
                try:
                    _get_pyannote_pipeline(token)
                    diar_info["ok"] = True
                    diar_info["durationSec"] = round(time.perf_counter() - diar_started, 4)
                except Exception as exc:
                    diar_info["error"] = str(exc)

        if _WHISPERCPP_DISABLE_GPU_AFTER_FAILURE:
            warnings.append("whisper.cpp GPU fallback cache is active (CPU will be used until worker restart)")

        return {
            "status": "ok" if asr_info.get("ok") else "partial",
            "profile": normalized_profile,
            "asr": asr_info,
            "diarization": diar_info,
            "durationSec": round(time.perf_counter() - started, 4),
            "warnings": warnings,
        }

    def _real_transcribe(self, request: JobRequest) -> tuple[list[TranscriptSegment], str, BackendInfo]:
        # `asrBackend` is still accepted in payloads for compatibility, but FreeWhispr now
        # standardizes on whisper.cpp and routes all ASR through this backend.
        return self._real_transcribe_whispercpp(request)

    def _real_transcribe_whispercpp(self, request: JobRequest) -> tuple[list[TranscriptSegment], str, BackendInfo]:
        global _WHISPERCPP_DISABLE_GPU_AFTER_FAILURE
        binary = _resolve_whispercpp_binary()
        if binary is None:
            raise RuntimeError("MISSING_WHISPERCPP_BINARY")

        model_path = _resolve_whispercpp_model_path(request.asrModel)
        if model_path is None:
            raise RuntimeError(f"MISSING_WHISPERCPP_MODEL:{request.asrModel}")

        audio_path = Path(request.audioPath)
        if not audio_path.exists():
            raise RuntimeError(f"INPUT_AUDIO_NOT_FOUND:{audio_path}")

        base_cmd = [
            str(binary),
            "-m", str(model_path),
            "-f", str(audio_path),
        ]
        if request.languageMode and request.languageMode != "auto":
            base_cmd.extend(["-l", request.languageMode])
        threads = _resolve_whispercpp_threads(request.profile)
        base_cmd.extend(["-t", str(threads)])
        beam_size, best_of = _resolve_whispercpp_decode_params(request.profile)
        base_cmd.extend(["-bs", str(beam_size), "-bo", str(best_of)])

        processing_dir = Path(request.outputDir) / "processing"
        processing_dir.mkdir(parents=True, exist_ok=True)
        json_prefix = processing_dir / f"whispercpp-{request.jobId}"
        json_output_path = json_prefix.with_suffix(".json")
        try:
            if json_output_path.exists():
                json_output_path.unlink()
        except Exception:
            pass
        base_cmd.extend(["-oj", "-ojf", "-of", str(json_prefix)])

        force_no_gpu = (
            os.environ.get("FREEWHISPR_WHISPERCPP_NO_GPU", "0") == "1"
            or _WHISPERCPP_DISABLE_GPU_AFTER_FAILURE
        )

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
            _WHISPERCPP_DISABLE_GPU_AFTER_FAILURE = True

        if run.returncode != 0:
            raise RuntimeError(
                "WHISPERCPP_EXEC_FAILED:"
                + (run.stderr.strip() or run.stdout.strip() or f"exit={run.returncode}")
            )

        fallback_lang = request.languageMode if request.languageMode != "auto" else "unknown"
        detected_lang = fallback_lang
        segments: list[TranscriptSegment] = []
        json_parse_fallback = False
        if json_output_path.exists():
            try:
                segments, detected_lang = _parse_whispercpp_json_output(
                    json_output_path,
                    include_words=request.wordTimestamps,
                )
            except Exception:
                json_parse_fallback = True

        if not segments:
            segments = _parse_whispercpp_segments(run.stdout)
            detected_lang = _parse_whispercpp_detected_language(run.stdout, run.stderr, fallback=fallback_lang)

        if not segments:
            raise RuntimeError("WHISPERCPP_PARSE_FAILED")

        combined_logs = "\n".join([run.stdout or "", run.stderr or ""])
        coreml_sidecar_path = _whispercpp_coreml_encoder_path_for_model(model_path)
        coreml_requested = coreml_sidecar_path.exists()
        coreml_used = "Core ML model loaded" in combined_logs
        coreml_load_failed = ("failed to load Core ML model" in combined_logs) or (coreml_requested and not coreml_used)

        backend = BackendInfo(
            name="whisper.cpp",
            model=model_path.name,
            metadata={
                "binary": binary.name,
                "threads": str(threads),
                "beamSize": str(beam_size),
                "bestOf": str(best_of),
                "wordTimestamps": "true" if request.wordTimestamps else "false",
                "parser": "stdout" if json_parse_fallback else "json",
                "gpuRequested": "true" if requested_gpu else "false",
                "gpuUsed": "true" if used_gpu else "false",
                "gpuFallbackToCpu": "true" if (requested_gpu and not used_gpu) else "false",
                "inputExt": audio_path.suffix.lower().lstrip(".") or "unknown",
                "coremlRequested": "true" if coreml_requested else "false",
                "coremlUsed": "true" if coreml_used else "false",
                "coremlLoadFailed": "true" if coreml_load_failed else "false",
                "coremlEncoderPath": coreml_sidecar_path.name if coreml_requested else "",
            },
        )
        return segments, detected_lang, backend

    def _real_diarize(self, request: JobRequest) -> tuple[list[SpeakerTurn], BackendInfo]:
        token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
        if not token:
            raise RuntimeError("DIARIZATION_AUTH_REQUIRED")
        if not _python_module_available("pyannote.audio"):
            raise RuntimeError("MISSING_PYANNOTE:module_not_found")
        try:
            pipe = _get_pyannote_pipeline(token)
        except Exception as exc:
            raise RuntimeError(f"MISSING_PYANNOTE:{exc}") from exc
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
        transcript_dir = Path(request.outputDir) / "transcript"

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
                if request.diarizationOnly:
                    if not request.transcriptPath:
                        raise RuntimeError("DIARIZATION_RETRY_REQUIRES_TRANSCRIPT")
                    transcript_path = Path(request.transcriptPath)
                    if not transcript_path.exists():
                        raise RuntimeError(f"TRANSCRIPT_NOT_FOUND:{transcript_path}")
                    emit("preparing", 0.12, "Loading existing transcript")
                    self._check_cancel()
                    existing_document = timed("load_transcript", lambda: _load_existing_transcript_document(transcript_path))
                    segments = existing_document.segments
                    detected_language = existing_document.sourceLanguage
                    asr_backend = existing_document.transcriptionBackend or BackendInfo(name="whisper.cpp", model=request.asrModel)
                    emit("transcribing", 0.55, "Using existing transcript")
                    self._check_cancel()
                else:
                    emit("transcribing", 0.12, f"Loading Whisper model ({request.asrModel})")
                    self._check_cancel()
                    segments, detected_language, asr_backend = timed("transcribing", lambda: self._real_transcribe(request))
                    emit("transcribing", 0.55, "Transcription complete")
                    self._check_cancel()
                    existing_document = None

                turns: list[SpeakerTurn] = []
                diar_backend = None
                if request.diarizationEnabled:
                    if not request.diarizationOnly:
                        emit("reconciling", 0.58, "Preparing transcript preview")
                        self._check_cancel()
                        interim_document = timed(
                            "reconciling_preview",
                            lambda: build_transcript_document(
                                session_id=request.sessionId,
                                segments=segments,
                                turns=[],
                                detected_language=detected_language,
                                asr_backend=asr_backend,
                                diar_backend=None,
                            ),
                        )
                        timed("preview_exports", lambda: write_json_export(interim_document, transcript_dir))
                        emit("diarizing", 0.6, "Transcript ready — continuing speaker separation")
                    emit("diarizing", 0.62, "Loading diarization model")
                    self._check_cancel()
                    turns, diar_backend = timed("diarizing", lambda: self._real_diarize(request))
                    emit("diarizing", 0.8, "Speaker diarization complete")
                    self._check_cancel()
                elif request.diarizationEnabled is False:
                    emit("reconciling", 0.7, "Building transcript")
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
                if request.diarizationOnly and existing_document is not None:
                    _preserve_speaker_labels(existing_document, document)
                result = {"document": document}

            emit("writing_output", 0.94, "Writing transcript files")
            export_paths = timed("exports", lambda: write_exports(result["document"], transcript_dir))
            metrics = {
                "pipelineVersion": "0.1.0",
                "jobId": request.jobId,
                "sessionId": request.sessionId,
                "profile": request.profile,
                "asrBackend": request.asrBackend,
                "asrModel": request.asrModel,
                "languageMode": request.languageMode,
                "diarizationEnabled": request.diarizationEnabled,
                "inputAudioExtension": Path(request.audioPath).suffix.lower(),
                "stageDurationsSec": stage_times,
                "totalDurationSec": round(time.perf_counter() - start, 4),
                "warnings": warnings,
            }
            document = result["document"]
            if getattr(document, "transcriptionBackend", None):
                metrics["transcriptionBackend"] = document.transcriptionBackend.to_dict()
                metadata = document.transcriptionBackend.metadata or {}
                if str(metadata.get("gpuFallbackToCpu", "")).lower() == "true":
                    warnings.append("whisper.cpp fell back from GPU to CPU due to a Metal allocation failure")
            if getattr(document, "diarizationBackend", None):
                metrics["diarizationBackend"] = document.diarizationBackend.to_dict()
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
            if msg == "DIARIZATION_RETRY_REQUIRES_TRANSCRIPT":
                raise WorkerExecutionError(
                    "DIARIZATION_RETRY_REQUIRES_TRANSCRIPT",
                    "Retrying speaker separation requires an existing transcript file",
                )
            if msg.startswith("TRANSCRIPT_NOT_FOUND:"):
                raise WorkerExecutionError(
                    "TRANSCRIPT_NOT_FOUND",
                    "Existing transcript file was not found for speaker separation retry",
                    {"raw": msg},
                )
            raise


class WorkerExecutionError(Exception):
    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}

    def to_worker_error(self) -> WorkerError:
        return WorkerError(code=self.code, message=self.message, details=self.details or None)
