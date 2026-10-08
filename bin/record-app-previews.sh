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
    # US region + Apple's 9:41 status bar (restored at the end of the run).
    bin/sim-marketing-mode.sh on "$udid" > /dev/null

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

# Caption cards in the store-art style (bin/store-art/caption.html: indigo
# glass card, letter-spaced label, New York headline with a gold italic
# accent), rendered on transparency by bin/store_art.py and composited with
# the core overlay filter (Homebrew's ffmpeg lacks drawtext). App previews may
# only show the app's own screen capture plus text/design overlays: Apple
# rejects device frames and "framing around the video screen capture"
# (Guideline 2.3.4), so the brand look lives in these cards, not a frame.
#
# Caption windows and content-end times are in RAW capture seconds (the
# overlays run before the trim/speed-up, where t is still raw time) and are
# TUNED TO THE CURRENT RECORDINGS — after re-recording, re-tune them from a
# 2 fps contact sheet:
#   ffmpeg -i build/previews-raw/<name>.mov -vf "fps=2,scale=110:-2,tile=12x8" \
#     -frames:v 1 sheet.png

make_caption() { # <label> <headline> <headline px> <max card width px> <out.png>
    bin/.venv/bin/python bin/store_art.py caption --label "$1" --headline "$2" \
        --size "$3" --width "$4" --out "$5" > /dev/null
}

post() { # <name> <geometry filter>
    # Uses per-video globals: PRE (filter before captions, e.g. transpose),
    # CAPS ("LABEL;HEADLINE;start;end;anchor;y" — *word* is the gold accent,
    # "|" a line break, anchor L/R/C, y in px from the top or "bNNN" from the
    # bottom), CAPSIZE (headline px), CAPMAXW, CAPMARGIN, and SEGMENTS
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
    local idx=1 cur="v0" spec label head start endt anchor y png x yexpr fo
    for spec in "${CAPS[@]}"; do
        # The card fades in while rising 40 px into place over 0.35 s, and
        # fades out over the last 0.3 s of its window.
        IFS=';' read -r label head start endt anchor y <<< "$spec"
        png="$RAW/caps-$name-$idx.png"
        make_caption "$label" "$head" "$CAPSIZE" "$CAPMAXW" "$png"
        inputs+=(-loop 1 -i "$png")
        case "$anchor" in
            L) x="$CAPMARGIN" ;;
            R) x="W-w-$CAPMARGIN" ;;
            *) x="(W-w)/2" ;;
        esac
        case "$y" in
            b*) yexpr="H-h-${y#b}" ;;
            *)  yexpr="$y" ;;
        esac
        fo=$(python3 -c "print(max($start, $endt - 0.3))")
        fc="$fc;[$idx:v]format=rgba,fade=t=in:st=$start:d=0.35:alpha=1,fade=t=out:st=$fo:d=0.3:alpha=1[k$idx]"
        fc="$fc;[$cur][k$idx]overlay=x='$x':y='$yexpr+40*(1-clip((t-$start)/0.35,0,1))':shortest=1:enable='between(t,$start,$endt)'[v$idx]"
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
    # Put both simulators' region and status bar back.
    bin/sim-marketing-mode.sh off "$IPHONE_SIM" > /dev/null
    bin/sim-marketing-mode.sh off "$IPAD_SIM" > /dev/null
fi

PRE="null" CAPSIZE=104 CAPMAXW=1180 CAPMARGIN=56
CAPS=("Chapter alerts;Never miss a *chapter.*;6.0;8.6;L;b240"
      "Discover;See what's *popular.*;13.0;15.8;L;b240"
      "Smart search;Find your next *fic.*;22.2;30.0;L;b240"
      "Offline reading;Read anywhere,|*even offline.*;30.6;35.6;L;b240"
      "Listen;Let the story|*read to you.*;43.4;48.6;C;b330")
# Hard cuts: only a flash of the sidebar between beats, jump-cuts inside the
# long reader stretch — the dwells read as dead air at full length.
SEGMENTS=("6.0|8.6" "11.8|12.3" "13.0|15.8" "19.6|20.2" "22.2|30.0"
          "30.6|32.8" "33.6|35.6" "39.6|40.8" "43.4|48.6")
post iphone "scale=886:1920:flags=lanczos"

PRE="null" CAPSIZE=132 CAPMAXW=1500 CAPMARGIN=72
CAPS=("Smart search;Find your next *fic.*;5.6;14.2;L;b220"
      "Offline reading;Read anywhere,|*even offline.*;14.6;21.0;L;b220"
      "Listen;Let the story|*read to you.*;26.8;32.2;R;b300")
SEGMENTS=("5.6|14.2" "14.6|17.4" "18.6|21.0" "23.6|24.8" "26.8|32.2")
post ipad "scale=1200:1600:flags=lanczos"

# simctl records a rotated simulator in its portrait buffer with sideways
# content, so the mac chain rotates upright (landscapeRight → transpose=1)
# BEFORE captioning, then pillarboxes the 4:3 capture onto the 16:9 canvas
# in brand indigo, matching the screenshot set. (A plain pillarbox only:
# decorative "framing" around the capture gets previews rejected.)
PRE="transpose=1" CAPSIZE=150 CAPMAXW=1900 CAPMARGIN=90
CAPS=("Smart search;Find your next *fic.*;5.0;9.8;L;b160"
      "Offline reading;Read anywhere,|*even offline.*;10.4;16.4;R;b160"
      "Listen;Let the story|*read to you.*;22.4;27.8;R;b260")
SEGMENTS=("5.0|9.8" "10.4|13.2" "14.0|16.4" "19.0|20.6" "22.4|27.8")
post mac "scale=-2:1080:flags=lanczos,pad=1920:1080:(ow-iw)/2:0:color=0x3B2E8C"

echo "Done. Previews in $OUT"
