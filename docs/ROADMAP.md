# Fanficly roadmap

Last reviewed: 2026-10-10, at 1.10.0 (build 31). Written from the code, not from wishes: every item below names the files it touches and what already exists.

Agents: read [Autonomous roadmap work](../AGENTS.md#autonomous-roadmap-work) in AGENTS.md before picking anything. Humans: reorder, add and strike items freely. This file is the backlog. Each item is also mirrored as a GitHub issue titled `RM-nnn: …` (#37–#56, and RM-021 onward as added) for discussion; if they disagree, this file wins. Claims are PRs, never issue assignments.

## Where the app is

Fanficly is a mature, local-first AO3 reader: search with typeahead and filters, Browse and Popular, a three-mode reader (continuous, chapter, page-by-page with a two-page spread), reader profiles, on-device TTS, a library with folders and sorting, local follows with background polling, reading stats, a last-read widget, iCloud backup merge, a Safari share extension, and iPhone, iPad, Mac Catalyst and iPhone Duo layouts. About 240 unit tests, plus reader layout UI tests in CI.

What's thin or missing, from reading the code:

- **Series.** Only the search parser and subscriptions know the word; there's no series page, no "part 2 of 5" in the reader, no next-in-series.
- **Per-work memory.** No notes, no personal tags. Only one block mechanism: hiding a single work (`HiddenWork`). No tag or author blocklist.
- **AO3 account actions.** Login, subscribe, bookmarks (read-only) and comments exist. Kudos, creating a bookmark, Marked for Later and history do not.
- **Comments** are work-level, first page only (a documented follow-up in AGENTS.md).
- **Offline.** Downloads are one work at a time. There's no bulk download for a folder or the followed list.
- **System integration.** Six home-screen widgets exist (last read, streak, subscriptions, folders, saved searches, recommendations) but no lock-screen families and no App Shortcuts. Followed works are indexed in Core Spotlight (`WorkPersistence.indexWork`), but nothing handles a tap on a Spotlight result (no `CSSearchableItemActionType` handler). The saved-search widget's `fanficly://search?query=` route carries filter JSON the consumer can't read (documented limitation in AGENTS.md).
- **iPhone Duo.** Vertical toolbars need `Label` items, and the ellipsis symbol clashes with the system overflow menu (AGENTS.md "Not done yet").
- **Localization.** English only.

## Principles every item must respect

1. **Privacy posture.** Nothing leaves the device except requests to AO3 and the user's own iCloud. No analytics, no SDKs, no off-device AI.
2. **Good guest to AO3.** Everything goes through `AO3Client` and its 1 req/sec throttle. New features add as few requests as possible, never parallelize scrapes, and never retry a POST.
3. **Never guess in search.** See "Search never silently reinterprets words".
4. **Forward-only sync.** New persisted fields obey the restore rules (newer wins, OR for flags, never regress).
5. **Plain, calm UI.** VoiceOver labels on every icon-only control; no new nav-bar clutter in the reader.

## Non-goals

Servers or accounts of our own, ads, telemetry, a "trending" feed we'd have to scrape heavily, posting or editing works, off-device recommendation, images on by default, and auto-hiding reader chrome (tried twice, left alone).

## How items are written

Each item is a heading `### RM-nnn — Title` followed by a `Status:` line the tooling reads. IDs are permanent: never renumber, never reuse. New ideas get the next free number.

- **Status:** `open` (free to claim), `claimed` (an open PR or `roadmap/RM-nnn-*` branch exists; the PR is the claim, not this file), or `done`.
- **Size:** `S` is about one file plus tests, `M` is a few files plus tests. Anything bigger must be split into new `S`/`M` items before it's started.
- **Validation:** `unit` = fully provable by XCTest on a Mac or in CI. `mac` = also needs a person to look at it in a simulator, so say so in the PR. Agents on a Linux orb can't compile Swift, so every item is validated by CI on the PR.

---

## Now (1.11, small and self-contained)

### RM-001 — Parser fixture hardening
- **Status:** open · **Size:** S · **Validation:** unit
- **Why:** Scraping is the app's only data source. `SubscriptionsParser` already fails closed (login page → `unauthorized`, no list and no shell → `parseFailed`); the other parsers silently return empty arrays on markup drift.
- **Scope:** Give `SearchResultsParser`, `WorkPageParser`, `MediaCategoryParser` and `WorkFiltersParser` the same treatment: a login or error page throws `AO3Error.unauthorized` or `parseFailed` rather than returning `[]`, and callers that would delete or overwrite data on an empty result keep skipping on a throw. Genuine zero-result pages (AO3's "No results found") must still return `[]`.
- **Done when:** each parser has tests for a genuine empty page, a login page and a garbage page; no caller regresses (search shows an error, not "No results", for a login page).
- **Touches:** `Networking/HTMLParsers/*`, `FanficlyTests/*ParserTests.swift`.

### RM-002 — "Read" and "In Library" badges on result rows
- **Status:** open · **Size:** S · **Validation:** unit + mac
- **Why:** Search and Browse can't tell you what you've already read or saved.
- **Scope:** `WorkRow` shows a small badge ("In Library", "Finished", or a percent) using the existing `Work` and `ReadingProgress` rows. Compute the lookup once per result page as a `[Int: Badge]` from one fetch, not one fetch per row. Put the pure mapping in a testable function.
- **Done when:** mapping tests cover saved, started, finished and unknown works; VoiceOver reads the badge as part of the row (`.accessibilityElement(children: .combine)` is only safe if the row holds no `Link` or button — it holds the bookmark button, so label the badge instead).
- **Touches:** `Search/SearchView.swift` (`WorkRow`), `Library/WorkPersistence.swift`.

### RM-003 — Reading-time estimate
- **Status:** open · **Size:** S · **Validation:** unit
- **Why:** Word counts alone are hard to judge. `ReadingStat` already records real active seconds and words read, so a personal words-per-minute exists.
- **Scope:** A pure `ReadingSpeed` helper: personal WPM from `ReadingStat` (clamped to 120–600, falling back to 250 until there are ≥ 3 finished works), and a formatted "~45 min" string. Show it in `WorkRow` and `WorkHeaderMetadata` next to the word count.
- **Done when:** tests cover the fallback, clamping, and formatting at 0, < 1 min, minutes, and hours. No new persisted data.
- **Touches:** `Reader/WorkHeaderMetadata.swift`, `Search/SearchView.swift`, new helper in `Reader/ReadingProgressStore.swift` (don't add a file).

### RM-004 — Lock-screen widget for last read
- **Status:** open · **Size:** S · **Validation:** mac
- **Why:** None of the six widgets support the lock screen.
- **Scope:** Add `accessoryRectangular` and `accessoryCircular` families to `FanficlyWidget` showing title and progress, using the same `WidgetProgressStore` data and resume URL. No new data path.
- **Done when:** previews exist for both families; the tap target is the existing `fanficly://resume/…` URL; the widget target still builds. State in the PR that it needs a look on a device or simulator.
- **Touches:** `FanficlyWidget/FanficlyWidget.swift`.

### RM-020 — Make the saved-search widget route work
- **Status:** open · **Size:** S · **Validation:** unit
- **Why:** AGENTS.md ("Other widgets and shortcut routes") documents that the saved-search widget puts saved-filter JSON in `fanficly://search?query=`, but `SearchView.consumePendingQuery` expects prompt syntax, so tapping a saved search doesn't run it.
- **Scope:** Have the widget write `AO3SearchFilters.promptText()` (the `key:value` rendering `SearchSyntax.parse` reads back exactly) instead of JSON, or decode JSON explicitly in the consumer; pick one and document the contract. Old widget URLs must not crash the consumer.
- **Done when:** a round-trip test (saved filters → URL → pending query → parsed filters equal), plus a test that a legacy JSON query degrades to a plain keyword search. Update the "Current limitation" note in AGENTS.md.
- **Touches:** `FanficlyWidget/FanficlyWidget.swift`, `WidgetDataStore.swift`, `Search/SearchView.swift`.

### RM-005 — Duo-ready toolbar labels
- **Status:** open · **Size:** M · **Validation:** mac
- **Why:** With the 27.1 SDK toolbars go vertical on the iPhone Duo and want a title plus symbol. The Duo ships Oct 23 2026.
- **Scope:** Convert the reader's toolbar items (chapters, Aa, minimize, export, options) from `Image` to `Label`, with `.labelStyle(.iconOnly)` where the bar is horizontal. Replace the `ellipsis.circle` options symbol with a non-ellipsis one so it stops clashing with the system overflow. Keep the parent to ≤ 2 items.
- **Done when:** `ReaderLayoutTests` pass on iPhone and iPad; the PR attaches the reader-layout screenshots artifact and says the Duo pose was not checked unless someone ran it.
- **Touches:** `Reader/ReaderView.swift`, `Search/SearchView.swift` (`WorkDetailView`), `Library/SavedWorkReader.swift`.

## Next (1.12)

### RM-006 — Tag and author blocklist
- **Status:** open · **Size:** M · **Validation:** unit
- **Why:** The only block today is one work at a time (`HiddenWork`).
- **Scope:** A local blocklist of tags and author usernames, applied in `ContentFilter.apply` alongside hidden works and the Mature filter. Add it from a work's tag chip or byline and manage it in Settings → Content. New `@Model` `BlockedTerm` (kind, value, createdAt) registered in `FanficlyApp.sharedModelContainer` and the `PersistenceTests` schema, included in the iCloud backup as a union (deletions don't propagate, like the rest).
- **Done when:** filter tests cover tag match (case-insensitive, AO3 canonical names), author match, no match, and an empty list; backup merge test shows two devices union their lists. A blocked tag never hides a work the user opened on purpose (direct links, library).
- **Touches:** `Settings/ContentFilter.swift`, `Models/Work.swift`, `Library/iCloudSyncManager.swift`, `Settings/SettingsView.swift`.

### RM-007 — Series page and "next in series"
- **Status:** open · **Size:** M · **Validation:** unit
- **Why:** Series are how many readers move between stories, and Fanficly can't follow one.
- **Scope:** A `SeriesParser` for `/series/<id>` (title, author, works in order) and `AO3Endpoints.series`; `AO3Client.fetchSeries` through the throttle; a `SeriesView` reached from a series link in the work header. Parse "Part N of <series>" from the work page's `dd.series` into `AO3WorkMetadata` (optional fields, so saved data and backups still decode).
- **Done when:** parser tests with inline HTML (series with 1 work, several, a work in two series, a deleted entry); endpoint test; `MockAO3Client` and `DemoAO3Client` implement the new method. Put `SeriesView` in an existing file.
- **Touches:** `Networking/*`, `Networking/HTMLParsers/`, `Reader/WorkHeaderMetadata.swift`, `Browse/BrowseView.swift`.

### RM-008 — Per-chapter comments
- **Status:** open · **Size:** M · **Validation:** unit
- **Why:** AGENTS.md lists this as a known follow-up: on multi-chapter works, comments are work-level and first-page only. `fetchComments`/`postComment` already take a `chapterId`.
- **Scope:** Resolve the current chapter's AO3 chapter id (already scraped as `div.chapter[id^=chapter-]`) and pass it through `CommentsView`; add "Load more" for comment pagination (`page=`). Comment posting stays a single non-retried POST.
- **Done when:** parser/endpoint tests for the chapter-scoped URL and page parameter; `CommentsView` still works for one-shot works with no chapter id.
- **Touches:** `Search/SearchView.swift` (`CommentsView`), `Networking/AO3Endpoints.swift`, `Networking/AO3Client.swift`.

### RM-009 — Notes and personal tags on library works
- **Status:** open · **Size:** M · **Validation:** unit
- **Why:** AO3 tags describe the story; readers also want "for a bad day" or "reread at Christmas".
- **Scope:** Optional `note: String?` and `personalTags: [String]` fields on `Work` (additive schema; defaults keep migration automatic). Edit them from the Library row's context menu; Library search matches them. Back up and restore with forward-only semantics: a non-empty value never gets overwritten by an empty one, and when both sides differ, local wins.
- **Done when:** persistence tests, backup merge tests (old backup without the fields decodes), library search test.
- **Touches:** `Models/Work.swift`, `Library/LibraryView.swift`, `Library/iCloudSyncManager.swift`.

### RM-010 — Bulk download for a folder
- **Status:** open · **Size:** M · **Validation:** unit
- **Why:** Offline reading before a flight means tapping download on each work.
- **Scope:** "Download all" on a custom folder, reusing the sequential, cancellable queue pattern from `RestoreDownloadCenter` (candidates: works with no `WorkPersistence.epubURL`). Progress banner, cancel keeps what finished. The 1 req/sec throttle paces it; no parallelism.
- **Done when:** the candidate selection and progress bookkeeping are pure and tested; cancelling mid-run keeps finished downloads.
- **Touches:** `Library/RestoreDownloadCenter.swift`, `Library/LibraryView.swift`.

### RM-011 — Yearly reading goal
- **Status:** open · **Size:** S · **Validation:** unit
- **Why:** The Stats tab reports; it doesn't invite.
- **Scope:** An optional goal (stories finished this year) stored in `@AppStorage`, shown as a progress ring on the Stats tab and in the wrap card. Pure progress/pace function in `ReadingStatsAggregator` ("on pace", "3 ahead").
- **Done when:** tests for pace at year start, mid-year, past the goal, and a zero goal (hidden). The setting is per-device and not synced, so there's no sync risk.
- **Touches:** `Library/LibraryView.swift` (`StatsView`, `WrapShareCard`), `Reader/ReadingProgressStore.swift`.

### RM-012 — Library export and import as a file
- **Status:** open · **Size:** S · **Validation:** unit
- **Why:** iCloud backup is opt-in and tied to one Apple ID; a plain file is a safe fallback and a way to move between accounts.
- **Scope:** Reuse the backup encoder: "Export library file…" writes the JSON to the share sheet; "Import…" runs it through the existing forward-only restore merge. No new merge rules.
- **Done when:** a round-trip test (export → restore into an empty in-memory container) and a test that importing an older file never moves progress backwards.
- **Touches:** `Library/iCloudSyncManager.swift`, `Settings/SettingsView.swift`.

## Later (needs design, or a person at a Mac)

### RM-013 — Leave kudos
- **Status:** open · **Size:** M · **Validation:** unit + mac
- **Scope:** A POST to `/kudos` with the scraped token, from the work's options menu, login-gated, once per work and remembered locally so it doesn't invite a double-tap. Same CSRF flow as comments. Never retried.
- **Open question:** AO3 returns guest-kudos differently from logged-in kudos; confirm against the live site by hand before shipping.

### RM-014 — Create and edit AO3 bookmarks
- **Status:** open · **Size:** M · **Validation:** unit + mac
- **Scope:** The Bookmarks tab is read-only today. Add "Bookmark on AO3" (with notes, tags, rec, private) as a POST to `/works/<id>/bookmarks`. Needs the form scraped for field names; must be tested against the live site by hand.

### RM-015 — Marked for Later and history import
- **Status:** open · **Size:** M · **Validation:** unit
- **Scope:** Login-gated list of `/users/<name>/readings?show=to-read`, parsed like the bookmarks page (reuse `SearchResultsParser` with a blurb selector). Read-only first.

### RM-016 — Open Spotlight results, and App Shortcuts
- **Status:** open · **Size:** M · **Validation:** mac
- **Scope:** Handle `CSSearchableItemActionType` (`work-<id>` identifiers from `WorkPersistence.indexWork`) by routing through the existing resume route; index every saved library work, not only followed ones (deindex on delete); add a "Continue reading" App Shortcut. Index data stays on-device.

### RM-017 — Localization groundwork
- **Status:** open · **Size:** M (the groundwork only) · **Validation:** mac
- **Scope:** Move user-facing strings to a String Catalog, one screen family per PR. Do not translate yet. AO3 tag and category names stay in AO3's exact English forms.

### RM-018 — Split the big view files
- **Status:** open · **Size:** M · **Validation:** unit
- **Why:** `SearchView.swift` holds search, `WorkDetailView` and `CommentsView`.
- **Scope:** Move types verbatim to their own files. This needs `xcodegen generate` and a committed `.xcodeproj`, which is why it isn't done in passing. Do it as the only change in the PR, with no behavior edits.

### RM-019 — Accessibility audit of non-reader screens
- **Status:** open · **Size:** S per screen · **Validation:** mac
- **Scope:** Walk Library, Stats, Subscriptions and Settings at the largest Dynamic Type size and with VoiceOver; fix truncation and unlabeled controls; add a UI test that asserts labels on a screen's icon-only buttons. One screen per PR.

### RM-021 — Shift-⌘ +/− to change the Mac UI size
- **Status:** open · **Size:** S · **Validation:** unit + mac
- **Why:** Global UI zoom (`app.zoomScale` in `RootView`) is bound to hidden buttons for ⌘+, ⌘=, ⌘− and ⌘0 only. The request is to also change the interface size with ⇧⌘+ / ⇧⌘− (and ⇧⌘= for keyboards where + needs no shift), and to make the shortcuts discoverable.
- **Scope:** Add the Shift-⌘ bindings to the existing zoom in/out actions (no second zoom mechanism, same step and min/max clamp). Move the zoom commands into a "View" `CommandMenu` in `FanficlyApp` so they show in the Mac menu bar with their shortcuts, instead of hidden buttons. Keep the existing ⌘ bindings working unless the maintainer says to drop them. Extract the clamp/step into a pure function.
- **Open question for the maintainer:** should ⌘+/− keep controlling UI size, or move to reader text size, leaving only ⇧⌘+/− for UI? The PR keeps both until told otherwise.
- **Done when:** tests for the pure step/clamp function (up at max, down at min, 1.0 reset); the PR lists the shortcuts to try on a Mac, including a non-US layout if available. Mac Catalyst only; iPad hardware keyboards get the same bindings harmlessly.
- **Touches:** `RootView.swift`, `FanficlyApp.swift`.

## Engineering health (any release)

Not features, but worth doing; add as items when started.

- `AGENTS.md` is the only agent guide; `CLAUDE.md` just imports it. Update AGENTS.md.
- Keep the unit-test count in AGENTS.md roughly honest when a PR adds a test file.
- Every new `AO3ClientProtocol` method lands with `MockAO3Client`, `DemoAO3Client` and `StubAO3Client` support in the same PR.
- Release housekeeping (version bump, screenshots, App Store metadata) is done by the maintainer, never by a roadmap PR.
