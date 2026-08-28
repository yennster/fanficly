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

make_caption() { # <text> <max fontsize> <max pill width px> <out.png>
    bin/.venv/bin/python - "$1" "$2" "$3" "$4" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
text, size, max_w, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
FONT = "/Library/Fonts/SF-Pro-Display-Black.otf"

# Shrink until the pill fits the frame — a long caption at full size would
# be wider than the video and get clipped by the centered overlay.
while size > 24:
    font = ImageFont.truetype(FONT, size)
    l, t, r, b = font.getbbox(text)
    px, py = int(size * 0.5), int(size * 0.32)
    w, h = r - l + 2 * px, b - t + 2 * py
    if w <= max_w:
        break
    size -= 4

img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle([0, 0, w - 1, h - 1], radius=h // 2, fill=(0x3B, 0x2E, 0x8C, 242))
d.text((px - l, py - t), text, font=font, fill="white")
img.save(out)
PY
}

post() { # <name> <geometry filter>
    # Uses per-video globals: PRE (filter before captions, e.g. transpose),
    # CAPS ("TEXT|start|end" triplets), CAPSIZE, CAPY, and SEGMENTS
    # ("start|end" in raw seconds) — the kept slices, concatenated in order.
    # Segment editing is what keeps the pacing snappy: dead time (long
    # sidebar dwells between beats, the recorder's home-screen tail after
    # teardown) is simply not in the list; a transition keeps only a short
    # flash of the menu so the cut still reads. Captions overlay BEFORE the
    # cuts, so their windows stay in raw capture time. Whatever total
    # remains is uniformly sped up to land at ~27.5 s when it runs long.
    local name="$1" geo="$2" total speed
    total=$(python3 -c "
segs = '${SEGMENTS[*]}'.split()
print(sum(float(s.split('|')[1]) - float(s.split('|')[0]) for s in segs))")
    speed=$(python3 -c "print(max(1.0, $total / 27.5))")
    echo "==> $name: ${#SEGMENTS[@]} segments, ${total}s kept, speed ${speed}x"
    local inputs=(-i "$RAW/$name.mov")
    # fps=30 FIRST: simctl records variable frame rate with no frames at all
    # during static stretches, so trim boundaries and caption windows would
    # snap to the next real frame and silently drop static seconds.
    local fc="[0:v]fps=30,${PRE}[v0]"
    local idx=1 cur="v0" spec text start endt png
    for spec in "${CAPS[@]}"; do
        IFS='|' read -r text start endt <<< "$spec"
        png="$RAW/caps-$name-$idx.png"
        make_caption "$text" "$CAPSIZE" "$CAPMAXW" "$png"
        inputs+=(-i "$png")
        fc="$fc;[$cur][$idx:v]overlay=(W-w)/2:$CAPY:enable='between(t,$start,$endt)'[v$idx]"
        cur="v$idx"
        idx=$((idx + 1))
    done
    local n=${#SEGMENTS[@]} i=1 labels=""
    fc="$fc;[$cur]split=$n"
    for ((i = 1; i <= n; i++)); do fc="$fc[c$i]"; done
    for ((i = 1; i <= n; i++)); do
        IFS='|' read -r start endt <<< "${SEGMENTS[$((i - 1))]}"
        fc="$fc;[c$i]trim=start=$start:end=$endt,setpts=PTS-STARTPTS[s$i]"
        labels="$labels[s$i]"
    done
    fc="$fc;${labels}concat=n=$n:v=1:a=0[vseg];[vseg]setpts=PTS/$speed,$geo,fps=30[vout]"
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

PRE="null" CAPSIZE=100 CAPY=200 CAPMAXW=1230
CAPS=("NEVER MISS A CHAPTER|4.5|8.5"
      "DISCOVER WHAT’S POPULAR|12|16"
      "SEARCH IN PLAIN ENGLISH|19.7|24"
      "READ ANYWHERE, OFFLINE|24.5|31.5"
      "LISTEN ON THE GO|33|40.5")
# Keep only a flash of the sidebar between beats — the full back-pop dwells
# read as dead air.
SEGMENTS=("1.0|2.2" "4.5|8.5" "8.5|9.3" "12.0|16.0" "16.0|16.8" "19.7|40.5")
post iphone "scale=886:1920:flags=lanczos"

PRE="null" CAPSIZE=110 CAPY=150 CAPMAXW=1920
CAPS=("SEARCH IN PLAIN ENGLISH|1.5|11"
      "READ ANYWHERE, OFFLINE|12.5|19.5"
      "LISTEN ON THE GO|22.5|26.5")
# Tighten the long static hold on saved searches before typing begins.
SEGMENTS=("1.0|3.0" "6.5|26.5")
post ipad "scale=1200:1600:flags=lanczos"

# simctl records a rotated simulator in its portrait buffer with sideways
# content, so the mac chain rotates upright (landscapeRight → transpose=1)
# BEFORE captioning, then pillarboxes the 4:3 capture onto the 16:9 canvas
# in brand indigo (bin/frame-screenshots.py BG), matching the screenshot set.
PRE="transpose=1" CAPSIZE=100 CAPY=110 CAPMAXW=2500
CAPS=("SEARCH IN PLAIN ENGLISH|1.5|8.5"
      "READ ANYWHERE, OFFLINE|10|17"
      "LISTEN ON THE GO|20|23.5")
SEGMENTS=("1.5|3.5" "6.5|23.5")
post mac "scale=-2:1080:flags=lanczos,pad=1920:1080:(ow-iw)/2:0:color=0x3B2E8C"

echo "Done. Previews in $OUT"
