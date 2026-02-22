from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import uuid
from typing import Any

from .service import WorkerService
from .models import envelope, WorkerError


class Emitter:
    def __init__(self) -> None:
        self._lock = threading.Lock()

    def emit(self, message: dict[str, Any]) -> None:
        line = json.dumps(message, ensure_ascii=False)
        with self._lock:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()


def _parse_line(line: str) -> dict[str, Any]:
    try:
        return json.loads(line)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON: {exc}") from exc


def run(stdin: Any = None) -> int:
    stdin = stdin or sys.stdin
    _configure_default_cache_environment()
    emitter = Emitter()
    service = WorkerService(emitter.emit)

    emitter.emit(
        envelope(
            "event",
            None,
            "worker_boot",
            {
                "event": "worker_ready",
                "service": "freewhispr-worker",
                "pid": os.getpid(),
                "session": str(uuid.uuid4()),
            },
        )
    )

    for raw in stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            msg = _parse_line(line)
            request_id = str(msg.get("requestId") or uuid.uuid4())
            command = msg.get("command")
            payload = msg.get("payload", {})
            if not isinstance(command, str):
                raise ValueError("Missing or invalid 'command'")
            if not isinstance(payload, dict):
                raise ValueError("Invalid 'payload'; expected object")
            service.handle_command(request_id, command, payload)
        except Exception as exc:
            emitter.emit(
                envelope(
                    "error",
                    None,
                    "parse_message",
                    WorkerError(code="INVALID_MESSAGE", message=str(exc)).to_dict(),
                )
            )
    # Allow a one-shot stdin producer to close without terminating an accepted job early.
    service.wait_for_current_job()
    return 0


def _configure_default_cache_environment() -> None:
    cache_root = os.path.join(tempfile.gettempdir(), "freewhispr-worker-cache")
    mpl_dir = os.path.join(cache_root, "matplotlib")
    xdg_dir = os.path.join(cache_root, "xdg-cache")
    hf_dir = os.path.join(cache_root, "huggingface")
    torch_dir = os.path.join(cache_root, "torch")
    for path in (mpl_dir, xdg_dir, hf_dir, torch_dir):
        os.makedirs(path, exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", mpl_dir)
    os.environ.setdefault("XDG_CACHE_HOME", xdg_dir)
    os.environ.setdefault("HF_HOME", hf_dir)
    os.environ.setdefault("HUGGINGFACE_HUB_CACHE", os.path.join(hf_dir, "hub"))
    os.environ.setdefault("TORCH_HOME", torch_dir)


def main() -> None:
    raise SystemExit(run())


if __name__ == "__main__":
    main()
