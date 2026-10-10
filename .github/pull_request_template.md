<!-- One feature or fix per PR. For roadmap work, the title starts "RM-nnn: ". -->

## What and why

Roadmap item: RM-nnn (or "none")

## How it was checked

- [ ] Unit tests added/updated, and listed here:
- [ ] CI is green on iPhone, iPad and Mac Catalyst (or: still running / failing, and why)
- [ ] Reader changes: `ReaderLayoutTests` passed in CI
- [ ] Not built locally (no Xcode): validation is CI only
- [ ] Needs a human look on a device or simulator: (say what to look at)

## Guardrails

- [ ] Only goes through `AO3Client` (throttled); no POST retries
- [ ] No new dependencies, analytics or off-device data
- [ ] Search still never reinterprets typed words
- [ ] New persisted fields are forward-only for restore/merge
- [ ] `docs/ROADMAP.md`: this item's Status set to `done`, nothing else changed
- [ ] AGENTS.md updated if a convention or gotcha changed
