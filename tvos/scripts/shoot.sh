#!/bin/bash
# Screenshot app screens on a booted Apple TV simulator, into docs/screenshots/.
#
#   scripts/shoot.sh <udid> <label> [route ...]
#
# Routes are `-HongguoRoute` values; the default set covers every tab. Runs offline (sample rows)
# and muted. HONGGUO_SHOOT_LIVE=1 uses the real service instead, HONGGUO_SHOOT_WAIT sets the
# seconds to wait before each shot and HONGGUO_SHOOT_ARGS adds launch arguments. The simulator is
# shut down afterwards (an idle one's screen saver crashes); HONGGUO_KEEP_SIM=1 keeps it booted.
set -euo pipefail
cd "$(dirname "$0")/.."
UDID="$1"; LABEL="$2"; shift 2
BUNDLE_ID="io.github.shuiandy.hongguo-drama.tvos"
ROUTES=("$@")
if [[ ${#ROUTES[@]} -eq 0 ]]; then
    ROUTES=(recommend theater ranking following search me)
fi
OFFLINE=(-HongguoOfflineFixtures YES)
[[ "${HONGGUO_SHOOT_LIVE:-}" == "1" ]] && OFFLINE=()
mkdir -p docs/screenshots
for route in "${ROUTES[@]}"; do
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" "${OFFLINE[@]}" -HongguoMuted YES -HongguoRoute "$route" ${HONGGUO_SHOOT_ARGS:-} >/dev/null
    sleep "${HONGGUO_SHOOT_WAIT:-4}"
    xcrun simctl io "$UDID" screenshot "docs/screenshots/tv-$LABEL-$route.png" 2>/dev/null
    echo "docs/screenshots/tv-$LABEL-$route.png"
done
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
[[ "${HONGGUO_KEEP_SIM:-}" == "1" ]] || xcrun simctl shutdown "$UDID" 2>/dev/null || true
