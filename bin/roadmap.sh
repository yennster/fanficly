#!/usr/bin/env bash
# List roadmap items and whether anyone has claimed them.
#   bin/roadmap.sh            every item: ID, size, status, claim, title
#   bin/roadmap.sh free       only items that are open AND unclaimed
# A claim is an open PR, or a remote branch, whose name or title mentions the ID
# (branch `roadmap/RM-007-series-page`). Needs `gh` and network for claims; with
# neither it says so and treats nothing as claimed, so re-run before you start.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
roadmap="$repo_root/docs/ROADMAP.md"
mode="${1:-all}"

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
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$size" "$status" "$claim" "$title"
done
