#!/bin/sh
# Xcode Cloud runs this before each xcodebuild. In the "Store art" workflow
# (bin/xcode-cloud-store-art.py), before the screenshots run, it gives the
# simulators Apple's 9:41 status bar, as bin/sim-marketing-mode.sh does for a
# local capture. Best effort: a simulator it misses keeps the real clock, and
# that never fails the build.
set -u

[ "${CI_WORKFLOW:-}" = "Store art" ] || exit 0
[ "${CI_XCODEBUILD_ACTION:-}" = "test-without-building" ] || exit 0

xcrun simctl list devices available \
  | grep -E "iPhone 17 Pro Max \(|iPad Pro 13-inch \(M5\) \(|iPhone Duo \(" \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
  | while read -r udid; do
      xcrun simctl boot "$udid" 2>/dev/null || true
      xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || continue
      xcrun simctl ui "$udid" appearance light || true
      xcrun simctl status_bar "$udid" override --time "9:41" \
        --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 \
        --batteryState discharging --batteryLevel 100 \
        && echo "9:41 status bar on $udid" || true
    done
exit 0
