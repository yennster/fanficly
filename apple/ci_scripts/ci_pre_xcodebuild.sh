#!/bin/sh
# Xcode Cloud runs this before each xcodebuild. In the "Store art" workflow
# (bin/xcode-cloud-store-art.py), before the screenshots run, it gives the
# test's simulator Apple's 9:41 status bar, as bin/sim-marketing-mode.sh does
# for a local capture. Best effort: a simulator it misses keeps the real
# clock, and that never fails or holds up the build.
set -u

[ "${CI_WORKFLOW:-}" = "Store art" ] || exit 0
[ "${CI_XCODEBUILD_ACTION:-}" = "test-without-building" ] || exit 0

# Only this action's destination. Booting every matching simulator on every
# runtime, and waiting on each with no limit, held the iPad and iPhone Duo
# actions until Xcode Cloud errored them without running a test.
udid="${CI_TEST_DESTINATION_UDID:-}"
if [ -z "$udid" ] && [ -n "${CI_TEST_DESTINATION_DEVICE_TYPE:-}" ]; then
  # The runtime's own section first, the newest other runtime if that misses.
  udid=$(xcrun simctl list devices available \
    | awk -v runtime="-- ${CI_TEST_DESTINATION_RUNTIME:-} --" -v name="    ${CI_TEST_DESTINATION_DEVICE_TYPE} (" '
        /^-- / { here = ($0 == runtime); next }
        index($0, name) == 1 { if (here) { print; found = 1; exit } else any = $0 }
        END { if (!found && any) print any }' \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')
fi
if [ -z "$udid" ]; then
  echo "No simulator for ${CI_TEST_DESTINATION_DEVICE_TYPE:-?} (${CI_TEST_DESTINATION_RUNTIME:-?}): real status bar"
  exit 0
fi

xcrun simctl boot "$udid" 2>/dev/null || true
# Waits at most 3 minutes for the boot (macOS has no timeout command).
xcrun simctl bootstatus "$udid" >/dev/null 2>&1 &
wait_pid=$!
i=0
while kill -0 "$wait_pid" 2>/dev/null && [ "$i" -lt 180 ]; do
  sleep 1
  i=$((i + 1))
done
if kill -0 "$wait_pid" 2>/dev/null; then
  kill "$wait_pid" 2>/dev/null
  echo "$udid didn't boot in 3 minutes: real status bar"
  exit 0
fi
xcrun simctl ui "$udid" appearance light || true
xcrun simctl status_bar "$udid" override --time "9:41" \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState discharging --batteryLevel 100 \
  && echo "9:41 status bar on $udid" || true
exit 0
