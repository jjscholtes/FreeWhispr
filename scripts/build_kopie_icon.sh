#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$ROOT/tmp/icon-build"
MASTER_PNG="$TMP_DIR/FreeWhispr-1024.png"
ICONSET_DIR="$TMP_DIR/FreeWhispr.iconset"
OUT_ICNS="$ROOT/branding/FreeWhispr.icns"
OUT_PREVIEW_PNG="$ROOT/branding/FreeWhispr-1024.png"

mkdir -p "$TMP_DIR"
mkdir -p "$TMP_DIR"/{home,tmp,clang-module-cache,.cache}

export HOME="$TMP_DIR/home"
export TMPDIR="$TMP_DIR/tmp/"
export XDG_CACHE_HOME="$TMP_DIR/.cache"
export CLANG_MODULE_CACHE_PATH="$TMP_DIR/clang-module-cache"

echo "[1/4] Rendering FreeWhispr icon master PNG"
swift "$ROOT/scripts/generate_kopie_icon.swift" --output "$MASTER_PNG"
cp "$MASTER_PNG" "$OUT_PREVIEW_PNG"

echo "[2/4] Building macOS iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

resize() {
  local size="$1"
  local out="$2"
  sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET_DIR/$out" >/dev/null
}

resize 16   icon_16x16.png
resize 32   icon_16x16@2x.png
resize 32   icon_32x32.png
resize 64   icon_32x32@2x.png
resize 128  icon_128x128.png
resize 256  icon_128x128@2x.png
resize 256  icon_256x256.png
resize 512  icon_256x256@2x.png
resize 512  icon_512x512.png
resize 1024 icon_512x512@2x.png

echo "[3/4] Compiling .icns"
iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"

echo "[4/4] Done"
echo "Icon:    $OUT_ICNS"
echo "Preview: $OUT_PREVIEW_PNG"
