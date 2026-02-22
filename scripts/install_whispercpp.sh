#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$ROOT/vendor/whisper.cpp"
REF="${WHISPERCPP_REF:-master}"
BUILD_TYPE="${WHISPERCPP_BUILD_TYPE:-Release}"
METAL=1
COREML=0
UPDATE_REPO=1
CLEAN_BUILD=0
DOWNLOAD_MODEL=""
JOBS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build whisper.cpp locally for FreeWhispr (macOS) with Metal enabled by default.

Options:
  --repo-dir <path>        Clone/build whisper.cpp in this directory (default: $REPO_DIR)
  --ref <git-ref>          Git branch/tag/commit to checkout (default: $REF)
  --no-update              Do not fetch/pull repository updates if repo already exists
  --clean                  Remove existing build directory before configuring
  --no-metal               Build without Metal support (not recommended on Apple Silicon)
  --coreml                 Enable Core ML support in whisper.cpp build (optional)
  --download-model <name>  Run whisper.cpp's model downloader after build (e.g. large-v3-turbo)
  --jobs <n>               Parallel build jobs (default: auto)
  --help                   Show this help

Environment:
  WHISPERCPP_REF           Default git ref for --ref
  WHISPERCPP_BUILD_TYPE    Default build type (Release/Debug)

After a successful build, FreeWhispr can use the binary via:
  FREEWHISPR_WHISPERCPP_BIN=<path-to-whisper-cli>
  FREEWHISPR_WHISPERCPP_MODEL_DIR=<path-to-whisper-models-dir>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir)
      REPO_DIR="${2:-}"
      shift 2
      ;;
    --ref)
      REF="${2:-}"
      shift 2
      ;;
    --no-update)
      UPDATE_REPO=0
      shift
      ;;
    --clean)
      CLEAN_BUILD=1
      shift
      ;;
    --no-metal)
      METAL=0
      shift
      ;;
    --coreml)
      COREML=1
      shift
      ;;
    --download-model)
      DOWNLOAD_MODEL="${2:-}"
      shift 2
      ;;
    --jobs)
      JOBS="${2:-}"
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

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 1
fi

if command -v cmake >/dev/null 2>&1; then
  CMAKE_BIN="$(command -v cmake)"
elif [[ -x /opt/homebrew/bin/cmake ]]; then
  CMAKE_BIN="/opt/homebrew/bin/cmake"
else
  echo "cmake is required (install Xcode CLT + Homebrew cmake)" >&2
  exit 1
fi

mkdir -p "$(dirname "$REPO_DIR")"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "[1/5] Cloning whisper.cpp into $REPO_DIR"
  git clone https://github.com/ggml-org/whisper.cpp "$REPO_DIR"
else
  echo "[1/5] whisper.cpp repo already exists at $REPO_DIR"
fi

if [[ "$UPDATE_REPO" -eq 1 ]]; then
  echo "[2/5] Fetching repository updates"
  git -C "$REPO_DIR" fetch --tags --prune
else
  echo "[2/5] Skipping repository fetch (--no-update)"
fi

echo "[3/5] Checking out $REF"
git -C "$REPO_DIR" checkout "$REF"
if [[ "$UPDATE_REPO" -eq 1 ]]; then
  # Best effort fast-forward if checkout is a branch.
  git -C "$REPO_DIR" pull --ff-only || true
fi

BUILD_DIR="$REPO_DIR/build"
if [[ "$CLEAN_BUILD" -eq 1 ]]; then
  rm -rf "$BUILD_DIR"
fi

echo "[4/5] Configuring whisper.cpp (Metal=$([[ "$METAL" -eq 1 ]] && echo ON || echo OFF), CoreML=$([[ "$COREML" -eq 1 ]] && echo ON || echo OFF))"
"$CMAKE_BIN" -S "$REPO_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DWHISPER_METAL="$([[ "$METAL" -eq 1 ]] && echo ON || echo OFF)" \
  -DWHISPER_COREML="$([[ "$COREML" -eq 1 ]] && echo ON || echo OFF)"

echo "[5/5] Building whisper.cpp"
BUILD_CMD=("$CMAKE_BIN" --build "$BUILD_DIR" --config "$BUILD_TYPE")
if [[ -n "$JOBS" ]]; then
  BUILD_CMD+=(--parallel "$JOBS")
else
  BUILD_CMD+=(--parallel)
fi
"${BUILD_CMD[@]}"

BIN_DIR="$BUILD_DIR/bin"
WHISPER_BIN=""
for candidate in "$BIN_DIR/whisper-cli" "$BIN_DIR/main"; do
  if [[ -x "$candidate" ]]; then
    WHISPER_BIN="$candidate"
    break
  fi
done

if [[ -z "$WHISPER_BIN" ]]; then
  echo "Build completed, but whisper.cpp CLI binary was not found in $BIN_DIR" >&2
  exit 1
fi

if [[ -n "$DOWNLOAD_MODEL" ]]; then
  DOWNLOADER="$REPO_DIR/models/download-ggml-model.sh"
  if [[ -x "$DOWNLOADER" ]]; then
    echo "[extra] Downloading model: $DOWNLOAD_MODEL"
    (cd "$REPO_DIR" && ./models/download-ggml-model.sh "$DOWNLOAD_MODEL")
  else
    echo "Model downloader not found at $DOWNLOADER (skipping model download)" >&2
  fi
fi

echo
echo "whisper.cpp build complete"
echo "Binary:    $WHISPER_BIN"
echo "Bin dir:   $BIN_DIR"
echo "Models dir (default): $REPO_DIR/models"
echo
echo "For FreeWhispr local testing:"
echo "  export FREEWHISPR_WHISPERCPP_BIN=\"$WHISPER_BIN\""
echo "  export FREEWHISPR_WHISPERCPP_MODEL_DIR=\"$REPO_DIR/models\""
echo
echo "If you package the app, pass the binary into the packaging script:"
echo "  ./scripts/package_macos.sh --whispercpp-bin \"$WHISPER_BIN\" ..."
