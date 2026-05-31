#!/usr/bin/env bash
# Take a screenshot of the currently-booted iOS Simulator and save it to
# docs/screenshots/<name>.png. Usage:
#   bin/screenshot.sh search-empty
#   bin/screenshot.sh reader-sepia
# If no name is given, uses a timestamp.

set -euo pipefail

# Pick the right developer dir without requiring xcode-select to be set.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$repo_root/docs/screenshots"
mkdir -p "$out_dir"

name="${1:-shot-$(date +%Y%m%d-%H%M%S)}"
out="$out_dir/$name.png"

if ! xcrun simctl list devices booted | grep -q "Booted"; then
    echo "no simulator booted. boot one with:" >&2
    echo "  xcrun simctl boot \"iPhone 17\" && open -a Simulator" >&2
    exit 1
fi

xcrun simctl io booted screenshot "$out" 2>&1 | grep -v "^Wrote" || true
echo "saved: $out"

# Print the markdown line you can paste into README.md
echo
echo "Add to README:"
rel="${out#$repo_root/}"
echo "![$name]($rel)"
