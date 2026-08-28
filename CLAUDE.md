# AGENTS.md — working in the Fanficly repo

Short notes for Codex sessions and other agents.

## What this is

A SwiftUI app (iPhone + iPad, plus Mac via Catalyst; iOS 17+, Swift 6) that reads AO3 fanfiction. There is no AO3 JSON API, so the app talks to AO3 by scraping HTML with SwiftSoup, using one shared `URLSession` with a custom `User-Agent` and a 1 req/sec throttle. Everything runs on-device — no servers, no analytics.

## Layout

```
project.yml                    # xcodegen is the source of truth
bin/                           # developer scripts (icon gen, screenshots)
Fanficly/
  FanficlyApp.swift            # @main, env wiring, ModelContainer, BG task
  RootView.swift               # NavigationSplitView sidebar (Search, Browse,
                               #   Popular, Library, Stats, Recently Viewed,
                               #   Authors, Bookmarks, Subscriptions, Settings);
                               #   global ⌘
                               #   zoom (app.zoomScale); fanficly:// deep links
                               #   (import overlay + widget resume route)
  AO3ClientEnvironment.swift   # @Environment(\.ao3Client) key
  WidgetProgressStore.swift    # last-read progress for the widget: app-group
                               #   defaults + iCloud KVS mirror (debounced);
                               #   compiled into both app and widget targets
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
    SearchView.swift           # smart-search UI; results (WorkRow has an inline
                               #   bookmark/save button); saved searches;
                               #   WorkDetailView (reader + toolbar actions);
                               #   CommentsView (view/post chapter comments)
    AuthorWorksView.swift      # one author's works; Follow button +
                               #   FollowedAuthorsView (the Authors tab)
    SearchPromptParser.swift   # rules-based prompt → AO3SearchFilters
    AO3SearchFilters.swift     # 1:1 mapping of AO3's /works/search fields
    KnownTags.swift            # curated freeform + fandom dictionaries
    FoundationModelsEnricher.swift   # iOS 26+ on-device LLM fallback (no-op elsewhere)
  Browse/
    FandomCategories.swift     # 10 AO3 media categories + curated seed lists;
                               #   PopularTags (curated popular fandoms/ships/chars,
                               #   used as the Popular tab's offline fallback)
    BrowseView.swift           # category → live fandom list → filtered works;
                               #   landing page also lists saved filters.
                               #   FandomWorksView is drivable by filters+title
                               #   (fandom OR a saved filter), not just a fandom.
                               #   PopularView (the Popular tab) lives here too.
  Search/
    WorkFilterSheet.swift      # AO3-style filter panel editing AO3SearchFilters
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
    SavedWorkReader.swift      # offline if downloaded, else fetch on demand
    WorkPersistence.swift      # upsert, upsertMetadata, toggleFollow;
                               #   isAuthorFollowed / toggleFollowAuthor
    iCloudSyncManager.swift    # backup/restore SwiftData library to iCloud;
                               #   backups UNION with the existing cloud file
                               #   (mergedBackup) — never last-writer-wins
  Auth/                        # AuthState (Keychain) + LoginView
  Subscriptions/               # poller (AO3 subs + local work/author follows),
                               #   BG task; SubscriptionsView + BookmarksView
                               #   (the Bookmarks tab — your AO3 bookmarks)
  Settings/                    # SettingsView + ReaderSettingsView + privacy
  DesignSystem/                # Typography, Spacing, FlowLayout, SafariView, ShareSheet
  PrivacyInfo.xcprivacy        # zero collection, zero tracking
FanficlyTests/                 # ~240 XCTest cases — parsers, filters, endpoints,
                               #   HTML render, tracking, in-memory persistence
FanficlyUITests/               # smoke test + ScreenshotTests (README shots)
FanficlyShare/                 # Safari share extension target
  ShareViewController.swift    # intercepts browser URLs & redirects to main app
  Info.plist                   # share service configurations
FanficlyWidget/                # WidgetKit extension target (embedded in app)
  FanficlyWidget.swift         # last-read story widget (systemSmall/Medium):
                               #   title, author, progress bar; tap deep-links
                               #   fanficly://resume/<id>?chapter=&paragraph=
  FanficlyWidget.entitlements  # app group + iCloud KVS
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

~240 unit tests (`FanficlyTests`), all pure/fixture-based (no network):
- **Parsers** — `SearchResultsParserTests` (incl. the bookmarks page: `li.bookmark.blurb`, work id from the `/works/<id>` link, skipping series/external bookmarks), `WorkPageParserTests` (+ `LoginParserTests`, `CommentsParserTests` — threaded comment depth, guest comments, comment-form pseud id), `SubscriptionsParserTests`, `MediaCategoryParserTests`, `WorkMetadataParserTests`. Each feeds inline HTML fixtures and asserts the typed output.
- **Search** — `SearchPromptParserTests` (ships, characters, ratings, warnings, categories, freeforms incl. romance, fandoms, word count, status, engagement, language, exclusions), `AO3SearchFiltersTests` (every `work_search[*]` field mapping, NOT-exclusion composition, Codable round-trip for saved filters), `TagResolverTests` (canonical resolution, ship slash variants, character-fallback ship resolution via `StubAO3Client`), `PromptTextTests` (chip-removal → search-box text), `FandomCatalogTests` (fandom → category icon).
- **Endpoints** — `AO3EndpointsTests` (URLs, pagination, AO3 media path-encoding).
- **Reader** — `HTMLToAttributedTests` (formatting, paragraph collapsing, lists/headings/hr, transparent conversion caching), `ChapterTrackingTests` (anchor key/parse, topmost-anchor, current-chapter).
- **Persistence** — `PersistenceTests` spins up an in-memory `ModelContainer` to exercise `WorkPersistence` (upsert/metadata/follow, plus author follow: `isAuthorFollowed`/`toggleFollowAuthor` with seeded work ids, empty-username guard) and `ReadingProgressStore` (save/load round-trips), plus `ReaderProfile` merging (incl. deletion tombstones), per-device key migration, the iCloud backup/restore merge rules (two simulated devices via `overrideBackupURL`), and poller-level subscription-sync behavior.
- **Misc** — `ThrottleActorTests` (1 req/sec throttle timing + a concurrency test asserting N simultaneous waiters are serialized, never bursted). `ResumeProgressPolicyTests` (widget resume never rewinds saved progress). `StubAO3Client` is a scriptable `AO3ClientProtocol` test double for resolution logic.

When you add a feature, add its tests here. Make a private helper `internal` if it needs direct testing (see `TagResolver.candidates/bestMatch`).

The CoreData "Sandbox access to file-write-create denied" noise during test runs is harmless — it comes from SwiftUI booting the SwiftData container in the test host. Filter it out with `| grep -v CoreData:`.

## Conventions

- **AO3Client is the only seam to the network.** UI views never touch `URLSession`. Anything that needs data uses `@Environment(\.ao3Client)`. There's a `MockAO3Client` for previews and tests.
- **Throttle.** Always go through `AO3Client` — never bypass the throttle. AO3 is generous to good citizens, hostile to bad ones.
- **Parsers are pure.** `SearchResultsParser` (also drives the bookmarks page via a `blurbSelector` param), `WorkPageParser`, `CommentsParser` (in `WorkPageParser.swift`), `LoginParser`, `SubscriptionsParser`, `WorkMetadataParser` take HTML strings and return typed values. Test them with inline HTML fixtures.
- **SwiftData models** live in `Models/Work.swift`. The model container is constructed once in `FanficlyApp` and shared with `BackgroundRefresh`.
- **Settings come from `@AppStorage`**, not custom UserDefaults wrappers. Reader typography keys are per-device — always go through `ReaderProfile.deviceKey(_:)` (suffixes `.phone`/`.pad`/`.mac`).
- **No third-party dependencies beyond SwiftSoup and KeychainAccess.** Don't add analytics, crash reporters, or any SDK with a network side-channel — privacy posture is the headline feature.
- **Never present sheets/alerts from `Menu` content.** Menu content is torn down when the menu dismisses, so a `.sheet`/`.alert` attached to a view *inside* a menu has no live anchor by the time async work finishes and silently never presents (VoiceOver users hit it every time — slower dismissal). Own the state in the screen view and attach the presentation there; `WorkExporter` + `.workExportPresentation(_:)` (in `WorkExportButton.swift`) is the pattern.
- **VoiceOver is a supported input.** Icon-only buttons/menus get `.accessibilityLabel`; multi-`Text` rows get `.accessibilityElement(children: .combine)` (but never combine a container holding tappable `Link`s/buttons — it hides them); decorative SF Symbols next to text get `.accessibilityHidden(true)`; invisible gestures (the reader's tap-to-turn zones, chrome-toggle tap) need `.accessibilityAction(named:)` equivalents — the reader's live in `ReaderView` (`accessibilityTurnPage`/`accessibilityTurnChapter`/`toggleChromeAccessibly`, which also posts announcements). Long-running silent transitions (export download, search, import) post `UIAccessibility.announcement`.

## Common tasks

**Add a new search filter.** Add the field on `AO3SearchFilters` + a row to its `queryItems()`, then add an extractor to `SearchPromptParser`, then a test. UI chips render automatically from the existing chip strip — see `includeChips()`.

**Add a new HTML parser.** Put it in `Networking/HTMLParsers/`. Take a `String` of HTML, parse with SwiftSoup, return a Sendable struct. Add fixture-based tests in `FanficlyTests/`.

**Add a new SwiftData model.** Define the `@Model` in `Models/Work.swift`. Add it to `FanficlyApp.sharedModelContainer`'s `Schema` (and the in-memory `Schema` in `PersistenceTests`). SwiftData will migrate automatically across additive schema changes; destructive changes need a versioned migration plan. `FollowedAuthor` is a recent example.

**Add a new sidebar tab.** Add a case to `SidebarItem` (in `RootView.swift`) — order in the enum drives the sidebar order — give it a `title` + `systemImage`, add it to the `switch selectedDetailItem` in `mainSplitView`, and add a `Button`/`keyboardShortcut` to the "Go" `CommandMenu` in `FanficlyApp.swift` (renumber ⌘N to match). Recent examples: `popular`, `authors`, `bookmarks`. `xcodegen` isn't always available; prefer adding the tab's view to an existing file (e.g. `PopularView` in `BrowseView.swift`, `BookmarksView` in `SubscriptionsView.swift`, `FollowedAuthorsView` in `AuthorWorksView.swift`) over a new file, so the committed `.xcodeproj` doesn't need regenerating.

**Run the app on a different device.** Replace `iPhone 17` in the build/run commands with whatever is available. CI auto-picks — see `.github/workflows/ci.yml`.

## Things to know about AO3

- No JSON API. We are a respectful guest of `archiveofourown.org`. The `User-Agent` identifies the app and links to the repo so AO3 ops can find us.
- Explicit-rated works show an age-gate page unless the request includes `view_adult=true` (we set this).
- `?view_full_work=true` inlines all chapters on a single page.
- Login is form-based. GET `/users/login` → scrape the `authenticity_token` (either `<meta name="csrf-token">` or `<input name="authenticity_token">`), then POST with cookies. Session cookie is kept in `HTTPCookieStorage.shared` and automatically serialized & persisted to/from the secure iOS Keychain via `CredentialStore` to prevent logouts when the app is terminated or restarted.
- The structured `dl.work.meta.group` on a work page contains the canonical tags. Chapters are wrapped in `div.chapter[id^=chapter-]` — use that exact selector to avoid matching the nested `.preface` divs.
- Work subscription is a POST to `/works/<id>/subscriptions` with `subscription[subscribable_type]=Work` + token. Requires login.
- **Subscription sync fails closed.** With an expired cookie AO3 302s the subscriptions page to the login form and URLSession follows it, so the client sees a 200 of login HTML. `SubscriptionsParser` throws `AO3Error.unauthorized` when the page contains a login form and `parseFailed` when it has neither a subscription list nor the index shell — and `syncSubscriptionList` skips its delete pass on any empty fetch, so markup drift or a stale session can never mass-delete `SubscriptionRecord`s (and their `lastSeenChapterCount` baselines). `fetchSubscriptions` walks every page of `/users/<name>/subscriptions` (50-page ceiling); any page failing throws the whole call so a partial list can't reach the delete pass.
- **Bookmarks** — `/users/<name>/bookmarks` (paginated) lists works in `li.bookmark.blurb` (vs. `li.work.blurb` on search), so `AO3Client.fetchBookmarks` reuses `SearchResultsParser.parse(html:blurbSelector:)`. The `<li>` id is `bookmark_<id>`, not `work_<id>`, so `parseBlurb` falls back to the `/works/<id>` title link for the work id (`SearchResultsParser.workId(fromHref:)`); series/external/deleted bookmarks have no such link and are skipped. The `BookmarksView` tab is login-gated (private bookmarks need the session cookie) and live-fetched with infinite scroll.
- **Comments** — fetched by loading the work page with `?show_comments=true` (`AO3Endpoints.workComments`) and parsing the thread with `CommentsParser` (commenter, date, `blockquote.userstuff` body, and reply depth from ancestor `li.comment` nesting). Posting is a POST to `/works/<id>/comments` (`workCommentsPost`) with `comment[comment_content]`, the scraped `authenticity_token`, and `comment[pseud_id]` (read from the live comment form via `CommentsParser.defaultPseudId`) — same CSRF flow as login/subscribe. Requires login. `CommentsView` (reader … menu) shows the thread and a composer; AO3 may hold new comments for moderation, so it re-fetches after posting. v1 is work-level (first page); per-chapter comment association on multi-chapter works is a known follow-up.
- Browse-by-fandom hits `/media/<category>/fandoms`; category names are path-encoded with AO3's scheme (`&`→`*a*`, `/`→`*s*`, `.`→`*d*`, etc. — see `AO3Endpoints.ao3PathEncode`).
- Tag autocomplete: `/autocomplete/{relationship,character,freeform,fandom}?term=…` returns JSON `[{id,name}]`. Used to resolve user-typed filter tags to canonical names before searching. **Two gotchas, both must hold or you get a 404 and tags silently don't resolve:** (1) the request must send `Accept: application/json` — the shared session defaults to `Accept: text/html`, and AO3's Rails content-negotiation 404s the JSON-only route on an HTML Accept; (2) the `term` must be percent-encoded including `/` (→`%2F`), because `URLComponents` leaves a raw slash in query values and AO3 404s on it. A ship like `Hermione/Draco` hits both.
- **Tag resolution is conservative for freeforms.** AO3 ranks autocomplete by popularity, so `TagResolver` routes freeforms through `bestFreeformMatch`, which only accepts a suggestion that is the *same tag* up to case/spacing/punctuation (fixing casing, `hurt comfort` → `Hurt/Comfort`) — otherwise it keeps exactly what the user typed, so `caveman` can't silently become `Caveman Derek Hale`. And **failed lookups are never cached**: only authoritative answers (including genuine no-matches) are memoized in the process-lifetime cache; a 429/offline error falls back for that one search and retries next time.
- Rating is **single-select** on `/works/search` (`work_search[rating_ids]`, a `<select>`). Sending the array form `rating_ids[]` AND-matches and returns nothing for 2+ ratings (a work has exactly one rating). So `AO3SearchFilters` emits the scalar field for one rating and OR-s multiple via the query field: `(rating_ids:12 OR rating_ids:13)`. Warnings/categories legitimately stay arrays (a work can have several).
- Multi-format export: `/downloads/<id>/work.<ext>` where ext ∈ {azw3, epub, mobi, pdf, html}. `WorkExportButton` downloads to a temp file and presents `ShareSheet` (UIActivityViewController).
- Reading position: stored per-work in `ReadingProgress` (ao3Id, chapterIndex, paragraphIndex). The reader renders each chapter as paragraphs (`ChapterContentView`) tagged `c<chapter>-p<index>`, tracks the topmost one via `ScrollAnchorKey`, and restores by scrolling to the chapter then the paragraph. Anchors are sampled every `anchorStride` paragraphs **plus always the final paragraph** (`isAnchorIndex`), and all three reading modes detect end-of-content explicitly (`ChapterTracking.endOfContentAnchor`, checked before the sample throttle) so a work read to the last line reaches exactly 1.0 and earns the Finished badge — the topmost-anchor path alone tops out around 0.8.
- **Opt-in story images** — "Show images in stories" (Settings → Reader, default **off** = historical text-only rendering). When on, embedded `<img>` tags render as fixed-height (240pt) `ReaderInlineImage` slots in all three reading modes. Image slots occupy real paragraph indices so anchors, TTS karaoke (unspoken, like scene breaks), progress, and pagination stay aligned; the fixed height keeps loading layout-neutral so a slow host can't displace a restored position. URL policy: https only (http upgraded, protocol-relative resolved); `data:`/`javascript:`/root-relative/AO3-host sources rejected — image loads bypass the throttle + User-Agent and would carry the session cookie. Known trade-off (documented in code): toggling shifts paragraph indices, so a saved position drifts by the number of images above it. Downloaded works stay text-only offline.
- **Text-to-speech ("Listen") is 100% on-device** — `SpeechController` wraps `AVSpeechSynthesizer` (no model bundle, no network, so the privacy posture holds). It speaks `HTMLToAttributed.speechParagraphs(...)` one chapter at a time, enqueuing every paragraph up front for gapless playback and mapping each utterance back to its index via `ObjectIdentifier` to drive the mini-player and detect chapter end. `speechParagraphs` is **index-aligned with the rendered paragraphs** (scene breaks become empty, unspoken slots that are skipped) so the reader can **karaoke-highlight** the spoken paragraph (`ChapterContentView.highlightParagraph`) and auto-scroll it into view (`scrollToSpokenParagraph`, plus the paginated page's own `onChange`). On finish it bumps `finishedTick`; `ReaderView` observes that and auto-advances to the next chapter (a signal, not a stored closure, to avoid a retain cycle with the view). `currentParagraph` is the rendered index (for the highlight); `spokenPosition`/`spokenCount` drive the "¶ x / y" readout. On multi-chapter works the narration bar's chapter label is a `Menu`+`Picker` (`chapterNarrationBinding`) that jumps narration to any chapter via `narrate(toChapter:)`, resyncing the visible page; `startNarration` now picks up from `currentAnchor` (chapter + paragraph) across all reading modes. Voice + speaking rate live in Reader settings (`reader.ttsVoiceId`/`reader.ttsRate`); voice id `""` means the platform default. Background/lock-screen playback needs the `audio` `UIBackgroundMode` (in `project.yml`) plus an `AVAudioSession` `.playback`/`.spokenAudio` session and `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` wiring — all in `SpeechController`. Synth-delegate and remote-command callbacks arrive off the main actor, so they capture only Sendable values (`ObjectIdentifier`) and hop via `Task { @MainActor in }`.
- **"More by this author"** — `AO3WorkSummary.authorUsername` (parsed from the byline `/users/<login>` href by `SearchResultsParser.authorLogin`) makes the reader byline a `NavigationLink(value: AuthorRef)`. `AuthorWorksView` lists that author's works via `AO3Client.fetchAuthorWorks` (the works page reuses the search blurb parser). Every navigation stack applies the shared `.workAndAuthorDestinations()` modifier so both `AO3WorkSummary`→reader and `AuthorRef`→author works resolve everywhere.
- **Following authors** (the Authors tab) is local-only, like work follows — see "Local follow vs. AO3 subscribe" below. `AuthorWorksView` has a Follow button; `FollowedAuthorsView` lists followed authors. The poller checks each for newly-published works.
- **Popular tab** — AO3 has no popular/trending endpoint, so popularity is derived from AO3's cumulative work counts: `AO3Client.fetchPopularSnapshot()` ranks **fandoms** by the `/media/<cat>/fandoms` counts (`MediaCategoryParser` now also reads the trailing `(count)`) and aggregates **ships/characters** from the works-filter facet sidebar of the top few fandoms (`WorkFiltersParser` over `/tags/<tag>/works`, `AO3Endpoints.tagWorks`). Live facet markup: include-checkbox ids are `include_work_search_<kind>_ids_<tagid>` and the name+count share one plain span (`Ship Name (57746)`), so the selector is `label[for^=include_][for*=_<kind>_ids_]` (anchoring on `include_` matters — the Exclude half repeats every tag) with the count parsed from the trailing `(N)` via `MediaCategoryParser.trailingCount`. `PopularStore` caches the `PopularSnapshot` in `UserDefaults` and refreshes at most once/day in the background; `PopularView` shows the cached/live lists immediately and **falls back to the curated `PopularTags` seed** whenever a list is empty (offline / markup drift), so the tab is never blank. Tapping a tag opens `FandomWorksView(popular:)`, which maps it to fandom/relationship/character `AO3SearchFilters` sorted by kudos. Names (live or curated) must stay in AO3's exact canonical form or the tag won't resolve. NB: counts are cumulative, not daily/trending — AO3 exposes no trend feed.
- The search field is a vertical-axis `TextField`, so Return inserts a newline rather than firing `.onSubmit`. SearchView watches `onChange` for a `\n` and triggers the search itself.
- `SearchPromptParser` matches regexes on a lowercased buffer but extracts title/creator text from the original-case buffer with the same NSRanges — so the lowercase fold must be **length-preserving** (Turkish `İ` lowercases to two UTF-16 units and desynced them; `İstanbul by:melis` used to crash with `NSRangeException`). Don't replace the custom fold with a plain `.lowercased()`.
- Top-level tab views (Search, Library) use an **inline** nav title — a large title pops in awkwardly because those screens have a custom header VStack, not a scroll view for the title to anchor against.
- AO3 may return 429 if we hit it too fast. The throttle should prevent this but handle the case anyway: `performRequest` retries transient failures (URLSession timeouts/dropped connections, 429 within a short `Retry-After`) with exponential backoff — **idempotent GETs only**, never POSTs (login/comment/subscribe must not double-submit), and never while offline. `ThrottleActor.wait()` reserves each caller's slot atomically *before* suspending (actor methods run synchronously up to the first await), so concurrent callers get strictly-spaced instants — a burst of simultaneous requests was what tripped AO3's tarpit and surfaced as 30s "network timeout" errors on list screens.
- **The reader uses the plain system nav bar — no auto-hide.** We tried scroll-to-hide chrome twice (parent-driven `.toolbar(.hidden)`, then a fully custom floating toolbar) and both were unreliable/ugly, so the reader just keeps the standard `.toolbar` items: `ReaderView` provides the chapters + typography (Aa) + minimize items; the parent adds export plus either a save button (`SavedWorkReader`) or a single options menu (`WorkDetailView`: comments / save-to-library / download / report / hide). Keep the parent to ≤2 items — the iPhone portrait nav bar fits ~5 trailing icons before the system spills the rest into its own "…" overflow, which reads as a confusing second ellipsis next to the `ellipsis.circle` menu. The bar is painted with the reader's `background` (`.toolbarBackground(bg, .visible)`) and themed with `.toolbarColorScheme` — never `.preferredColorScheme`, which propagates to the whole window and flips the app light↔dark when you leave a light reader. The chapter indicator bar (continuous mode) uses `bg`, not `.ultraThinMaterial`, so nothing reads as system gray. If you reattempt auto-hide, do NOT reintroduce a custom chrome — the consensus was to leave it.
- **The reader body ignores the keyboard safe area** (`.ignoresSafeArea(.keyboard, edges: .bottom)` on `ReaderView`'s root). The page text is `.focusable()`/`.focused()` for hardware arrow-key turns (`ReaderKeyPressModifier`); without this, returning from the background can restore focus and leave iOS holding a phantom keyboard inset, collapsing the page into a blank band (~keyboard height) at the bottom. The reader has no text input, so ignoring the keyboard inset is always safe.
- **Reader story text is not selectable** — there's intentionally no `.textSelection(.enabled)` on the paragraph `Text`s (continuous/paginated `ChapterContentView` and page-by-page `ReaderPageCell`), so press-and-hold never shows a "Copy" callout. Don't re-add it.

## Local follow vs. AO3 subscribe

Two distinct concepts — don't conflate them:
- **Follow** (bookmark icon) is local-only, no login. `WorkPersistence.toggleFollow` saves the work's metadata to SwiftData with `isFollowed = true`. A bookmark button also rides on each search/browse `WorkRow` for one-tap save without opening the work. The background poller checks followed works for new chapters and fires a local notification — works fully logged out.
- **Follow author** (the Authors tab) is also local-only. `WorkPersistence.toggleFollowAuthor` stores a `FollowedAuthor` (username, displayName, `knownWorkIds` seeded at follow time so the first poll doesn't alert for the back catalogue). `SubscriptionPoller.checkFollowedAuthors()` fetches each author's works page and notifies on newly-published works.
- **Subscribe** (bell, in the … menu) POSTs to AO3 and requires login. It mirrors into AO3's own subscription list.
All feed `SubscriptionPoller`; `username` is optional so the poller runs for follows even with no account. `runFullPoll` builds **one queue of all three record kinds sorted oldest-check-first** (`Work.lastCheckedAt`, additive schema field), saves after each record, and breaks on task cancellation — so a ~30s `BGAppRefreshTask` that gets cut off resumes exactly where it stopped next run and author follows can't starve behind long sub lists. Attempt time is stamped up front (success or failure) so a deleted work can't hog the queue head. The per-category functions (`checkForNewChapters`/`checkFollowedWorks`/`checkFollowedAuthors`) remain for the Subscriptions tab's manual refresh. Notification permission is requested at the moment of follow (`NotificationsAuthorization.requestAfterFollow()`, fired by `toggleFollow`/`toggleFollowAuthor`, login not required — no-op in demo/unit-test runs), not just from the login-gated Subscriptions view.

## Custom URL Scheme & Share Extension

- **Deep Link Handling**: The main app registers the custom scheme `fanficly` in `project.yml`. Any URL matching `fanficly://import?url=<url>` is caught by `RootView.swift`'s `.onOpenURL` handler, which triggers the `ImportOverlay` view to fetch the work metadata and chapters, download the EPUB for offline storage, and launch the reader sheet (`SavedWorkReader`).
- **Share Extension**: The `FanficlyShare` target is a Safari Share Extension. When activated on a Safari URL, it loads the URL attachment, encodes it, opens `fanficly://import?url=<encodedURL>`, and completes the extension request.
- **Widget resume route**: `fanficly://resume/<workId>?chapter=<n>&paragraph=<m>` — opened when the user taps the widget. `RootView.parseResumeRoute` parses it; the handler decides what (if anything) to install via the pure `ResumeProgressPolicy.anchorToInstall` (in `RootView.swift`), switches the sidebar to Library, and pushes `SavedWorkReader` (or `WorkDetailView` if the work isn't saved) via a `ResumeWorkRoute` navigation destination. **A resume tap never moves saved progress backwards**: if local `ReadingProgress` exists, only a *strictly fresher* `WidgetProgressStore` entry (i.e. progress synced from another device — local saves stamp both stores with the same `Date.now`, so same-device entries always tie) may override it, and even then the store's anchor installs, never the URL anchor baked into the widget (WidgetKit timeline reloads are budget-throttled, so the URL can lag hours behind). No local progress → seed from the store, falling back to the URL snapshot. **`openResumeRoute` must not clear `detailPath` itself** — it only switches the tab and sets `pendingResumeRoute`; the `.task(id:)` on the detail stack assigns `detailPath = [route]` in one atomic mutation. The old code called `select(.library)` (which clears the path) and then re-pushed in the deferred task; that clear-then-repush spans two update cycles and, when the app was already open, SwiftUI could drop the push and strand you on an empty Library. The single atomic assignment is also idempotent when the same work is already open.

## Reader settings profiles

Typography settings are per-device: every reader key goes through `ReaderProfile.deviceKey(_:)` and each platform stores its own active profile (`reader.activeProfile.{phone,pad,mac}`). Profiles are Codable structs serialized as JSON under the `reader.profiles` key, managed from the reader's Aa menu and `ReaderSettingsView` (create/rename/delete/switch). `ReaderProfileSyncStore` mirrors that key through iCloud key-value storage, merging by case-insensitive profile name (`ReaderProfile.mergedProfiles`); `iCloudSyncManager` also includes profiles in full library backups. Legacy un-suffixed keys migrate once via `ReaderProfile.migrateLegacySettingsIfNeeded()`.

**Deletions sync as tombstones.** A pure union merge resurrected deleted profiles instantly (KVS caches locally), so `ReaderProfile` carries optional `updatedAt`/`deletedAt` stamps (optional like `widthRaw` — old JSON still decodes, and old app versions ignore the new keys). View save helpers call the `saveProfiles(_:previousJSON:)` overload, which stamps `updatedAt` only on content changes, turns names missing from the new list into tombstones (hidden from `loadProfiles`, kept in the stored array so the deletion propagates), and prunes tombstones after 90 days. `mergedProfiles` resolves per-name conflicts by newest stamp — tombstone beats stale copy, newer re-creation beats tombstone, two stamp-less legacy copies keep the old union behavior. Trade-off: a device offline past the 90-day tombstone lifetime can resurrect a profile it still holds live.

## iCloud library backup (merge, never clobber)

`iCloudSyncManager.backupToiCloud` must never write a whole-file snapshot: `queueBackup` fires on every mutation, so last-writer-wins would let a near-empty device overwrite a full one's backup. The backup decodes the existing cloud `library_backup.json` and **unions** it with the local snapshot (`mergedBackup`, a pure `nonisolated static` helper) before writing: cloud-only records are kept for every type; on conflict the local record wins, except reading positions keep the newer `updatedAt`, chapters survive from whichever side has more, and stats merge conservatively. If the cloud file is an un-downloaded `.icloud` placeholder, the backup starts the download and skips (next `queueBackup` retries). `ChapterBackup.aoId` is optional so older backups decode. Stat merges lift `totalSeconds` to `max(existing, Σ mergedDaySeconds)` after unioning day buckets, preserving the `totalSeconds == Σ daySeconds` invariant (All Time must never show less than a Year). Consequence of union semantics: deletions don't propagate between devices — the safe default versus silent data loss.

**Restore is a strictly forward merge** — it also runs automatically: the launch `.task` restore-merges whenever iCloud sync is on and the cloud file changed since this device last applied *or wrote* it (`cloudBackupHasUnappliedChanges`, stamped under `icloud.lastRestoredBackupDate` by both restore and backup), not just on an empty library. That's only safe because restore can never move data backwards: reading positions (both `ReadingProgress` rows and `Work.lastRead*`) apply only when the backup side is newer, follow/star/pin merge as an OR, folder assignments union (never `removeAll`), `lastSeenChapterCount` only advances (regressing it would re-fire chapter notifications), and chapters replace only when the backup carries **more** than the local copy (a metadata-only follow backs up `chapters: []` — restoring that must not wipe an offline download). Keep any new restore field to these forward-only semantics or the launch sync will corrupt whichever device opens second.

**EPUB re-download after restore** — the backup carries chapter *text* but not the EPUB *files*, so restored works read offline yet lose their Downloaded state. After any successful restore, `RestoreDownloadCenter.proposeRedownload` (candidates: works with chapters but no `WorkPersistence.epubURL`) drives a root-level prompt + progress banner (`.restoreRedownloadUI()` on `RootView`): x/total bar, spinner, cancellable mid-run — cancelling keeps everything already restored/downloaded. Downloads go through `AO3Client.downloadEPUB` sequentially (the 1 req/sec throttle paces them).

## Last-read widget

`FanficlyWidget` shows the last-read story with a progress bar. `ReadingProgressStore.save` writes every progress update into `WidgetProgressStore`, which persists to the `group.io.github.yennster.fanficly` app-group defaults and mirrors to iCloud KVS (debounced ~1.2 s; immediate when the reader closes) so the widget and other devices stay fresh. `FanficlyApp` installs the KVS observers at launch (`WidgetProgressStore` / `ReaderProfileSyncStore` `.installCloudSyncObserver()`), skipped in demo and unit-test runs. Tapping the widget opens the resume route above.

## Mac Catalyst

The app also builds for the Mac via Catalyst (`TARGETED_DEVICE_FAMILY: "1,2,6"`, `SUPPORTS_MACCATALYST: YES` in project.yml). `RootView` implements a global UI zoom — `app.zoomScale`, bound to ⌘+/⌘=/⌘−/⌘0 — by counter-scaling the root view. The reader handles hardware arrow-key page turns via `ReaderKeyPressModifier` (`.onKeyPress`), with `.focusEffectDisabled()` so no focus ring is drawn. There is no Mac Catalyst simulator: Mac screenshots are captured on a landscape iPad Pro 13-inch sim instead (see Screenshots).


## Screenshots

`bin/take-screenshots.sh` is the interactive capture (manual navigation). `FanficlyUITests/ScreenshotTests` is the automated version — it drives the app **in `-demoMode`** and writes PNGs to `docs/screenshots/{iphone,ipad,mac}/` (idiom subfolder; path derived from `#filePath`; the simulator runs as the host user so it can write there). Run it with `-only-testing:FanficlyUITests/ScreenshotTests/testCaptureMainScreens`; the Mac set comes from `bin/take-mac-screenshots.sh`, which runs `testCaptureMacScreens` on a landscape iPad Pro 13-inch simulator (stand-in for the Mac app — there's no Catalyst sim). Demo mode is fully offline so the shots are deterministic. One iPad gotcha: re-selecting a sidebar item in `NavigationSplitView` doesn't pop the detail stack, so the Privacy capture pops back one level via the nav-bar back button instead. CI never runs UI tests (`-only-testing:FanficlyTests`).

**App Store marketing screenshots** are framed by `bin/frame-screenshots.py` (run by the `fastlane screenshots` lane after capture). It frames each raw shot in a genuine Apple device bezel via `fastlane frameit`, then composites it onto the solid indigo brand canvas (`#3B2E8C`) with a bold two-line ASO headline, writing exact-size PNGs to `fastlane/screenshots/en-US/` (iPhone 6.9" `1320×2868`, iPad 13" `2064×2752` — iPad is framed at frameit's supported 12.9" `2048×2732` then composited onto the 13" canvas). Mac shots get a window-style frame (border + soft shadow, no frameit bezel) on a `2560×1600` canvas and land in `fastlane/screenshots-mac/en-US/` — a separate tree because deliver matches shots to App Store slots by pixel size and the iOS listing rejects Mac sizes. `fastlane release` uploads the iOS set; `fastlane release_mac` archives the Catalyst build and uploads the Mac set with `platform: osx`. Headlines/order live in the `SLIDES` list at the top of the script. Requires `brew install fastlane imagemagick`. `fastlane/screenshots/` is git-ignored (regenerate via the lane).

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

`ReadingStat` is registered in `FanficlyApp.sharedModelContainer`'s `Schema`
(and `PersistenceTests`' in-memory schema), included in `iCloudSyncManager`
backup/restore (`StatBackup`; restore merges conservatively — max of totals,
per-day maxima, and `maxProgress`, OR of `workIsComplete`, widest date span — so
two devices never double-count; the two progress fields are optional in
`StatBackup` so older backups still decode), and seeded in `DemoSeed` for
screenshots. `ReadingStat.snapshot` is the shared
value-type bridge from the @Model to the pure aggregator.

## Privacy posture (do not regress)

The app stores **nothing** off-device, with one shape of exception: sync data in the user's **own private iCloud** (opt-in library backups via `iCloudSyncManager`, plus iCloud key-value storage for reader profiles and last-read progress) — Apple infrastructure under the user's Apple ID, unreadable by us. Don't add analytics, crash reporting, or remote logging. The only persisted secret is AO3's own session cookie (in iOS Keychain). See `PRIVACY.md` and `PrivacyInfo.xcprivacy`.
