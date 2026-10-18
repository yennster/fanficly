#!/usr/bin/env bash
# Capture the "mac" marketing screenshots headlessly — the SAME contained way
# the iPhone/iPad shots are taken: inside the iOS Simulator, never driving your
# real Mac desktop.
#
# Mac Catalyst has no simulator (it only runs natively on the Mac), so we use a
# large iPad simulator in LANDSCAPE — which renders the exact same
# NavigationSplitView sidebar + detail layout a Mac window shows. The shots are
# captured by the demo-mode `FanficlyUITests/ScreenshotTests/testCaptureMacScreens`
# UI test and, because the simulator can write to the repo (unlike a sandboxed
# Catalyst run), land directly in docs/screenshots/mac/.
#
# The simulator is forced to LIGHT appearance and demo mode uses the normal
# system blue accent (see FanficlyApp), so the shots look clean and standard.
#
# Usage:
#   bin/take-mac-screenshots.sh
#   bin/take-mac-screenshots.sh --device "iPad Pro 13-inch (M5)"
#   bin/take-mac-screenshots.sh --frame      # also run frame-screenshots.py after

set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

device="iPad Pro 13-inch (M5)"
frame_after=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --frame)  frame_after=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Resolve an available simulator UDID for the requested device.
udid="$(xcrun simctl list devices available | grep -F "$device (" | head -1 | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' || true)"
if [[ -z "$udid" ]]; then
  echo "error: no available simulator named '$device'." >&2
  echo "available iPads:" >&2
  xcrun simctl list devices available | grep -i ipad >&2
  exit 1
fi

echo "==> Using simulator: $device ($udid)"
xcrun simctl boot "$udid" 2>/dev/null || true
# Light appearance → clean, standard-looking shots (the app's reader theme is
# 'system' in demo mode, so it follows this).
xcrun simctl ui "$udid" appearance light 2>/dev/null || true

mkdir -p "$repo_root/docs/screenshots/mac" build
echo "==> Capturing 'mac' screenshots in the iOS Simulator (not your Mac desktop)…"
set +e
xcodebuild test \
  -project Fanficly.xcodeproj -scheme Fanficly \
  -destination "id=$udid" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  -only-testing:FanficlyUITests/ScreenshotTests/testCaptureMacScreens \
  > build/mac-screenshots-sim.log 2>&1
status=$?
set -e
if [[ $status -ne 0 ]]; then
  echo "   (xcodebuild exited $status — best-effort capture; last log lines:)"
  grep -viE "CoreData:" build/mac-screenshots-sim.log | tail -12
fi

echo "==> docs/screenshots/mac:"
ls -1 "$repo_root"/docs/screenshots/mac/*.png 2>/dev/null | sed 's#.*/#   #' || echo "   (none written)"

if [[ $frame_after -eq 1 ]]; then
  echo "==> Framing…"
  py="$repo_root/bin/.venv/bin/python"; [[ -x "$py" ]] || py="python3"
  "$py" "$repo_root/bin/frame-screenshots.py"
else
  echo "==> Next: frame with  bin/.venv/bin/python bin/frame-screenshots.py"
fi
