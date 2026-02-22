#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV_PATH="${1:-$ROOT/.venv313}"
PYTHON_BIN="${VOXSCRIBE_BOOTSTRAP_PYTHON:-python3}"

echo "Creating venv at: $VENV_PATH"
"$PYTHON_BIN" -m venv "$VENV_PATH"

echo "Installing worker dependencies"
"$VENV_PATH/bin/pip" install --upgrade pip
"$VENV_PATH/bin/pip" install -r "$ROOT/worker/requirements.txt"

cat <<EOF

Done.
Next:
  1) Export HF_TOKEN (for pyannote model access)
  2) Run ./scripts/validate_real_worker.sh --python "$VENV_PATH/bin/python3"
EOF
