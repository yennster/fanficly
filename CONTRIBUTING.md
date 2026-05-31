# Contributing to Fanficly

Thanks for wanting to help. A few quick guidelines.

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
3. **Test the parser.** New rules in `SearchPromptParser` need unit tests covering both positive and negative cases.
4. **Match AO3's terminology.** Use the same field names and category names AO3 uses (relationships, freeforms, categories, archive warnings).
5. **Keep dependencies minimal.** Adding a new SPM package needs a justification in the PR description.

## Pull requests

- One feature/fix per PR.
- Reference an issue if one exists.
- Make sure `xcodebuild test` passes on both iPhone and iPad simulators.
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
