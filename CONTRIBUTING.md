# Contributing to Fanficly

Thanks for wanting to help. This repository holds two apps, each with its own guide:

- **iPhone, iPad and Mac** (`apple/`): [apple/CONTRIBUTING.md](apple/CONTRIBUTING.md)
- **Windows** (`windows/`): [windows/CONTRIBUTING.md](windows/CONTRIBUTING.md)

What applies to both:

1. **Be a good guest to AO3.** Every request goes through the app's AO3 client and its one-request-a-second throttle. Never scrape in parallel or retry a POST.
2. **No telemetry, no analytics, no third-party SDKs.** If you change what's stored or sent, update that app's privacy policy ([PRIVACY.md](PRIVACY.md) or [windows/PRIVACY.md](windows/PRIVACY.md)).
3. **Never make search guess.** Typed words stay keywords; tags become filters only when the user picks a suggestion.
4. **One app per pull request**, against `main`. CI builds only the app whose folder you changed.

## What to work on

Each app has a roadmap of small items with permanent IDs: [apple/docs/ROADMAP.md](apple/docs/ROADMAP.md) (`RM-001` up) and [windows/ROADMAP.md](windows/ROADMAP.md) (`RM-101` up). `bin/roadmap.sh free apple` or `bin/roadmap.sh free windows` lists what's unclaimed. Claim an item by opening a draft PR from a `roadmap/RM-nnn-slug` branch. AI agents follow [AGENTS.md](AGENTS.md); a person always does the merge.

## Code of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
