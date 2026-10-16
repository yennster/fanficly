# AGENTS.md — working in Fanficly for Windows

Architecture, workflow and regression rules for agents working on the `windows` branch. Read "What this is" and "Start here" first, then the section for the part you're changing. Keep this file current when behaviour or ownership changes, and check details against the source rather than trusting older notes.
Picking up roadmap work? Go straight to [Autonomous roadmap work](#autonomous-roadmap-work).

## What this is

A native Windows app (WinUI 3 on the Windows App SDK, C# on .NET 10, Native AOT in Release, MSIX for the Microsoft Store, x64 and ARM64, Windows 10 2004 / build 19041 and later) that reads AO3 fanfiction. It is a port of the SwiftUI app on `main`. There is no AO3 JSON API, so the app scrapes AO3's HTML with AngleSharp, through one `HttpClient` with a custom `User-Agent` and a 1 request/second throttle. Everything runs on the PC: no servers, no analytics.

The Swift sources (`Fanficly/`, `FanficlyTests/`, …) stay in this branch as the reference implementation. Most C# types name their Swift counterpart in a doc comment ("SwiftData's `@Query`", "the Mac's swipe action"); when behaviour is unclear, the Swift code is the specification. The Apple app's own guide is `AGENTS.md` on `main`.

## Start here

- **Build truth:** `windows/Fanficly.Windows.slnx`, `windows/Directory.Build.props`, `windows/Directory.Packages.props` (central package versions) and `windows/global.json` (SDK 10.0.100, `rollForward: latestFeature`). There is no XAML markup and no generated project to regenerate: adding a `.cs` file under a project folder is enough.
- **Product rules:** reading, search, Browse, Popular and local follows need no account. AO3 bookmarks, subscriptions and posting comments need login. Follow is not subscribe; saved chapter text is not an EPUB download. Never guess tags from keywords.
- **Data safety:** keep offline chapter text, timestamped progress, subscription notification baselines and forward-only backup merges intact. The library is a local SQLite file, not a cloud database; sync is an opt-in file in a folder the user picks.
- **Network and privacy:** every AO3 request goes through `IAO3Client` and its throttle. No telemetry, no backend. Never log passwords, cookies or keys (`AppHost.Log` writes a local file).
- **Validation:** `dotnet test` on the Core tests runs anywhere. The app compiles on Linux and macOS, but running it and the UI tests needs Windows (or CI). See [Tests](#tests) and [Which machine you're on](#which-machine-youre-on).
- **Related docs:** `README.md` (features and setup), `CONTRIBUTING.md`, `ACCESSIBILITY.md`, `PRIVACY.md` (linked from the Store listing, so keep it accurate), `MICROSOFT_STORE.md` (packaging, listing, release tags), `docs/ROADMAP.md`, `.github/workflows/windows-ci.yml` and `windows-store.yml`.

## Architecture

Two projects carry the app:

- **`Fanficly.Core`** (`net10.0`, no Windows APIs): the AO3 client and parsers, search syntax, the SQLite library, sync merging, stats, subscriptions polling, deep links, widget data, and the reader's pure layout logic. All of it lives in the single namespace `Fanficly.Core`. Its tests run on any OS.
- **`Fanficly.App`** (`net10.0-windows10.0.26100.0`): the WinUI shell, screens, and Windows integrations (toasts, widgets, background task, jump list, gamepad, DPAPI cookie vault, Store review).

```text
Program.Main (STA; COM-server modes; single-instance redirect)
  └─ App.OnLaunched → AppHost.Initialize (services) → MainWindow
       ├─ NavigationView sidebar → Tabs.Root(item) → Screen
       │    └─ Navigator stack: Push / ReplacePath / GoBack
       │         └─ Routes.* factories (work page, author, comments, login, …)
       ├─ IAO3Client → AO3Client → Throttle → HTTP → pure parsers → records
       ├─ LibraryStore (SQLite) → WorkPersistence / ReadingProgressStore / stats
       └─ LibrarySyncManager → library_backup.json in the sync folder
Widgets COM server / background task (separate processes) → same Core stores
```

**The UI is code-only WinUI.** Screens build ordinary WinUI controls in C# with the helpers in `UI/Kit.cs`; there is no XAML markup, no `x:Bind`, no data templates in markup. `App` implements `IXamlMetadataProvider` (forwarding to `XamlControlsXamlMetaDataProvider`) and `Main` lives in `Program.cs` (`DISABLE_XAML_GENERATED_MAIN`). That's why the app compiles and type-checks on any OS.

**`Screen`, `Navigator`, `MainWindow` (in `Shell/`).**
- `Screen` is the base class for every page: `Title`/`Subtitle`, `ShowsHeader`, `PrefersFullWindow`, a lazily built `View` (override `Build()`), `PrimaryCommands`/`SecondaryCommands` for the header's command bar (call `InvalidateChrome()` when they change), `OnAppearing`/`OnDisappearing`/`OnRemoved`, `HandleKey(VirtualKey, modifiers)` and `HandleBack()`.
- `Navigator` is one tab's stack: `SetRoot`, `Push`, `ReplacePath` (replace everything above the root), `GoBack` (asks the top screen's `HandleBack` first), `Remove`, `PopToRoot`, `Depth`, `CanGoBack`, and a `Changed` event.
- `MainWindow` owns the `TitleBar`, the `NavigationView` sidebar (Settings in its footer), the header (title, subtitle, command bar), the message area for InfoBars (`ShowMessage`, which also announces to Narrator), zoom, full screen and window placement. `MainWindow.Current` is the one window. Clicking the selected tab again pops it to its root.

**`Tabs` and `Routes` are registries filled from `[ModuleInitializer]`s.** Each feature folder registers itself, so the shell never references feature screens directly:
- `Views/Tabs.cs`: `Tabs.Register(SidebarItem, Func<Screen>)` and `Tabs.Root(item)` (a `PlaceholderScreen` saying "Coming soon." when nothing registered).
- `Views/Routes.cs`: factories `WorkDetail`, `SavedWork`, `Resume`, `AuthorWorks`, `FilteredWorks`, `Comments`, `Login`; actions `Import` and `LibraryFolder`; the `SearchRequested` event. Call the helpers (`Routes.OpenWork`, `OpenSavedWork`, `OpenAuthor`, `OpenFilteredWorks`, `OpenComments`, `OpenLogin`, `RequestSearch`); a missing factory pushes a placeholder rather than crashing.
- Registrations today: `BrowseRegistration` (Browse, Popular, `FilteredWorks`), `SearchModule` (Search), `LibraryModule` (Library, Stats, `LibraryFolder`), `HistoryRegistration` (Recently Viewed), `AuthorsModule` (Authors, `AuthorWorks`, and the notification-permission prompt), `AccountModule` (Subscriptions, Bookmarks, `Login`, `Comments`), `SettingsModule` (Settings), `ImportOverlay` (`Import`), `ReaderModule` (`WorkDetail`, `SavedWork`, `Resume`; see [the reader](#the-reader-listen-export-and-reading-position)).

**Module initializers must not create XAML objects.** They run when the assembly loads, before `Application.Start` brings the XAML runtime up, and creating a `FontFamily`, brush, style or any `DependencyObject` there crashes the app at launch. Registering factories (lambdas) is fine. `Symbols.Font` is lazy for exactly this reason (`SettingsModule` calls `Symbols.Add` from its initializer), and `SearchModule.EnsureSymbols()` adds its icons from the UI thread when the screen is first built. Keep static field initializers of anything a module initializer touches free of XAML objects too.

**Launch, in order (`App.OnLaunched`):** add `XamlControlsResources`, `Theme.InstallAccent`, `AppHost.Initialize()` (services, below), create `MainWindow` with `RootFactory = Tabs.Root`, `AppHost.OnWindowCreated`, `AppearanceSettings.Apply()`, `RestoreBanner.Attach`, `Window.Start(AppHost.InitialTab)` (else the saved `app.selectedTabRaw`, else Search), `Activate()`, the 17+ age gate (`ContentSafetyViews.EnsureAgeGateAsync`), then `AppHost.HandleActivation(..., isLaunch: true)`. Unhandled exceptions are logged and marked handled.

**Services (`Services/AppServices.cs`, `AppHost.InitializeServices`).** `AppHost.Client`, `AppHost.Library`, `AppHost.Auth` and `AppHost.Sync` are the process-wide services.
- Normal run: `AO3Client`, `LibraryStore.Open(AppPaths.Database)` (a damaged file is moved aside as `library.sqlite.damaged-<timestamp>` and a fresh one opened), `ProtectedCookieVault` as `CredentialStore.Shared`, the shared widget store as `AppGroupStore.Shared`, and `LibrarySyncManager` on the folder in `settings.syncFolder`. It then installs the cloud-sync observers (`WidgetProgressStore`, `ReaderProfileSyncStore`, `StreakStore`), registers toast notifications, starts `InAppPolling` and registers the background task.
- `InstallLibraryHooks` wires Core's `LibraryHooks` (streak on a read, last-read widget plus jump list on progress, widget data refresh) and queues a backup on every `LibraryStore.Changed`.
- `RunLaunchTasksAsync` restores from the sync folder when sync is on and the backup changed since this PC last applied or wrote it, proposes EPUB re-downloads, runs `ReadingStatsBackfill`, and refreshes widget data.
- On close: save the library, back up if sync is on, flush the synced settings and the widget store.

**Concurrency.** `IAO3Client` methods are async and thread-safe; `Throttle` serializes them. `LibraryStore` takes one lock per call so the UI and the poller can share it, but records aren't locked: mutate a given record from one thread at a time. `LibraryStore.Changed` is raised on the saving thread; screens subscribe through `LibraryChanges` (in `Views/Browse/`), which marshals to the UI thread and coalesces bursts. Never touch XAML objects off the UI thread; hop with `DispatcherQueue.TryEnqueue`. Keep cancellation tokens flowing, and never retry a POST.

## Storage map

| Data | Where | Notes |
| --- | --- | --- |
| Library records | `LibraryStore` over `library.sqlite` (`AppPaths.Database`) | Identity map loaded at open (chapter bodies lazily). Mutate, `Insert`/`Delete`, then `Save` (one transaction, diffed against what was last written), which raises `Changed` with `LibraryEntityKinds`. |
| Settings (the `@AppStorage` stand-in) | `KeyValueStores.Default` = `JsonFileKeyValueStore(AppPaths.Settings)` (`settings.json`, flushed after 300 ms) | Reader typography keys are per device: always `ReaderProfile.DeviceKey(...)` (suffix `.windows` here). |
| Synced settings (the iCloud key-value stand-in) | `KeyValueStores.Synced` = `SyncFolderKeyValueStore` (`Shared/synced.json`, copied to `<sync folder>/fanficly-settings-sync.json`) | Push debounced 1 s, pull 500 ms after the file changes; last writer wins per key. Carries reader profiles, last-read progress and the streak. Only reaches the folder while sync is on, unlike iOS where key-value sync is always on. |
| Widget data (the app-group stand-in) | `AppGroupStore.Shared` = `Shared/group.json` (`WidgetStorage.SharedStorePath`) | Read by the widgets COM server, which re-reads from disk before every update. |
| AO3 login | `ProtectedCookieVault`: `Credentials/ao3_username.bin` and `ao3_cookies.bin`, DPAPI-encrypted for the current Windows user | Passwords are never stored. |
| EPUB files | `AppPaths.Downloads\<id>.epub` | `AO3Client.DownloadEpubAsync` writes into the folder the client is built with (`AppPaths.Downloads`, in `AppServices` and the background task); `WorkPersistence.EpubPath` looks in `WorkPersistence.LibraryFolder`, set to the same folder at launch, for the Downloaded state. Keep the two in step. |
| Exports | `%TEMP%\Fanficly\Exports` (`AO3Client.ExportsDirectory`) | Temporary files for the share sheet and "Save a copy as". Not the library. |
| Log | `Logs/fanficly.log` (`AppHost.Log`), deleted and restarted past 512 KB; Debug output only in demo mode | Never sent anywhere. Never log secrets. |
| Library backup | `<sync folder>/library_backup.json` (`LibrarySyncManager`) | Same JSON format as the Swift backup, so a Mac and a PC can share one iCloud Drive folder. |

`AppPaths.LocalData` is the package's `ApplicationData.Current.LocalFolder` when installed from MSIX, else `%LOCALAPPDATA%\Fanficly`. `AppPaths.IsPackaged` says which.

Mutations go through `WorkPersistence` (Upsert, UpsertMetadata, ToggleFollow, Unfollow, ToggleStar, TogglePin, DeleteWork, folder operations, RecordView, ToggleFollowAuthor), which saves and calls `LibrarySyncManager.QueueBackupShared`. `QueueBackup` refreshes widget data even with sync off, then debounces the backup by 2 s. A raw `store.Save()` does neither. `UpsertMetadata` keeps chapter bodies; `Upsert(payload)` replaces them. Chapter indices are one-based and paragraph indices zero-based; keep them aligned across parsing, rendering, speech, pagination, saved anchors and resume URLs.

## Layout

```
.github/workflows/
  windows-ci.yml               # PRs to windows + pushes touching windows/: core
                               #   tests, x64/ARM64 builds, UI tests +
                               #   screenshots, MSIX bundle
  windows-store.yml            # windows-v* tag: build, WACK, Store submit, release
  windows-screenshots.yml      # [screenshots] push or manual: capture every screen,
                               #   build the Store art, commit the pictures
  ci.yml                       # the Apple app; runs on main only
Fanficly/ … FanficlyWidget/    # the Swift app: reference implementation, not built here
docs/
  ROADMAP.md                   # Windows backlog (RM-101 onward)
  screenshots/windows/         # README shots from ScreenshotTests (desktop/tablet/compact)
                               #   + showcase.jpg, committed by windows-screenshots.yml
windows/
  Fanficly.Windows.slnx        # the solution (four projects)
  global.json                  # .NET SDK pin
  Directory.Build.props        # nullable, implicit usings, EnableWindowsTargeting
  Directory.Packages.props     # every package version (central management)
  scripts/
    Capture-Screen.ps1         # launch the app in demo mode and save the window
    Copy-Screenshots.ps1       # screenshots workflow: UI-test shots into docs/
    Chart-IconFont.py          # CI: chart which glyphs the system icon fonts have
    Install-IconFont.ps1       # CI: install Segoe Fluent Icons on Server images
    make_store_art.py          # Store screenshots + hero/box/poster from the 4K
                               #   captures (headless Chrome, Pillow)
    Set-ScreenResolution.ps1   # CI: enlarge the runner's display
    Write-Screenshots.ps1      # CI: print screenshots into the log as base64
    store/                     # Store version, identity, listing, WACK, screenshots
  store-art/                   # HTML templates for the Store art (screenshot.html,
                               #   promo.html, brand.css: the iOS store art's look)
  store/
    listing/en-us/             # Store listing text (privacy URL points at PRIVACY.md)
    screenshots/               # Store screenshots (en-us/, 3840x2160, generated)
    images/                    # Store art: hero, box, poster (en-us/, generated)
    version.txt                # the app version the release workflow stamps
  src/Fanficly.Core/
    Auth/                      # AuthState, ICookieVault, KeyedCookieVault,
                               #   CredentialStore
    Browse/                    # BrowseModels, FandomCatalog (categories + curated
                               #   PopularTags), PopularStore (daily snapshot)
    Demo/DemoAO3Client.cs      # offline demo client + DemoCatalog
    Library/
      LibraryEntities.cs       # every record type (Work, Chapter, ReadingProgress,
                               #   ReadingStat, CustomFolder, FollowedAuthor, …)
      LibrarySchema.cs         # tables + append-only migrations (user_version)
      LibraryStore.cs          # the SQLite store (SwiftData stand-in)
      LibraryJson.cs           # hand-written JSON for list/dict columns
      WorkPersistence.cs       # all library mutations + EPUB paths
      ReadingProgressStore.cs  # progress, ReadingStatsStore/Aggregator/Backfill
      LibrarySort.cs           # library sort keys, pinned first
      LibraryHooks.cs          # app-provided callbacks (widgets, streak, indexer)
      DemoSeed.cs              # demo library
    Networking/
      IAO3Client.cs            # the network seam
      AO3Client.cs             # live client: throttle, cookies, retries, timeouts
      AO3Endpoints.cs          # URL builders + AO3PathEncode
      AO3Models.cs             # summaries, payloads, AO3Exception, WorkExportFormat
      MockAO3Client.cs         # canned client for tests
      Throttle.cs              # 1 req/sec, slot reserved before waiting
    Parsing/                   # HtmlDom (AngleSharp helpers) + one parser per page
                               #   kind; CommentsParser is in WorkPageParser.cs
    Reader/                    # pure reader logic: HTMLToAttributed, ChapterTracking,
                               #   ReaderPaginator, ReaderTheme/Metrics/Spread,
                               #   ReaderProfile(+SyncStore), SentenceSegmenter
    Search/                    # AO3SearchFilters, SearchSyntax, SearchSuggestions,
                               #   TagResolver, KnownTags
    Settings/                  # IKeyValueStore + stores, ContentFilter (17+,
                               #   mature filter, hidden works), ReviewPrompt,
                               #   SidebarItem (tab order + raw values)
    Stats/StreakStore.cs       # reading-day streak
    Subscriptions/             # SubscriptionPoller, NotificationRouting,
                               #   BackgroundRefresh, NotificationsAuthorization
    Sync/                      # LibraryBackup (+JSON), LibrarySyncManager,
                               #   RestoreDownloadCenter
    Widget/                    # DeepLink, ResumeRoute, WidgetCenter,
                               #   WidgetDataStore, WidgetProgressStore
  src/Fanficly.App/
    Program.cs                 # Main: COM-server modes, single instance, Start
    App.cs                     # OnLaunched, XAML metadata provider
    Package.appxmanifest       # identity, protocol, share target, toasts,
                               #   widgets, background task
    app.manifest               # PerMonitorV2 DPI, Windows 10/11
    Assets/                    # icons, tiles, splash, widget screenshots
    Public/                    # files the Widgets board may read (widget icon)
    Services/
      AppHost.cs               # flags (-demoMode, -set, -tab, -iconGallery), log,
                               #   activation
      AppServices.cs           # service wiring, launch tasks, close
      AppRouting.cs            # deep links, share target, drop/paste import,
                               #   notification routes
      AppPaths.cs              # where everything lives on disk
      SyncFolderKeyValueStore.cs # the synced settings file
    Shell/                     # MainWindow, Navigator, Screen, SidebarItem
                               #   (glyphs + Ctrl shortcuts)
    UI/
      Kit.cs                   # layout/control helpers (class UI) + ElementExtensions
      Theme.cs                 # brand accent, brushes, high contrast, type ramp
      Symbols.cs               # SF Symbol name → Segoe Fluent glyph (or a
                               #   drawn path for the few the fonts lack)
      Segmented.cs             # segmented picker (SwiftUI .segmented): Popular, Stats
      Dialogs.cs               # one ContentDialog at a time
      VirtualList.cs           # virtualized list with infinite scroll
      RichText.cs, FlowPanel.cs # rich text blocks; wrapping chip layout
    Platform/
      Notifications.cs         # AppNotificationManager toasts
      BackgroundRefreshTask.cs # in-app polling, timer task registration + server
      Widgets/                 # widget provider, six widgets, COM server,
                               #   make_widget_art.py (generates WidgetGlyphs.g.cs)
      GamepadInput.cs          # Xbox controller navigation
      JumpListService.cs       # taskbar jump list
      ProtectedCookieVault.cs  # DPAPI cookie storage
      StoreReviewRequester.cs  # Store rating dialog / review page
    Views/
      Tabs.cs, Routes.cs       # the registries
      Search/                  # SearchScreen, WorkFilterSheet, SearchChips,
                               #   SearchHelp (tips), ShareLink
      Browse/                  # Browse, category fandoms, filtered works,
                               #   Popular; LibraryChanges
      Library/                 # Library, folders, rows, sort menu, actions,
                               #   restore banner, helpers
      History/                 # Recently Viewed
      Authors/                 # author works (Follow), followed authors
      Account/                 # login, bookmarks, subscriptions, comments,
                               #   content safety (age gate, hidden works)
      Stats/                   # Stats tab, period, share card
      Import/ImportOverlay.cs  # fanficly://import: fetch, save, download, open
      Settings/                # Settings, Reader settings, Sync, Privacy,
                               #   Shortcuts, About, appearance, voice sample
      Shared/WorkRow.cs        # result row with inline bookmark button
      Reader/                  # ReaderModule (routes); WorkDetailScreen (live work
                               #   page), SavedWorkReaderScreen, ReaderHostScreen;
                               #   ReaderView{,.Chrome,.Content,.Continuous,
                               #   .Paginated,.Pages}.cs; ReaderText and
                               #   ReaderTextMeasurer (draw = measure);
                               #   SpeechController (Listen), WorkExporter,
                               #   WorkHeaderMetadataView, ReaderPrefs, ReaderBrushes
  tests/
    Fanficly.Core.Tests/       # xUnit, 448 cases, fixture-based, no network
    Fanficly.UITests/          # FlaUI: SmokeTests, ScreenshotTests,
                               #   ReaderLayoutTests (Windows only)
```

## Build & run

All commands run from `windows/`. You need the .NET 10 SDK.

```bash
dotnet test tests/Fanficly.Core.Tests            # unit tests (any OS)
dotnet build src/Fanficly.App -p:Platform=x64    # compile the app (any OS; ARM64 too)
dotnet build tests/Fanficly.UITests              # compile the UI tests (any OS)
```

Off Windows, `EnableWindowsTargeting` lets the Windows projects compile and the csproj turns off MakePri and MSIX tooling, so a Linux build proves the code compiles but produces nothing runnable.

Run on Windows (unpackaged, self-contained):

```powershell
dotnet build src/Fanficly.App -c Debug -p:Platform=x64 -p:WindowsPackageType=None `
  -p:WindowsAppSDKSelfContained=true -p:RuntimeIdentifier=win-x64 -o ../artifacts/app-x64
../artifacts/app-x64/Fanficly.exe -demoMode
```

Launch arguments: `-demoMode` (offline `DemoAO3Client`, in-memory library and settings, demo login `demo_reader`, no toasts or review prompts, no age gate), `-set key=value` (demo mode only, repeatable: presets a setting in the in-memory store, e.g. `-set reader.mode.windows=pageByPage`), `-demoLongChapters` (long demo chapters for page layout), `-tab <raw>` (`search`, `browse`, `popular`, `library`, `recentlyViewed`, `authors`, `bookmarks`, `subscriptions`, `stats`, `settings`), `-iconGallery` (pushes `IconGalleryScreen`, every icon the app uses, so a glyph missing from the installed font shows as an empty box). A `fanficly:` or AO3 `https:` link among the arguments is opened too; the reader layout tests pass `fanficly://resume/90001`. `-RegisterProcessAsComServer` and `-BackgroundTask` are for Windows to start the widget and background-task servers; don't pass them by hand.

Unpackaged runs have no package identity, so the Widgets board, the background task, the share target, the `fanficly://` protocol and the Store rating dialog don't work there; in-app polling, toasts and the jump list are attempted but may not show. Deploy the packaged app from Visual Studio (WinUI application development workload) to test those. The Store bundle (Release, Native AOT, x64 + ARM64) is built with MSBuild as in `windows-ci.yml`'s `package` job and in `README.md`; releasing is in `MICROSOFT_STORE.md`.

## Tests

**Core tests** (`tests/Fanficly.Core.Tests`, xUnit, 448 cases in 37 files, all fixture-based, no network). They pass on Linux, macOS and Windows.
- **Parsers:** `SearchResultsParserTests` (incl. the bookmarks page), `WorkPageParserTests` (incl. login and comments parsing), `SubscriptionsParserTests` (fails closed), `MediaCategoryParserTests`, `WorkMetadataParserTests`, `HtmlDomTests`.
- **Networking:** `AO3ClientTests` (through a fake `HttpMessageHandler`: retries, cookies, redirects, timeouts, form posts), `AO3EndpointsTests`, `ThrottleTests` (spacing, and concurrent waiters serialized), `DemoAO3ClientTests`.
- **Search:** `SearchSyntaxTests`, `SearchSuggestionsTests`, `AO3SearchFiltersTests`, `TagResolverTests` (with `StubAO3Client`), `FandomCatalogTests`, `BrowseModelsTests`, `PopularStoreTests`.
- **Library and sync:** `LibraryStoreTests` (identity map, save diffing, migrations, relationships), `PersistenceTests`, `LibraryBackupJsonTests` (the Swift backup format), `LibrarySortTests`, `ReadingStatsRecordTests`, `StreakStoreTests`, `CrossAreaTests`.
- **Reader logic:** `HTMLToAttributedTests`, `ChapterTrackingTests`, `ReaderMetricsTests` (spread rule, page-area tracking, and `ReaderPaginator` across a device matrix with `FakeTextMeasurer`), `ReaderProfileTests` (merge, tombstones, per-device keys).
- **Routing and widgets:** `DeepLinkTests`, `NotificationRouteTests`, `ResumeProgressPolicyTests`, `WidgetDataStoreTests`, `WidgetProgressStoreTests`.
- **Other:** `SubscriptionPollerTests` (with `PollerFakeClient`), `AuthStateTests`, `ContentSafetyTests`, `ReviewPromptTests`.

Tests that touch the static stores (`KeyValueStores`, `AppGroupStore`, …) join `[Collection(GlobalStoreCollection.Name)]` so they don't run in parallel. Core's internals are visible to the test project, so make a helper `internal` (not `public`) when it needs direct testing.

**UI tests** (`tests/Fanficly.UITests`, FlaUI over UI Automation, Windows only). `AppSession` launches `FANFICLY_EXE` (default `windows/artifacts/app-x64/Fanficly.exe`) with `-demoMode` at a form factor (Desktop 1600×1000, Tablet 834×1112, Compact 420×880, and for Store art Store 1200×750 at `-captureScale 2.4` and StoreTablet 834×1112 at `-captureScale 2`) and finds elements by automation id.
- `SmokeTests`: launch, every tab from its Ctrl shortcut (laptop and compact), sidebar selection, `-tab`, back, zoom and F11, a second launch handed to the running window, and a `fanficly://search` link.
- `ScreenshotTests.CaptureMainScreens` (a theory over desktop, tablet, compact) saves `01-home`, `02-search-results`, `03-reader`, `04-library`, `05-browse`, `05-browse-fandoms`, `06-recently-viewed`, `07-reader-settings`, `08-privacy`, `09-tts`, `10-popular`, `11-comments`, `12-bookmarks` to `FANFICLY_SCREENSHOTS` (default `windows/artifacts/screenshots`), one folder per size, and fails if any screen couldn't be reached. It also runs at the `store` size. `CaptureReaderPages` (desktop, tablet, store, store-tablet) opens the reader page by page (`-demoLongChapters`, `fanficly://resume/90001`), presses Page Down once and saves `13-reader-spread`. The reader, comments and Listen shots come last, from a fresh launch: a search result, then `work.options` → `work.options.comments`, then `reader.aa` → `reader.listen`. `CaptureIconGallery` launches with `-iconGallery`, saves `icons/icons-<n>`, and fails naming any icon the PC's fonts can't draw (`IconFont.CanDraw`, GDI glyph lookup); drawn icons are captioned "(drawn)" and skipped.
- `ReaderLayoutTests` (page by page in a 760×1000 window, widened to 1280×860 for the spread) launch with `-demoLongChapters`, `-set` presets for the mode and typography, and `fanficly://resume/90001`; turn to a full page mid-chapter by clicking its outer third; and read the page label from `reader.pageFooter`'s name ("…, pages 3–4 of 12"). They check that the footer is under 60 px tall and on the window's bottom edge; that each page's text (inside `reader.page.left` / `reader.page.right`) ends at most 75 px above it and never under it; that minimizing and restoring, and the New Profile dialog, leave the page label alone; that a middle-third click hides the controls (the footer goes) while the page keeps its first words and its one or two pages, and holds more text when it gained room, and a second click brings them back unchanged; and that a wider window shows a spread exactly when `ReaderSpread`'s rule says so. Each step saves `reader-layout/01-page` … `09-wide-controls-back` before its checks, so a failure still leaves a picture.
- The open tab is read from the header title's `ItemStatus` (`tab:<raw>`), because the sidebar items leave the automation tree when the pane folds into its menu button.
- They drive the real window: hands off while they run.

When you add a feature, add its Core tests, and a smoke step if it adds a tab or route.

## Conventions

- **`IAO3Client` is the only seam to the network.** Screens use `AppHost.Client`; nothing else creates an `HttpClient`. Implementations: `AO3Client` (live), `DemoAO3Client` (demo mode), `MockAO3Client`; tests also use `StubAO3Client` and `PollerFakeClient`. A new interface method needs all of them.
- **Throttle.** Every request waits on the client's `Throttle`. Never bypass it, never parallelize scrapes.
- **Parsers are pure.** They take an HTML string and return records. Use `HtmlDom` helpers, which reproduce the SwiftSoup calls the Swift parsers make. AngleSharp follows CSS strictly: attribute values in selectors must be quoted (`a[href^='/tags/']`), unlike jsoup.
- **Native AOT.** Release builds are trimmed and compiled ahead of time (`PublishAot`, `IsAotCompatible` on both projects, the CsWinRT AOT optimizer). So: no `System.Text.Json` serializer or reflection-based binding (JSON is hand-written with `Utf8JsonWriter`/`JsonDocument`, see `LibraryJson`, `LibraryBackupJson`, `WidgetJson`); no runtime code generation, `dynamic` or `Activator` on unknown types; WinRT types you implement are `partial` classes so CsWinRT can generate their vtables (see the widget provider and class factories); lists hand ItemsRepeater boxed indices (`VirtualList<T>`) rather than arbitrary C# objects. Treat any new trim or AOT warning as an error and fix it. The Debug build is JIT, so AOT problems show up only in the Release `package` job.
- **Settings go through `KeyValueStores.Default`** (or `.Synced` for the few synced channels), not custom files. Reader typography keys always go through `ReaderProfile.DeviceKey(...)`.
- **Dependencies.** Only AngleSharp and Microsoft.Data.Sqlite at runtime (plus the Windows App SDK). Versions live in `Directory.Packages.props`. Don't add analytics, crash reporters or any SDK with a network side channel.
- **Never show a dialog from menu content.** A `MenuFlyout` item's handler defers through the dispatcher (`AfterMenu` in `LibraryActions`, `Later` in `SearchScreen`/`StatsScreen`) so the flyout has closed before a `ContentDialog` opens. Open dialogs only through `Dialogs` (`AlertAsync`, `ConfirmAsync`, `PromptAsync`, `SheetAsync`, `ShowAsync`): WinUI allows one `ContentDialog` per window at a time, and `Dialogs` queues them.
- **UI helpers.** Build screens with `UI.UI.*` (`VStack`, `HStack`, `Grid`, `Text`, `Secondary`, `Caption`, `SectionHeader`, `Icon`, `Button`, `IconButton`, `ToolbarButton`, `Card`, `Chip`, `EmptyState`, `Loading`, `Scroll`, `Section`, `SettingsRow`, `NavRow`, `Toggle`, `MenuItem`, `CheckItem`, `Menu`, `Flow`, `Banner`, …) and the `ElementExtensions` (`A11y`, `A11yHeading`, `A11yHidden`, `Tip`, `Shortcut`, `OnTapped`, `Margin`, …). Settings pages use `SettingsKit`; `UI.SettingsRow` moves a wide control under its label below 440 px, like Windows Settings' cards. Where the Mac uses a segmented `Picker`, use `Segmented`. Chips, tokens and tags have 4 px corners (Windows' token style), not the Mac's capsules. Icons are named by their SF Symbol name and mapped in `Symbols` (`Symbols.Add` for new ones). Pick glyphs Segoe Fluent Icons actually has: the icon gallery test fails on any it can't draw. For an icon it lacks on some PCs (the bookmark ribbon, a filled bell), add path markup to `Symbols.Drawn` (a 16-unit grid, 1-unit stroke, nonzero fill) and create icons with `Symbols.Icon`/`UI.Icon`, never `new FontIcon { Glyph = … }`, so the drawn ones work everywhere.
- **Colours come from `Theme`.** Brushes are swapped in place when the theme changes, and in high contrast they become the system colours. Don't hard-code colours in a screen.
- **Automation ids** are lowercase, dotted `<area>.<thing>`: `sidebar.<raw>`, `header.title`, `header.commands`, `search.box`, `library.search`, `library.list`, `library.work.<id>`, `work.<id>`, `history.list`, `browse.fandom.<i>`, `settings.privacy`, and the reader's (listed in [the reader section](#the-reader-listen-export-and-reading-position)). UI tests depend on them; don't rename one without updating the tests.
- **Narrator is a supported input.** Icon-only buttons get a name (`UI.IconButton`'s label is its tooltip and its Narrator name); headings get `A11yHeading`; decorative icons `A11yHidden`; rows that combine several texts use `AccessibleGroup` (in `LibraryHelpers`), but never wrap something that holds its own buttons. Slow, silent operations announce their result (`MainWindow.ShowMessage` announces; `MainWindow.Announce` for the rest).
- **Keyboard.** `MainWindow` offers every key to the top screen's `HandleKey` first (unless a text box has focus); screens implement shortcuts there. Add new shortcuts to `ShortcutsScreen` and give menu items their keyboard accelerator text.
- **Port faithfully.** Copy the Swift behaviour, names and edge cases, and name the Swift type in the doc comment. Where Windows differs on purpose (haptics hidden, Mica, toasts), say so in the comment.

## Common tasks

**Add a tab.** Add a case to `SidebarItem` in Core (the order of `SidebarItems.All` is the sidebar order), with its raw value, title and SF Symbol name; give it a glyph in `Symbols` if needed and a shortcut in `Shell/SidebarItem.cs`; register its screen with `Tabs.Register` from a `[ModuleInitializer]` in its feature folder; add it to `ShortcutsScreen`, the jump list if it's a common destination, and the smoke tests' tab list.

**Add a route.** Add a factory or action to `Routes`, an `Open…` helper that falls back to a placeholder, and register it from the feature's module initializer. If a deep link or notification should reach it, extend `DeepLink`/`NotificationRoute` in Core (with tests) and `AppRouting`.

**Add a setting.** Pick a key that matches the Swift `@AppStorage` key when one exists, read and write it through `KeyValueStores.Default` (per-device reader keys through `ReaderProfile.DeviceKey`), add the row with `SettingsKit`, and decide whether it belongs in the backup (`SettingsBackup.Fields` in `Sync/LibraryBackup.cs`) or the synced store.

**Add a search filter.** Add the field to `AO3SearchFilters` (its `QueryItems` row, `IsEmpty`, `Merging`, `Clone` and the saved-JSON read and write), a `key:value` token in `SearchSyntax.Parse`/`Render` with a round-trip test, a chip in `SearchChips`, and optionally a control in `WorkFilterSheet`. Only add a natural phrase to `SearchSyntax`'s phrase list if it can never mean anything but the filter.

**Add a parser.** Put it in `Parsing/`, take an HTML string, parse with `HtmlDom`, return a record, and add fixture tests. Fail closed where a wrong empty result could delete data (see `SubscriptionsParser`).

**Add a library field or record type.** Add the property and its column to the entity's `Columns`, `ToRow` and `Read`; for a new type, add it to `LibrarySchema.Tables`, `LibraryEntityKinds`, and `LibraryStore`'s table reads. Append a migration to `LibrarySchema.Migrations` (never edit an existing one; additive only, every new column with a default). Then decide its backup, restore (forward-only, below) and demo-seed behaviour, and add `LibraryStoreTests`.

**Add a test.** Inline fixtures, no network. Use `MockAO3Client`/`StubAO3Client` or a fake `HttpMessageHandler`, `LibraryStore.OpenInMemory()` and `InMemoryKeyValueStore`; join `GlobalStoreCollection` if you touch a static store.

## Things to know about AO3

- No JSON API. We are a respectful guest. The `User-Agent` is `Fanficly/<version> (+github.com/yennster/fanficly)` so AO3's operators can find us.
- Work URLs carry `view_adult=true` (skip the age-gate page) and `view_full_work=true` (all chapters on one page).
- Chapters are `div.chapter[id^='chapter-']`; the canonical tags are in `dl.work.meta.group`.
- **Login** is form-based: GET `/users/login`, scrape `authenticity_token` (`LoginParser`), POST with cookies. `AO3Client` keeps cookies itself and saves them to the cookie vault, so a session survives restarts. The password is never stored.
- **Subscribe** is a POST to `/works/<id>/subscriptions` with `subscription[subscribable_type]=Work` and the token (`SubscribeToWorkAsync`). Needs login. The work page's options menu calls it and mirrors the result into a local `SubscriptionRecord` (`work:<id>`, baseline today's chapter count); signed out the item opens login, and an expired session offers to sign in again.
- **Subscription sync fails closed.** An expired cookie turns the subscriptions page into the login form. `SubscriptionsParser.ParsePage` throws `AO3Exception` with `Unauthorized` for a login page and `ParseFailed` when there's neither a list nor the page shell; `FetchSubscriptionsAsync` walks every page (50-page ceiling) and throws if any page fails; `SyncSubscriptionListAsync` deletes records only after a non-empty fetch. So markup drift or a stale session can't mass-delete `SubscriptionRecord`s and their `LastSeenChapterCount` baselines.
- **Bookmarks** (`/users/<name>/bookmarks`) list works as `li.bookmark.blurb`; `SearchResultsParser.Parse(html, blurbSelector)` reads them and takes the work id from the `/works/<id>` link (`SearchResultsParser.WorkId`), skipping series and external bookmarks.
- **Comments** load per chapter (`AO3Endpoints.ChapterComments`, or `WorkComments` for a one-shot) and parse with `CommentsParser` (depth from nested `li.comment`). Posting replays the page's own new-comment form (`CommentsParser.NewCommentForm`, `DefaultPseudId`) with the token. Needs login. `CommentsScreen` re-fetches after posting because AO3 may hold comments for moderation.
- **Browse** uses `/media/<category>/fandoms`, with category names path-encoded by `AO3Endpoints.AO3PathEncode` (`&`→`*a*`, `/`→`*s*`, `.`→`*d*`, …).
- **Autocomplete** (`/autocomplete/{tag,fandom,relationship,character,freeform}?term=`) must send `Accept: application/json` (the client also sends `X-Requested-With`), and the term must encode `/` as `%2F`, or AO3 answers 404 and tags silently don't resolve.
- **Tag resolution is conservative for freeforms.** `TagResolver.BestFreeformMatch` accepts only the same tag up to case, spacing and punctuation; otherwise it keeps what the user typed. Only authoritative answers are cached; a 429 or offline error falls back for that one search.
- **Rating is single-select** on `/works/search`. One rating goes in `work_search[rating_ids]`; several are OR-ed in the query field (`(rating_ids:12 OR rating_ids:13)`), because the array form AND-matches and returns nothing. Warnings and categories stay arrays.
- **Search never silently reinterprets words.** The box text goes to `work_search[query]`. Tags become filters only when a suggestion is tapped (`other_tag_names`, excludes in `excluded_tag_names`). Only `key:value` tokens and `SearchSyntax`'s short phrase list convert on submit, because AO3 requires every keyword to match. Don't reintroduce guessing.
- **Typeahead:** 350 ms after typing stops, the trailing words go to `/autocomplete/tag` (backing off a word at a time), re-ranked by `SearchSuggestions.RankTags`, memoized in `TagSuggestionCache`.
- **AO3 search is slow:** 20–30 s to first byte is normal. `SearchAsync` uses a 60 s timeout and one retry (other requests 30 s, resource limit 90 s). `SearchScreen` keeps one cancellable search and offers Cancel after 5 s.
- **Filter-only searches sort by kudos** (`SearchSyntax.AutomaticSort`) until the user picks a sort.
- **Saved searches, recents and `fanficly://search?query=`** store `AO3SearchFilters.PromptText()`, which `SearchSyntax.Parse` reads back exactly. The Saved Searches widget sends a saved filter's JSON instead, as the Swift widget does: `DeepLink.SearchPrompt` turns a query that starts with `{` and decodes as filters into their prompt text and passes anything else through, so `SearchScreen` runs both.
- **Popular** is derived from cumulative counts (`FetchPopularSnapshotAsync`: fandom counts from the media pages, ships and characters from the works-filter sidebar of the top fandoms via `WorkFiltersParser`, selector `label[for^='include_'][for*='_{kind}_ids_']`). `PopularStore` caches it (`popular.snapshot.v1`) and refreshes at most daily; the screen falls back to the curated `PopularTags` when a list is empty.
- **Retries:** `AO3Client` retries idempotent GETs only (up to 2 times, 0.5 s then 1 s backoff) on timeouts, dropped connections, and 429 with `Retry-After` of 10 s or less, and never while offline. Never retry a POST.
- **Throttle:** `Throttle.WaitAsync` reserves the caller's slot before it waits, so simultaneous callers are spaced out rather than released in a burst (a burst is what trips AO3's tarpit).
- **Export:** `/downloads/<id>/work.<ext>` for `WorkExportFormat` Azw3, Epub, Mobi, Pdf, Html (`ExportWorkAsync`, into `%TEMP%\Fanficly\Exports`); EPUB downloads for offline use go through `DownloadEpubAsync`, into `AppPaths.Downloads`.

## Local follow vs. AO3 subscribe

- **Follow** (bookmark icon) is local only, no login: `WorkPersistence.ToggleFollow` saves the work with `IsFollowed`. `WorkRow` has an inline bookmark button.
- **Follow author** (the Authors tab) is local only: `ToggleFollowAuthor` stores a `FollowedAuthor` with the known work ids seeded, so the first poll doesn't announce the back catalogue.
- **Subscribe** POSTs to AO3 and needs login; it mirrors AO3's own subscription list, which the Subscriptions tab shows next to local follows. Unsubscribing opens AO3 in the browser.

All three feed `SubscriptionPoller`. `RunFullPollAsync` builds one queue of all three kinds, oldest check first (`LastCheckedAt`), stamps each attempt up front, saves after each, and stops on cancellation, so a cut-off run resumes where it stopped. `CheckForNewChaptersAsync`, `CheckFollowedWorksAsync` and `CheckFollowedAuthorsAsync` serve the Subscriptions tab's manual refresh. The poll runs in-app (`InAppPolling`: first after a minute, then every `BackgroundRefresh.DefaultInterval`, 4 hours) and, when packaged, from a timer background task (`BackgroundTaskRegistrar`: 240 minutes, internet required). `FanficlyBackgroundTask` opens its own store and client, runs for about 30 seconds, and skips when the main window is open.

Toasts need no permission on Windows, but the user can turn them off in Windows Settings. The first time a follow asks (`NotificationsAuthorization.RequestAfterFollow` → `Request`, set by `AuthorsModule`) while Fanficly's notifications are off, a dialog offers to open that settings page; it's shown once (`notifications.permissionPromptShown`) and never in demo mode.

**Tapping a toast opens what it's about.** `NotificationRoute` (`NewChapters(workId)`, `NewWork(workId)`, `NewWorks(author)`) is encoded in the toast's arguments (`ToArguments`/`FromArguments`; old work-id-only arguments decode as `NewChapters`). `Notifications.Register()` runs before the window exists so a toast that cold-launches the app is delivered; `NotificationRouter.Shared` holds a route that arrives before the window. `AppRouting.OpenNotificationRoute` replaces the current tab's path with the live work page (`Routes.WorkDetail`) or the author's works, on top of whatever tab is showing.

## Activation, single instance and deep links

`Program.Main` registers the instance under the key `main` (`AppInstance.FindOrRegisterForKey`). A second launch (a protocol link, a jump-list entry, a toast, a share) redirects its activation to the running instance (waiting up to 10 s) and exits; the main instance receives it in `App.OnRedirectedActivation` and brings its window to the front. `AppHost.HandleActivation` handles protocol activation (`OpenUri`), the share target, launch arguments (`-tab <raw>`, or a `fanficly:` or AO3 `https:` link) and toast activation. `AppHost.InstallDropAndPaste` (in `AppRouting.cs`, called from `OnWindowCreated`) also makes the window's root a drop target: a dropped link or text, or Ctrl+V when no text box has focus (`PasteImport`, from `MainWindow`'s key handling after the screen declines the key), goes through `WorkIdFromDataAsync` → `DeepLink.WorkIdFromText` → `ImportOrWarn`, the same path as the share target. A dropped non-AO3 link shows a warning; a paste that isn't an AO3 work link is ignored silently.

`DeepLink.Parse` handles, in `AppRouting`:
- `fanficly://resume/<id>?chapter=&paragraph=` (widgets, jump list): replaces the current path with `Routes.Resume`. `ReaderModule.InstallResumeProgress` asks `ResumeProgressPolicy.AnchorToInstall` what to install: a resume never moves saved progress backwards; only a strictly fresher `WidgetProgressStore` entry from another device may override local progress, and then the store's anchor installs, never the one in the URL. It then opens the saved reader when the work is in the Library, else the live work page, and the reader restores from the installed progress.
- `fanficly://import?url=<AO3 url>`: `ImportOverlay` fetches the work, saves it as followed, downloads the EPUB and opens the saved reader. The share target turns a shared link or text into this route (`DeepLink.WorkIdFromText`); a non-AO3 link shows a warning.
- `fanficly://library?folder=<name>`: selects Library, then opens the folder.
- `fanficly://search?query=<prompt>`: stores the query under `search.pendingQuery`, selects Search and raises `Routes.RequestSearch`; `SearchScreen` runs it through `DeepLink.SearchPrompt` (saved-filter JSON from the widget becomes prompt text).

## Windows integrations

- **Widgets** (Windows 11 Widgets board, packaged only): `FanficlyWidgetProvider` (COM class `B46F852C…`) serves six Adaptive Card widgets in small and medium sizes: Continue reading (`LastRead`), Reading Streak, Subscriptions, Folder Shortcuts, Saved Searches, Recommendation. Windows starts `Fanficly.exe -RegisterProcessAsComServer`; `WidgetComServer` registers the class factory, makes `WidgetStorage` re-read `Shared/group.json` before each update, and exits when no widgets remain. The app pushes updates through `WidgetCenter.ReloadRequested`. Taps open `fanficly://` links. Widget glyphs and picker screenshots come from `Platform/Widgets/make_widget_art.py` (Pillow), which writes `WidgetGlyphs.g.cs` and `Assets/Widgets/*`; don't edit the generated file by hand.
- **Background task:** `windows.backgroundTasks` timer in the manifest, run through the Windows App SDK's `UniversalBGTask` and the COM class `8090198F…` (`Fanficly.exe -BackgroundTask`, `BackgroundTaskServer`/`BackgroundTaskFactory`).
- **Toasts:** `AppNotificationManager` (`Platform/Notifications.cs`), toast activation COM class `C19ED655…`.
- **Jump list:** `JumpListService.RefreshAsync` adds "Continue “<title>”" (the resume link) under Reading and "Go to" entries for Search, Library, Popular and Subscriptions (`-tab`). Skipped in demo mode.
- **Gamepad:** `GamepadInput` polls `Windows.Gaming.Input` every 16 ms while the window is active (and steps aside when XAML delivers gamepad keys itself). D-pad and left stick move focus; A invokes, toggles, expands or selects; B goes back; LB/RB switch tabs; LT/RT reach the screen as page-turn keys; the right stick scrolls; Menu toggles the sidebar; View toggles full screen. The screen gets first refusal through `HandleKey`: in the reader, LT/RT and D-pad left/right turn pages and LB/RB change chapter instead of switching tabs.
- **Store rating:** `StoreReviewRequester` (rating dialog when packaged, else the Store review page). `ReviewPromptPolicy` needs at least 3 finished stories, 3 reading days, 7 days since the first read, no ask in this version and 120 days since the last ask; never in demo mode. Settings → About also has "Rate in Microsoft Store".
- **Window:** Mica backdrop (Desktop Acrylic where Mica isn't supported), a custom `TitleBar` with back button and, in a narrow window, the pane toggle. The sidebar's `NavigationView` changes display mode at 641 and 1008 px wide. Zoom 50–200 % in 10 % steps (`app.zoomScale`, Ctrl+Plus/Minus/0, announced). F11 full screen. Window bounds are remembered (`app.windowBounds`); minimum 360×480.

## Sync folder backup (merge, never clobber)

Windows has no iCloud API, so sync is a folder the user picks in Settings → Sync (`settings.iCloudSyncEnabled`, `settings.syncFolder`), usually in OneDrive or iCloud Drive for Windows; Settings suggests both, including the Apple app's iCloud container folder (`iCloud~io~github~yennster~fanficly/Documents`) so a Mac and a PC can share one backup.

- **Backup unions, never overwrites.** `LibrarySyncManager.Backup` reads the existing `library_backup.json` and merges it with the local snapshot (`MergedBackup`, pure and tested) before writing: records only in the file are kept; on conflict the local record wins, except reading positions keep the newer `UpdatedAt`, chapters survive from whichever side has more, and stats merge conservatively (`MergedStat`: total seconds never below the sum of day buckets). A `.library_backup.json.icloud` placeholder means the file isn't downloaded, so the backup skips.
- **Restore is strictly forward** and runs automatically at launch when the file changed since this PC last applied or wrote it (`CloudBackupHasUnappliedChanges`, stamp `icloud.lastRestoredBackupDate`). Positions apply only when newer, follow/star/pin are OR-ed, folders union, `LastSeenChapterCount` only advances, chapters replace only when the backup has more. Keep any new restore field forward-only or the second device to open will corrupt data.
- **EPUB re-download:** the backup carries chapter text, not EPUB files; after a restore `RestoreDownloadCenter.ProposeRedownload` offers to download them again (the `RestoreBanner`, cancellable, paced by the throttle).
- The JSON format is the Swift app's (`LibraryBackupJson`, ISO 8601 dates). `SettingsBackup.Fields` carries the per-device reader keys for phone, pad, Mac and Windows (`reader.*.windows`) and each device's active profile (`activeProfileWindows` is Windows-only; the Swift decoder ignores keys it doesn't know). Not backed up: followed authors, recently viewed and tags (as in Swift).
- Deletions don't propagate between devices (union semantics); Settings → Sync → Clear Synced Data removes the synced files.

## Reader settings profiles

Typography settings are per device (`ReaderProfile.CurrentDevice = ReaderDevice.Windows`, keys like `reader.theme.windows`, active profile `reader.activeProfile.windows`). Profiles are JSON under `reader.profiles`, managed in Settings → Reader (new, rename, delete, switch). `ReaderProfileSyncStore` mirrors that key through the synced store, merging by case-insensitive name (`MergedProfiles`). Deletions are tombstones (`DeletedAt`), kept 90 days so they propagate; the newest stamp wins per name. Legacy unsuffixed keys migrate once (`MigrateLegacySettingsIfNeeded`).

## Reading stats

`ReadingStat` (one row per work id) snapshots the work's metadata, accumulates active reading seconds per day (`DaySeconds`, `yyyy-MM-dd`), and keeps `MaxProgress` (only advances) and `WorkIsComplete`. `ReadingStatsStore` upserts; `ReadingStatsAggregator.Summarize` rolls up a period (pure, tested). Words read are `Σ wordCount × MaxProgress`; stories read count only finished works (`MaxProgress ≥ 0.99`, or `≥ 0.95` for a complete work). `ReadingStatsBackfill` seeds rows once from older history. The Stats tab (`StatsScreen`) shows Week / Month / Year / All Time (default All Time) with paging, and shares a `WrapShareCard` image (Share, Save Image As, Copy Image). The Library shows a `LibraryStatsStrip` that opens Stats. Recording time and progress happens in the reader (see [the reader section](#the-reader-listen-export-and-reading-position)).

## Content safety

The app is 17+. `ContentSafetyViews.EnsureAgeGateAsync` asks once at first launch (skipped in demo mode). "Filter mature & explicit works" (`content.filterMatureExplicit`, default on) hides Mature and Explicit results in lists. Hidden works (`HiddenWork`, `HiddenWorkStore`) are filtered from lists and can be unhidden in Settings → Content & Safety. Hiding a work is "Hide this work" in the live work page's options menu (`HiddenWorkStore.Hide`, then the page closes); "Report this work" beside it opens AO3's abuse-report page in the browser.

## The reader, Listen, export and reading position

`Views/Reader` holds the screens and the WinUI reader; the pure logic it builds on is in Core and tested (`HTMLToAttributed`, `ChapterTracking`, `ChapterAnchors`, `ReaderAnchorSampler`, `ReaderPaginator`, `ReaderTheme`, `ReaderMetrics`, `ReaderSpread`, `PageAreaTracker`, `ReaderProfile`, `SentenceSegmenter`).

- **Routes** (`ReaderModule`): `Routes.WorkDetail` → `WorkDetailScreen` (fetches the work, records the view, then the reader); `Routes.SavedWork` → `SavedWorkReaderScreen.ForWork` (reads the saved chapter text offline when there is any, else fetches the work; falls back to the live page when the work isn't in the Library); `Routes.Resume` → installs progress (above) and opens one of the two. Both screens derive from `ReaderHostScreen`, which shows the loading or error view in the reader's colours, hides the window header once the reader exists (the reader draws its own top bar in its theme) and forwards `OnAppearing`/`OnDisappearing`/`OnRemoved` and `HandleKey` to `ReaderView`. `ReaderView` is not a screen: it's split by concern into `ReaderView.cs` (state, lifecycle, position, timing, keys, Narrator menu), `.Chrome` (top bar, chapter indicator, page footer, Listen bar, chapters and Aa menus, profiles), `.Content` (title and chapter headers), `.Continuous`, `.Paginated` and `.Pages`.
- **Toolbar.** The reader's own items: Back (only in full screen, when the stack can go back), Chapters (multi-chapter works), Aa (reader settings) and Full screen. The parent adds exactly two through `SetTrailingItems`: the work page adds Save to Library (`work.save`, a local follow) and Work options (`work.options`: `work.options.comments`, Share & export (`work.export`), `work.options.download`, `work.options.subscribe`, `work.options.report`, `work.options.hide`); the saved reader adds Comments (`work.comments`, which resolves missing chapter ids from AO3 once for per-chapter threads) and More (`work.options`: Share & export, Save Offline as `work.options.download`). Anything a menu item presents is deferred through the dispatcher (`Later`, `PresentLater`, `WorkExporter.Start`) so the flyout has closed first. Busy states swap the menu icon for a spinner.
- **Aa menu:** Listen to chapter (`reader.listen`, Ctrl+L), Profile (select, save current settings here, rename, delete, save current as new), Reading mode, Pages on screen (page-by-page only), Theme, Font, Bold text, and presets for text size, line spacing, paragraph spacing, character spacing and margins ("Page margins", `reader.spreadWidthPercent`, while a spread is on screen). Every value is a per-device key through `ReaderPrefs` (`ReaderProfile.DeviceKey`). Settings → Theme & typography has the same settings as sliders with a live preview. A change to a profile key queues a backup. The reader divides every typography value by `app.zoomScale`, so the app's zoom leaves story text alone.
- **Three reading modes** (`ReadingMode`, default continuous):
  - *Continuous scroll*: one `ItemsRepeater` (virtualized) of title header, chapter headers and paragraphs, converted off the UI thread; a chapter indicator bar (`reader.chapterIndicator`) for multi-chapter works; a tap anywhere toggles the controls.
  - *Swipe by chapter* (`paginated`): a `FlipView` with one vertically scrolling chapter per item (only the chapter on screen and its neighbours are built) and a `PipsPager`; Left/Right change chapter, Page Up/Down and Space scroll a screenful and roll into the next chapter at the end.
  - *Page-by-page*: a `FlipView` of pages, or spreads; selection is always a page id. Pages near the one on screen (two either side, or one spread) are built, the rest freed.
- **The text column** is `ReaderMetrics.TextColumnWidth(width, margins %)` with `limitLineLength: false`: the margins setting alone sets the line length, with no 40 em cap on Windows.
- **Two-page spread.** `reader.twoPageSpread` (default on). `ReaderSpread.LayoutFor`: at least 700 px wide, at least 1.15 × as wide as tall, and two pages of at least 280 px around a 56 px gutter, which is blank (no drawn crease). It's decided on the controls-up height (`PageAreaTracker.SpreadDecisionHeight`), so hiding the controls never switches between one page and two. Pages pair within a chapter; the footer reads "Pages 3–4 of 12". The title page keeps at least the default spread width so its metadata isn't crushed.
- **Pages fill the area on screen.** `PageAreaTracker`: a new width or window height starts over; otherwise pages shrink at once, so text never runs under the controls, and grow once the area holds still for 0.3 s (50 ms when the controls toggle). Pagination is debounced 60 ms and skipped when nothing in its `PaginationTrigger` changed. `ReaderTextMeasurer` measures real XAML `TextBlock`s built by the same `ReaderText` code that draws the page, parented in an invisible host inside the reader so they lay out at the window's scale; it clears its cache when the `XamlRoot` changes. Every page is checked against the drawn layout, including the neighbouring chapters (`ReaderPaginator.ChecksAdjacentChapters`, true by default on Windows), so pages fill to the last line with no reserve.
- **Re-paginating keeps the page in place.** The reader tracks where the page on screen begins (`PageStart`: paragraph, sentence, offset; in a spread, the left page's) and `ReaderPaginator.PerformPagination` breaks a page exactly there on a resize, a typography change, the controls or the Listen bar showing or hiding, so lines come and go at the foot instead of the page jumping. A kept page that pairing would put on the right is marked `StartsSpread`. A chapter change re-paginates around the new chapter.
- **Turning.** Keys reach `ReaderView.HandleKey` before anything else (unless a text box, menu item, slider, combo box, list item, radio button or pips pager has focus): Left/Right, Page Up/Down, Space and Shift+Space, LT/RT and D-pad left/right turn a page (the D-pad only while no button has focus, so it can still move along the toolbar) (or a spread; in the scrolling modes, a screenful, and Left/Right change chapter in swipe by chapter); Ctrl+Left/Right and LB/RB change chapter (announced "Chapter n of m"); Home/End go to the chapter's first or last page or edge; Up/Down scroll 48 px in the scrolling modes; Ctrl+L toggles Listen; Esc leaves full screen, else shows hidden controls. Pointer: the outer thirds of the page area turn (in a spread, the left page's outer side goes back), the middle third toggles the controls, the mouse wheel turns one page per notch with a 300 ms pause (a page that overflows scrolls first), a quick sideways pen stroke turns, and touch swipes the `FlipView`. Ctrl+wheel never zooms the reader. Page turns animate only when "Page-turn animation" and Windows' animation setting allow.
- **Narrator.** The reading area's context menu (right-click, press and hold, Shift+F10, Menu key) holds Next/Previous page (page-by-page), Next/Previous chapter, Show/Hide reader controls and Listen to chapter / Stop listening; page, chapter and controls changes are announced. Story text isn't selectable (`IsTextSelectionEnabled = false`). Regions are `RegionGrid`s, which give a plain grid an automation peer so its id is visible.
- **Automation ids:** `reader.root`, `reader.content` (the body of whichever mode), `reader.back`, `reader.chapterTitle`, `reader.chapters`, `reader.aa`, `reader.fullscreen`, `reader.listen`, `reader.chapterIndicator`, `reader.pageFooter` (its name is "<chapter>, page n of m" / "pages n–m of t", or "Laying out pages"), `reader.page.left` / `reader.page.right` (only the page or spread on screen, named "Page n of m, chapter c"), `reader.narrationBar`, `speech.playPause`, `speech.chapter`, `speech.rate`, `speech.stop`, plus the parents' `work.*` ids above.
- **Full screen** is the window's (F11, the button): `EnterImmersive` hides the sidebar and title bar (`MainWindow.SetChromeHidden`) and the reader's controls; leaving the reader leaves full screen.
- **Reading position** is saved per work (`ReadingProgress`: chapter, paragraph, plus a 0…1 fraction) through `ReadingProgressStore`, which also stamps `Work.LastRead*`, the streak, the last-read widget and the jump list. Saves are throttled to one per 1.5 s and forced on leaving, minimizing and closing the window. Continuous and swipe-by-chapter report anchor offsets (every `ChapterAnchors.AnchorStride` (6) paragraphs plus always the last) to `ReaderAnchorSampler`, which is resize-aware and takes a trailing sample where scrolling settles; the end of content is detected explicitly (`ChapterTracking.EndOfContentAnchor`), and page-by-page anchors to the last paragraph on the work's final page (or the right page of the final spread), so a story read to the last line reaches 100 % and counts as finished. Restore: continuous lands on the paragraph repeatedly while heights settle, swipe by chapter restores its paragraph once, page-by-page selects the page holding the anchor. A width change re-anchors the scrolling modes to the paragraph that was on top. Switching modes keeps the live anchor.
- **Reading time** counts only while the reader is the screen on top and the window isn't minimized (`MainWindow.VisibilityChanged`), capped at 4 hours a span, flushed when the reader leaves the top, the window is minimized or closes, and checkpointed with progress saves once a span passes 2 minutes. Words are credited only up to the progress reached. The read that finishes a story calls `ReviewPrompter.StoryFinished`, and `ReaderClosed` is asked when the reader is popped (`Removed`), never when a screen is pushed over it.
- **Story images** are opt-in (`reader.showImages`, default off). When on, images render in fixed-height slots (`ReaderInlineImage.SlotHeight`, 240) in every mode so loading can't move the text; the paginator budgets the same height. `HTMLToAttributed.ResolvedImageUrl` allows only https (http upgraded, protocol-relative resolved) and rejects `data:`, `javascript:`, root-relative and `archiveofourown.org` sources. `ReaderText.ImageSlot` loads them with a XAML `BitmapImage`, outside `IAO3Client`: no throttle, and never the client's AO3 cookies. A failed load shows "Image unavailable". Images are never saved with downloads, so offline they don't load. Toggling the setting shifts paragraph indices, so a saved position can drift by the number of images above it (as in Swift).
- **Listen (text to speech)** is on-device: `SpeechController` renders each paragraph with `Windows.Media.SpeechSynthesis` (voice `reader.ttsVoiceId`, empty = system default; rate `reader.ttsRate` on the Apple scale, 0.5 = 1.0×) a few paragraphs ahead into a `MediaPlaybackList`, so playback is gapless. It speaks `HTMLToAttributed.SpeechParagraphs`, index-aligned with the rendered paragraphs (scene breaks and images are empty, unspoken slots), starts from the current anchor, highlights the spoken paragraph (a flush background, no reflow) and keeps it in view or turns to its page, and advances chapters on its own (`Finished` → `AdvanceNarration`). The Listen bar (`reader.narrationBar`) has previous/next paragraph, play/pause, a chapter picker (multi-chapter), "¶ x / y", a speed menu (0.5×–2.0×, persisted) and stop. `SystemMediaTransportControls` give media keys, headsets and the Windows media flyout play/pause/next/previous and show chapter, author and work. Narration keeps playing while the window is minimized and stops when the reader leaves the top. If synthesis fails, an InfoBar points to Settings → Time & language → Speech.
- **Export** (`WorkExporter`, owned by the screen, never by menu content): "Share & export…" lists AZW3, EPUB, MOBI, PDF and HTML for the share sheet (`DataTransferManager` for the window), and "Save a copy as" the same formats through a `FileSavePicker`. The download goes through `ExportWorkAsync` (so the throttle applies), is announced, and failures show an alert.
- **Download / Save Offline** saves the full work (`WorkPersistence.Upsert`) and its EPUB (`DownloadEpubAsync`); the item then reads "Downloaded".
- **Keep screen awake:** `reader.keepScreenAwake` (default on) holds a `DisplayRequest` while the reader is on top and releases it when it leaves.
- **Layout UI tests:** `ReaderLayoutTests` (see [Tests](#tests)). Run them after any change to the reader's layout, the measurer or the paginator.

## Store art capture mode

`-captureScale N` (demo mode only, `Platform/CaptureMode.cs`) draws the whole window at N× through a `ScaleTransform` on the root, hides the system caption buttons (drawn instead as glyphs in the title bar, since they can't scale), and subclasses the window (`WM_GETMINMAXINFO`) so it may be larger than the screen. The UI tests' `store` sizes use it so a small CI screen still gives 4K pictures; `PrintWindow` draws the off-screen part. Keyboard and UI Automation patterns reach the whole window, mouse clicks only the on-screen part, so Store-size steps drive the app by keyboard and `Invoke`. It changes nothing outside demo mode.

## Privacy posture (do not regress)

The app stores nothing off the PC except, when the user turns sync on, the backup and synced-settings files in a folder they choose (their own OneDrive, iCloud Drive or other synced folder). It talks only to archiveofourown.org, plus image hosts when the user opts into story images. No analytics, crash reporting or remote logging. The only secret is AO3's session cookie, DPAPI-encrypted. See `PRIVACY.md`; it's the Store listing's privacy policy, so update it with any change to what's stored or sent.

## CI

`.github/workflows/windows-ci.yml` runs on every pull request to `windows` and on pushes to `windows` that touch `windows/` or the Windows workflows. A newer push waits for the running build rather than cancelling it.

- **Core tests:** `dotnet test` in Release on `windows-latest`, results as `core-test-results`.
- **App (x64, ARM64):** unpackaged self-contained Debug builds; the x64 build is launched in demo mode and photographed (`launch-screenshot`).
- **UI tests and screenshots:** builds the app and UI tests, sets a 1920×1200 display, installs the Windows 11 icon font, runs `SmokeTests`, then `ScreenshotTests` (the three sizes, the store sizes, the reader pages and the icon gallery), then `ReaderLayoutTests`, charts the icon fonts, builds the Store art into `ui-screenshots/store-art/` (not committed) with `make_store_art.py --out`, prints the pictures into the log and uploads `ui-screenshots` (including `icons/` and `reader-layout/`) and `ui-test-results`. The screenshot and reader layout steps run even when an earlier step failed.
- **MSIX bundle:** after Core tests and App pass, MSBuild builds the Release (Native AOT) x64 + ARM64 Store upload (`msix-bundle`). This is the only job that compiles with AOT, so it's where trim and AOT problems surface.

`windows-screenshots.yml` (`contents: write`; a push to `windows` whose message contains `[screenshots]`, or a manual run once it's on the default branch) builds the app, runs `ScreenshotTests`, copies the pictures with `windows/scripts/Copy-Screenshots.ps1` to `docs/screenshots/windows/{desktop,tablet,compact}/`, builds the Store art with `windows/scripts/make_store_art.py` (ten 3840×2160 slides with `captions.txt` in `windows/store/screenshots/en-us/`, the hero, box and poster in `windows/store/images/en-us/`, and `docs/screenshots/windows/showcase.jpg`), and commits them to the branch it ran on. That's release housekeeping: a maintainer runs it, roadmap PRs don't.

`windows-store.yml` (a `windows-v*` tag or a manual run) builds, runs the Windows App Certification Kit, submits to the Store (environment `microsoft-store`) and makes a GitHub release; see `MICROSOFT_STORE.md`. CI picks the runner image's tools; don't hard-code machine-specific paths.

## Autonomous roadmap work

The backlog is [`docs/ROADMAP.md`](docs/ROADMAP.md). Windows items are numbered from **RM-101** so they never collide with the Apple roadmap's IDs on `main`. This loop is for an agent told to "pick a roadmap item and ship a PR". It ends at an **open PR against `windows`**. A human merges.

**Hard rules**
- Never merge a PR, enable auto-merge, approve your own PR, push to `windows` or `main`, force-push a branch you didn't create, or edit CI to make it pass.
- Never touch release housekeeping: `windows/store/` (version, listing, screenshots), the manifest's `Identity` and version, `docs/screenshots/`, signing settings, the Store workflow.
- Don't change the Swift sources; they are the reference. One roadmap item per PR, one agent per item; don't start an item that's claimed.
- Don't reformat or refactor what the item doesn't need. Don't add dependencies.
- Don't create GitHub issues, labels or releases. Anything outward-facing beyond the one PR needs the user's say-so.

**The loop**
1. **Orient.** `git fetch origin && git checkout -b tmp origin/windows`; read Conventions, "Things to know about AO3" and the roadmap's principles.
2. **Pick.** `bin/roadmap.sh free` (needs `gh`) lists open, unclaimed items from this branch's roadmap. Take the lowest-numbered `S` or `M` item unless the user named one; prefer `Validation: unit` when you can't run Windows. If nothing is free, stop and say so.
3. **Verify it's real.** Read the files the item names. If it's already done, wrong, or bigger than `M`, open a roadmap-only PR that fixes or splits it, or report back.
4. **Claim before coding.** Branch `roadmap/RM-1nn-short-slug` from `origin/windows`, push, and open a **draft PR with base `windows`** (`gh pr create --draft --base windows`) titled `RM-1nn: <title>`. Re-run `bin/roadmap.sh`; if another claim for the same ID appeared, close yours and pick again.
5. **Implement the smallest slice** that meets "Done when", following the Conventions (the client seam, pure parsers, `KeyValueStores`, Narrator names, AOT rules).
6. **Test.** Core tests for every behaviour change; a smoke step for a new tab or route.
7. **Validate honestly** (below).
8. **Update the roadmap** in the same PR: that item's `Status` to `done`, nothing else. Update this file if you added a convention or found a gotcha.
9. **Commit, push, mark ready** (`gh pr ready`) when CI is green or the failure is explained. Report the item, the PR URL, what you tested and what a person should look at on Windows.

### Which machine you're on

- **Windows:** run the Core tests, build and run the app in demo mode, and run the smoke tests for UI changes (and `ReaderLayoutTests` for reader layout changes). For packaging-related changes, build the Release bundle with MSBuild.
- **Linux or macOS:** install the .NET 10 SDK (the repo's `.agents/setup` prepares the Apple-side tooling only). You can run `dotnet test tests/Fanficly.Core.Tests` and compile the app and UI tests, which catches most errors. You can't run the app, the UI tests or the AOT build; CI does those on the PR (`gh pr checks <pr> --watch`). Keep the PR in draft until the build and tests are green, and say plainly what you couldn't run.
- Either way, never claim a test passed that you didn't see pass.

**If you get stuck:** three failed CI attempts at the same error, or AO3 behaviour you can't confirm without the live site → stop, leave the draft PR with what you learned, and say what you need. Scrape fixtures must come from real pages.

**Adding to the roadmap:** append items with the next free `RM-1nn`; never renumber or reuse an ID. Keep each item `S` or `M` with a concrete "Done when".
