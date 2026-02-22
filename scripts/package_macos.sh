#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${FREEWHISPR_APP_NAME:-${VOXSCRIBE_APP_NAME:-FreeWhispr}}"
BUNDLE_ID="${FREEWHISPR_BUNDLE_ID:-${VOXSCRIBE_BUNDLE_ID:-com.jesse.voxscribe}}"
APP_ICON_ICNS="${FREEWHISPR_APP_ICON_ICNS:-${VOXSCRIBE_APP_ICON_ICNS:-$ROOT/branding/FreeWhispr.icns}}"
APP_PKG_PATH="$ROOT/app"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
BUILD_CONFIGURATION="${VOXSCRIBE_BUILD_CONFIGURATION:-release}"
BUILD_EXECUTABLE=""
ZIP_PATH="$DIST_DIR/${APP_NAME}.zip"
DMG_PATH="$DIST_DIR/${APP_NAME}.dmg"
DMG_STAGE_DIR="$DIST_DIR/.dmg-stage-${APP_NAME}"
SKIP_BUILD=0
WORKER_VENV_PATH="${FREEWHISPR_WORKER_VENV_PATH:-${VOXSCRIBE_WORKER_VENV_PATH:-}}"
WHISPERCPP_BIN_PATH="${FREEWHISPR_WHISPERCPP_BIN_PATH:-}"
WHISPERCPP_MODEL_DIR="${FREEWHISPR_WHISPERCPP_MODEL_DIR:-}"
SIGN_IDENTITY="${FREEWHISPR_CODESIGN_IDENTITY:-${VOXSCRIBE_CODESIGN_IDENTITY:-}}"
NOTARY_PROFILE="${FREEWHISPR_NOTARY_PROFILE:-${VOXSCRIBE_NOTARY_PROFILE:-}}"
OMIT_DIARIZATION_RUNTIME=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --skip-build                 Reuse existing app/.build/<configuration>/$APP_NAME
  --configuration <name>       Swift build configuration (release|debug). Default: $BUILD_CONFIGURATION
  --worker-venv <path>         Copy a prepared Python venv into app bundle Resources/worker_runtime
  --omit-diarization-runtime   Skip bundling Python diarization runtime (smaller app; install on demand)
  --whispercpp-bin <path>      Copy a built whisper.cpp CLI binary into app bundle Resources/whispercpp
  --whispercpp-model-dir <p>   Optionally copy whisper.cpp models dir into app bundle Resources/whispercpp/models
  --sign-identity <name>       Codesign app bundle with Developer ID identity
  --notary-profile <profile>   Run xcrun notarytool submit --keychain-profile <profile> and staple
  --bundle-id <id>             Override CFBundleIdentifier (default: $BUNDLE_ID)
  --help                       Show this help

Environment overrides (preferred names):
  FREEWHISPR_WORKER_PYTHON       Runtime override for local testing (not baked into bundle)
  FREEWHISPR_BUNDLE_ID           Default bundle identifier
  FREEWHISPR_CODESIGN_IDENTITY   Default codesign identity
  FREEWHISPR_NOTARY_PROFILE      Default notarytool keychain profile
  FREEWHISPR_WORKER_VENV_PATH    Default path for --worker-venv
  FREEWHISPR_WHISPERCPP_BIN_PATH Default path for --whispercpp-bin
  FREEWHISPR_WHISPERCPP_MODEL_DIR Default path for --whispercpp-model-dir

Legacy compatibility env names with VOXSCRIBE_* prefixes are still accepted.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --configuration)
      BUILD_CONFIGURATION="${2:-}"
      shift 2
      ;;
    --worker-venv)
      WORKER_VENV_PATH="${2:-}"
      shift 2
      ;;
    --omit-diarization-runtime)
      OMIT_DIARIZATION_RUNTIME=1
      shift
      ;;
    --whispercpp-bin)
      WHISPERCPP_BIN_PATH="${2:-}"
      shift 2
      ;;
    --whispercpp-model-dir)
      WHISPERCPP_MODEL_DIR="${2:-}"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
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

if [[ "$BUILD_CONFIGURATION" != "release" && "$BUILD_CONFIGURATION" != "debug" ]]; then
  echo "Unsupported configuration: $BUILD_CONFIGURATION (use release or debug)" >&2
  exit 1
fi

BUILD_EXECUTABLE="$APP_PKG_PATH/.build/$BUILD_CONFIGURATION/$APP_NAME"

mkdir -p "$DIST_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "[1/6] Building $BUILD_CONFIGURATION executable"
  CACHE_ROOT="$ROOT/tmp/swift-package-env"
  mkdir -p "$CACHE_ROOT"/{home,tmp,clang-module-cache,swiftpm-module-cache,.cache}
  export HOME="$CACHE_ROOT/home"
  export TMPDIR="$CACHE_ROOT/tmp/"
  export XDG_CACHE_HOME="$CACHE_ROOT/.cache"
  export CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang-module-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/swiftpm-module-cache"
  set +e
  BUILD_OUTPUT="$(swift build --package-path "$APP_PKG_PATH" -c "$BUILD_CONFIGURATION" 2>&1)"
  BUILD_STATUS=$?
  set -e
  printf '%s\n' "$BUILD_OUTPUT"
  if [[ "$BUILD_STATUS" -ne 0 ]]; then
    if grep -q "this SDK is not supported by the compiler" <<<"$BUILD_OUTPUT"; then
      cat <<'EOF' >&2

Swift compiler / macOS SDK mismatch detected while building the app for packaging.
Fix by selecting/updating a matching Xcode + Command Line Tools installation, then rerun this script.
EOF
    fi
    exit "$BUILD_STATUS"
  fi
fi

if [[ ! -x "$BUILD_EXECUTABLE" ]]; then
  echo "Release executable not found: $BUILD_EXECUTABLE" >&2
  exit 1
fi

echo "[2/6] Staging app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$BUILD_EXECUTABLE" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ -f "$APP_ICON_ICNS" ]]; then
  cp "$APP_ICON_ICNS" "$RES_DIR/$APP_NAME.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_NAME</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>FreeWhispr records microphone audio to create local transcripts.</string>
</dict>
</plist>
EOF

echo "[3/6] Copying worker sidecar resources"
cp -R "$ROOT/worker" "$RES_DIR/worker"
find "$RES_DIR/worker" -name "__pycache__" -type d -prune -exec rm -rf {} +
rm -rf "$RES_DIR/worker/tests"
if [[ -f "$RES_DIR/worker/voxscribe_worker.py" ]]; then
  chmod +x "$RES_DIR/worker/voxscribe_worker.py"
fi

mkdir -p "$RES_DIR/installers"
cp "$ROOT/scripts/install_worker_deps.sh" "$RES_DIR/installers/install_worker_deps.sh"
chmod +x "$RES_DIR/installers/install_worker_deps.sh"

if [[ "$OMIT_DIARIZATION_RUNTIME" -eq 1 ]]; then
  echo "[4/6] Skipping bundled diarization runtime (--omit-diarization-runtime)"
  rm -rf "$RES_DIR/worker_runtime"
elif [[ -n "$WORKER_VENV_PATH" ]]; then
  echo "[4/6] Copying worker runtime from $WORKER_VENV_PATH"
  if [[ ! -d "$WORKER_VENV_PATH" ]]; then
    echo "Worker venv path does not exist: $WORKER_VENV_PATH" >&2
    exit 1
  fi
  rm -rf "$RES_DIR/worker_runtime"
  cp -R "$WORKER_VENV_PATH" "$RES_DIR/worker_runtime"
else
  echo "[4/6] No worker venv specified (bundle will use system python or VOXSCRIBE_WORKER_PYTHON override)"
fi

if [[ -z "$WHISPERCPP_BIN_PATH" ]]; then
  for candidate in \
    "$ROOT/vendor/whisper.cpp/build/bin/whisper-cli" \
    "$ROOT/whisper.cpp/build/bin/whisper-cli" \
    "$ROOT/vendor/whisper.cpp/build/bin/main" \
    "$ROOT/whisper.cpp/build/bin/main"
  do
    if [[ -x "$candidate" ]]; then
      WHISPERCPP_BIN_PATH="$candidate"
      break
    fi
  done
fi

if [[ -n "$WHISPERCPP_BIN_PATH" ]]; then
  echo "[4b/6] Copying whisper.cpp runtime from $WHISPERCPP_BIN_PATH"
  if [[ ! -x "$WHISPERCPP_BIN_PATH" ]]; then
    echo "whisper.cpp binary is not executable: $WHISPERCPP_BIN_PATH" >&2
    exit 1
  fi
  WHISPERCPP_RES_DIR="$RES_DIR/whispercpp"
  mkdir -p "$WHISPERCPP_RES_DIR"
  cp "$WHISPERCPP_BIN_PATH" "$WHISPERCPP_RES_DIR/whisper-cli"
  chmod +x "$WHISPERCPP_RES_DIR/whisper-cli"

  WHISPERCPP_BIN_DIR="$(cd "$(dirname "$WHISPERCPP_BIN_PATH")" && pwd)"
  for pattern in "ggml-metal"*".metal" "ggml-metal"*".metallib" "ggml-metal"*; do
    for sidecar in "$WHISPERCPP_BIN_DIR"/$pattern; do
      [[ -e "$sidecar" ]] || continue
      [[ -f "$sidecar" ]] || continue
      cp "$sidecar" "$WHISPERCPP_RES_DIR/"
    done
  done

  if [[ -n "$WHISPERCPP_MODEL_DIR" ]]; then
    echo "[4c/6] Copying whisper.cpp models from $WHISPERCPP_MODEL_DIR"
    if [[ ! -d "$WHISPERCPP_MODEL_DIR" ]]; then
      echo "whisper.cpp model dir does not exist: $WHISPERCPP_MODEL_DIR" >&2
      exit 1
    fi
    rm -rf "$WHISPERCPP_RES_DIR/models"
    cp -R "$WHISPERCPP_MODEL_DIR" "$WHISPERCPP_RES_DIR/models"
  fi
else
  echo "[4b/6] No whisper.cpp binary specified/found (skipping whisper.cpp runtime bundling)"
fi

echo "[5/7] Creating distribution zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "[6/7] Codesigning app bundle with identity: $SIGN_IDENTITY"
  codesign --force --timestamp --options runtime --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
else
  echo "[6/7] Skipping codesign (no --sign-identity provided)"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Notarization requires a signed app. Provide --sign-identity." >&2
    exit 1
  fi
  echo "[notary] Submitting zip with profile: $NOTARY_PROFILE"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
fi

echo "[7/7] Creating distribution DMG"
rm -f "$DMG_PATH"
rm -rf "$DMG_STAGE_DIR"
mkdir -p "$DMG_STAGE_DIR"
cp -R "$APP_BUNDLE" "$DMG_STAGE_DIR/"
ln -s /Applications "$DMG_STAGE_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGE_DIR"

echo
echo "Bundle ready: $APP_BUNDLE"
echo "Archive:      $ZIP_PATH"
echo "DMG:          $DMG_PATH"
echo "Worker entrypoint in bundle: Contents/Resources/worker/<internal worker script>"
echo "Optional bundled runtime path: Contents/Resources/worker_runtime/bin/python3"
echo "Optional whisper.cpp runtime path: Contents/Resources/whispercpp/whisper-cli"
