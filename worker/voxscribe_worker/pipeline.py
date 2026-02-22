from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
import random
import time
import wave
from typing import Callable, Any

from .models import TranscriptSegment, WordToken, BackendInfo, WorkerError, JobRequest
from .reconcile import SpeakerTurn, build_transcript_document
from .exports import write_exports


ProgressCallback = Callable[[str, float, str], None]


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
        faster_whisper_ok = False
        pyannote_ok = False
        missing: list[str] = []
        try:
            import faster_whisper  # noqa: F401

            faster_whisper_ok = True
        except Exception:
            missing.append("faster-whisper")
        try:
            import pyannote.audio  # type: ignore # noqa: F401

            pyannote_ok = True
        except Exception:
            missing.append("pyannote.audio")
        token_present = bool(os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN"))
        return {
            "pythonVersion": os.sys.version.split()[0],
            "dependencies": {
                "fasterWhisperAvailable": faster_whisper_ok,
                "pyannoteAvailable": pyannote_ok,
            },
            "diarizationTokenPresent": token_present,
            "status": "ready" if faster_whisper_ok else "needs_setup",
            "missingDependencies": missing,
        }

    def capabilities(self) -> dict[str, Any]:
        return {
            "profiles": {
                "fast": {"asrModel": "turbo", "description": "Faster transcription"},
                "best": {"asrModel": "large-v3", "description": "Higher accuracy, slower"},
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
        # Optional real backend. Falls back to a structured error if unavailable or unsupported.
        try:
            from faster_whisper import WhisperModel  # type: ignore
        except Exception as exc:
            raise RuntimeError(f"MISSING_FASTER_WHISPER:{exc}") from exc

        model_name = request.asrModel
        compute_type = "int8" if request.profile == "fast" else "int8_float16"
        model = WhisperModel(model_name, device="cpu", compute_type=compute_type)
        language = None if request.languageMode == "auto" else request.languageMode
        segments_result, info = model.transcribe(
            request.audioPath,
            task="transcribe",
            language=language,
            word_timestamps=request.wordTimestamps,
            vad_filter=True,
        )
        segments: list[TranscriptSegment] = []
        for idx, seg in enumerate(segments_result, start=1):
            words = None
            if getattr(seg, "words", None):
                words = []
                for word in seg.words:
                    if word.start is None or word.end is None:
                        continue
                    words.append(
                        WordToken(
                            startMs=int(word.start * 1000),
                            endMs=int(word.end * 1000),
                            text=str(word.word).strip(),
                            probability=getattr(word, "probability", None),
                        )
                    )
            segments.append(
                TranscriptSegment(
                    id=f"seg_{idx}",
                    startMs=int(seg.start * 1000),
                    endMs=int(seg.end * 1000),
                    speakerId=None,
                    text=str(seg.text).strip(),
                    confidence=getattr(seg, "avg_logprob", None),
                    words=words,
                )
            )
        detected_lang = getattr(info, "language", None) or language or "unknown"
        backend = BackendInfo(name="faster-whisper", model=model_name)
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
            asr_backend=BackendInfo(name="faster-whisper-mock", model=request.asrModel),
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
            if msg.startswith("MISSING_FASTER_WHISPER"):
                raise WorkerExecutionError("MODEL_NOT_INSTALLED", "faster-whisper dependency is not installed", {"raw": msg})
            if msg.startswith("MISSING_PYANNOTE"):
                raise WorkerExecutionError("DIARIZATION_MODEL_UNAVAILABLE", "pyannote.audio dependency is not installed", {"raw": msg})
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
