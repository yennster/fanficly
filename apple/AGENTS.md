# AGENTS.md — working on Fanficly for iPhone, iPad and Mac

Architecture, development workflow, and regression constraints for agents working
on the Apple app in `apple/`. **Paths in this guide are relative to `apple/`**,
and commands run from there, except `bin/roadmap.sh`, which is at the repository
root. Claude Code loads this file through `apple/CLAUDE.md` when you work in this
folder; the repository-wide rules are in the root [`AGENTS.md`](../AGENTS.md). Read the overview first, then the detailed section for the
subsystem you change. Keep this file current when ownership or behavior changes,
and verify implementation details against source. This is the agent guide
for the Apple app: `apple/CLAUDE.md` just imports it, so edit this file, never that one.
The Windows app in `windows/` has its own guide, [`windows/AGENTS.md`](../windows/AGENTS.md).
Picking up roadmap work? Go straight to [Autonomous roadmap work](#autonomous-roadmap-work).

## What this is

A SwiftUI app (iPhone + iPad, plus Mac via Catalyst; iOS 17+, Swift 6) that reads AO3 fanfiction. There is no AO3 JSON API, so the app talks to AO3 by scraping HTML with SwiftSoup, using one shared `URLSession` with a custom `User-Agent` and a 1 req/sec throttle. Everything runs on-device — no servers, no analytics.

## Start here

- **Two apps, one branch:** this app is `apple/` (everything below); the
  Windows app is `windows/`. Both ship from `main`. CI is path-filtered:
  `.github/workflows/ci.yml` runs for `apple/**` (and itself), the Windows
  workflows for `windows/**`. Keep a PR to one app. The privacy policy is the
  repository root's `PRIVACY.md`, because the App Store listing links to it there.
- **Project/build truth:** `project.yml` defines all five targets, Swift 6 strict
  concurrency, dependencies, generated Info.plists, entitlements, and schemes.
  Regenerate with XcodeGen; do not hand-edit the generated project. Keep the iOS
  17 baseline working and guard newer SDK APIs. Discover installed destinations;
  simulator names and the device-specific notes below are not build prerequisites.
- **Product rules:** reading/search/local follows require no account. AO3
  bookmarks, subscriptions, and posting comments require login. Follow is not
  subscribe; saved text is not an EPUB download. Never guess tags from keywords.
- **Data safety:** preserve existing offline chapters, timestamped progress,
  subscription notification baselines, and forward-only iCloud merges. SwiftData
  is local (`cloudKitDatabase: .none`), not automatically CloudKit-synchronized.
- **Network/privacy:** all AO3 requests use the injected client and its throttle.
  No telemetry or backend. Opt-in story images are the explicit external-host
  exception; keep their URL restrictions. Never log passwords, cookies, or keys.
- **Validation:** use fixture/unit tests for logic, demo-mode UI tests for layout,
  and a Mac for native execution. This Linux orb cannot build or run the app.
  See [Tests](#tests) and [Linux orbs](#linux-orbs).
- **Related docs:** `README.md` (user features/setup), `CONTRIBUTING.md` (change
  policy), `ACCESSIBILITY.md`, `../PRIVACY.md`, `../.github/workflows/ci.yml` (actual CI).
  Releases run in GitHub Actions (`../.github/workflows/release.yml`,
  `store-assets.yml`; lanes in `fastlane/Fastfile`), described in
  `docs/RELEASING.md`. Never run them, cut a release, or upload assets unless
  the maintainer asks for that release.

## Architecture and runtime ownership

This is a native app with feature-organized SwiftUI views, small stores/helpers,
and an actor-backed network boundary, not a web app or a separate view-model
layer. Views own transient loading/error/task state in `@State`, read settings
with `@AppStorage`, query local models with `@Query`, and receive the client,
authentication state, and model context through the environment.

```text
FanficlyApp (composition root: client + AuthState + ModelContainer)
  └─ RootView (adaptive navigation, incoming URLs, notification routes)
       ├─ Search / Browse / authors / account lists
       │    └─ AO3ClientProtocol → AO3Client actor → throttled AO3 requests
       │         └─ pure HTML parsers → Sendable summaries / work payloads
       ├─ WorkDetailView (live payload) / SavedWorkReader (saved or fetched)
       │    └─ ReaderView → HTML paragraphs / pagination / on-device speech
       │         └─ progress + stats → local models / widget snapshots
       └─ Library / Settings → local persistence + optional iCloud backup
BackgroundRefresh → SubscriptionPoller → same client + local model container
```

**Composition and launch (`FanficlyApp.swift`).** The app creates one live
`AO3Client` (or `DemoAO3Client`), `AuthState`, and shared `ModelContainer`.
`NotificationTapHandler` installs in `init`, before launch completes. Normal
launch installs progress/profile/streak KVS observers. The launch task migrates
legacy single-folder relationships into `Work.folders`, restore-merges a changed
iCloud backup when enabled, then backfills reading stats. `RootView` separately
seeds demo data and presents the first-launch age gate. On backgrounding, the app
schedules refresh and backs up when enabled; the refresh handler schedules the
next request and runs the poller. The default four-hour earliest refresh date
is a request to iOS, not a guaranteed polling interval.

**Concurrency boundary.** `AO3ClientProtocol: Sendable` is the dependency seam;
`AO3Client` and `ThrottleActor` isolate networking and scheduling. Parsed payloads
are value types, not SwiftData objects. UI-facing stores and persistence helpers
use `@MainActor`; do not pass a view's `ModelContext` or `@Model` instances into
detached tasks. `BackgroundRefresh.runPoll` creates its own context from the
shared container. Keep cancellation effective and never retry write requests.

**Navigation ownership.** `RootView` owns `SidebarItem`, the split view,
`compactSelection`, and the detail `NavigationPath`; persisted
`app.selectedTabRaw` also drives the Go menu. Compact cold launch starts at the
sidebar; resizing preserves the current detail. Work/author list destinations
are shared through `.workAndAuthorDestinations()` in `SearchView.swift`.
Root-level resume and notification routes have special cold/warm handling; read
their detailed sections before changing path or tab selection. Import accepts
share-extension URLs, dropped URLs/text, and paste providers. Folder and search
widget routes use their own paths described below.

**Fetching and reading.** Search syntax becomes `AO3SearchFilters`; endpoints
encode it, the client fetches, and SwiftSoup parsers produce typed results.
Opening a live result uses `WorkDetailView` in `SearchView.swift`; merely reading
does not require creating a library `Work`. `SavedWorkReader` reads stored
`Chapter.bodyHTML` when available, otherwise fetches a payload on demand. Both
feed `ReaderView`. There is no EPUB rendering engine: chapter HTML is converted
to attributed paragraphs and drawn natively. `ReaderPaginator` and
`ReaderPageCell` live in `ReaderView.swift`; geometry policy lives in
`ReaderTheme.swift`. Modes are continuous, swipe-by-chapter, and page-by-page.

## Storage map and mutation contracts

| Data | Owner / storage | Important distinction |
| --- | --- | --- |
| Library metadata and text | `Models/Work.swift`: `Work` → `Chapter` (cascade delete), `CustomFolder` relationships | `upsertMetadata` preserves chapter bodies; `upsert(payload:)` replaces them. |
| Local activity | `ReadingProgress`, `RecentlyViewed`, `ReadingStat` | Keyed by AO3 work ID independently of a saved `Work`; reading unsaved stories still records progress/stats. |
| Follows/account records | `Work.isFollowed`, `FollowedAuthor`, `SubscriptionRecord`, `BookmarkRecord` | Remote Bookmarks UI fetches live; these model types do not imply every AO3 record is cached. |
| Search/safety records | `SavedSearch`, `SavedFilter`, `HiddenWork`, `TagRecord` | Saved filters encode `AO3SearchFilters` as JSON; saved search prompts round-trip through `SearchSyntax`. |
| EPUB files | `Documents/library/<workId>.epub`, via `AO3Client.downloadEPUB` | `WorkPersistence.epubURL` checks file existence, not `Work.epubLocalPath`. Offline chapter text and the Downloaded badge are separate. |
| Export files | Temporary directory via `AO3Client.exportWork` / `WorkExporter` | Exporting a format is not saving chapter text into the library. |
| Settings/cache | `UserDefaults` / `@AppStorage` | Reader typography uses per-device keys; popular snapshot and recent searches are not SwiftData models. |
| Login | `CredentialStore` in `Auth/Credentials.swift` | Keychain stores username and serialized AO3 cookies; passwords are never persisted. The live session uses shared cookie storage. |
| Widget snapshots | App-group defaults (`group.io.github.yennster.fanficly`) | Extension reads Codable snapshots, not the app's SwiftData database. |
| Cross-device sync | `iCloudSyncManager` file backup; separate KVS stores for profiles, last-read progress, streak | Library backup is opt-in; its switch is not a master switch for the KVS channels. |

All 13 SwiftData types are registered in `FanficlyApp.sharedModelContainer`.
Adding a model requires checking the test schema, backup DTOs and merge/restore,
demo seed, deletion behavior, and any widget snapshot it affects. Registration
alone does not add backup coverage: currently `TagRecord`, `RecentlyViewed`, and
`FollowedAuthor` are not serialized by `iCloudSyncManager`.

Mutations often save the context and call `iCloudSyncManager.queueBackup`.
That method first refreshes widget snapshots **even with library sync off**,
then debounces the optional backup by two seconds. Do not assume a raw
`context.save()` updates widgets or cloud data. `ReadingProgressStore.save`
updates the per-ID anchor, existing `Work.lastRead*`, streak, and widget snapshots
(the last-read widget only when a progress fraction is supplied).
Chapter indices are one-based; paragraph indices
are zero-based. Keep those indices aligned between parsing, rendering, speech,
pagination, saved anchors, and resume URLs.

## Layout

```
project.yml                    # xcodegen is the source of truth
bin/                           # developer scripts (icon gen, screenshots,
                               #   store art); ../bin/roadmap.sh = list and
                               #   claim-check roadmap items (repo root)
docs/ROADMAP.md                # the backlog (RM-nnn items); agents: see below
docs/RELEASING.md              # cloud release + store-art workflows, secrets
docs/screenshots/              # demo-mode captures (iphone, ipad, mac, duo-*)
fastlane/                      # Fastfile (lanes) + store copy; generated art
                               #   and keys are git-ignored
../.github/                    # workflows (ci.yml = this app; release.yml and
                               #   store-assets.yml run fastlane) + PR template
../PRIVACY.md                  # this app's privacy policy (the App Store links it)
Fanficly/
  FanficlyApp.swift            # @main, env wiring, ModelContainer, BG task
  RootView.swift               # NavigationSplitView sidebar (Search, Browse,
                               #   Popular, Library, Stats, Recently Viewed,
                               #   Authors, Bookmarks, Subscriptions, Settings);
                               #   global zoom (app.zoomScale, UIZoom); deep links
                               #   (import, resume, folder, search) + notifications
  AO3ClientEnvironment.swift   # @Environment(\.ao3Client) key
  WidgetProgressStore.swift    # last-read progress for the widget: app-group
                               #   defaults + iCloud KVS mirror (debounced);
                               #   compiled into both app and widget targets
  WidgetDataStore.swift        # shared Codable widget snapshot types + reads
  WidgetDataUpdater.swift      # app-only SwiftData → widget snapshot projection
  StreakStore.swift            # reading-day history + streak, app group + KVS
  Models/Work.swift            # all SwiftData @Model types (Work,
                               #   ReadingProgress, ReadingStat, CustomFolder,
                               #   FollowedAuthor, …)
  Networking/
    AO3Client.swift            # protocol + live actor + MockAO3Client;
                               #   retries transient GET failures (timeouts,
                               #   429 w/ short Retry-After) with backoff —
                               #   never POSTs
    AO3Endpoints.swift         # URL builders
    ThrottleActor.swift        # 1 req/sec; reserves each caller's slot
                               #   atomically BEFORE suspending, so concurrent
                               #   callers space out instead of bursting
    HTMLParsers/               # one file per page kind
  Search/
    SearchView.swift           # search UI: keyword box + suggestion row +
                               #   filter chips + Filters sheet; results (WorkRow
                               #   has an inline bookmark/save button); recent &
                               #   saved searches;
                               #   WorkDetailView (reader + toolbar actions);
                               #   CommentsView (view/post chapter comments)
    AuthorWorksView.swift      # one author's works; Follow button +
                               #   FollowedAuthorsView (the Authors tab)
    SearchSyntax.swift         # search text ⇄ AO3SearchFilters: keywords stay
                               #   keywords; only key:value tokens + a short
                               #   filter-only phrase list become filters
    SearchSuggestions.swift    # typeahead: AO3 /autocomplete/tag (re-ranked) +
                               #   local filter/abbreviation suggestions; recents
    AO3SearchFilters.swift     # 1:1 mapping of AO3's /works/search fields
    KnownTags.swift            # fandom abbreviations + alias dictionaries
                               #   (suggestion vocabulary — never auto-applied)
    TagResolver.swift          # canonicalize tags typed in the Filters sheet
    WorkFilterSheet.swift      # AO3-style filter panel editing AO3SearchFilters
  Browse/
    FandomCategories.swift     # 10 AO3 media categories + curated seed lists;
                               #   PopularTags (curated popular fandoms/ships/chars,
                               #   used as the Popular tab's offline fallback)
    BrowseView.swift           # category → live fandom list → filtered works;
                               #   landing page also lists saved filters.
                               #   FandomWorksView is drivable by filters+title
                               #   (fandom OR a saved filter), not just a fandom.
                               #   PopularView (the Popular tab) lives here too.
  Reader/
    ReaderView.swift           # continuous + paginated modes, chapter header,
                               #   floating chapter indicator, typography menu,
                               #   reading-position save/restore; plain system
                               #   nav bar (no auto-hide — see below); paginated
                               #   mode has tap-to-turn zones + "Listen" TTS bar;
                               #   hardware arrow keys turn pages
    ChapterContentView.swift   # renders a chapter as paragraphs w/ scroll
                               #   anchors; every anchorStride-th paragraph +
                               #   ALWAYS the final one (isAnchorIndex) so
                               #   progress can reach 100%; image paragraphs
                               #   render as ReaderInlineImage slots
    HTMLText.swift             # async cached HTML → AttributedString (summary)
    HTMLToAttributed.swift     # SwiftSoup → AttributedString / paragraphs;
                               #   speechParagraphs() feeds the TTS narrator,
                               #   index-aligned with the rendered paragraphs;
                               #   convertParagraphs(includeImages:) emits
                               #   image slots for the opt-in images setting
    SpeechController.swift      # on-device TTS ("Listen") via AVSpeechSynthesizer:
                               #   gapless per-paragraph narration, chapter
                               #   auto-advance, lock-screen Now Playing controls
    WorkHeaderMetadata.swift   # rating/warnings/tags/stats; collapsible drawer
    ChapterTracking.swift      # PreferenceKeys: current chapter + paragraph anchor
    ReadingProgressStore.swift # load/save ReadingProgress by ao3Id; stamps
                               #   Work.lastRead* and feeds WidgetProgressStore
    ReaderProfile.swift        # named typography profiles (JSON under
                               #   "reader.profiles"); per-device setting keys
                               #   via deviceKey() (.phone/.pad/.mac) + migration
    ReaderProfileSyncStore.swift  # mirrors reader.profiles through iCloud KVS
    WorkExportButton.swift     # multi-format export → share sheet
    ReaderTheme.swift          # theme/font/size/spacing/width/mode, @AppStorage
  Library/
    LibraryView.swift          # All/Starred/Downloaded/Folders filters, custom
                               #   folders (CustomFolder) w/ move sheet, metadata
                               #   search bar; rows show a reading-progress bar
                               #   (% read / Finished) for any started work
    LibrarySort.swift          # Library/folder sort (Date Saved, Last Read,
                               #   Last Updated, Title, Author, Length; pinned
                               #   stay on top) + LibrarySortMenu — lives in the
                               #   content (first filter chip / folder header),
                               #   deliberately NOT the nav bar
    SavedWorkReader.swift      # offline if chapter text exists, else fetch
    RestoreDownloadCenter.swift # optional EPUB re-download after cloud restore
    WorkPersistence.swift      # upsert, upsertMetadata, toggleFollow;
                               #   isAuthorFollowed / toggleFollowAuthor
    iCloudSyncManager.swift    # backup/restore SwiftData library to iCloud;
                               #   backups UNION with the existing cloud file
                               #   (mergedBackup) — never last-writer-wins
  Auth/                        # AuthState (Keychain) + LoginView
  Subscriptions/               # poller (AO3 subs + local work/author follows),
                               #   BG task; SubscriptionsView + BookmarksView
                               #   (the Bookmarks tab — your AO3 bookmarks);
                               #   NotificationRouting (notification tap →
                               #   work / author page)
  Settings/                    # SettingsView + ReaderSettingsView + privacy;
                               #   ReviewPrompt (rare App Store rating prompt +
                               #   Settings → About "Rate Fanficly" link);
                               #   ContentFilter + ContentSafetyViews (age/hide)
  DesignSystem/                # Typography, Spacing, FlowLayout, SafariView, ShareSheet
  Localizable.xcstrings        # String Catalog: user-facing strings (English only)
  PrivacyInfo.xcprivacy        # zero collection, zero tracking
FanficlyTests/                 # XCTest cases — parsers, filters, endpoints,
                               #   HTML render, tracking, in-memory persistence
FanficlyUITests/               # smoke test + ReaderLayoutTests (run in CI)
                               #   + ScreenshotTests (README shots)
FanficlyShare/                 # Safari share extension target
  ShareViewController.swift    # intercepts browser URLs & redirects to main app
  Info.plist                   # share service configurations
FanficlyWidget/                # WidgetKit extension target (embedded in app)
  FanficlyWidget.swift         # six-widget bundle: last read, streak,
                               #   subscriptions, folders, saved searches,
                               #   local recommendations; deep-links into app
  FanficlyWidget.entitlements  # app group + iCloud KVS
```

## Linux orbs

`../.agents/setup` (at the repository root) prepares the portable developer tools: Chromium, ffmpeg,
ShellCheck, and the existing `bin/.venv` Python environment (Pillow,
PyJWT with crypto support, and requests, pinned in `bin/requirements.txt`).
Run Python scripts with `bin/.venv/bin/python`; no shell activation is needed.
Setup is safe to repeat and reuses installed packages. `../.agents/resume` only
checks the environment; it does not install dependencies or authenticate.

**The native app cannot build or run on Linux.** Xcode, Apple SDKs, simulators,
XcodeGen, and all app tests need a Mac. There is no Linux Swift package/test
target. Use the macOS CI or a Mac runner for native validation; do not install
Linux Swift as a substitute. Fastlane is intentionally not installed here:
its lanes run on GitHub's macOS runners, and their credentials live only in
the `app-store` environment's secrets (`docs/RELEASING.md`).
No database, app server, signing credentials, or AO3 login is needed for setup.

Chromium can render HTML artwork, but exact marketing assets still need the
Mac's Apple fonts and downloaded frameit bezels. Do not overwrite tracked
screenshots with Linux font fallbacks. Setup never downloads private assets,
reads signing keys, or runs App Store upload scripts.

To update Python dependencies, edit `bin/requirements.in`, then run:

```bash
uv pip compile bin/requirements.in --python-version 3.11 --generate-hashes --output-file bin/requirements.txt
../.agents/setup
```

## Autonomous roadmap work

The backlog is [`docs/ROADMAP.md`](docs/ROADMAP.md) (each item is mirrored by a GitHub issue titled `RM-nnn: …` for discussion; the file and PR claims are authoritative). This is the loop for an agent told to "pick a roadmap feature and ship a PR". It ends at an **open PR**. A human merges.

**Hard rules**
- Never merge a PR, enable auto-merge, approve your own PR, push to `main`, force-push a branch you didn't create, or edit CI to make it pass.
- Never touch release housekeeping: version/build numbers, App Store metadata, `appstore/`, `screenshots/`, `docs/screenshots/`, signing files, `fastlane/`.
- One roadmap item per PR, and one agent per item. Don't start an item that's `claimed`, even if its PR looks stale; mention it in your report instead.
- Don't reformat or refactor code the item doesn't need. Don't add dependencies.
- Don't create GitHub issues, labels or releases. (A PR may say `Refs #n` for its item's mirror issue, but don't use `Closes`: a human closes it after merging.) Anything outward-facing beyond the one PR needs the user's say-so.

**The loop**
1. **Orient.** `git fetch origin && git checkout -b tmp origin/main`, read this file's Conventions and "Things to know about AO3", and the roadmap's principles.
2. **Pick.** Run `bin/roadmap.sh free apple` (open and unclaimed; needs `gh`; `windows` lists the Windows roadmap instead). Take the lowest-numbered item that is size `S` or `M`, unless the user named one. Prefer `Validation: unit` items when you can't run a simulator. If nothing is free, stop and say so — don't invent work.
3. **Verify it's real.** Read the files the item names. If the feature already exists, the premise is wrong, or the item is bigger than `M`, don't build it: open a PR that only edits the roadmap (fix or split the item, with new IDs) or report back.
4. **Claim before coding.** Create the branch `roadmap/RM-nnn-short-slug` from `origin/main`, push it, and open a **draft PR** titled `RM-nnn: <title>` whose body is the filled-in PR template. The branch/PR is the claim `bin/roadmap.sh` sees; re-run `bin/roadmap.sh` first and if another claim appeared for the same ID in the meantime, abandon yours (close your draft) and pick again. (A draft PR needs at least one commit; push the roadmap's `claimed` note, or an empty commit `git commit --allow-empty -m "Claim RM-nnn"`.)
5. **Implement the smallest slice** that meets the item's "Done when". Follow the Conventions above (AO3Client is the only network seam, parsers are pure, AppStorage for settings, VoiceOver labels, etc.). Prefer extending an existing file; a new source file means `xcodegen generate` and a regenerated `.xcodeproj`, which you can only do on a Mac.
6. **Test.** Add tests for every behavior change in `FanficlyTests/` (fixtures inline, no network), and add the feature's tests to the list in "Tests" below if it's a new area. A new `AO3ClientProtocol` method needs `MockAO3Client`, `DemoAO3Client` and `StubAO3Client` updated.
7. **Validate honestly** (see "Which machine you're on").
8. **Update the roadmap** in the same PR: set that item's `Status` to `done`, and nothing else in the file. Update AGENTS.md (the only agent guide; CLAUDE.md just imports it) if you added a convention or a gotcha; keep it to what the next agent can't see from the code.
9. **Commit, push, mark the PR ready** (`gh pr ready`) only when CI is green or the failure is explained. Then stop. Report: the item, the PR URL, what you tested, what you could not, and anything a human should look at on a device.

**Which machine you're on**
- **Mac with Xcode:** run the unit tests the way "Tests" shows; for reader changes also `bundle exec fastlane reader_layout_tests`. Run `xcodegen generate` only if you added or removed files.
- **Linux orb (no Xcode):** you can't compile Swift or run any test, and you must not install Linux Swift as a substitute — SwiftUI, SwiftData and XCTest don't exist there. Write the code and tests carefully, mirror existing patterns closely, and let CI be the compiler: after pushing, check `gh pr checks <pr> --watch` (or the `github_repo_ci_status` tool), read the failing log, fix, push again. Keep the PR in draft until the build and `FanficlyTests` are green. Say plainly in the PR that nothing was built locally. For `Validation: mac` items, list exactly what a human needs to look at.
- Either way: never claim a test passed that you didn't see pass.

**If you get stuck:** three failed CI attempts at the same error, or an AO3 behavior you can't confirm without the live site (a form's field names, a redirect) → stop, leave the draft PR with what you learned, and say what you need. Don't guess at AO3's markup: scrape fixtures must come from real pages the user provides or that you can verify.

**Adding to the roadmap:** append new items with the next free `RM-nnn`; never renumber or reuse an ID. Keep each item `S` or `M` with a concrete "Done when". A roadmap-only PR is fine and needs no test run.

## Build & run

The Xcode project is generated from `project.yml` — never edit `.xcodeproj/project.pbxproj` by hand. After adding/removing source files:

```bash
xcodegen generate
```

Build for the simulator from CLI (no Xcode UI):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Fanficly.xcodeproj -scheme Fanficly \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Run on a booted sim:

```bash
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Fanficly.app
xcrun simctl launch booted io.github.yennster.fanficly
```

If you hit `xcrun: error: unable to find utility "simctl"`, `xcode-select` is pointing at Command Line Tools — fix with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` or just prefix commands with `DEVELOPER_DIR=...`.

## Tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Fanficly.xcodeproj -scheme Fanficly \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:FanficlyTests
```

CI runs the same on both an iPhone and an iPad simulator, and again under Mac Catalyst (a separate job), then runs `FanficlyUITests/ReaderLayoutTests` on the iPhone and the iPad. CI picks the newest installed Xcode and the newest available sim UDIDs at runtime — don't hardcode device names anywhere. Locally, `bundle exec fastlane unit_tests` runs the unit tests the same three ways, and `bundle exec fastlane reader_layout_tests` runs `ReaderLayoutTests` on an iPhone, an iPad, the iPhone Duo and the Mac (see below). Under Mac Catalyst, `xcodebuild test` needs `MACOSX_DEPLOYMENT_TARGET=14.0` on a Mac older than the SDK's macOS, or it refuses ("doesn't match FanficlyTests's macOS 27.0 deployment target"). CI and both lanes pass it.

`FanficlyTests` normally runs without live AO3 requests. `LiveResolutionTests`
is the exception: it skips unless `AO3_LIVE=1` is set in the **test scheme's**
environment (a shell variable alone does not reach the simulator test process).
Use it deliberately, not as the default regression suite.

Coverage map:
- **Parsers** — `SearchResultsParserTests` (incl. the bookmarks page: `li.bookmark.blurb`, work id from the `/works/<id>` link, skipping series/external bookmarks), `WorkPageParserTests` (+ `LoginParserTests`, `CommentsParserTests` — threaded comment depth, guest comments, comment pagination, comment-form pseud id, `KudosParserTests` — the kudos form and AO3's `/kudos.js` answers), `SubscriptionsParserTests`, `MediaCategoryParserTests`, `WorkMetadataParserTests`. Each feeds inline HTML fixtures and asserts the typed output.
- **Search** — `SearchSyntaxTests` (everyday words like "teen wolf"/"supernatural"/"french kiss" stay keywords; the filter-only phrases; every `key:value` token; render⇄parse round trip; old saved-filter JSON still decodes), `SearchSuggestionsTests` (trailing-word extraction, local suggestions, AO3 tag ranking, applying a suggestion, recents, results count), `AO3SearchFiltersTests` (every `work_search[*]` field mapping, NOT-exclusion composition, Codable round-trip for saved filters), `TagResolverTests` (canonical resolution, ship slash variants, character-fallback ship resolution via `StubAO3Client`), `FandomCatalogTests` (fandom → category icon).
- **Endpoints** — `AO3EndpointsTests` (URLs, pagination, AO3 media path-encoding).
- **Reader** — `HTMLToAttributedTests` (formatting, paragraph collapsing, lists/headings/hr, transparent conversion caching), `ChapterTrackingTests` (anchor key/parse, topmost-anchor, current-chapter). In `ReaderMetricsTests.swift`: `ReaderSpreadTests` (when two pages show, the gutter on the Duo's fold), `PageAreaTrackerTests` (page-by-page's page height: shrink at once, grow once settled, fill the screen with the controls hidden, and full screen keeps one page or two), and `ReaderPaginationTests` — the pure `ReaderPaginator` across a device matrix (iPhone SE to Pro Max in both orientations, iPhone Duo folded and unfolded, iPad mini and Pro 13-inch in both, a Mac window) × three typography settings: no page runs past its page area, every page but a chapter's last is full (no more blank under its last line than a paragraph gap and a line), and every sentence lands on exactly one page, all measured as SwiftUI draws the page (`ReaderPageCell.pageContent`). `test_uncheckedPages_stillFitTheirPageArea` holds the iOS-only boundingRect path (the chapters either side of the one being read) to its area. It also re-paginates each layout 84 pt taller and shorter (the controls hiding and showing) from a mid-chapter `PageStart`: that page keeps its first words, stays on the left of its spread when two pages show, and it and every page after it are full. Re-paginating from one of its own page breaks changes nothing. Add a device there when the app gains a new screen shape.
- **Reader layout (UI)** — `ReaderLayoutTests` (in `FanficlyUITests.swift`) drives demo mode with `-demoLongChapters` (a demo-only flag that makes chapters long enough for a full page mid-chapter) in page-by-page and checks what's drawn: the page footer (`reader.pageFooter`) sits on the bottom edge, each page's text ends within 75 pt of it (the bottom margin, a paragraph gap and a line) and never under it, and the page label doesn't change when the app is backgrounded or a keyboard comes up (the New Profile prompt; skipped where a hardware keyboard means none shows). Hiding the controls (full screen; the page footer goes too, iPhone Duo included) re-paginates, checked on one page and again in the wide window's spread: the page keeps its first words and, when it gained room for a new paragraph's first two lines, holds more text (it used to leave the controls' room blank); showing them keeps the first words again. It also checks a wide window (landscape, the Mac) shows a two-page spread exactly when `ReaderSpread`'s rule says so. Each step saves a screenshot (`01-page` … `09-wide-controls-back`) to `build/reader-layout-screenshots/<device>/` and the test result, taken before that step's checks so a failure still leaves a picture; CI uploads the folder as the `reader-layout-screenshots` artifact on every run. It runs on whatever destination you give it. Before shipping reader layout changes, run `bundle exec fastlane reader_layout_tests`: the iPhone, the iPad and the iPhone Duo in its current pose, then the Mac (`-destination 'platform=macOS,variant=Mac Catalyst'`). The Mac run drives the real app window, so hands off, and macOS asks for an administrator password to enable UI automation before it starts, so an unattended run sits waiting there. Then fold or unfold the Duo in Device Hub and run `bundle exec fastlane reader_layout_tests devices:"iPhone Duo" mac:false`. Unfolded, the tests hide the sidebar first, because beside it the reader is too narrow for the spread. Taps are aimed from the window, never from `app`, because the unfolded Duo reports `app.frame` in portrait.
- **Persistence** — `PersistenceTests` spins up an in-memory `ModelContainer` to exercise `WorkPersistence` (upsert/metadata/follow, plus author follow: `isAuthorFollowed`/`toggleFollowAuthor` with seeded work ids, empty-username guard) and `ReadingProgressStore` (save/load round-trips), plus `ReaderProfile` merging (incl. deletion tombstones), per-device key migration, the iCloud backup/restore merge rules (two simulated devices via `overrideBackupURL`), and poller-level subscription-sync behavior.
- **Localization** — `LocalizationTests` (the String Catalog ships in the bundle and the moved screens' keys resolve to their English text).
- **Misc** — `ThrottleActorTests` (1 req/sec throttle timing + a concurrency test asserting N simultaneous waiters are serialized, never bursted). `ResumeProgressPolicyTests` (widget resume never rewinds saved progress). `ReviewPromptTests` (rating-prompt policy gates; `ReadingStatsStore.record` flags only the read that finishes a story). `LibrarySortTests` (every sort key + direction, pinned-first, missing dates sink, stable ties). `NotificationRouteTests` (each poller notification's payload survives plist storage and decodes to the right tap destination, incl. old work-id-only payloads). `StubAO3Client` is a scriptable `AO3ClientProtocol` test double for resolution logic.

Extend the existing test file for the behavior you change. Prefer observable
contracts and regression cases over assertions about implementation details.
Make a private helper `internal` if it needs direct testing (see
`TagResolver.candidates/bestMatch`).
Additional focused suites include `ContentSafetyTests`, `StreakStoreTests`,
`WidgetDataStoreTests`, and `WorkExporterTests` (which also holds `KudosGiverTests`).

**Test seams and demo mode:** the environment's default client is
`MockAO3Client` (small preview fixture); `FanficlyTests/StubAO3Client` scripts
responses/failures; `DemoAO3Client` plus `DemoSeed` supplies the larger offline
UI dataset. `-demoMode` selects that client, uses in-memory SwiftData, bypasses
the age gate, and sets a demo username. It also resets some **real UserDefaults**
keys, so use a dedicated simulator/test installation. `-demoLongChapters` feeds
reader layout tests. `isTestMode` detects `XCTestConfigurationFilePath` and
suppresses selected side effects; it does **not** select the demo client or make
the app container in-memory. Persistence tests create their own in-memory
containers and override cloud backup destinations with `overrideBackupURL`.

Targeted native checks (on a Mac; choose an installed destination):

```bash
# Replace the final test selector with the relevant suite.
xcodebuild test -project Fanficly.xcodeproj -scheme Fanficly \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO -only-testing:FanficlyTests/SearchSyntaxTests

xcodebuild test -project Fanficly.xcodeproj -scheme Fanficly \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO -only-testing:FanficlyUITests/ReaderLayoutTests

xcodebuild test -project Fanficly.xcodeproj -scheme Fanficly \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=14.0 \
  -only-testing:FanficlyTests
```

The CoreData "Sandbox access to file-write-create denied" noise during test runs is harmless — it comes from SwiftUI booting the SwiftData container in the test host. Filter it out with `| grep -v CoreData:`.

## Conventions

- **AO3Client is the only seam for AO3 requests.** UI views never create AO3 `URLSession` requests; use `@Environment(\.ao3Client)`. There's a `MockAO3Client` for previews and tests. Opt-in external story artwork uses `ReaderInlineImage` / `AsyncImage`, with the URL restrictions below.
- **Throttle.** Always go through `AO3Client` — never bypass the throttle. AO3 is generous to good citizens, hostile to bad ones.
- **Parsers are pure.** `SearchResultsParser` (also drives the bookmarks page via a `blurbSelector` param), `WorkPageParser`, `CommentsParser` (in `WorkPageParser.swift`), `LoginParser`, `SubscriptionsParser`, `WorkMetadataParser` take HTML strings and return typed values. Test them with inline HTML fixtures.
- **SwiftData models** live in `Models/Work.swift`. The model container is constructed once in `FanficlyApp` and shared with `BackgroundRefresh`.
- **Settings come from `@AppStorage`**, not custom UserDefaults wrappers. Reader typography keys are per-device — always go through `ReaderProfile.deviceKey(_:)` (suffixes `.phone`/`.pad`/`.mac`).
- **No third-party dependencies beyond SwiftSoup and KeychainAccess.** Don't add analytics, crash reporters, or any SDK with a network side-channel — privacy posture is the headline feature.
- **Never present sheets/alerts from `Menu` content.** Menu content is torn down when the menu dismisses, so a `.sheet`/`.alert` attached to a view *inside* a menu has no live anchor by the time async work finishes and silently never presents (VoiceOver users hit it every time — slower dismissal). Own the state in the screen view and attach the presentation there; `WorkExporter` + `.workExportPresentation(_:)` (in `WorkExportButton.swift`) is the pattern. That goes for a toolbar `Menu` itself too: attached to the reader's Aa menu, the New Profile prompt never appeared on iPhone Duo's vertical toolbar strip, so `ProfileAlertsModifier` hangs it on `ReaderView`.
- **User-facing strings live in the String Catalog** (`Fanficly/Localizable.xcstrings`, RM-017), English only for now. Moved so far: `SettingsView.swift` (Settings and its Privacy screen); the rest is RM-024, one screen family per PR. SwiftUI only looks up `LocalizedStringKey`s: literals passed to `Text`, `Button`, `Section`, `Label` etc. are, but a `String` parameter (`func section(_ title: String)`), `LabeledContent(_:value:)`'s value and `Text(someString)` are shown verbatim, so take `LocalizedStringKey` in helpers and use `String(localized:)` outside views. AO3 data (tags, categories, titles) must stay verbatim in AO3's exact English form; never put it in the catalog. On Linux, add each moved string to the catalog by hand (keys are the exact English text, `\n` for multiline literals, each with an explicit `en` `stringUnit` whose value is the key: entries with no source-language value aren't compiled into the bundle's table at all); `LocalizationTests` checks the table ships and resolves. CI and the release workflow run `xcodegen generate`, so the catalog is bundled there; the committed `.xcodeproj` lists it once someone regenerates it on a Mac, and until then an Xcode Cloud build falls back to the same English keys.
- **VoiceOver is a supported input.** Icon-only buttons/menus get `.accessibilityLabel`; multi-`Text` rows get `.accessibilityElement(children: .combine)` (but never combine a container holding tappable `Link`s/buttons — it hides them); decorative SF Symbols next to text get `.accessibilityHidden(true)`; invisible gestures (the reader's tap-to-turn zones, chrome-toggle tap) need `.accessibilityAction(named:)` equivalents — the reader's live in `ReaderView` (`accessibilityTurnPage`/`accessibilityTurnChapter`/`toggleChromeAccessibly`, which also posts announcements). Long-running silent transitions (export download, search, import) post `UIAccessibility.announcement`.

## Common tasks

**Add a new search filter.** Add the field on `AO3SearchFilters` (+ its `queryItems()` row, `isEmpty`, the tolerant `init(from:)` and `merging`), a `key:value` token in `SearchSyntax.apply`/`render` (round-trip test), a chip in `SearchView.activeChips`, and optionally a control in `WorkFilterSheet`. Only add a *natural phrase* to `SearchSyntax.phrases` if it can never mean anything but the filter — that list is deliberately short.

**Add a new HTML parser.** Put it in `Networking/HTMLParsers/`. Take a `String` of HTML, parse with SwiftSoup, return a Sendable struct. Add fixture-based tests in `FanficlyTests/`.

**Add a new SwiftData model.** Define the `@Model` in `Models/Work.swift`. Add it to `FanficlyApp.sharedModelContainer`'s `Schema` (and the in-memory `Schema` in `PersistenceTests`). SwiftData will migrate automatically across additive schema changes; destructive changes need a versioned migration plan. `FollowedAuthor` is a recent example.

**Add a new sidebar tab.** Add a case to `SidebarItem` (in `RootView.swift`) — order in the enum drives the sidebar order — give it a `title` + `systemImage`, add it to the `switch selectedDetailItem` in `mainSplitView`, and add a `Button`/`keyboardShortcut` to the "Go" `CommandMenu` in `FanficlyApp.swift` (renumber ⌘N to match). Recent examples: `popular`, `authors`, `bookmarks`. `xcodegen` isn't always available; prefer adding the tab's view to an existing file (e.g. `PopularView` in `BrowseView.swift`, `BookmarksView` in `SubscriptionsView.swift`, `FollowedAuthorsView` in `AuthorWorksView.swift`) over a new file, so the committed `.xcodeproj` doesn't need regenerating.

**Run the app on a different device.** Replace `iPhone 17` in the build/run commands with whatever is available. CI auto-picks — see `../.github/workflows/ci.yml`.

## Things to know about AO3

- No JSON API. We are a respectful guest of `archiveofourown.org`. The `User-Agent` identifies the app and links to the repo so AO3 ops can find us.
- Explicit-rated works show an age-gate page unless the request includes `view_adult=true` (we set this).
- `?view_full_work=true` inlines all chapters on a single page.
- Login is form-based. GET `/users/login` → scrape the `authenticity_token` (either `<meta name="csrf-token">` or `<input name="authenticity_token">`), then POST with cookies. Session cookie is kept in `HTTPCookieStorage.shared` and automatically serialized & persisted to/from the secure iOS Keychain via `CredentialStore` to prevent logouts when the app is terminated or restarted.
- The structured `dl.work.meta.group` on a work page contains the canonical tags. Chapters are wrapped in `div.chapter[id^=chapter-]` — use that exact selector to avoid matching the nested `.preface` divs.
- **Guest-page parsers fail closed too.** `SearchResultsParser`, `WorkPageParser`, `MediaCategoryParser` and `WorkFiltersParser` throw `unauthorized` for the login page (a stale session, or a guest opening a restricted work) and `parseFailed` for a page without their own markup, so an error page can't read as "No results" or overwrite a saved work. The shared test is `AO3PageCheck` (in `SearchResultsParser.swift`): it looks for a login form **inside `#main`**, because every logged-out AO3 page has the header's small login form, which is why `SubscriptionsParser`'s "any login form" test can't be reused there. A genuine empty page still returns `[]` when it carries its listing shell: the index `<ol>`, `#main`'s Rails `controller-action` class (`works-search`, `works-index`, `bookmarks-index`, `fandoms-index`), or AO3's "No results found" / "No fandoms found" line. Fixture shells are `AO3PageFixtures` in `SearchResultsParserTests.swift`, cut down from otwarchive's templates.
- Work subscription is a POST to `/works/<id>/subscriptions` with `subscription[subscribable_type]=Work` + token. Requires login.
- **Subscription sync fails closed.** With an expired cookie AO3 302s the subscriptions page to the login form and URLSession follows it, so the client sees a 200 of login HTML. `SubscriptionsParser` throws `AO3Error.unauthorized` when the page contains a login form and `parseFailed` when it has neither a subscription list nor the index shell — and `syncSubscriptionList` skips its delete pass on any empty fetch, so markup drift or a stale session can never mass-delete `SubscriptionRecord`s (and their `lastSeenChapterCount` baselines). `fetchSubscriptions` walks every page of `/users/<name>/subscriptions` (50-page ceiling); any page failing throws the whole call so a partial list can't reach the delete pass.
- **Bookmarks** — `/users/<name>/bookmarks` (paginated) lists works in `li.bookmark.blurb` (vs. `li.work.blurb` on search), so `AO3Client.fetchBookmarks` reuses `SearchResultsParser.parse(html:blurbSelector:)`. The `<li>` id is `bookmark_<id>`, not `work_<id>`, so `parseBlurb` falls back to the `/works/<id>` title link for the work id (`SearchResultsParser.workId(fromHref:)`); series/external/deleted bookmarks have no such link and are skipped. The `BookmarksView` tab is login-gated (private bookmarks need the session cookie) and live-fetched with infinite scroll.
- **Comments are per-chapter when the AO3 chapter ID is known.** `AO3Client.fetchComments(workId:chapterId:page:)` loads `chapterComments` or falls back to `workComments` (the first chapter's thread), with `show_comments=true`. `CommentsParser` in `WorkPageParser.swift` parses threaded comment bodies and depth. AO3 pages a thread by top-level comment (`page=`); `CommentsParser.parsePage` reads the will_paginate list inside `#comments_placeholder` (verified against otwarchive's `comments/_commentable` and its list renderer), and `CommentsView` appends the next page from "Load more comments", skipping ids it already shows. Posting requires login and replays the **live form** from `CommentsParser.newCommentForm`: its action URL, CSRF token, pseud ID, and hidden `commentable_id`/`commentable_type` fields determine the destination. Do not hardcode a work-level POST. `CommentsView` re-fetches after posting (AO3 may moderate new comments). `Chapter.aoId` is optional for older downloads; `SavedWorkReader.ensureChapterIds` fetches and persists missing IDs without replacing saved text.
- **Kudos** (`AO3Client.leaveKudos`, from the work's options menu in `WorkDetailView` and `SavedWorkReader`) mirror AO3's own kudos button, read from otwarchive's source (`KudosController`, `comments/_commentable.html.erb`, the kudos script in `application.js`) because testing against the live site would leave real kudos. GET the work's first page, require `KudosParser.isSignedIn` (the `#greeting` link and no login form; AO3 takes guest kudos too, so an expired cookie would otherwise leave one as a guest: throw `.unauthorized`. Not `LoginParser.currentUsername`: its `#header` fallback matches the signed-out `/users/login?return_to=…` link), replay `form#new_kudo`'s hidden fields (absent on your own work or when blocked) with the page's **meta** `csrf-token`, and POST them to `/kudos.js`. Not the form's own token: AO3 runs Rails' per-form CSRF tokens, so that one only validates for `/kudos`. `/kudos.js` answers 201 on success, 422 with `{"error_message": …}` for a refusal, and 422 with `{"errors": {"auth_error": …}}` for a refused token (`.unauthorized`); `performRequest(passing: [422])` hands the body back, and any other answer is an error that isn't remembered. "You have already left kudos here. :)" is the duplicate answer for users and guests alike, and counts as left. `KudosStore` remembers kudosed work ids in `UserDefaults` (`kudos.leftWorkIds`, cleared by `AuthState.logout`) so the button reads "Kudos Left"; the POST is never retried.
- Browse-by-fandom hits `/media/<category>/fandoms`; category names are path-encoded with AO3's scheme (`&`→`*a*`, `/`→`*s*`, `.`→`*d*`, etc. — see `AO3Endpoints.ao3PathEncode`).
- Tag autocomplete: `/autocomplete/{relationship,character,freeform,fandom}?term=…` returns JSON `[{id,name}]`. Used to resolve user-typed filter tags to canonical names before searching. **Two gotchas, both must hold or you get a 404 and tags silently don't resolve:** (1) the request must send `Accept: application/json` — the shared session defaults to `Accept: text/html`, and AO3's Rails content-negotiation 404s the JSON-only route on an HTML Accept; (2) the `term` must be percent-encoded including `/` (→`%2F`), because `URLComponents` leaves a raw slash in query values and AO3 404s on it. A ship like `Hermione/Draco` hits both.
- **Tag resolution is conservative for freeforms.** AO3 ranks autocomplete by popularity, so `TagResolver` routes freeforms through `bestFreeformMatch`, which only accepts a suggestion that is the *same tag* up to case/spacing/punctuation (fixing casing, `hurt comfort` → `Hurt/Comfort`) — otherwise it keeps exactly what the user typed, so `caveman` can't silently become `Caveman Derek Hale`. And **failed lookups are never cached**: only authoritative answers (including genuine no-matches) are memoized in the process-lifetime cache; a 429/offline error falls back for that one search and retries next time.
- Rating is **single-select** on `/works/search` (`work_search[rating_ids]`, a `<select>`). Sending the array form `rating_ids[]` AND-matches and returns nothing for 2+ ratings (a work has exactly one rating). So `AO3SearchFilters` emits the scalar field for one rating and OR-s multiple via the query field: `(rating_ids:12 OR rating_ids:13)`. Warnings/categories legitimately stay arrays (a work can have several).
- Multi-format export: `/downloads/<id>/work.<ext>` where ext ∈ {azw3, epub, mobi, pdf, html}. `WorkExportButton` downloads to a temp file and presents `ShareSheet` (UIActivityViewController).
- Reading position: stored per-work in `ReadingProgress` (ao3Id, chapterIndex, paragraphIndex). The reader renders each chapter as paragraphs (`ChapterContentView`) tagged `c<chapter>-p<index>`, tracks the topmost one via `ScrollAnchorKey`, and restores by scrolling to the chapter then the paragraph. Anchors are sampled every `anchorStride` paragraphs **plus always the final paragraph** (`isAnchorIndex`), and all three reading modes detect end-of-content explicitly (`ChapterTracking.endOfContentAnchor`, checked before the sample throttle) so a work read to the last line reaches exactly 1.0 and earns the Finished badge — the topmost-anchor path alone tops out around 0.8.
- **Opt-in story images** — "Show images in stories" (Settings → Reader, default **off** = historical text-only rendering). When on, embedded `<img>` tags render as fixed-height (240pt) `ReaderInlineImage` slots in all three reading modes. Image slots occupy real paragraph indices so anchors, TTS karaoke (unspoken, like scene breaks), progress, and pagination stay aligned; the fixed height keeps loading layout-neutral so a slow host can't displace a restored position. URL policy: https only (http upgraded, protocol-relative resolved); `data:`/`javascript:`/root-relative/AO3-host sources rejected — image loads bypass the throttle + User-Agent and would carry the session cookie. Known trade-off (documented in code): toggling shifts paragraph indices, so a saved position drifts by the number of images above it. Downloaded works stay text-only offline.
- **Text-to-speech ("Listen") is 100% on-device** — `SpeechController` wraps `AVSpeechSynthesizer` (no model bundle, no network, so the privacy posture holds). It speaks `HTMLToAttributed.speechParagraphs(...)` one chapter at a time, enqueuing every paragraph up front for gapless playback and mapping each utterance back to its index via `ObjectIdentifier` to drive the mini-player and detect chapter end. `speechParagraphs` is **index-aligned with the rendered paragraphs** (scene breaks become empty, unspoken slots that are skipped) so the reader can **karaoke-highlight** the spoken paragraph (`ChapterContentView.highlightParagraph`) and auto-scroll it into view (`scrollToSpokenParagraph`, plus the paginated page's own `onChange`). On finish it calls `onChapterFinished`, which `ReaderView` sets in `narrate(chapter:from:)` (and refreshes when `chapters` grows) to auto-advance to the next chapter. It's a direct call, not an observed signal, because SwiftUI doesn't run a backgrounded view's `onChange`: an observed tick left narration stuck at the end of a chapter with the app in the background. The closure captures the view, so `stop()` (called whenever the reader closes) drops it to break the cycle. `currentParagraph` is the rendered index (for the highlight); `spokenPosition`/`spokenCount` drive the "¶ x / y" readout. On multi-chapter works the narration bar's chapter label is a `Menu`+`Picker` (`chapterNarrationBinding`) that jumps narration to any chapter via `narrate(toChapter:)`, resyncing the visible page; `startNarration` now picks up from `currentAnchor` (chapter + paragraph) across all reading modes. Voice + speaking rate live in Reader settings (`reader.ttsVoiceId`/`reader.ttsRate`); voice id `""` means the platform default. Background/lock-screen playback needs the `audio` `UIBackgroundMode` (in `project.yml`) plus an `AVAudioSession` `.playback`/`.spokenAudio` session and `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` wiring, re-activating the session on resume and handling `AVAudioSession.interruptionNotification` (pause on a call, resume when the system says `.shouldResume`), plus a `ProcessInfo.beginActivity` held while a chapter is loaded so App Nap doesn't stall the synthesizer's callbacks when the Mac window is minimized — all in `SpeechController`. Synth-delegate and remote-command callbacks arrive off the main actor, so they capture only Sendable values (`ObjectIdentifier`) and hop via `Task { @MainActor in }`.
- **"More by this author"** — `AO3WorkSummary.authorUsername` (parsed from the byline `/users/<login>` href by `SearchResultsParser.authorLogin`) makes the reader byline a `NavigationLink(value: AuthorRef)`. `AuthorWorksView` lists that author's works via `AO3Client.fetchAuthorWorks` (the works page reuses the search blurb parser). Every navigation stack applies the shared `.workAndAuthorDestinations()` modifier so both `AO3WorkSummary`→reader and `AuthorRef`→author works resolve everywhere.
- **Following authors** (the Authors tab) is local-only, like work follows — see "Local follow vs. AO3 subscribe" below. `AuthorWorksView` has a Follow button; `FollowedAuthorsView` lists followed authors. The poller checks each for newly-published works.
- **Popular tab** — AO3 has no popular/trending endpoint, so popularity is derived from AO3's cumulative work counts: `AO3Client.fetchPopularSnapshot()` ranks **fandoms** by the `/media/<cat>/fandoms` counts (`MediaCategoryParser` now also reads the trailing `(count)`) and aggregates **ships/characters** from the works-filter facet sidebar of the top few fandoms (`WorkFiltersParser` over `/tags/<tag>/works`, `AO3Endpoints.tagWorks`). Live facet markup: include-checkbox ids are `include_work_search_<kind>_ids_<tagid>` and the name+count share one plain span (`Ship Name (57746)`), so the selector is `label[for^=include_][for*=_<kind>_ids_]` (anchoring on `include_` matters — the Exclude half repeats every tag) with the count parsed from the trailing `(N)` via `MediaCategoryParser.trailingCount`. `PopularStore` caches the `PopularSnapshot` in `UserDefaults` and refreshes at most once/day in the background; `PopularView` shows the cached/live lists immediately and **falls back to the curated `PopularTags` seed** whenever a list is empty (offline / markup drift), so the tab is never blank. Tapping a tag opens `FandomWorksView(popular:)`, which maps it to fandom/relationship/character `AO3SearchFilters` sorted by kudos. Names (live or curated) must stay in AO3's exact canonical form or the tag won't resolve. NB: counts are cumulative, not daily/trending — AO3 exposes no trend feed.
- **Search never silently reinterprets words** (the 2026-10 overhaul). The old prompt parser turned common words into hard filters: "teen wolf" became a Teen rating plus the word "wolf", "supernatural" the Supernatural fandom, "french kiss" French-language works, "the other side" the Other category, "soft/family/drama" AND-ed tags. On iOS 26 an on-device LLM step also *erased the keywords* whenever it guessed any tag. Now:
  - The box text goes to AO3's own full-text search (`work_search[query]`).
  - Tags become filters only when a suggestion is tapped. They go in `work_search[other_tag_names]`, which AO3 matches against any tag type (verified: same counts as `fandom_names`). Excludes go in `excluded_tag_names`.
  - Only `key:value` tokens and `SearchSyntax.phrases` convert on submit. Those phrases must convert because **AO3 requires every keyword to match**: "edward bella romance all human" had 496 results, adding the word "complete" left 9.
  - Don't reintroduce guessing.
  - The parser runs case-insensitive regexes on the original string (no lowercased twin buffer), so the old Turkish-`İ` NSRange desync can't recur.
- **Search typeahead:** after 350 ms of no typing, the trailing ≤3 words go to `/autocomplete/tag`, backing off a word at a time when nothing comes back. That endpoint returns every tag type in one throttled request but ranks poorly ("Teen Wolf (TV)" came 4th), so `SearchSuggestions.rankTags` re-ranks. Results are memoized in `TagSuggestionCache`. Tapping a suggestion removes the words it came from.
- **AO3 search is slow:** 20–30 s time-to-first-byte is normal. `AO3Client.search` uses a 60 s request timeout and 1 retry; the session resource timeout is 90 s. `SearchView` keeps one cancellable `searchTask`, so an old response can never overwrite newer results, and offers Cancel after 5 s. There are no pre-search requests (suggestions are already canonical; only tags typed into the Filters sheet go through `TagResolver`).
- **Filter-only searches default to Kudos sort** (`SearchSyntax.automaticSort`). AO3's best match has nothing to rank without keywords. This applies until the user picks a sort.
- **Saved searches, recents and the `fanficly://search?query=` deep link store `promptText()`**, the `key:value` rendering, which `SearchSyntax.parse` reads back exactly. Saved searches from before the overhaul were natural-language prompts; they now run as keyword searches.
- Top-level tab views (Search, Library) use an **inline** nav title — a large title pops in awkwardly because those screens have a custom header VStack, not a scroll view for the title to anchor against.
- AO3 may return 429 if we hit it too fast. The throttle should prevent this but handle the case anyway: `performRequest` retries transient failures (URLSession timeouts/dropped connections, 429 within a short `Retry-After`) with exponential backoff — **idempotent GETs only**, never POSTs (login/comment/subscribe must not double-submit), and never while offline. `ThrottleActor.wait()` reserves each caller's slot atomically *before* suspending (actor methods run synchronously up to the first await), so concurrent callers get strictly-spaced instants — a burst of simultaneous requests was what tripped AO3's tarpit and surfaced as 30s "network timeout" errors on list screens.
- **The reader uses the system nav bar — no scroll-driven auto-hide or custom floating chrome.** Explicit minimize/tap-to-restore is supported through `isUIMinimized`; it hides the bar and footer and re-measures pages. `ReaderView` owns chapters, typography (Aa), and minimize controls; parent screens own comments/export/library actions (`SavedWorkReader` groups export and Save Offline in More). Keep the parent to ≤2 items — the iPhone portrait nav bar fits ~5 trailing icons before the system spills the rest into its own overflow, which looks like a second ellipsis. Paint the bar with the reader's `background` (`.toolbarBackground(bg, .visible)`) and theme it with `.toolbarColorScheme` — never `.preferredColorScheme`, which propagates to the whole window and flips the app light↔dark when leaving a light reader. The chapter indicator bar uses `bg`, not `.ultraThinMaterial`. Earlier scroll-to-hide and custom-toolbar attempts were unreliable; do not reintroduce them.
- **The reader body ignores the keyboard safe area** (`.ignoresSafeArea(.keyboard, edges: .bottom)` on `ReaderView`'s root, **outside** the bottom `.safeAreaInset` bars). The page text is `.focusable()`/`.focused()` for hardware arrow-key turns (`ReaderKeyPressModifier`); without this, returning from the background can restore focus and leave iOS holding a phantom keyboard inset, collapsing the page into a blank band (~keyboard height) at the bottom. It must wrap the bars too: applied only inside them, the page footer / narration bar still rode up on the phantom inset (a keyboard-high blank band under the footer), and page-by-page measured its pages for the squashed area above. The reader has no text input, so ignoring the keyboard inset is always safe.
- **Reader story text is not selectable** — there's intentionally no `.textSelection(.enabled)` on the paragraph `Text`s (continuous/paginated `ChapterContentView` and page-by-page `ReaderPageCell`), so press-and-hold never shows a "Copy" callout. Don't re-add it.

## Local follow vs. AO3 subscribe

Two distinct concepts — don't conflate them:
- **Follow** (bookmark icon) is local-only, no login. `WorkPersistence.toggleFollow` saves the work's metadata to SwiftData with `isFollowed = true`. A bookmark button also rides on each search/browse `WorkRow` for one-tap save without opening the work. The background poller checks followed works for new chapters and fires a local notification — works fully logged out.
- **Follow author** (the Authors tab) is also local-only. `WorkPersistence.toggleFollowAuthor` stores a `FollowedAuthor` (username, displayName, `knownWorkIds` seeded at follow time so the first poll doesn't alert for the back catalogue). `SubscriptionPoller.checkFollowedAuthors()` fetches each author's works page and notifies on newly-published works.
- **Subscribe** (bell, in the … menu) POSTs to AO3 and requires login. It mirrors into AO3's own subscription list.
All feed `SubscriptionPoller`; `username` is optional so the poller runs for follows even with no account. `runFullPoll` builds **one queue of all three record kinds sorted oldest-check-first** (`Work.lastCheckedAt`, additive schema field), saves after each record, and breaks on task cancellation — so a ~30s `BGAppRefreshTask` that gets cut off resumes exactly where it stopped next run and author follows can't starve behind long sub lists. Attempt time is stamped up front (success or failure) so a deleted work can't hog the queue head. The per-category functions (`checkForNewChapters`/`checkFollowedWorks`/`checkFollowedAuthors`) remain for the Subscriptions tab's manual refresh. Notification permission is requested at the moment of follow (`NotificationsAuthorization.requestAfterFollow()`, fired by `toggleFollow`/`toggleFollowAuthor`, login not required — no-op in demo/unit-test runs), not just from the login-gated Subscriptions view.

**Tapping a notification opens what it's about.** Every poller notification's `userInfo` encodes a `NotificationRoute` (`Subscriptions/NotificationRouting.swift`): `.newChapters(workId)`, `.newWork(workId)` (a followed author's one new work) or `.newWorks(author)` (several at once). `NotificationTapHandler` is the `UNUserNotificationCenterDelegate`, installed in `FanficlyApp.init()` because it must be set before `didFinishLaunching` returns or a tap that cold-launches the app is never delivered. Its callback runs off the main actor, so it decodes the Sendable route there and hops to `NotificationRouter.shared`; `RootView` takes it from there (`onChange(initial: true)` covers a cold-launch tap that lands before the view exists). `openNotificationRoute` has two cases. **iPhone on the sidebar menu** (always after a cold launch): select the route's `landingTab` — Library for a saved work, Subscriptions for an AO3-only subscription, Followed Authors for author news — and let a deferred `.task(id:)` push once the detail column mounts, like the widget resume route. **A tab already on screen** (any iPad/Mac state, or iPhone inside a tab): replace `detailPath` with the route directly, on top of the current tab — no tab switch. Both halves were learned the hard way (end-to-end, tapping real banners): switching the compact split view's selection while a screen is pushed intermittently drops the push (SwiftUI's "NavigationRequestObserver tried to update multiple times per frame"), and a deferred task never runs on a stack with a screen pushed over it — in compact width not even a modifier on the `NavigationStack` itself — so a tap for the tab already showing silently did nothing. The destination is `.id(route)`'d because replacing one route with another in the same slot otherwise reuses the old screen, still showing the old work. Work routes always open the **live** `WorkDetailView`, even for a saved work, because a downloaded copy doesn't have the new chapter (reading position is keyed by work id, so it still resumes). Payloads from before routing existed carry only `workId` and decode as `.newChapters`. There's no `willPresent`, so a notification posted while the app is foregrounded still isn't shown.

## Custom URL Scheme & Share Extension

- **Deep Link Handling**: The main app registers the custom scheme `fanficly` in `project.yml`. Any URL matching `fanficly://import?url=<url>` is caught by `RootView.swift`'s `.onOpenURL` handler, which triggers the `ImportOverlay` view to fetch the work metadata and chapters, download the EPUB for offline storage, and launch the reader sheet (`SavedWorkReader`).
- **Share Extension**: The `FanficlyShare` target is a Safari Share Extension. When activated on a Safari URL, it loads the URL attachment, encodes it, opens `fanficly://import?url=<encodedURL>`, and completes the extension request.
- **Widget resume route**: `fanficly://resume/<workId>?chapter=<n>&paragraph=<m>` — opened when the user taps the widget. `RootView.parseResumeRoute` parses it; the handler decides what (if anything) to install via the pure `ResumeProgressPolicy.anchorToInstall` (in `RootView.swift`), then pushes `SavedWorkReader` (or `WorkDetailView` if the work isn't saved) via a `ResumeWorkRoute` navigation destination. **A resume tap never moves saved progress backwards**: if local `ReadingProgress` exists, only a *strictly fresher* `WidgetProgressStore` entry (i.e. progress synced from another device — local saves stamp both stores with the same `Date.now`, so same-device entries always tie) may override it, and even then the store's anchor installs, never the URL anchor baked into the widget (WidgetKit timeline reloads are budget-throttled, so the URL can lag hours behind). No local progress → seed from the store, falling back to the URL snapshot. **`openResumeRoute` navigates in the same two cases as `openNotificationRoute`** (above): from the **iPhone sidebar menu** (incl. cold launch) it selects Library and sets `pendingResumeRoute`, and the `.task(id:)` on the detail stack pushes once the column mounts; with **a tab already on screen** it assigns `detailPath = [route]` directly, on top of that tab — no tab switch — replacing whatever was pushed. Routing every tap through the deferred task used to break that second case: with another reader pushed in Library the tap did nothing, and the stale route fired later, when you popped back to the Library root. **In the sidebar case `openResumeRoute` must still not clear `detailPath` itself**: the old code called `select(.library)` (which clears the path) and then re-pushed in the deferred task; that clear-then-repush spans two update cycles and SwiftUI could drop the push and strand you on an empty Library. The destination is `.id(route)`'d so one resume route replacing another builds a fresh reader instead of handing the old one the new route; assigning the same route again is a no-op.

## Reader settings profiles

Typography settings are per-device: typography/layout keys go through `ReaderProfile.deviceKey(_:)` and each platform stores its own active profile (`reader.activeProfile.{phone,pad,mac}`). This does not apply to every reader preference: `reader.showImages` and `reader.keepScreenAwake` use unsuffixed keys. Profiles are Codable structs serialized as JSON under the `reader.profiles` key, managed from the reader's Aa menu and `ReaderSettingsView` (create/rename/delete/switch). `ReaderProfileSyncStore` mirrors that key through iCloud key-value storage, merging by case-insensitive profile name (`ReaderProfile.mergedProfiles`); `iCloudSyncManager` also includes profiles in full library backups. Legacy un-suffixed typography keys migrate once via `ReaderProfile.migrateLegacySettingsIfNeeded()`.

**Deletions sync as tombstones.** A pure union merge resurrected deleted profiles instantly (KVS caches locally), so `ReaderProfile` carries optional `updatedAt`/`deletedAt` stamps (optional like `widthRaw` — old JSON still decodes, and old app versions ignore the new keys). View save helpers call the `saveProfiles(_:previousJSON:)` overload, which stamps `updatedAt` only on content changes, turns names missing from the new list into tombstones (hidden from `loadProfiles`, kept in the stored array so the deletion propagates), and prunes tombstones after 90 days. `mergedProfiles` resolves per-name conflicts by newest stamp — tombstone beats stale copy, newer re-creation beats tombstone, two stamp-less legacy copies keep the old union behavior. Trade-off: a device offline past the 90-day tombstone lifetime can resurrect a profile it still holds live.

## iCloud library backup (merge, never clobber)

`iCloudSyncManager.backupToiCloud` must never write a whole-file snapshot: `queueBackup` fires on every mutation, so last-writer-wins would let a near-empty device overwrite a full one's backup. The backup decodes the existing cloud `library_backup.json` and **unions** it with the local snapshot (`mergedBackup`, a pure `nonisolated static` helper) before writing: cloud-only records are kept for every type; on conflict the local record wins, except reading positions keep the newer `updatedAt`, chapters survive from whichever side has more, and stats merge conservatively. If the cloud file is an un-downloaded `.icloud` placeholder, the backup starts the download and skips (next `queueBackup` retries). `ChapterBackup.aoId` is optional so older backups decode. Stat merges lift `totalSeconds` to `max(existing, Σ mergedDaySeconds)` after unioning day buckets, preserving the `totalSeconds == Σ daySeconds` invariant (All Time must never show less than a Year). Consequence of union semantics: deletions don't propagate between devices — the safe default versus silent data loss.

**Restore is a strictly forward merge** — it also runs automatically: the launch `.task` restore-merges whenever iCloud sync is on and the cloud file changed since this device last applied *or wrote* it (`cloudBackupHasUnappliedChanges`, stamped under `icloud.lastRestoredBackupDate` by both restore and backup), not just on an empty library. That's only safe because restore can never move data backwards: reading positions (both `ReadingProgress` rows and `Work.lastRead*`) apply only when the backup side is newer, follow/star/pin merge as an OR, folder assignments union (never `removeAll`), `lastSeenChapterCount` only advances (regressing it would re-fire chapter notifications), and chapters replace only when the backup carries **more** than the local copy (a metadata-only follow backs up `chapters: []` — restoring that must not wipe an offline download). Keep any new restore field to these forward-only semantics or the launch sync will corrupt whichever device opens second.

**EPUB re-download after restore** — the backup carries chapter *text* but not the EPUB *files*, so restored works read offline yet lose their Downloaded state. After any successful restore, `RestoreDownloadCenter.proposeRedownload` (candidates: works with chapters but no `WorkPersistence.epubURL`) drives a root-level prompt + progress banner (`.restoreRedownloadUI()` on `RootView`): x/total bar, spinner, cancellable mid-run — cancelling keeps everything already restored/downloaded. Downloads go through `AO3Client.downloadEPUB` sequentially (the 1 req/sec throttle paces them).

## Last-read widget

`FanficlyWidget` shows the last-read story with a progress bar. When passed a progress fraction, `ReadingProgressStore.save` also writes to `WidgetProgressStore`, which persists to the `group.io.github.yennster.fanficly` app-group defaults and mirrors to iCloud KVS (debounced ~1.2 s; immediate when the reader closes). `FanficlyApp` installs the KVS observers for `WidgetProgressStore`, `ReaderProfileSyncStore`, and `StreakStore` at launch, skipped in demo and unit-test runs. Tapping the widget opens the resume route above. Besides small and medium it offers the lock-screen `accessoryCircular` and `accessoryRectangular` families (iPhone and iPad; the Mac has no lock screen); they read the same entry, use template colors only, and set the same resume URL.

## Other widgets and shortcut routes

`FanficlyWidgetsBundle` in `FanficlyWidget/FanficlyWidget.swift` includes six
widgets: last read, reading streak, subscriptions, folder shortcuts, saved
searches, and recommendations. `project.yml` compiles `WidgetProgressStore.swift`,
`StreakStore.swift`, and `WidgetDataStore.swift` into **both** app and extension.
Keep those shared files free of app-only models/UI dependencies;
`WidgetDataUpdater.swift` is the app-only SwiftData projection layer.

- `WidgetDataStore.updateAll(context:)` writes snapshots to app-group defaults
  (and standard defaults as fallback), then reloads timelines. The extension
  does not scrape AO3. Recommendations are saved local works prioritized by
  starred/pinned/recently saved, not a remote recommendation service.
- `StreakStore` records local-calendar reading dates, unions dates through KVS,
  and keeps the latest 100 activity dates. A streak continues from today or
  yesterday; `StreakStoreTests` covers its date policy.
- `fanficly://library?folder=<name>` selects Library, then a deferred
  `PinnedFolderRoute` opens the named folder. Folder identity in this route is
  its name; a missing/renamed folder shows Folder Not Found.
- `fanficly://search?query=<prompt>` selects Search and writes
  `search.pendingQuery`; `SearchView.consumePendingQuery` consumes/clears it
  and loads the prompt via `SearchSyntax`. **Current limitation:** the widget
  also includes saved-filter JSON in this same query field, but the consumer
  expects prompt syntax, not JSON. Do not assume saved filters round-trip through
  that route; an implementation change needs an explicit encoding contract/test.
- Subscription/recommendation widgets use `fanficly://resume/<id>`; unlike
  notification work routes, this can open the saved copy.

## iPhone Duo (foldable) — Oct 2026

The Duo (5.4" outer, 7.6" inner, iOS 27.1, ships Oct 23 2026) is the **phone** idiom on both displays. The outer display is compact width; the inner one is regular/regular, so the app shows its sidebar + detail layout there. Folding and unfolding resize the same scene: no relaunch, no scenePhase change. What's handled:

- **Size-class changes keep your place.** `RootView`'s `onChange(of: horizontalSizeClass)` maps the tab on screen into `compactSelection` (keeping `detailPath`). It used to reset to the sidebar, so every fold, Pro Max rotation or iPad Split View resize dropped you out of the story. Only a fresh launch starts on the sidebar.
- **The reader re-anchors after a width change.** Continuous and chapter-page modes scroll the tracked top paragraph back to the top (`reanchor`). Two subtleties make that correct:
  - **Samples are resize-aware.** `TrailingAnchorSample.width` records the width samples belong to; preference updates at another width are reflow, not reading, and are ignored. Otherwise a reflow sample lands just before `onChange(of: width)` and re-anchors to the wrong paragraph.
  - **There's a trailing sample.** The ~3/sec throttle used to drop the end of a fling, so the tracked anchor (and saved progress) could sit a whole fling behind the screen. `scheduleTrailingAnchorSample` records where scrolling settles.
- **Line length is capped on wide phone layouts.** `ReaderMetrics.textColumnWidth` caps the column at 40 em (~80 characters) for the phone profile only. Its width % was tuned on ~400pt and would stretch across the inner display or a Pro Max in landscape. The paginator uses the same function, so measured pages match drawn ones.
- **Page-by-page re-paginates when the window height changes**, e.g. when a pinned picture-in-picture video shrinks the app, and when the controls show or hide (below).
- **All four iPhone orientations are listed**, which Duo multitasking requires.
- **Page-by-page has a two-page spread** (`ReaderSpread` in `ReaderTheme.swift`). It's on by default, chosen per device with "Pages on screen: One page / Two pages" (right under Reading mode in the Aa menu, and a segmented picker in Settings → Reader; stored as `reader.twoPageSpread`). Two-page mode has its own text width, `reader.spreadWidthPercent` (default 88%, 60–100): the Aa menu's margins item edits whichever layout is on screen ("Page margins" vs "Margins"), and Settings shows a "Two-page margins" slider. The header-only title page always uses at least the default width, so narrow margins can't crush its metadata row. When the window is wide (≥700 pt and wider than tall: Duo unfolded, iPad landscape, the Mac), pages pair up side by side like a book, two pages per turn, "Pages 3–4 of 12" in the footer. Pages pair within each chapter, so chapters open on a fresh spread. The gutter sits on the fold, read via `GeometryProxy.reservedRegions(kind: .division, options: .includeInactive)` because the fold reads as inactive while the Duo lies flat, and the gutter is **blank: no drawn crease**, since the hardware fold is the only seam. With the controls hidden (full screen) the vertical strip and the page footer both go, as the footer does everywhere, and the pages take the footer's room; a tap anywhere in the page's middle third (blank areas included, via `contentShape`) brings the controls back. Both pages paginate at the spread's page width; selection stays a page id, so progress, restore and narration are unchanged.
- **Page-by-page measures pages for the area actually on screen**, with the controls (nav bar, page footer, narration bar) showing or hidden, so pages fill the screen either way (`PageAreaTracker`, in `ReaderTheme.swift`). Pages shrink as soon as the area does, so text never runs under the controls. They grow once the area has held still for 0.3 s (a transition passing, the narration bar closing), but within 50 ms when the controls hide, or the old pages sit over a blank band while the bars slide away; the 50 ms joins the Mac's two steps (page footer, then toolbar). One page or two is decided on the controls-up height for the window (`PageAreaTracker.controlsUpHeight`), not the area on screen: full screen's extra height makes the area squarer, and an iPad in landscape beside the sidebar switched from two pages to one when the controls hid. History: measuring the chrome-hidden height cut off a page's last lines whenever the controls were up; measuring only the smallest area seen left blank space at the foot of every page after one brief short layout (a push transition, the narration bar); and measuring the controls-up area left their room blank whenever the controls were hidden.
- **Pages fill to their last line.** `ReaderPaginator.paginateChapter` packs a page by `boundingRect`, then `fitPage` checks it against SwiftUI's own layout (`drawnHeightMeasure`, `ReaderPageCell.pageContent` in a hosting controller) and, when the two disagree, re-packs, bisecting the budget between the fullest packing that fit and the smallest that ran past. They do disagree: on iOS a long paragraph can wrap to one line fewer than `boundingRect` counts, and under the Mac's metrics New York lines draw a point taller and small text fits more words a line, so unchecked pages came out a line or more short (or, on the Mac, ran a line under the footer). A paragraph may start with a single line at the foot of a page (holding back a lone opening line, as books do, left up to two lines blank), and checked pages are packed to the page area exactly (`ReaderPaginator.reserve` is 0; it was 2% of the page). The check costs ~1.5 ms a page, so on iOS only the chapter being read gets it; the chapters either side (paginated so page turns run on into them, and re-paginated once reached) pack by `boundingRect` with the old 2% headroom (`uncheckedReserve`). The Mac checks every chapter (`checksAdjacentChapters`), since there unchecked pages could run past the footer. `ReaderMetrics.textColumnWidth` is in whole points.
- **Re-paginating keeps the page on screen in place.** `ReaderView` tracks where that page's text begins (`PageStart`: paragraph, sentence, and character offset into the sentence, carried on each `ParagraphAtom` as `sentenceIndex`/`sentenceOffset`) and `ReaderPaginator.paginateChapter(startingAt:)` breaks a page exactly there, so showing or hiding the controls, the narration bar, a resize or a typography change adds or removes lines at the foot of the page instead of jumping to wherever the new pages break. The page before it may come out short. In a two-page spread the kept start is the left page's, and when pairing from the chapter's start would put the kept page on the right, it's marked `startsSpread` and `ReaderSpread.spreads` opens a spread on it (the page before then stands alone), so the spread on screen never swaps sides. Re-paginating from one of the layout's own page breaks (reopening on a page) gives the same pages and pairs. A chapter jump re-paginates from the new chapter's start. iPhone Duo's open book pins its top (`bookTopShift`), so there a toggle only adds or removes the page footer's room.

**Testing on the Duo simulator:** the repo builds with **Xcode 27.1** (iOS 27.1 SDK and runtime), which has an "iPhone Duo" device type. Set its pose in Device Hub (`Xcode.app/Contents/Applications/DeviceHub.app`, which replaced Simulator.app): the Closed / Partially Open / Open buttons under the device. Pose can't be scripted, and `simctl io … screenConfig power` crashed SpringBoard, so don't use it. Under XCUITest: `XCUIScreen.main` is the **outer** display (black while unfolded), the unfolded app's own frame (`app.frame`) is reported in portrait while the UI is landscape, but the window's and elements' frames are right, so aim coordinates from `app.windows.firstMatch` or an element, never from `app`. No screen exposes a titled navigation bar, because the bars are vertical. While unfolded, `simctl io … screenshot` still captures the dark outer display. An **iPhone Pro Max rotated** still makes the same compact ↔ regular transition for quick checks.

**App Store screenshots for the Duo** (required from April 2027): the `screenshots` lane runs `ScreenshotTests/testCaptureDuoScreens` on the Duo (when the Xcode has one) in whatever pose it's in: folded → `docs/screenshots/duo-outer` (portrait, 1398×2034 slides), unfolded → `duo-inner` (landscape like an open book, 2853×2007 slides, the reader shown as a two-page spread). CI captures the pose the simulator boots in and reframes the committed captures of the other; refresh that one by hand on a Mac. `upload_store_art` uploads them, with the iPhone preview, which the Duo slot accepts at 886×1920, through the App Asset Library API (`bin/upload-duo-assets.py`), because deliver doesn't know the Duo sizes.

**Not done yet:**
- With the 27.1 SDK, toolbars and tab bars go **vertical** on the Duo, and Apple wants toolbar items to carry a title + symbol there (the reader's items have drawn as icons in the strip; whether the strip ever draws the titles is unverified, but the system also uses them for overflow and Large Content Viewer). So every reader toolbar item (`ReaderView`, `WorkDetailView`, `SavedWorkReader`) is a `Label`, never a bare `Image`, with no `.labelStyle`: the automatic style already draws icons only in a horizontal bar, and forcing `.iconOnly` would take the titles away from the system everywhere (there's no API to tell the two apart). Apple reserves the ellipsis symbol for the system overflow menu, so the parents' options menus (More, Work options) use `book.circle`; don't bring back `ellipsis.circle`.
- There's no API to detect a Duo. Never branch on idiom or screen size; use size classes and geometry.

## Mac Catalyst

The app also builds for the Mac via Catalyst (`TARGETED_DEVICE_FAMILY: "1,2,6"`, `SUPPORTS_MACCATALYST: YES` in project.yml). `RootView` implements a global UI zoom — `app.zoomScale` — by counter-scaling the root view. Step and clamp live in the pure `UIZoom` (0.5–2.0 in tenths, `UIZoomTests`). The View menu (`CommandGroup(after: .sidebar)` in `FanficlyApp`, not a `CommandMenu("View")`, which would add a second View menu) shows Zoom In ⇧⌘+, Zoom Out ⇧⌘− and Actual Size ⌘0; a menu item takes one shortcut, so `RootView` keeps the other spellings (⌘+, ⌘=, ⇧⌘=, ⌘−, ⇧⌘_) as hidden buttons. The reader handles hardware arrow-key page turns via `ReaderKeyPressModifier` (`.onKeyPress`), with `.focusEffectDisabled()` so no focus ring is drawn. There is no Mac Catalyst simulator: Mac screenshots are captured on a landscape iPad Pro 13-inch sim instead (see Screenshots).


## Screenshots

`bin/take-screenshots.sh` is the interactive capture (manual navigation). `FanficlyUITests/ScreenshotTests` is the automated version — it drives the app **in `-demoMode`** and writes PNGs to `docs/screenshots/{iphone,ipad,mac}/` (idiom subfolder; path derived from `#filePath`; the simulator runs as the host user so it can write there). Run it with `-only-testing:FanficlyUITests/ScreenshotTests/testCaptureMainScreens`; the Mac set comes from `testCaptureMacScreens` on a landscape iPad Pro 13-inch simulator (stand-in for the Mac app — there's no Catalyst sim). Demo mode is fully offline so the shots are deterministic. CI never runs the screenshot or preview UI tests; its only UI tests are `ReaderLayoutTests`. Capture gotchas:
- **Marketing mode.** `bin/sim-marketing-mode.sh on|off <sim>` switches a simulator to US region (so the status bar reads "9:41", not "09:41"), light appearance, and Apple's 9:41 status bar, then restores the saved region. The `screenshots` lane and `bin/record-app-previews.sh` both use it. The tests also pass `-AppleLocale en_US` so numbers read "48,213" whatever the simulator's region is. Demo mode forces `.preferredColorScheme(.light)`, so a dark *reader theme* still gets a dark status bar in captures.
- **Settings rows below the fold aren't created** by the lazy `List`, so the Privacy capture scrolls until "What this app sees and stores" exists. Without that it silently skipped the shot and `08-privacy.png` stayed stale from June to October 2026. On iPad, re-selecting a sidebar item doesn't pop the detail stack, so it pops back one level via the nav-bar back button first.
- **Landscape split view navigates by ⌘1–9** (the "Go" menu, mirrored in `openSidebarItem`'s map). It falls back to tapping the sidebar row when the keypresses never land, which happens on a freshly booted simulator; otherwise the shot captured the wrong tab.
- The search shot types explicit `tag:"Slow Burn" complete` (the same chips a tapped suggestion makes, and a full page of results), because waiting on live typeahead timed out mid-run on iPhone.

**App Store marketing screenshots** are built by `bin/frame-screenshots.py` (run by the `fastlane screenshots` lane after capture). Each one is a web page — `bin/store-art/screenshot.html` + `brand.css` — rendered at the exact App Store size by headless Chrome through `bin/store_art.py`. That's the same look as the product-page header and search-results art: indigo mesh gradient with paper grain and faint floating pages (the icon's motif), a letter-spaced label, a New York serif headline with a gold italic accent and sparkles, and the app in a genuine Apple bezel (frameit's downloaded Silver iPhone 17 Pro Max / iPad Pro 12.9" / MacBook Pro 16 frames, composited directly, not via `fastlane frameit`). Copy and order live in `SLIDES` (`*word*` = gold accent, `|` = line break, joined on the one-line Mac layout). Outputs: `screenshots/final/` (tracked, plus the README `showcase.png`), `fastlane/screenshots/en-US/` (iPhone 6.9" `1320×2868`, iPad 13" `2064×2752`) and `fastlane/screenshots-mac/en-US/` (`2560×1600`; a separate tree because deliver matches shots to slots by pixel size and the iOS listing rejects Mac sizes). Mac raws are cropped below the iPad status bar to a top-anchored 16:10 window first. Chrome needs `--run-all-compositor-stages-before-draw` or large drop-shadow layers occasionally leave an unpainted white tile. `release`/`metadata_only` upload both sets (`platform:` ios, mac or both), and `upload_store_art` uploads the latest generated ones.

**App preview videos** (`bin/record-app-previews.sh`, or `fastlane previews`) record `PreviewTourTests` in marketing mode and caption each beat with a card rendered from `bin/store-art/caption.html` (indigo glass card, label, New York headline with the gold accent), faded and risen in by ffmpeg. **No device frames or decorative framing around the capture**: Apple rejects previews under Guideline 2.3.4 for "framing around the video screen capture", so the brand look lives only in the overlay cards, and the Mac's 4:3 capture gets a plain indigo pillarbox. Caption specs are `LABEL;HEADLINE;start;end;anchor;y` (`y` = `bNNN` for a bottom margin) in raw seconds, re-tuned from a contact sheet after every re-record. simctl drops frames while the screen is static and squeezes that time out, so a beat needs motion to survive. `upload_store_art` uploads them with `bin/upload-app-previews.py` (deliver can't upload previews).

**Creative assets** — the product-page header (`3840×1646`) and search-results (`3840×2560`) images — are rendered into git-ignored `fastlane/creative/en-US/` by the `creative_assets` lane (`bin/make-creative-assets.py`, layout in `bin/store-art/creative.html`, from the demo-mode captures). `upload_store_art` (`bin/upload-creative-assets.py`) uploads them through the App Store Connect **App Asset Library** API (reserve → PUT → commit → `PRODUCT_PAGE_HEADER_ASSET` / `APP_STORE_SEARCH_RESULTS_ASSET` placements on the editable iOS version), since deliver doesn't support them. Key content must sit in Apple's centered safe areas (header 1646×661, search 2168×1030), with no prices, URLs or other platforms' logos, and everything 4+.

## Reading stats & yearly wrap

The **Stats tab** (`StatsView`, in `LibraryView.swift`) shows reading totals
(stories read, time read, words read, current day-streak) and top fandoms /
categories / ships / authors for a chosen period — **Week / Month / Year / All
Time** — with ‹ › to page through periods (`StatsPeriod`, an `anchor` date, and
`Calendar.dateInterval(of:for:)`). It works for everyone, on-device; iCloud only
*syncs* the data across the user's own devices (it is **not** gated behind
iCloud).

Source of truth is the `ReadingStat` @Model (one row per work, keyed by
`ao3Id`, in `Models/Work.swift`): a snapshot of the work's metadata at read
time (so stats cover fics the user never saved to the Library) plus accumulated
active reading seconds, bucketed per calendar **day** (`daySeconds: [String:
Double]`, keyed `yyyy-MM-dd`) so any period rolls up from the one row. Each row
also stores `maxProgress` (furthest 0…1 position reached) and `workIsComplete`.
`ReadingStatsStore` (in `ReadingProgressStore.swift`) upserts rows; non-empty
metadata overwrites the snapshot, empty fields are left intact so a later
metadata-less read can't wipe it, and `maxProgress` only ever advances (never
regresses on a re-skim). Aggregation lives in the pure, testable
`ReadingStatsAggregator` (no SwiftData/UI) — `summarize(_:interval:)` (interval
`nil` = all-time), plus `dayKey`/`dataDateRange` for the period navigator.

**Words read and stories read are progress-based, not per-open.** Opening a work
must not credit its whole word count: "words read" is `Σ wordCount × maxProgress`
(`ReadingStatSnapshot.wordsRead`), and "stories read" counts only **finished**
works (`isFinished` — `maxProgress ≥ 0.99`, or `≥ 0.95` for a complete work,
matching the Library row's "Finished" badge). A period includes a work if it was
*read during* the interval (a `daySeconds` day in range), independent of time, so
zero-time backfilled reads still show in their week/month/year. The Stats tab
**defaults to All Time**. `ReadingStatsBackfill` (one-shot, gated by
`reading.stats.backfilled.v2`, run from `FanficlyApp`'s launch `.task` after the
iCloud restore) seeds rows for history that predates the feature **and** enriches
pre-existing rows whose `maxProgress` defaulted to 0 — pulling progress from
`Work.lastReadProgress` (or the chapter reached). It records zero time (none was
ever captured) but dates each read so periods line up.

**Reading time is real active time**, not a word-count estimate: `ReaderView`
times spans while the reader is open, foregrounded, **and visible** —
`ReaderLifecycleModifier` keeps its own `isVisible` `@State` (set in
`onAppear`, cleared in `onDisappear`) and only restarts the timer on
scene-phase `.active` while visible, so a reader buried under a pushed view
(author page, a second reader) can't record phantom time; flushing on leaving
`.active` stays unconditional so no recorded time is lost. Spans flush on
disappear and when backgrounded, plus a mid-session checkpoint from
`saveProgress` so a force-quit doesn't lose a long session. A single span is
capped at 4h so a reader left open overnight can't inflate totals. The streak
number reuses the existing `StreakStore`. Progress can genuinely reach 1.0:
see the end-of-content anchor rule under "Things to know about AO3" (reading
position bullet) — without it, finished works stalled around 81% and never
counted as read.

The Library list shows a compact `LibraryStatsStrip` (stories/time/streak) atop
the list that taps through to the Stats tab (by setting `app.selectedTabRaw`).
The Stats screen's toolbar Share button renders `WrapShareCard` (a portrait
wrap-up image for the selected period on the indigo brand canvas) via
`ImageRenderer` and presents it through the shared `ShareSheet`.

**Yearly reading goal** (RM-011): an optional count of stories to finish this
year in `@AppStorage(ReadingGoal.storageKey)` (`reading.yearlyGoal`, 0 = no
goal), per-device and deliberately not in the iCloud backup. The Stats tab shows
a `ReadingGoalCard` ring (or a "Set a 2026 Reading Goal" button, also on the
empty state) on All Time and the current year only, and `WrapShareCard` adds a
goal row for those scopes. "This year's finished" is `summarize(…, interval:
<this year>).storiesRead`, the wrap's rule; with no finish date stored, a story
finished last year and reopened this year counts too. Pace is
the pure `ReadingStatsAggregator.goalProgress` (an even spread across the year,
rounded down, so January 1st is "On pace"), tested in `PersistenceTests`.

`ReadingStat` is registered in `FanficlyApp.sharedModelContainer`'s `Schema`
(and `PersistenceTests`' in-memory schema), included in `iCloudSyncManager`
backup/restore (`StatBackup`; restore merges conservatively — max of totals,
per-day maxima, and `maxProgress`, OR of `workIsComplete`, widest date span — so
two devices never double-count; the two progress fields are optional in
`StatBackup` so older backups still decode), and seeded in `DemoSeed` for
screenshots. `ReadingStat.snapshot` is the shared
value-type bridge from the @Model to the pure aggregator.

## App Store rating prompt

`ReviewPrompter` (Settings/ReviewPrompt.swift) asks via SwiftUI `requestReview` only at a moment of success and only for clearly engaged readers. `ReadingStatsStore.record` returns true for the read that *finishes* a story; the reader reports it, and when that reader closes `ReviewPromptPolicy` must pass. The policy needs ≥3 finished stories, ≥3 reading days, ≥7 days since the first read, never asked in this version, and ≥120 days since the last ask. `RootView` then shows it ~1.2s later, over the list, never over story text. The ask is recorded up front, since StoreKit doesn't report display. Never in demo/test runs. Settings → About also has a manual "Rate Fanficly on the App Store" link (`ReviewPrompter.writeReviewURL`, app id 6775897153). Don't add more triggers: keeping it rare is the point.

## Privacy posture (do not regress)

There is **no developer-operated backend or data collection**. Library backups
and KVS sync (reader profiles, last-read progress, streak) use the user's own
private iCloud. Search, login, comments, and subscriptions communicate directly
with AO3; opting into story images also contacts their external hosts. Do not
describe the app as never transmitting data. Passwords are used only for login;
session cookies are persisted in Keychain. Don't add analytics, crash reporting,
or remote logging. See `../PRIVACY.md` and `Fanficly/PrivacyInfo.xcprivacy`.

## Content safety and accessibility

`RootView` presents the 17+ confirmation until `ContentControl.ageConfirmedKey`
is set (demo mode bypasses it). `ContentFilter.apply` removes local hidden work
IDs and, by default, Mature/Explicit ratings from result lists. This is
**display-layer filtering**, not an AO3 query filter or a universal reader access
gate; result totals can exceed the number of visible rows. New result-list
surfaces should preserve this policy. `HiddenWorkStore` owns local hide/unhide;
Settings exposes hidden works and the content policy. AO3 hosts and moderates the
stories; Fanficly does not host them.

Use the `DesignSystem` helpers and existing native controls. Keep VoiceOver
labels, announcements, accessible alternatives to reader gestures, and
screen-owned sheet/alert presentation (see Conventions). Verify reader themes,
large text, compact/regular widths, all three reading modes, and controls
shown/hidden when changing shared reader layout. Read `ACCESSIBILITY.md` before
changing reading comfort or assistive-technology behavior.
