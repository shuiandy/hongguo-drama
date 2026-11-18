#!/usr/bin/env bash
# Builds HongguoDrama.app from the Swift package.
#   ./scripts/build-app.sh            release build, ad-hoc signed, into ./build
#   SIGN_IDENTITY="Developer ID Application: ..." ./scripts/build-app.sh
#   ARCHS="arm64 x86_64" ./scripts/build-app.sh   universal binary
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS:-$(uname -m)}"
OUT="${OUT:-$ROOT/build}"
APP="$OUT/HongguoDrama.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

echo "==> swift build ($CONFIG, $ARCHS)"
swift build -c "$CONFIG" "${arch_flags[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${arch_flags[@]}" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/HongguoDrama" "$APP/Contents/MacOS/HongguoDrama"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi
# SwiftPM resource bundles, if any target adds resources later.
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

echo "==> codesign ($SIGN_IDENTITY)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "==> done: $APP"
