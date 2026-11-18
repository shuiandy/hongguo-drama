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
# Signing identity. Without SIGN_IDENTITY, a stable local identity is preferred over ad-hoc:
# an ad-hoc signature changes on every build, so macOS forgets the keychain "Always Allow"
# and asks for the login password again after each rebuild.
#   1. "Hongguo Drama Local Signing" (made by ./scripts/make-local-signing-cert.sh)
#   2. an "Apple Development" identity already in the login keychain
#   3. ad-hoc ("-")
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for name in "Hongguo Drama Local Signing" "Apple Development"; do
    hash="$(printf '%s\n' "$identities" | grep -F "\"$name" | head -n1 | awk '{print $2}' || true)"
    if [[ -n "$hash" ]]; then SIGN_IDENTITY="$hash"; SIGN_NAME="$name"; break; fi
  done
  if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="-"
    echo "note: no stable signing identity found, signing ad-hoc (the keychain will ask again after each rebuild)."
    echo "      run ./scripts/make-local-signing-cert.sh once to fix that."
  fi
fi
SIGN_NAME="${SIGN_NAME:-$SIGN_IDENTITY}"

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

echo "==> codesign ($SIGN_NAME)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
elif [[ "$SIGN_NAME" == *"Developer ID"* ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  # Local or development identity: stable designated requirement, no notarization timestamp.
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "==> done: $APP"
