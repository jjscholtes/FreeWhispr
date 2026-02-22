#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${VOXSCRIBE_APP_NAME:-Kopie}"
BUNDLE_ID="${VOXSCRIBE_BUNDLE_ID:-com.jesse.voxscribe}"
APP_ICON_ICNS="${VOXSCRIBE_APP_ICON_ICNS:-$ROOT/branding/Kopie.icns}"
APP_PKG_PATH="$ROOT/app"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
BUILD_CONFIGURATION="${VOXSCRIBE_BUILD_CONFIGURATION:-release}"
BUILD_EXECUTABLE=""
ZIP_PATH="$DIST_DIR/${APP_NAME}.zip"
SKIP_BUILD=0
WORKER_VENV_PATH="${VOXSCRIBE_WORKER_VENV_PATH:-}"
SIGN_IDENTITY="${VOXSCRIBE_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${VOXSCRIBE_NOTARY_PROFILE:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --skip-build                 Reuse existing app/.build/<configuration>/$APP_NAME
  --configuration <name>       Swift build configuration (release|debug). Default: $BUILD_CONFIGURATION
  --worker-venv <path>         Copy a prepared Python venv into app bundle Resources/worker_runtime
  --sign-identity <name>       Codesign app bundle with Developer ID identity
  --notary-profile <profile>   Run xcrun notarytool submit --keychain-profile <profile> and staple
  --bundle-id <id>             Override CFBundleIdentifier (default: $BUNDLE_ID)
  --help                       Show this help

Environment overrides:
  VOXSCRIBE_WORKER_PYTHON       Runtime override for local testing (not baked into bundle)
  VOXSCRIBE_BUNDLE_ID           Default bundle identifier
  VOXSCRIBE_CODESIGN_IDENTITY   Default codesign identity
  VOXSCRIBE_NOTARY_PROFILE      Default notarytool keychain profile
  VOXSCRIBE_WORKER_VENV_PATH    Default path for --worker-venv
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
  <string>Kopie records microphone audio to create local transcripts.</string>
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

if [[ -n "$WORKER_VENV_PATH" ]]; then
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

echo "[5/6] Creating distribution zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "[6/6] Codesigning app bundle with identity: $SIGN_IDENTITY"
  codesign --force --timestamp --options runtime --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
else
  echo "[6/6] Skipping codesign (no --sign-identity provided)"
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

echo
echo "Bundle ready: $APP_BUNDLE"
echo "Archive:      $ZIP_PATH"
echo "Worker path in bundle: Contents/Resources/worker/voxscribe_worker.py"
echo "Optional bundled runtime path: Contents/Resources/worker_runtime/bin/python3"
