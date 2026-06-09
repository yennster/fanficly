# AGENTS.md — working in the Fanficly repo

Short notes for Codex sessions and other agents.

## What this is

A SwiftUI app (iPhone + iPad, iOS 17+, Swift 6) that reads AO3 fanfiction. There is no AO3 JSON API, so the app talks to AO3 by scraping HTML with SwiftSoup, using one shared `URLSession` with a custom `User-Agent` and a 1 req/sec throttle. Everything runs on-device — no servers, no analytics.

## Layout

```
project.yml                    # xcodegen is the source of truth
bin/                           # developer scripts (icon gen, screenshots)
Fanficly/
  FanficlyApp.swift            # @main, env wiring, ModelContainer, BG task
  RootView.swift               # NavigationSplitView sidebar
  AO3ClientEnvironment.swift   # @Environment(\.ao3Client) key
  Models/Work.swift            # all SwiftData @Model types
  Networking/
    AO3Client.swift            # protocol + live actor + MockAO3Client
    AO3Endpoints.swift         # URL builders
    ThrottleActor.swift
    HTMLParsers/               # one file per page kind
  Search/
    SearchView.swift           # smart-search UI, results, saved searches,
                               #   WorkDetailView (reader + toolbar actions)
    SearchPromptParser.swift   # rules-based prompt → AO3SearchFilters
    AO3SearchFilters.swift     # 1:1 mapping of AO3's /works/search fields
    KnownTags.swift            # curated freeform + fandom dictionaries
    FoundationModelsEnricher.swift   # iOS 26+ on-device LLM fallback (no-op elsewhere)
  Browse/
    FandomCategories.swift     # 10 AO3 media categories + curated seed lists
    BrowseView.swift           # category → live fandom list → filtered works;
                               #   landing page also lists saved filters.
                               #   FandomWorksView is drivable by filters+title
                               #   (fandom OR a saved filter), not just a fandom.
  Search/
    WorkFilterSheet.swift      # AO3-style filter panel editing AO3SearchFilters
  Reader/
    ReaderView.swift           # continuous + paginated modes, chapter header,
                               #   floating chapter indicator, typography menu,
                               #   reading-position save/restore; plain system
                               #   nav bar (no auto-hide — see below); paginated
                               #   mode has tap-to-turn zones + "Listen" TTS bar
    ChapterContentView.swift   # renders a chapter as paragraphs w/ scroll anchors
    HTMLText.swift             # async cached HTML → AttributedString (summary)
    HTMLToAttributed.swift     # SwiftSoup → AttributedString / paragraphs;
                               #   speechParagraphs() feeds the TTS narrator,
                               #   index-aligned with the rendered paragraphs
    SpeechController.swift      # on-device TTS ("Listen") via AVSpeechSynthesizer:
                               #   gapless per-paragraph narration, chapter
                               #   auto-advance, lock-screen Now Playing controls
    WorkHeaderMetadata.swift   # rating/warnings/tags/stats; collapsible drawer
    ChapterTracking.swift      # PreferenceKeys: current chapter + paragraph anchor
    ReadingProgressStore.swift # load/save ReadingProgress by ao3Id
    WorkExportButton.swift     # multi-format export → share sheet
    ReaderTheme.swift          # theme/font/size/spacing/width/mode, @AppStorage
  Library/
    LibraryView.swift          # All/Following/Downloaded filter
    SavedWorkReader.swift      # offline if downloaded, else fetch on demand
    WorkPersistence.swift      # upsert, upsertMetadata, toggleFollow
    iCloudSyncManager.swift    # backup/restore SwiftData library to iCloud
  Auth/                        # AuthState (Keychain) + LoginView
  Subscriptions/               # poller (AO3 subs + local follows), BG task
  Settings/                    # SettingsView + ReaderSettingsView + privacy
  DesignSystem/                # Typography, Spacing, FlowLayout, SafariView, ShareSheet
  PrivacyInfo.xcprivacy        # zero collection, zero tracking
FanficlyTests/                 # ~120 XCTest cases — parsers, filters, endpoints,
                               #   HTML render, tracking, in-memory persistence
FanficlyUITests/               # smoke test + ScreenshotTests (README shots)
FanficlyShare/                 # Safari share extension target
  ShareViewController.swift    # intercepts browser URLs & redirects to main app
  Info.plist                   # share service configurations
```

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

CI runs the same on both an iPhone and an iPad simulator. CI picks the newest installed Xcode and the newest available sim UDIDs at runtime — don't hardcode device names anywhere.

~120 unit tests (`FanficlyTests`), all pure/fixture-based (no network):
- **Parsers** — `SearchResultsParserTests`, `WorkPageParserTests` (+ `LoginParserTests`), `SubscriptionsParserTests`, `MediaCategoryParserTests`, `WorkMetadataParserTests`. Each feeds inline HTML fixtures and asserts the typed output.
- **Search** — `SearchPromptParserTests` (ships, characters, ratings, warnings, categories, freeforms incl. romance, fandoms, word count, status, engagement, language, exclusions), `AO3SearchFiltersTests` (every `work_search[*]` field mapping, NOT-exclusion composition, Codable round-trip for saved filters), `TagResolverTests` (canonical resolution, ship slash variants, character-fallback ship resolution via `StubAO3Client`), `PromptTextTests` (chip-removal → search-box text), `FandomCatalogTests` (fandom → category icon).
- **Endpoints** — `AO3EndpointsTests` (URLs, pagination, AO3 media path-encoding).
- **Reader** — `HTMLToAttributedTests` (formatting, paragraph collapsing, lists/headings/hr), `ChapterTrackingTests` (anchor key/parse, topmost-anchor, current-chapter).
- **Persistence** — `PersistenceTests` spins up an in-memory `ModelContainer` to exercise `WorkPersistence` (upsert/metadata/follow) and `ReadingProgressStore` (save/load round-trips).
- **Misc** — `ThrottleActorTests` (1 req/sec throttle timing). `StubAO3Client` is a scriptable `AO3ClientProtocol` test double for resolution logic.

When you add a feature, add its tests here. Make a private helper `internal` if it needs direct testing (see `TagResolver.candidates/bestMatch`).

The CoreData "Sandbox access to file-write-create denied" noise during test runs is harmless — it comes from SwiftUI booting the SwiftData container in the test host. Filter it out with `| grep -v CoreData:`.

## Conventions

- **AO3Client is the only seam to the network.** UI views never touch `URLSession`. Anything that needs data uses `@Environment(\.ao3Client)`. There's a `MockAO3Client` for previews and tests.
- **Throttle.** Always go through `AO3Client` — never bypass the throttle. AO3 is generous to good citizens, hostile to bad ones.
- **Parsers are pure.** `SearchResultsParser`, `WorkPageParser`, `LoginParser`, `SubscriptionsParser`, `WorkMetadataParser` take HTML strings and return typed values. Test them with inline HTML fixtures.
- **SwiftData models** live in `Models/Work.swift`. The model container is constructed once in `FanficlyApp` and shared with `BackgroundRefresh`.
- **Settings come from `@AppStorage`**, not custom UserDefaults wrappers.
- **No third-party dependencies beyond SwiftSoup and KeychainAccess.** Don't add analytics, crash reporters, or any SDK with a network side-channel — privacy posture is the headline feature.

## Common tasks

**Add a new search filter.** Add the field on `AO3SearchFilters` + a row to its `queryItems()`, then add an extractor to `SearchPromptParser`, then a test. UI chips render automatically from the existing chip strip — see `includeChips()`.

**Add a new HTML parser.** Put it in `Networking/HTMLParsers/`. Take a `String` of HTML, parse with SwiftSoup, return a Sendable struct. Add fixture-based tests in `FanficlyTests/`.

**Add a new SwiftData model.** Define the `@Model` in `Models/Work.swift`. Add it to `FanficlyApp.sharedModelContainer`'s `Schema`. SwiftData will migrate automatically across additive schema changes; destructive changes need a versioned migration plan.

**Run the app on a different device.** Replace `iPhone 17` in the build/run commands with whatever is available. CI auto-picks — see `.github/workflows/ci.yml`.

## Things to know about AO3

- No JSON API. We are a respectful guest of `archiveofourown.org`. The `User-Agent` identifies the app and links to the repo so AO3 ops can find us.
- Explicit-rated works show an age-gate page unless the request includes `view_adult=true` (we set this).
- `?view_full_work=true` inlines all chapters on a single page.
- Login is form-based. GET `/users/login` → scrape the `authenticity_token` (either `<meta name="csrf-token">` or `<input name="authenticity_token">`), then POST with cookies. Session cookie is kept in `HTTPCookieStorage.shared` and automatically serialized & persisted to/from the secure iOS Keychain via `CredentialStore` to prevent logouts when the app is terminated or restarted.
- The structured `dl.work.meta.group` on a work page contains the canonical tags. Chapters are wrapped in `div.chapter[id^=chapter-]` — use that exact selector to avoid matching the nested `.preface` divs.
- Work subscription is a POST to `/works/<id>/subscriptions` with `subscription[subscribable_type]=Work` + token. Requires login.
- Browse-by-fandom hits `/media/<category>/fandoms`; category names are path-encoded with AO3's scheme (`&`→`*a*`, `/`→`*s*`, `.`→`*d*`, etc. — see `AO3Endpoints.ao3PathEncode`).
- Tag autocomplete: `/autocomplete/{relationship,character,freeform,fandom}?term=…` returns JSON `[{id,name}]`. Used to resolve user-typed filter tags to canonical names before searching. **Two gotchas, both must hold or you get a 404 and tags silently don't resolve:** (1) the request must send `Accept: application/json` — the shared session defaults to `Accept: text/html`, and AO3's Rails content-negotiation 404s the JSON-only route on an HTML Accept; (2) the `term` must be percent-encoded including `/` (→`%2F`), because `URLComponents` leaves a raw slash in query values and AO3 404s on it. A ship like `Hermione/Draco` hits both.
- Rating is **single-select** on `/works/search` (`work_search[rating_ids]`, a `<select>`). Sending the array form `rating_ids[]` AND-matches and returns nothing for 2+ ratings (a work has exactly one rating). So `AO3SearchFilters` emits the scalar field for one rating and OR-s multiple via the query field: `(rating_ids:12 OR rating_ids:13)`. Warnings/categories legitimately stay arrays (a work can have several).
- Multi-format export: `/downloads/<id>/work.<ext>` where ext ∈ {azw3, epub, mobi, pdf, html}. `WorkExportButton` downloads to a temp file and presents `ShareSheet` (UIActivityViewController).
- Reading position: stored per-work in `ReadingProgress` (ao3Id, chapterIndex, paragraphIndex). The reader renders each chapter as paragraphs (`ChapterContentView`) tagged `c<chapter>-p<index>`, tracks the topmost one via `ScrollAnchorKey`, and restores by scrolling to the chapter then the paragraph.
- **Text-to-speech ("Listen") is 100% on-device** — `SpeechController` wraps `AVSpeechSynthesizer` (no model bundle, no network, so the privacy posture holds). It speaks `HTMLToAttributed.speechParagraphs(...)` one chapter at a time, enqueuing every paragraph up front for gapless playback and mapping each utterance back to its index via `ObjectIdentifier` to drive the mini-player and detect chapter end. `speechParagraphs` is **index-aligned with the rendered paragraphs** (scene breaks become empty, unspoken slots that are skipped) so the reader can **karaoke-highlight** the spoken paragraph (`ChapterContentView.highlightParagraph`) and auto-scroll it into view (`scrollToSpokenParagraph`, plus the paginated page's own `onChange`). On finish it bumps `finishedTick`; `ReaderView` observes that and auto-advances to the next chapter (a signal, not a stored closure, to avoid a retain cycle with the view). `currentParagraph` is the rendered index (for the highlight); `spokenPosition`/`spokenCount` drive the "¶ x / y" readout. Voice + speaking rate live in Reader settings (`reader.ttsVoiceId`/`reader.ttsRate`); voice id `""` means the platform default. Background/lock-screen playback needs the `audio` `UIBackgroundMode` (in `project.yml`) plus an `AVAudioSession` `.playback`/`.spokenAudio` session and `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` wiring — all in `SpeechController`. Synth-delegate and remote-command callbacks arrive off the main actor, so they capture only Sendable values (`ObjectIdentifier`) and hop via `Task { @MainActor in }`.
- **"More by this author"** — `AO3WorkSummary.authorUsername` (parsed from the byline `/users/<login>` href by `SearchResultsParser.authorLogin`) makes the reader byline a `NavigationLink(value: AuthorRef)`. `AuthorWorksView` lists that author's works via `AO3Client.fetchAuthorWorks` (the works page reuses the search blurb parser). Every navigation stack applies the shared `.workAndAuthorDestinations()` modifier so both `AO3WorkSummary`→reader and `AuthorRef`→author works resolve everywhere.
- The search field is a vertical-axis `TextField`, so Return inserts a newline rather than firing `.onSubmit`. SearchView watches `onChange` for a `\n` and triggers the search itself.
- Top-level tab views (Search, Library) use an **inline** nav title — a large title pops in awkwardly because those screens have a custom header VStack, not a scroll view for the title to anchor against.
- AO3 may return 429 if we hit it too fast. The throttle should prevent this but handle the case anyway.
- **The reader uses the plain system nav bar — no auto-hide.** We tried scroll-to-hide chrome twice (parent-driven `.toolbar(.hidden)`, then a fully custom floating toolbar) and both were unreliable/ugly, so the reader just keeps the standard `.toolbar` items: `ReaderView` provides the chapters + typography (Aa) menus; the parent (`WorkDetailView` / `SavedWorkReader`) adds follow/export/save via its own `.toolbar`. The bar is painted with the reader's `background` (`.toolbarBackground(bg, .visible)`) and themed with `.toolbarColorScheme` — never `.preferredColorScheme`, which propagates to the whole window and flips the app light↔dark when you leave a light reader. The chapter indicator bar (continuous mode) uses `bg`, not `.ultraThinMaterial`, so nothing reads as system gray. If you reattempt auto-hide, do NOT reintroduce a custom chrome — the consensus was to leave it.

## Local follow vs. AO3 subscribe

Two distinct concepts — don't conflate them:
- **Follow** (bookmark icon) is local-only, no login. `WorkPersistence.toggleFollow` saves the work's metadata to SwiftData with `isFollowed = true`. The background poller checks followed works for new chapters and fires a local notification — works fully logged out.
- **Subscribe** (bell, in the … menu) POSTs to AO3 and requires login. It mirrors into AO3's own subscription list.
Both feed `SubscriptionPoller`; `username` is optional so the poller runs for follows even with no account.

## Custom URL Scheme & Share Extension

- **Deep Link Handling**: The main app registers the custom scheme `fanficly` in `project.yml`. Any URL matching `fanficly://import?url=<url>` is caught by `RootView.swift`'s `.onOpenURL` handler, which triggers the `ImportOverlay` view to fetch the work metadata and chapters, download the EPUB for offline storage, and launch the reader sheet (`SavedWorkReader`).
- **Share Extension**: The `FanficlyShare` target is a Safari Share Extension. When activated on a Safari URL, it loads the URL attachment, encodes it, opens `fanficly://import?url=<encodedURL>`, and completes the extension request.


## Screenshots

`bin/take-screenshots.sh` is the interactive capture (manual navigation). `FanficlyUITests/ScreenshotTests` is the automated version — it drives the app **in `-demoMode`** and writes PNGs to `docs/screenshots/{iphone,ipad}/` (idiom subfolder; path derived from `#filePath`; the simulator runs as the host user so it can write there). Run it with `-only-testing:FanficlyUITests/ScreenshotTests/testCaptureMainScreens`. Demo mode is fully offline so the shots are deterministic. One iPad gotcha: re-selecting a sidebar item in `NavigationSplitView` doesn't pop the detail stack, so the Privacy capture pops back one level via the nav-bar back button instead. CI never runs UI tests (`-only-testing:FanficlyTests`).

**App Store marketing screenshots** are framed by `bin/frame-screenshots.py` (run by the `fastlane screenshots` lane after capture). It frames each raw shot in a genuine Apple device bezel via `fastlane frameit`, then composites it onto the solid violet brand canvas (`#6D28D9`) with a bold two-line ASO headline, writing exact-size PNGs to `fastlane/screenshots/en-US/` (iPhone 6.9" `1320×2868`, iPad 13" `2064×2752` — iPad is framed at frameit's supported 12.9" `2048×2732` then composited onto the 13" canvas). Headlines/order live in the `SLIDES` list at the top of the script. Requires `brew install fastlane imagemagick`. `fastlane/screenshots/` is git-ignored (regenerate via the lane).

## Privacy posture (do not regress)

The app stores **nothing** off-device. Don't add analytics, crash reporting, or remote logging. The only persisted secret is AO3's own session cookie (in iOS Keychain). See `PRIVACY.md` and `PrivacyInfo.xcprivacy`.
