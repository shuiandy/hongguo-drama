#!/bin/bash
# Build HongguoDramaTV for an Apple TV simulator. Prints the simulator UDID and the built .app.
#
#   scripts/build-sim.sh            build only
#   scripts/build-sim.sh --run      build, boot the simulator, install and launch offline and muted
#   scripts/build-sim.sh --test     run the unit and UI tests, then shut the simulator down
#
# A booted Apple TV simulator left idle starts the screen saver, whose IdleScreen process crashes
# in the simulator (out of memory) and macOS shows a crash report each time. So --test (and
# shoot.sh) shut the simulator down when done; after --run, shut it down yourself. Set
# HONGGUO_KEEP_SIM=1 to keep it booted.
#
# HONGGUO_TV_UDID=<udid> picks a specific simulator; otherwise a booted Apple TV 4K first, then
# the newest one.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="io.github.shuiandy.hongguo-drama.tvos"
DERIVED="build/DerivedData"

pick_device() {
    xcrun simctl list devices available --json | python3 -c '
import json, re, sys
runtimes = json.load(sys.stdin)["devices"]
def version(key):
    m = re.search(r"tvOS-(\d+)-(\d+)", key)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
tvs = [(version(k), d) for k, ds in runtimes.items() if "tvOS" in k for d in ds if d["name"].startswith("Apple TV")]
tvs.sort(key=lambda p: (p[1]["state"] == "Booted", "4K" in p[1]["name"], p[0]), reverse=True)
if tvs:
    print(tvs[0][1]["udid"], tvs[0][1]["name"].replace(" ", "_"))
'
}

if [[ -n "${HONGGUO_TV_UDID:-}" ]]; then
    UDID="$HONGGUO_TV_UDID"; NAME="(HONGGUO_TV_UDID)"
else
    read -r UDID NAME < <(pick_device) || true
fi
[[ -n "${UDID:-}" ]] || { echo "No Apple TV simulator found. Install tvOS with: xcodebuild -downloadPlatform tvOS" >&2; exit 1; }
echo "Simulator: $NAME $UDID"

command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

mkdir -p build
if [[ "${1:-}" == "--test" ]]; then
    shut_down() { [[ "${HONGGUO_KEEP_SIM:-}" == "1" ]] || xcrun simctl shutdown "$UDID" 2>/dev/null || true; }
    trap shut_down EXIT
    xcodebuild \
        -project HongguoDramaTV.xcodeproj \
        -scheme HongguoDramaTV \
        -destination "platform=tvOS Simulator,id=$UDID" \
        -derivedDataPath "$DERIVED" \
        test > build/test-sim.log 2>&1 && status=0 || status=$?
    grep -E "xctest' (passed|failed)" -A1 build/test-sim.log | grep -E "Executed" || true
    grep -E "Test Case .* failed|TEST (SUCCEEDED|FAILED)" build/test-sim.log | tail -5 || true
    exit "$status"
fi

xcodebuild \
    -project HongguoDramaTV.xcodeproj \
    -scheme HongguoDramaTV \
    -configuration Debug \
    -destination "platform=tvOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    build | tee build/build-sim.log | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true
grep -q "BUILD SUCCEEDED" build/build-sim.log || { echo "Build failed, see build/build-sim.log" >&2; exit 1; }

APP="$PWD/$DERIVED/Build/Products/Debug-appletvsimulator/HongguoDramaTV.app"
echo "App: $APP"

if [[ "${1:-}" == "--run" ]]; then
    xcrun simctl boot "$UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$UDID" -b >/dev/null
    xcrun simctl install "$UDID" "$APP"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    # Offline sample rows, muted: no request leaves the simulator and no sound is played.
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -HongguoOfflineFixtures YES -HongguoMuted YES
    echo "When done: xcrun simctl shutdown $UDID (an idle Apple TV simulator's screen saver crashes)"
fi
