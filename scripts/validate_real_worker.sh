#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKER="$ROOT/worker/voxscribe_worker.py"
OUT_DIR="$ROOT/tmp/real-worker-validation"
PYTHON_BIN="${VOXSCRIBE_WORKER_PYTHON:-}"
AUDIO_PATH=""
RUN_JOB=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--python <path>] [--audio <path>]

Runs worker setup validation with the real (non-mock) pipeline path. If --audio is provided,
it also runs a transcription job with mockMode=false and VOXSCRIBE_ALLOW_STUB_PIPELINE=0.

Prerequisites:
  - faster-whisper + pyannote.audio installed in the chosen Python environment
  - HF_TOKEN or HUGGINGFACE_HUB_TOKEN exported (for diarization)

Examples:
  ./scripts/validate_real_worker.sh
  HF_TOKEN=... ./scripts/validate_real_worker.sh --python ./.venv313/bin/python3 --audio /path/to/sample.wav
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python)
      PYTHON_BIN="${2:-}"
      shift 2
      ;;
    --audio)
      AUDIO_PATH="${2:-}"
      RUN_JOB=1
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PYTHON_BIN" ]]; then
  for candidate in "$ROOT/.venv313/bin/python3" "$ROOT/.venv/bin/python3" "$ROOT/app/.venv313/bin/python3" "$ROOT/app/.venv/bin/python3" "$(command -v python3)"; do
    if [[ -n "${candidate:-}" && -x "${candidate:-}" ]]; then
      PYTHON_BIN="$candidate"
      break
    fi
  done
fi

if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
  echo "Could not resolve a Python executable. Use --python <path>." >&2
  exit 1
fi

echo "Using Python: $PYTHON_BIN"
echo "Running validate_setup..."
printf '%s\n' '{"type":"request","requestId":"validate-1","command":"validate_setup","payload":{}}' \
  | "$PYTHON_BIN" "$WORKER"

if [[ "$RUN_JOB" -eq 1 ]]; then
  if [[ ! -f "$AUDIO_PATH" ]]; then
    echo "Audio file not found: $AUDIO_PATH" >&2
    exit 1
  fi
  mkdir -p "$OUT_DIR"
  echo
  echo "Running real transcription job (mock disabled)..."
  env VOXSCRIBE_ALLOW_STUB_PIPELINE=0 \
    "$PYTHON_BIN" "$WORKER" <<EOF
{"type":"request","requestId":"real-job-1","command":"run_transcription_job","payload":{"jobId":"99999999-9999-9999-9999-999999999999","sessionId":"88888888-8888-8888-8888-888888888888","audioPath":"$AUDIO_PATH","outputDir":"$OUT_DIR","languageMode":"auto","profile":"fast","asrModel":"turbo","diarizationEnabled":true,"wordTimestamps":true,"mockMode":false}}
EOF
  echo
  echo "Outputs written under: $OUT_DIR"
fi
