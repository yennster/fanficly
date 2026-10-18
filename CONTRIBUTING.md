# Contributing to Fanficly

Thanks for wanting to help. A few quick guidelines.

This guide is for the iPhone, iPad and Mac app at the repository root. The Windows app lives in [`windows/`](windows/) and has [its own guide](windows/CONTRIBUTING.md). Both apps take pull requests against `main`.

## Setup

```bash
brew install xcodegen
git clone https://github.com/yennster/fanficly.git
cd fanficly
xcodegen generate
open Fanficly.xcodeproj
```

## Principles

1. **Be a good guest to AO3.** Don't increase request volume, don't parallelize scrapes per user, don't bypass our throttle. If you're adding a feature that needs more requests, profile it first and discuss in an issue.
2. **No telemetry, no analytics, no third-party SDKs.** Period. The privacy story is the headline feature.
3. **Never make search guess.** Typed words stay keywords for AO3's own search; tags become filters only when the user taps a suggestion. A new `key:value` token in `SearchSyntax` needs a round-trip test. Add a phrase to its filter-only list only if it can never mean anything but that filter, with tests for both the conversion and everyday text that must stay a keyword.
4. **Match AO3's terminology.** Use the same field names and category names AO3 uses (relationships, freeforms, categories, archive warnings).
5. **Keep dependencies minimal.** Adding a new SPM package needs a justification in the PR description.

## What to work on

The backlog is [docs/ROADMAP.md](docs/ROADMAP.md): small, scoped items with IDs (`RM-nnn`) and a "Done when". Run `bin/roadmap.sh free` to see what's unclaimed. Claim an item by opening a draft PR from a `roadmap/RM-nnn-slug` branch. AI agents follow the loop in [AGENTS.md](AGENTS.md#autonomous-roadmap-work); a human always does the merge.

## Pull requests

- One feature/fix per PR.
- Reference an issue if one exists.
- Make sure the unit tests pass on iPhone and iPad simulators and under Mac Catalyst (CI runs all three).
- If you change the reader, also run `FanficlyUITests/ReaderLayoutTests` (see the README's Tests section).
- Don't reformat code you didn't touch.
- Be kind in code review.

## Reporting bugs

Open an issue with:
- iOS version
- Device or simulator
- Steps to reproduce
- What you expected vs. what happened
- A redacted log (`os_log` output) if you have one

## Code of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
