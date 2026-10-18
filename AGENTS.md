# AGENTS.md — the Fanficly repository

Fanficly is an AO3 reader with two native apps on one `main` branch. This file holds the repository-wide rules; each app has its own guide with its architecture, tests and gotchas. `CLAUDE.md` just imports this file, so edit this one, never that one.

| Changing | Read | Claude Code loads it |
| --- | --- | --- |
| `apple/` (SwiftUI app for iPhone, iPad, Mac) | [`apple/AGENTS.md`](apple/AGENTS.md) | through `apple/CLAUDE.md` once you work in `apple/` |
| `windows/` (WinUI 3 app) | [`windows/AGENTS.md`](windows/AGENTS.md) | through `windows/CLAUDE.md` once you work in `windows/` |

Read the app's guide before changing anything in its folder; its paths are relative to that folder.

## Layout

```text
apple/        the Apple app: project.yml, Fanficly*/, bin/ (its scripts), docs/ROADMAP.md,
              docs/screenshots/{iphone,ipad,mac,duo-*}, screenshots/ (store art), appstore/
windows/      the Windows app: Fanficly.Windows.slnx, src/, tests/, store/, ROADMAP.md
website/      fanficly.app; Vercel builds it from main and skips unchanged builds
docs/screenshots/windows/  Windows README pictures (written by windows-screenshots.yml)
bin/roadmap.sh             lists both roadmaps: `bin/roadmap.sh free apple|windows`
PRIVACY.md    the Apple app's privacy policy; it stays at the root because the App Store
              listing and the website link to this URL
.agents/      Linux orb setup (the Apple app's Python tooling in apple/bin/.venv)
.github/      ci.yml (apple/**), windows-ci.yml / windows-store.yml / windows-screenshots.yml
              (windows/**), release.yml / store-assets.yml (Apple releases, run by hand;
              apple/docs/RELEASING.md), the PR template
```

## Rules for both apps

- **Keep a PR to one app.** CI is path-filtered: `ci.yml` runs for `apple/**`, the Windows workflows for `windows/**` (plus their own files). Shared files (this one, the root README, `bin/roadmap.sh`) can change with either.
- **Privacy is the headline feature.** No servers, analytics, crash reporters or SDKs with a network side-channel. Each app's privacy policy is a store listing's policy: keep it accurate.
- **Be a good guest to AO3.** Every request goes through the app's AO3 client and its 1 request/second throttle; never retry a POST.
- **Search never guesses.** Typed words stay keywords; only picked suggestions and explicit `key:value` tokens become filters.
- **The Swift app is the reference.** The Windows app ports its behavior; don't change `apple/` from a Windows PR.
- **Releases are the maintainer's.** Don't push `windows-v*` or `v*` tags, upload to a store, or change store metadata, version numbers or signing unless the maintainer asks.
- **Roadmap IDs are permanent.** Apple items are `RM-001` up, Windows items `RM-101` up; never renumber or reuse one.
