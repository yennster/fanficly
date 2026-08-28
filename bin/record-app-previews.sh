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

# --post-only: re-encode from the existing raw captures (for trim/caption
# tweaks) without driving the simulators again.
POST_ONLY=false
[ "${1:-}" = "--post-only" ] && POST_ONLY=true

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

# Caption pills matching the ASO screenshot branding (SF Pro Display Black on
# the indigo canvas), rendered with Pillow (Homebrew's ffmpeg lacks drawtext)
# and composited with the core overlay filter. Caption windows and content-end
# times are in RAW capture seconds (the overlays run before the trim/speed-up,
# where t is still raw time) and are TUNED TO THE CURRENT RECORDINGS — after
# re-recording, re-tune them from a 1 fps contact sheet:
#   ffmpeg -i build/previews-raw/<name>.mov -vf "fps=1,scale=110:-2,tile=8x6" \
#     -frames:v 1 sheet.png

make_caption() { # <text> <fontsize> <out.png>
    bin/.venv/bin/python - "$1" "$2" "$3" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
text, size, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
font = ImageFont.truetype("/Library/Fonts/SF-Pro-Display-Black.otf", size)
l, t, r, b = font.getbbox(text)
px, py = int(size * 0.5), int(size * 0.32)
w, h = r - l + 2 * px, b - t + 2 * py
img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle([0, 0, w - 1, h - 1], radius=h // 2, fill=(0x3B, 0x2E, 0x8C, 242))
d.text((px - l, py - t), text, font=font, fill="white")
img.save(out)
PY
}

post() { # <name> <content end (raw s)> <geometry filter>
    # Uses per-video globals: PRE (filter before captions, e.g. transpose),
    # CAPS ("TEXT|start|end" triplets), CAPSIZE, CAPY.
    # Trim launch settle (head) and everything past the content end (the
    # recorder tails into the home screen after teardown), then uniformly
    # speed up whatever remains so the preview lands at ~27.5 s — under the
    # App Store's 30 s cap. Mild speed-up reads as "snappy" in previews.
    local name="$1" end="$2" geo="$3" speed
    speed=$(python3 -c "print(max(1.0, ($end - 1.0) / 27.5))")
    echo "==> $name: content end ${end}s, speed ${speed}x"
    local inputs=(-i "$RAW/$name.mov")
    local fc="[0:v]${PRE}[v0]"
    local idx=1 cur="v0" spec text start endt png
    for spec in "${CAPS[@]}"; do
        IFS='|' read -r text start endt <<< "$spec"
        png="$RAW/caps-$name-$idx.png"
        make_caption "$text" "$CAPSIZE" "$png"
        inputs+=(-i "$png")
        fc="$fc;[$cur][$idx:v]overlay=(W-w)/2:$CAPY:enable='between(t,$start,$endt)'[v$idx]"
        cur="v$idx"
        idx=$((idx + 1))
    done
    fc="$fc;[$cur]trim=start=1:end=$end,setpts=(PTS-STARTPTS)/$speed,$geo,fps=30[vout]"
    ffmpeg -hide_banner -loglevel error -y \
        "${inputs[@]}" \
        -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
        -filter_complex "$fc" -map "[vout]" -map "$idx:a" \
        -c:v libx264 -pix_fmt yuv420p -profile:v high -crf 18 \
        -c:a aac -b:a 128k -shortest -movflags +faststart \
        "$OUT/$name.mp4"
    echo "==> wrote $OUT/$name.mp4"
}

if ! $POST_ONLY; then
    record iphone "$IPHONE_SIM" testPreviewTourPhone
    record ipad   "$IPAD_SIM"   testPreviewTourPad
    record mac    "$IPAD_SIM"   testPreviewTourMac
fi

PRE="null" CAPSIZE=64 CAPY=200
CAPS=("NEVER MISS A CHAPTER|4.5|8.5"
      "DISCOVER WHAT’S POPULAR|12|16"
      "SEARCH IN PLAIN ENGLISH|19.5|24"
      "READ ANYWHERE, OFFLINE|24.5|31.5"
      "LISTEN ON THE GO|33|40.5")
post iphone 40.5 "scale=886:1920:flags=lanczos"

PRE="null" CAPSIZE=72 CAPY=150
CAPS=("SEARCH IN PLAIN ENGLISH|1.5|11"
      "READ ANYWHERE, OFFLINE|12.5|19.5"
      "LISTEN ON THE GO|22.5|26.5")
post ipad 26.5 "scale=1200:1600:flags=lanczos"

# simctl records a rotated simulator in its portrait buffer with sideways
# content, so the mac chain rotates upright (landscapeRight → transpose=1)
# BEFORE captioning, then pillarboxes the 4:3 capture onto the 16:9 canvas
# in brand indigo (bin/frame-screenshots.py BG), matching the screenshot set.
PRE="transpose=1" CAPSIZE=68 CAPY=110
CAPS=("SEARCH IN PLAIN ENGLISH|1.5|8.5"
      "READ ANYWHERE, OFFLINE|10|17"
      "LISTEN ON THE GO|20|23.5")
post mac 23.5 "scale=-2:1080:flags=lanczos,pad=1920:1080:(ow-iw)/2:0:color=0x3B2E8C"

echo "Done. Previews in $OUT"
