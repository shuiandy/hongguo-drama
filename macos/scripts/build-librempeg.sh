#!/usr/bin/env bash
# Builds the ByteVC2 helper (librempeg, AGPL-3.0) for the native app from pinned upstream source,
# using the upstream build script kept in scripts/librempeg/ (macOS targets only), and stages it where build-app.sh picks it up:
#   vendor/librempeg/<arch>/librempeg  plus licence files and the corresponding-source archive.
#   ./scripts/build-librempeg.sh            this Mac's architecture
#   ARCHS="arm64 x86_64" ./scripts/build-librempeg.sh
# Needs Xcode command line tools, pkg-config and network access (codeload.github.com,
# code.videolan.org). Takes several minutes per architecture.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ARCHS="${ARCHS:-$(uname -m)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
for arch in $ARCHS; do
  case "$arch" in arm64) target=arm64;; x86_64) target=x64;; *) echo "unsupported arch $arch" >&2; exit 1;; esac
  work="$ROOT/vendor/librempeg-build-$arch"
  echo "==> building librempeg for $arch (logs in $work/logs)"
  bash "$ROOT/scripts/librempeg/build-librempeg-source.sh" "$work" "$target" "$JOBS"
  out="$ROOT/vendor/librempeg/$arch"
  mkdir -p "$out"
  cp "$work/artifacts/bin/"* "$out/"
  cp "$work/artifacts/"*-corresponding-source.tar.gz "$out/"
  echo "==> staged $out/librempeg"
done
