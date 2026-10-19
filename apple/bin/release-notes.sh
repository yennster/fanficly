#!/usr/bin/env bash
# What's changed since the last release, for the release workflow.
#
# Writes into build/release/:
#   previous-tag.txt  the last v* release tag before HEAD (empty for the first)
#   changes.md        the PRs merged into main and the issues closed since then,
#                     as Markdown bullets (the GitHub release lists them)
#   notes.txt         the App Store "What's New" / TestFlight text: $NOTES when
#                     given (the curated notes), else the merged PR titles
#
# Needs gh (GH_TOKEN) and the tags fetched (checkout with fetch-depth: 0).
# Usage: NOTES="…" bin/release-notes.sh
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/release
mkdir -p "$out"

prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)
printf '%s' "$prev" > "$out/previous-tag.txt"
if [ -n "$prev" ]; then
    since=$(TZ=UTC git log -1 --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format=%cd "$prev")
else
    since=1970-01-01T00:00:00Z
fi
echo "Changes since ${prev:-the beginning} ($since)" >&2

# Merged PRs and closed issues after the previous release's commit. PRs that
# only touch the Windows app (windows/ and its pictures and workflows) share
# main but aren't in this release, so they're left out.
prs=$(gh pr list --state merged --base main --limit 200 \
    --search "merged:>$since" --json number,title,files \
    --jq '[.[] | select(.files != [] and ([.files[].path | startswith("windows/") or startswith(".github/workflows/windows-")] | all) | not)]
          | sort_by(.number) | .[] | "- \(.title) (#\(.number))"')
issues=$(gh issue list --state closed --limit 200 \
    --search "closed:>$since reason:completed" --json number,title \
    --jq 'sort_by(.number) | .[] | "- \(.title) (#\(.number))"')

{
    if [ -n "$prs" ]; then printf '### Merged pull requests\n\n%s\n\n' "$prs"; fi
    if [ -n "$issues" ]; then printf '### Closed issues\n\n%s\n\n' "$issues"; fi
    if [ -z "$prs$issues" ]; then printf 'No pull requests merged since %s.\n' "${prev:-the first release}"; fi
} > "$out/changes.md"

if [ -n "${NOTES:-}" ]; then
    printf '%s\n' "$NOTES" > "$out/notes.txt"
else
    # Fallback: the user-facing PR titles (roadmap/docs/CI housekeeping left out).
    printf '%s\n' "$prs" \
        | grep -viE '^- (roadmap|docs?|ci|chore|website)\b' \
        | sed -E 's/^- /• /; s/ \(#[0-9]+\)$//' > "$out/notes.txt" || true
    [ -s "$out/notes.txt" ] || echo "Bug fixes and improvements." > "$out/notes.txt"
fi
cat "$out/changes.md" >&2
