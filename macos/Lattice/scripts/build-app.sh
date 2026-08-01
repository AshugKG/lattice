#!/bin/sh
set -eu

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
MODULE_CACHE_DIR="$PACKAGE_DIR/.cache/clang"
BUILD_DIR="$PACKAGE_DIR/.build"

mkdir -p "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

swift build --disable-sandbox --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_DIR" -c "$CONFIGURATION"
BIN_DIR=$(swift build --disable-sandbox --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_DIR" -c "$CONFIGURATION" --show-bin-path)
APP_DIR="$PACKAGE_DIR/build/Lattice.app"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Lattice" "$APP_DIR/Contents/MacOS/Lattice"
cp "$PACKAGE_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PACKAGE_DIR/../../src-tauri/icons/icon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR"

echo "$APP_DIR"
