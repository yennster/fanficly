#!/usr/bin/env bash
# Guided end-to-end screenshot workflow for the README.
#
# Boots a simulator, builds & installs the app, launches it, then
# walks through a checklist of screens and captures each one as you
# navigate to it manually. Writes PNGs to docs/screenshots/ and
# regenerates the README's Screenshots section to embed them.
#
# Usage: bin/take-screenshots.sh
#        bin/take-screenshots.sh --device "iPhone 17"
#        bin/take-screenshots.sh --skip-build   # if already installed
#        bin/take-screenshots.sh --only N       # capture only the Nth shot
#
# Requires: full Xcode (not just Command Line Tools).

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

device="iPhone 17"
skip_build=0
only_index=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)     device="$2"; shift 2 ;;
        --skip-build) skip_build=1; shift ;;
        --only)       only_index="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

out_dir="docs/screenshots"
mkdir -p "$out_dir"

# Each entry: filename:label:hint-shown-to-the-user
shots=(
    "01-search-empty:Empty search:Open the app on the Search tab"
    "02-search-results:Search results:Type a smart prompt and press search"
    "03-reader:Reader view:Tap a work and let it load"
    "04-typography:Typography menu:In the reader, open the textformat menu"
    "05-browse:Browse categories:Tap Browse in the sidebar"
    "06-browse-fandoms:Fandoms in a category:Tap a category"
    "07-library:Library tab:Tap Library in the sidebar"
    "08-settings:Settings:Tap Settings in the sidebar"
)

[[ -n "$only_index" ]] && shots=("${shots[$((only_index - 1))]}")

# Sanity: full Xcode installed?
if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find simctl >/dev/null 2>&1; then
    echo "error: simctl not available. Run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

# Boot the simulator if it's not already booted.
udid=$(xcrun simctl list devices --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
target = '$device'
for runtime, devs in data['devices'].items():
    for d in devs:
        if d.get('name') == target and d.get('isAvailable', False):
            print(d['udid'])
            sys.exit(0)
sys.exit(1)
")

if [[ -z "$udid" ]]; then
    echo "error: no available '$device' simulator. Try a different --device." >&2
    echo "available iPhones:" >&2
    xcrun simctl list devices available | grep -i iPhone | head -5 >&2
    exit 1
fi

state=$(xcrun simctl list devices --json | python3 -c "
import json, sys
print(next(d['state'] for k,v in json.load(sys.stdin)['devices'].items() for d in v if d['udid']=='$udid'))
")
if [[ "$state" != "Booted" ]]; then
    echo "booting $device …"
    xcrun simctl boot "$udid"
fi
open -a Simulator

if [[ $skip_build -eq 0 ]]; then
    echo "building Fanficly for the simulator …"
    xcodegen generate >/dev/null
    xcodebuild \
        -project Fanficly.xcodeproj -scheme Fanficly \
        -destination "id=$udid" \
        -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
        build >/tmp/fanficly-build.log 2>&1 || {
        echo "build failed; last 30 lines of log:" >&2
        tail -30 /tmp/fanficly-build.log >&2
        exit 1
    }
    xcrun simctl install "$udid" build/Build/Products/Debug-iphonesimulator/Fanficly.app
fi

xcrun simctl launch "$udid" io.github.yennster.fanficly >/dev/null

# Walk the user through the checklist.
captured=()
for entry in "${shots[@]}"; do
    name="${entry%%:*}"; rest="${entry#*:}"
    label="${rest%%:*}";   hint="${rest#*:}"
    echo
    echo "[$(printf '%s' "$name")] $label"
    echo "  → $hint, then press Enter to capture (or 's' + Enter to skip)…"
    read -r reply
    if [[ "$reply" == "s" ]]; then
        echo "  skipped."
        continue
    fi
    sleep 0.5
    out="$out_dir/$name.png"
    xcrun simctl io "$udid" screenshot "$out" 2>/dev/null
    echo "  saved $out"
    captured+=("$name|$label")
done

# Write the Screenshots section into the README.
echo
if [[ ${#captured[@]} -gt 0 ]]; then
    echo "regenerating README screenshots section …"
    python3 - "$repo_root/README.md" "${captured[@]}" <<'PY'
import sys, pathlib
readme_path = pathlib.Path(sys.argv[1])
shots = [arg.split('|', 1) for arg in sys.argv[2:]]
text = readme_path.read_text()

start = "<!-- screenshots:start -->"
end   = "<!-- screenshots:end -->"

block = [start, "## Screenshots", ""]
block.append('<table>')
for i, (name, label) in enumerate(shots):
    if i % 2 == 0:
        if i > 0: block.append('</tr>')
        block.append('<tr>')
    block.append(f'<td align="center"><img src="docs/screenshots/{name}.png" width="280" alt="{label}"><br><sub>{label}</sub></td>')
if shots:
    block.append('</tr>')
block.append('</table>')
block.append("")
block.append(end)
new = "\n".join(block)

if start in text and end in text:
    head, _, after = text.partition(start)
    _, _, tail = after.partition(end)
    out = head + new + tail
else:
    out = text.rstrip() + "\n\n" + new + "\n"

readme_path.write_text(out)
print(f"wrote {len(shots)} screenshots into the README")
PY
fi

echo
echo "done. Review the README and commit when you're happy:"
echo "  git add docs/screenshots README.md && git commit -m 'docs: update screenshots'"
