# CLAUDE.md — working in the Fanficly repo

Short notes for Claude Code sessions and other agents.

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
    BrowseView.swift           # category → live fandom list → works
  Reader/
    ReaderView.swift           # continuous + paginated modes, chapter header,
                               #   floating chapter indicator, typography menu
    HTMLText.swift             # async cached HTML → AttributedString
    HTMLToAttributed.swift     # SwiftSoup → AttributedString (fast, themeable)
    WorkHeaderMetadata.swift   # rating/warnings/tags/stats chips
    ChapterTracking.swift      # PreferenceKey for current-chapter detection
    ReaderTheme.swift          # theme/font family/size/width/mode, @AppStorage
  Library/
    LibraryView.swift          # All/Following/Downloaded filter
    WorkPersistence.swift      # upsert, upsertMetadata, toggleFollow
  Auth/                        # AuthState (Keychain) + LoginView
  Subscriptions/               # poller (AO3 subs + local follows), BG task
  Settings/                    # SettingsView + ReaderSettingsView + privacy
  DesignSystem/                # Typography, Spacing, FlowLayout, SafariView
  PrivacyInfo.xcprivacy        # zero collection, zero tracking
FanficlyTests/                 # XCTest — parsers, prompt parser, HTML render
FanficlyUITests/               # smoke test + ScreenshotTests (README shots)
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
- Login is form-based. GET `/users/login` → scrape the `authenticity_token` (either `<meta name="csrf-token">` or `<input name="authenticity_token">`), then POST with cookies. Session cookie persists in `HTTPCookieStorage.shared`.
- The structured `dl.work.meta.group` on a work page contains the canonical tags. Chapters are wrapped in `div.chapter[id^=chapter-]` — use that exact selector to avoid matching the nested `.preface` divs.
- Kudos is a POST to `/kudos.js` with `kudo[commentable_type]=Work` and the authenticity_token (both in body and `X-CSRF-Token` header). 422 means "already kudo'd by you" — treat as success.
- Work subscription is a POST to `/works/<id>/subscriptions` with `subscription[subscribable_type]=Work` + token. Requires login.
- Browse-by-fandom hits `/media/<category>/fandoms`; category names are path-encoded with AO3's scheme (`&`→`*a*`, `/`→`*s*`, `.`→`*d*`, etc. — see `AO3Endpoints.ao3PathEncode`).
- The search field is a vertical-axis `TextField`, so Return inserts a newline rather than firing `.onSubmit`. SearchView watches `onChange` for a `\n` and triggers the search itself.
- AO3 may return 429 if we hit it too fast. The throttle should prevent this but handle the case anyway.

## Local follow vs. AO3 subscribe

Two distinct concepts — don't conflate them:
- **Follow** (bookmark icon) is local-only, no login. `WorkPersistence.toggleFollow` saves the work's metadata to SwiftData with `isFollowed = true`. The background poller checks followed works for new chapters and fires a local notification — works fully logged out.
- **Subscribe** (bell, in the … menu) POSTs to AO3 and requires login. It mirrors into AO3's own subscription list.
Both feed `SubscriptionPoller`; `username` is optional so the poller runs for follows even with no account.

## Screenshots

`bin/take-screenshots.sh` is the interactive capture (manual navigation). `FanficlyUITests/ScreenshotTests` is the automated version — it drives the app and writes PNGs to `docs/screenshots/` (path derived from `#filePath`; the simulator runs as the host user so it can write there). Run it with `-only-testing:FanficlyUITests/ScreenshotTests/testCaptureMainScreens`. Network-dependent shots (search results, reader) are flaky under automation because AO3 rate-limits fresh sim sessions; capture those manually if needed. CI never runs UI tests (`-only-testing:FanficlyTests`).

## Privacy posture (do not regress)

The app stores **nothing** off-device. Don't add analytics, crash reporting, or remote logging. The only persisted secret is AO3's own session cookie (in iOS Keychain). See `PRIVACY.md` and `PrivacyInfo.xcprivacy`.
