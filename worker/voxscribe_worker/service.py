from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import os
import threading
import time
import traceback
from typing import Any, Callable

from .models import envelope, JobRequest, WorkerError, PIPELINE_VERSION
from .pipeline import ProcessingPipeline, PipelineContext, WorkerExecutionError


EmitFn = Callable[[dict[str, Any]], None]


@dataclass
class JobHandle:
    job_id: str
    request_id: str
    thread: threading.Thread
    cancel_event: threading.Event


class WorkerService:
    def __init__(self, emit: EmitFn):
        self._emit = emit
        self._lock = threading.Lock()
        self._current_job: JobHandle | None = None

    def _set_current_job(self, handle: JobHandle | None) -> None:
        with self._lock:
            self._current_job = handle

    def _get_current_job(self) -> JobHandle | None:
        with self._lock:
            return self._current_job

    def wait_for_current_job(self, timeout: float | None = None) -> None:
        handle = self._get_current_job()
        if handle is None:
            return
        handle.thread.join(timeout=timeout)

    def _emit_event(self, request_id: str, command: str, payload: dict[str, Any]) -> None:
        self._emit(envelope("event", request_id, command, payload))

    def handle_command(self, request_id: str, command: str, payload: dict[str, Any]) -> None:
        if command == "health_check":
            self._emit(
                envelope(
                    "response",
                    request_id,
                    command,
                    {
                        "status": "ok",
                        "service": "freewhispr-worker",
                        "pipelineVersion": PIPELINE_VERSION,
                        "pid": os.getpid(),
                    },
                )
            )
            return

        if command == "get_capabilities":
            pipeline = ProcessingPipeline(PipelineContext(cancel_requested=lambda: False))
            self._emit(envelope("response", request_id, command, pipeline.capabilities()))
            return

        if command == "validate_setup":
            pipeline = ProcessingPipeline(PipelineContext(cancel_requested=lambda: False))
            self._emit(envelope("response", request_id, command, pipeline.validate_setup()))
            return

        if command == "cancel_job":
            current = self._get_current_job()
            if current is None:
                self._emit(envelope("response", request_id, command, {"status": "noop", "message": "No running job"}))
                return
            current.cancel_event.set()
            self._emit(
                envelope(
                    "response",
                    request_id,
                    command,
                    {"status": "ok", "message": f"Cancellation requested for {current.job_id}", "jobId": current.job_id},
                )
            )
            return

        if command == "run_transcription_job":
            current = self._get_current_job()
            if current is not None and current.thread.is_alive():
                self._emit(
                    envelope(
                        "error",
                        request_id,
                        command,
                        WorkerError(
                            code="JOB_ALREADY_RUNNING",
                            message="A transcription job is already running",
                            details={"jobId": current.job_id},
                        ).to_dict(),
                    )
                )
                return

            request = JobRequest.from_payload(payload)
            cancel_event = threading.Event()
            handle = JobHandle(
                job_id=request.jobId,
                request_id=request_id,
                cancel_event=cancel_event,
                thread=threading.Thread(
                    target=self._run_job_thread,
                    args=(request_id, command, request, cancel_event),
                    daemon=True,
                ),
            )
            self._set_current_job(handle)
            handle.thread.start()
            self._emit(envelope("response", request_id, command, {"status": "accepted", "jobId": request.jobId}))
            return

        self._emit(
            envelope(
                "error",
                request_id,
                command,
                WorkerError(code="UNKNOWN_COMMAND", message=f"Unsupported command: {command}").to_dict(),
            )
        )

    def _run_job_thread(self, request_id: str, command: str, request: JobRequest, cancel_event: threading.Event) -> None:
        start_time = time.time()
        output_dir = Path(request.outputDir)
        (output_dir / "processing").mkdir(parents=True, exist_ok=True)
        log_path = output_dir / "processing" / "worker.log"
        metrics_path = output_dir / "processing" / "metrics.json"

        def append_log(message: str) -> None:
            timestamp = time.strftime("%Y-%m-%dT%H:%M:%S")
            with log_path.open("a", encoding="utf-8") as fh:
                fh.write(f"[{timestamp}] {message}\n")

        self._emit_event(
            request_id,
            command,
            {"event": "job_started", "jobId": request.jobId, "sessionId": request.sessionId},
        )
        append_log(f"job_started jobId={request.jobId}")

        pipeline = ProcessingPipeline(PipelineContext(cancel_requested=cancel_event.is_set))

        def on_progress(stage: str, fraction: float, message: str) -> None:
            self._emit_event(
                request_id,
                command,
                {
                    "event": "job_progress",
                    "jobId": request.jobId,
                    "stage": stage,
                    "progress": max(0.0, min(1.0, fraction)),
                    "message": message,
                },
            )
            append_log(f"progress stage={stage} progress={fraction:.3f} message={message}")

        try:
            result = pipeline.run_job(request, on_progress)
            metrics = result["metrics"]
            metrics["workerRuntimeSec"] = round(time.time() - start_time, 4)
            metrics_path.write_text(json.dumps(metrics, indent=2), encoding="utf-8")

            self._emit_event(
                request_id,
                command,
                {
                    "event": "job_completed",
                    "jobId": request.jobId,
                    "transcriptPath": result["exportPaths"]["json"],
                    "metricsPath": str(metrics_path),
                    "warnings": result.get("warnings", []),
                    "detectedLanguage": result["document"].sourceLanguage,
                },
            )
            self._emit(
                envelope(
                    "response",
                    request_id,
                    command,
                    {
                        "status": "completed",
                        "jobId": request.jobId,
                        "transcriptPath": result["exportPaths"]["json"],
                        "metricsPath": str(metrics_path),
                        "exportPaths": result["exportPaths"],
                        "detectedLanguage": result["document"].sourceLanguage,
                        "warnings": result.get("warnings", []),
                    },
                )
            )
        except WorkerExecutionError as exc:
            err = exc.to_worker_error()
            append_log(f"job_failed code={err.code} message={err.message}")
            self._emit_event(
                request_id,
                command,
                {"event": "job_failed", "jobId": request.jobId, "error": err.to_dict()},
            )
            self._emit(envelope("error", request_id, command, err.to_dict()))
        except RuntimeError as exc:
            if str(exc) == "JOB_CANCELLED":
                append_log("job_cancelled")
                self._emit_event(
                    request_id,
                    command,
                    {"event": "job_failed", "jobId": request.jobId, "error": {"code": "JOB_CANCELLED", "message": "Job cancelled"}},
                )
                self._emit(
                    envelope(
                        "response",
                        request_id,
                        command,
                        {"status": "cancelled", "jobId": request.jobId, "metricsPath": str(metrics_path)},
                    )
                )
            else:
                tb = traceback.format_exc()
                append_log(f"job_failed unexpected={exc}\n{tb}")
                err = WorkerError(code="UNKNOWN_PROCESSING_ERROR", message=str(exc))
                self._emit_event(request_id, command, {"event": "job_failed", "jobId": request.jobId, "error": err.to_dict()})
                self._emit(envelope("error", request_id, command, err.to_dict()))
        except Exception as exc:  # pragma: no cover - safety net
            tb = traceback.format_exc()
            append_log(f"job_failed unexpected={exc}\n{tb}")
            err = WorkerError(code="UNKNOWN_PROCESSING_ERROR", message=str(exc))
            self._emit_event(request_id, command, {"event": "job_failed", "jobId": request.jobId, "error": err.to_dict()})
            self._emit(envelope("error", request_id, command, err.to_dict()))
        finally:
            self._set_current_job(None)
