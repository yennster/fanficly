#!/usr/bin/env bash
# List roadmap items and whether anyone has claimed them.
#   bin/roadmap.sh                 every item: platform, ID, size, status, claim, title
#   bin/roadmap.sh free            only items that are open AND unclaimed
#   bin/roadmap.sh free windows    the same, for one app (apple: docs/ROADMAP.md,
#                                  windows: windows/ROADMAP.md; default both)
# A claim is an open PR, or a remote branch, whose name or title mentions the ID
# (branch `roadmap/RM-007-series-page`). Needs `gh` and network for claims; with
# neither it says so and treats nothing as claimed, so re-run before you start.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-all}"
platform="${2:-all}"
case "$platform" in
  apple)   roadmaps=("apple:$repo_root/docs/ROADMAP.md") ;;
  windows) roadmaps=("windows:$repo_root/windows/ROADMAP.md") ;;
  all)     roadmaps=("apple:$repo_root/docs/ROADMAP.md" "windows:$repo_root/windows/ROADMAP.md") ;;
  *)       echo "usage: bin/roadmap.sh [all|free] [apple|windows|all]" >&2; exit 2 ;;
esac

claims=""
if command -v gh >/dev/null 2>&1; then
  prs="$(gh pr list --state open --limit 100 --json number,title,headRefName \
    --jq '.[] | "#\(.number) \(.headRefName) \(.title)"' 2>/dev/null || echo "__GH_FAILED__")"
  [[ "$prs" == "__GH_FAILED__" ]] && { echo "warning: could not list PRs; claims unknown" >&2; prs=""; }
  branches="$(git -C "$repo_root" ls-remote --heads origin 'roadmap/*' 2>/dev/null | awk '{print $2}' || true)"
  claims="$prs"$'\n'"$branches"
else
  echo "warning: gh not installed; claims unknown" >&2
fi

for entry in "${roadmaps[@]}"; do
app="${entry%%:*}"
roadmap="${entry#*:}"
awk '
  /^### RM-[0-9]+/ { if (id) print id "\t" size "\t" status "\t" title
                     id=$2; title=$0; sub(/^### RM-[0-9]+ — /, "", title); size="?"; status="?" }
  id && /\*\*Status:\*\*/ {
    s=$0; sub(/.*\*\*Status:\*\* */, "", s); sub(/ .*/, "", s); status=s
    if (match($0, /\*\*Size:\*\* [A-Z]+/)) { size=substr($0, RSTART+10, RLENGTH-10) }
  }
  END { if (id) print id "\t" size "\t" status "\t" title }
' "$roadmap" | while IFS=$'\t' read -r id size status title; do
  claim="-"
  if grep -qiE "(^|[^0-9A-Za-z])${id}([^0-9]|$)" <<<"$claims"; then claim="CLAIMED"; fi
  if [[ "$mode" == "free" ]]; then
    [[ "$status" == "open" && "$claim" == "-" ]] || continue
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$app" "$id" "$size" "$status" "$claim" "$title"
done
done
