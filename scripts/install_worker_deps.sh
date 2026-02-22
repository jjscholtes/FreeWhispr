#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV_PATH="$ROOT/.venv313"
PYTHON_BIN="${VOXSCRIBE_BOOTSTRAP_PYTHON:-python3}"
MODE="all"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --venv <path>         Target venv path (default: $ROOT/.venv313)
  --python <path>       Python executable to create venv (default: $PYTHON_BIN)
  --diarization-only    Install only diarization dependencies (current worker runtime split mode)
  --all                 Install full worker dependencies (default)
  -h, --help            Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --venv)
      VENV_PATH="${2:-}"
      shift 2
      ;;
    --python)
      PYTHON_BIN="${2:-}"
      shift 2
      ;;
    --diarization-only)
      MODE="diarization-only"
      shift
      ;;
    --all)
      MODE="all"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      # Backward-compatible positional venv path
      VENV_PATH="$1"
      shift
      ;;
  esac
done

echo "Creating venv at: $VENV_PATH"
"$PYTHON_BIN" -m venv "$VENV_PATH"

echo "Installing worker dependencies"
"$VENV_PATH/bin/pip" install --upgrade pip
case "$MODE" in
  diarization-only|all)
    "$VENV_PATH/bin/pip" install -r "$ROOT/worker/requirements.txt"
    ;;
  *)
    echo "Unsupported mode: $MODE" >&2
    exit 1
    ;;
esac

cat <<EOF

Done.
Next:
  1) Export HF_TOKEN (for pyannote model access)
  2) Run ./scripts/validate_real_worker.sh --python "$VENV_PATH/bin/python3"
EOF
