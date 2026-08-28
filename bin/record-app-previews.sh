#!/bin/bash
# Records App Store app-preview videos from the demo-mode preview tour
# (FanficlyUITests/PreviewTourTests) on simulators, then post-processes them
# with ffmpeg to Apple's app-preview specs:
#
#   iphone  886x1920   (6.9" portrait)
#   ipad    1200x1600  (13" portrait)
#   mac     1920x1080  (landscape iPad capture, pillarboxed on the indigo
#                       ASO canvas — same stand-in as the Mac screenshots)
#
# Output: fastlane/previews/en-US/*.mp4 — H.264, 30 fps, <=28 s, with the
# silent stereo AAC track App Store Connect expects. Raw captures land in
# build/previews-raw/ (git-ignored). Upload is manual for now: App Store
# Connect > the editable version > drag each .mp4 into its device slot
# (previews attach to an EDITABLE version — create one first by uploading
# the next build). Requires: ffmpeg (brew install ffmpeg).
set -euo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

DD="$PWD/build"
RAW="$PWD/build/previews-raw"
OUT="$PWD/fastlane/previews/en-US"
mkdir -p "$RAW" "$OUT"

IPHONE_SIM="iPhone 17 Pro Max"
IPAD_SIM="iPad Pro 13-inch (M5)"

udid_for() {
    xcrun simctl list devices available | grep -F "$1 (" | head -1 \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1
}

record() { # <name> <sim name> <test method>
    local name="$1" sim="$2" method="$3"
    local udid
    udid=$(udid_for "$sim")
    [ -n "$udid" ] || { echo "ERROR: no available simulator named '$sim'"; exit 1; }
    echo "==> $name: $sim ($udid) / $method"
    # Cycle the simulator: an interrupted recordVideo leaves the sim's
    # host-side recording session stuck ("Host recording is already in
    # progress"), and only a shutdown clears it.
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b

    xcodebuild test -project Fanficly.xcodeproj -scheme Fanficly \
        -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO \
        -destination "id=$udid" \
        -only-testing:"FanficlyUITests/PreviewTourTests/$method" \
        > "$RAW/$name-test.log" 2>&1 &
    local test_pid=$!

    # Start recording once the app itself is running (the tour holds its
    # opening frame long enough to absorb the startup skew; the leading
    # second is trimmed in post).
    local waited=0
    until pgrep -f "$udid.*Fanficly.app/Fanficly" > /dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -gt 420 ]; then
            echo "ERROR: app never launched for $name — see $RAW/$name-test.log"
            kill "$test_pid" 2>/dev/null || true
            exit 1
        fi
        # Bail out early if the test run already died (build failure).
        kill -0 "$test_pid" 2>/dev/null || { echo "ERROR: test run exited before launch — see $RAW/$name-test.log"; exit 1; }
    done
    sleep 2
    # A recorder left over from an interrupted run blocks new recordings
    # ("Host recording is already in progress").
    pkill -f "simctl io $udid recordVideo" 2>/dev/null || true
    sleep 1
    xcrun simctl io "$udid" recordVideo --codec h264 --force "$RAW/$name.mov" &
    local rec_pid=$!

    # Stop recording the moment the app exits (test teardown) so the video
    # doesn't tail off into the home screen while xcodebuild wraps up.
    while pgrep -f "$udid.*Fanficly.app/Fanficly" > /dev/null 2>&1; do sleep 0.5; done
    kill -INT "$rec_pid" 2>/dev/null || true
    wait "$rec_pid" 2>/dev/null || true

    local test_rc=0
    wait "$test_pid" || test_rc=$?
    if [ "$test_rc" -ne 0 ]; then
        echo "ERROR: tour failed for $name — see $RAW/$name-test.log"
        exit 1
    fi
    if [ ! -s "$RAW/$name.mov" ]; then
        echo "ERROR: no recording written for $name (recorder failed to start?)"
        exit 1
    fi
}

post() { # <name> <video filter>
    # Trim launch settle (head) and test teardown (tail), then uniformly
    # speed up whatever remains so the preview lands at ~27.5 s — under the
    # App Store's 30 s cap. Mild speed-up reads as "snappy" in previews.
    local dur end speed
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW/$1.mov")
    end=$(python3 -c "print(max(2.0, $dur - 0.5))")
    speed=$(python3 -c "print(max(1.0, ($end - 1.0) / 27.5))")
    echo "==> $1: raw ${dur}s, speed ${speed}x"
    ffmpeg -hide_banner -loglevel error -y \
        -i "$RAW/$1.mov" \
        -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
        -vf "trim=start=1:end=$end,setpts=(PTS-STARTPTS)/$speed,$2,fps=30" \
        -c:v libx264 -pix_fmt yuv420p -profile:v high -crf 18 \
        -c:a aac -b:a 128k -shortest -movflags +faststart \
        "$OUT/$1.mp4"
    echo "==> wrote $OUT/$1.mp4"
}

record iphone "$IPHONE_SIM" testPreviewTourPhone
record ipad   "$IPAD_SIM"   testPreviewTourPad
record mac    "$IPAD_SIM"   testPreviewTourMac

post iphone "scale=886:1920:flags=lanczos"
post ipad   "scale=1200:1600:flags=lanczos"
# simctl records a rotated simulator in its portrait buffer with sideways
# content, so rotate upright first (landscapeRight → transpose=1). Then the
# 4:3 landscape capture is pillarboxed onto the 16:9 canvas in brand indigo
# (bin/frame-screenshots.py BG) so it matches the Mac screenshot set.
post mac    "transpose=1,scale=-2:1080:flags=lanczos,pad=1920:1080:(ow-iw)/2:0:color=0x3B2E8C"

echo "Done. Previews in $OUT"
