#!/usr/bin/env python3
"""What's changed since the last release, for every app, for the Release workflow.

One release ships every app (iPhone, iPad and Mac through App Store Connect,
Windows through the Microsoft Store) from one v* tag, so the notes come from
everything that landed on main since the previous v* tag:

  - every pull request merged into main (main's first-parent history: a squash
    merge's "(#N)" or a merge commit's "Merge pull request #N"),
  - every commit pushed to main without a pull request,
  - every issue closed as completed since the previous tag's commit.

Writes into build/release/ (relative to apple/):
  previous-tag.txt   the last v* tag before HEAD (empty for the first release)
  changes.md         all of the above as Markdown, for the GitHub release
  notes.txt          the App Store "What's New" / TestFlight text
  notes-windows.txt  the Microsoft Store "What's new in this version" text

The store notes list the user-facing changes: pull requests and direct commits
that change an app's code (apple/Fanficly*/ for the Apple notes,
windows/src/ for the Windows notes; tests, docs, CI and the website are left
out). Each line is the pull request's title, tidied ("RM-003 (Windows): " and
"(RM-020 parity)" dropped) and de-duplicated across the two apps. A line
"Release note: <text>" in a pull request's description replaces its title;
"Release note: none" leaves it out.

NOTES (environment), when set, replaces both store texts (the Windows one is cut
to the Microsoft Store's 1,500 characters).

Needs git with the tags (checkout with fetch-depth: 0) and gh with GH_TOKEN for
the pull request titles and closed issues (REST only).
Usage: [NOTES="…"] bin/release-notes.py
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

APPLE_LIMIT = 4000     # App Store Connect "What's New"
WINDOWS_LIMIT = 1500   # Microsoft Store "What's new in this version"
FALLBACK = "Bug fixes and improvements."

APPLE_CODE = re.compile(r"^(apple/)?Fanficly(Widget|Share)?/")
WINDOWS_CODE = re.compile(r"^windows/src/")


def run(*args: str, check: bool = True) -> str:
    return subprocess.run(args, check=check, capture_output=True, text=True).stdout.strip()


def repo_slug() -> str:
    if os.environ.get("GITHUB_REPOSITORY"):
        return os.environ["GITHUB_REPOSITORY"]
    url = run("git", "remote", "get-url", "origin")
    m = re.search(r"github\.com[:/]([^/]+/[^/.]+?)(\.git)?$", url) or re.search(r"/git/([^/]+/[^/]+)$", url)
    if not m:
        sys.exit(f"Can't tell the GitHub repository from the origin URL {url!r}; set GITHUB_REPOSITORY.")
    return m.group(1)


def gh_api(path: str) -> object:
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def tidy(title: str) -> str:
    t = re.sub(r"^RM-\d+(\s*\([^)]*\))?:\s*", "", title)                 # "RM-003 (Windows): "
    t = re.sub(r"^(Windows|Apple|iOS|Mac|iPhone|iPad)( app)?:\s*", "", t)  # "Windows: "
    t = re.sub(r"\s*\((#\d+|RM-\d+ parity|Windows|Apple|iPhone, iPad, Mac)\)", "", t)
    t = t.strip().rstrip(".")
    return t[:1].upper() + t[1:]


def bullets(lines: list[str], limit: int) -> str:
    out: list[str] = []
    for line in lines:
        candidate = "\n".join(out + [f"• {line}"])
        more = "\n• …and more fixes and improvements"
        if len(candidate) + len(more) > limit:
            out.append("• …and more fixes and improvements")
            break
        out.append(f"• {line}")
    return "\n".join(out) if out else FALLBACK


def main() -> None:
    os.chdir(Path(__file__).resolve().parent.parent)
    out_dir = Path("build/release")
    out_dir.mkdir(parents=True, exist_ok=True)
    slug = repo_slug()

    prev = run("git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD", check=False)
    (out_dir / "previous-tag.txt").write_text(prev)
    rev_range = f"{prev}..HEAD" if prev else "HEAD"
    since = (datetime.fromtimestamp(int(run("git", "log", "-1", "--format=%ct", prev)), tz=timezone.utc)
             if prev else datetime(1970, 1, 1, tzinfo=timezone.utc))
    print(f"Changes since {prev or 'the beginning'} ({since:%Y-%m-%dT%H:%M:%SZ})", file=sys.stderr)

    overrides = {}
    tsv = Path("../.github/release-notes.tsv")
    if tsv.exists():
        for row in tsv.read_text().splitlines():
            if row.strip() and not row.startswith("#"):
                number, text = row.split("\t", 1)
                overrides[int(number)] = text.strip()

    # Each change on main: (kind, number or sha, title, files, release-note override).
    changes = []
    log = run("git", "log", "--first-parent", "--reverse", "--format=%H%x09%s", rev_range)
    for line in filter(None, log.splitlines()):
        sha, subject = line.split("\t", 1)
        # Files the change added, edited or deleted; a file that only moved isn't a change.
        files = run("git", "diff-tree", "--no-commit-id", "--name-only", "-r", "-m", "--first-parent",
                    "-M", "--diff-filter=ACDMT", sha).splitlines()
        m = re.search(r"\(#(\d+)\)$", subject) or re.match(r"Merge pull request #(\d+)\b", subject)
        if m:
            number = int(m.group(1))
            pr = gh_api(f"repos/{slug}/pulls/{number}")
            body = pr.get("body") or ""
            note = re.search(r"(?im)^\s*release note:\s*(.+?)\s*$", body)
            override = overrides.get(number) or (note.group(1) if note else None)
            changes.append(("pr", number, pr["title"], files, override))
        else:
            changes.append(("commit", sha[:7], subject, files, None))

    issues = []
    page = 1
    while True:
        batch = gh_api(f"repos/{slug}/issues?state=closed&since={since:%Y-%m-%dT%H:%M:%SZ}&per_page=100&page={page}")
        for issue in batch:
            closed = datetime.strptime(issue["closed_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            if "pull_request" not in issue and issue.get("state_reason") == "completed" and closed > since:
                issues.append((issue["number"], issue["title"]))
        if len(batch) < 100:
            break
        page += 1

    def apps(files: list[str]) -> list[str]:
        found = []
        if any(APPLE_CODE.match(f) for f in files):
            found.append("Apple")
        if any(WINDOWS_CODE.match(f) for f in files):
            found.append("Windows")
        return found

    # changes.md: everything, for the GitHub release.
    md = []
    prs = [c for c in changes if c[0] == "pr"]
    commits = [c for c in changes if c[0] == "commit"]
    if prs:
        md.append("### Merged pull requests\n")
        for _, number, title, files, _ in sorted(prs, key=lambda c: c[1]):
            where = apps(files)
            md.append(f"- {title} (#{number})" + (f" · {', '.join(where)}" if where else ""))
        md.append("")
    if commits:
        md.append("### Commits pushed to main\n")
        md += [f"- {title} ({sha})" for _, sha, title, _, _ in commits]
        md.append("")
    if issues:
        md.append("### Closed issues\n")
        md += [f"- {title} (#{number})" for number, title in sorted(issues)]
        md.append("")
    if not md:
        md.append(f"Nothing merged since {prev or 'the first release'}.")
    (out_dir / "changes.md").write_text("\n".join(md) + "\n")

    # The store notes: user-facing changes per app, oldest first, no repeats.
    def store_lines(app: str) -> list[str]:
        seen, lines = set(), []
        for _, _, title, files, override in changes:
            if app not in apps(files) or (override or "").lower() == "none":
                continue
            line = override or tidy(title)
            if line.lower() not in seen:
                seen.add(line.lower())
                lines.append(line)
        return lines

    notes = os.environ.get("NOTES", "").strip()
    if notes:
        apple_text = notes[:APPLE_LIMIT]
        windows_text = notes if len(notes) <= WINDOWS_LIMIT else notes[:WINDOWS_LIMIT - 1].rstrip() + "…"
    else:
        apple_text = bullets(store_lines("Apple"), APPLE_LIMIT)
        windows_text = bullets(store_lines("Windows"), WINDOWS_LIMIT)
    (out_dir / "notes.txt").write_text(apple_text + "\n")
    (out_dir / "notes-windows.txt").write_text(windows_text + "\n")

    for name in ("notes.txt", "notes-windows.txt", "changes.md"):
        print(f"\n== {name} ==\n" + (out_dir / name).read_text(), file=sys.stderr)


if __name__ == "__main__":
    main()
