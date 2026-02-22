#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
CACHE_ROOT="$ROOT/tmp/swift-test-env"
LOG_FILE="$CACHE_ROOT/swift-test.log"

mkdir -p "$CACHE_ROOT"/{home,tmp,clang-module-cache,swiftpm-module-cache,build,.cache}

export HOME="$CACHE_ROOT/home"
export TMPDIR="$CACHE_ROOT/tmp/"
export XDG_CACHE_HOME="$CACHE_ROOT/.cache"
export CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/swiftpm-module-cache"
export SWIFTPM_BUILD_DIR="$CACHE_ROOT/build"

set +e
swift test --package-path "$APP_DIR" "$@" 2>&1 | tee "$LOG_FILE"
STATUS=${PIPESTATUS[0]}
set -e

if [[ "$STATUS" -ne 0 ]]; then
  if grep -q "this SDK is not supported by the compiler" "$LOG_FILE"; then
    cat <<'EOF' >&2

Swift compiler / macOS SDK mismatch detected.
The writable cache workaround is applied by this script, but your installed compiler and Command Line Tools SDK do not match.

Fix on macOS:
  1) Update Xcode and/or Command Line Tools so compiler + SDK versions match
  2) Select the intended toolchain: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  3) Re-run: ./scripts/swift_test.sh
EOF
  fi
fi

exit "$STATUS"
