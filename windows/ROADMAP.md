# Fanficly for Windows roadmap

Last reviewed: 2026-10-16, before the first Store release (`windows/store/version.txt`: 1.0). Written from the code: every item names the files it touches and what already exists.

This is the Windows app's backlog. The Apple app's roadmap is [`apple/docs/ROADMAP.md`](../apple/docs/ROADMAP.md). Windows items are numbered from **RM-101** so the two never share an ID; their branches and PRs target `main`, like the Apple app's. Agents: read [Autonomous roadmap work](AGENTS.md#autonomous-roadmap-work) in AGENTS.md before picking anything. Humans: reorder, add and strike items freely. Claims are PRs, never issue assignments.

## Where the app is

Fanficly for Windows is a native WinUI 3 port of the Swift app, compiled with Native AOT and packaged as an MSIX bundle for x64 and ARM64. What's in the tree and working:

- **Shell:** the sidebar (`NavigationView`) with every tab, and a title bar with a back button. The back stack is kept per tab.
- **Keyboard and input:**
  - Ctrl+1–9 and Ctrl+, shortcuts, and keyboard shortcuts throughout, listed in Settings.
  - Zoom from 50 to 200 %, and F11 full screen.
  - Xbox controller navigation.
- **Window:** Mica, light, dark and high-contrast themes, and remembered window placement.
- **Search:**
  - typeahead tag suggestions, filter chips and the full filter sheet;
  - saved and recent searches, and search tips;
  - Cancel for slow searches.
- **Browse and Popular:** Browse by media category with live fandom lists, filtered works, and saved filters. Popular uses a daily snapshot with a curated fallback.
- **Library:**
  - All, Starred, Downloaded and Folders, with folders, sorting, pins and stars;
  - offline EPUB downloads and sharing;
  - a reading-stats strip that opens the Stats tab.
- **History, authors and account:**
  - Recently Viewed, followed authors, and an author's works page with a Follow button.
  - AO3 sign-in, Bookmarks, and Subscriptions, which shows AO3 subscriptions alongside local follows.
  - Per-chapter comments with a composer, a page of threads at a time ("Load more comments").
- **Stats:** week, month, year and all-time totals, plus a shareable wrap-up card.
- **Updates and notifications:** new-chapter and new-work checks, in the app and from a timer background task. Toasts open the work or author they're about.
- **Sync:** library backup and restore through a user-chosen folder (OneDrive or iCloud Drive), in the Swift backup format, with merge-never-clobber backups, forward-only restores and EPUB re-download after a restore.
- **Windows integrations:**
  - six Widgets-board widgets;
  - a jump list;
  - the share target, dropping or pasting an AO3 link, and the `fanficly://` links (resume, import, library folder, search);
  - single-instance activation;
  - the Store rating prompt.
- **Settings:**
  - Account, Reader (profiles, typography, preview, voice), Appearance, Library, Sync, Notifications;
  - Content & Safety (17+ gate, mature filter, hidden works), Input, Privacy and About.
- **Reader:** `Views/Reader` registers `Routes.WorkDetail`, `SavedWork` and `Resume`.
  - The live work page and the saved-work reader, which reads offline from saved chapter text.
  - Three reading modes: continuous scroll, swipe by chapter, and page by page with a two-page spread on wide windows. Pages fill the window and keep their place when re-paginated.
  - Page turns by keyboard, mouse wheel, pen, touch and controller, with Narrator menu actions.
  - Typography presets and profiles, full screen, and keep screen awake.
  - Listen (on-device speech, highlighted, with media keys).
  - Opt-in story images, and export in five formats to the share sheet or a file.
  - Saved progress, resume, reading time and the review prompt's trigger.
  - Comments, download, subscribe, report and hide from the work page.
- **Tests:** 448 Core unit tests run on any OS. Windows CI also runs FlaUI smoke, screenshot and reader layout tests, and builds the Store bundle. A manual workflow captures and commits the screenshots.

## Principles every item must respect

1. **Privacy posture.** Nothing leaves the PC except requests to AO3 and files in the user's own sync folder. No analytics, no SDKs, no off-device AI. Update `PRIVACY.md` (the Store listing's privacy policy) with any change to what's stored or sent.
2. **Good guest to AO3.** Everything goes through `IAO3Client` and its 1 request/second throttle. Add as few requests as possible, never scrape in parallel, never retry a POST.
3. **Never guess in search.** See "Search never silently reinterprets words" in AGENTS.md.
4. **Forward-only sync.** New persisted fields obey the restore rules (newer wins, OR for flags, never regress), and the backup stays readable by the Swift app.
5. **Native AOT.** No reflection-based JSON or binding; the Release bundle must build without new trim or AOT warnings.
6. **Parity with the Swift app.** Port behaviour faithfully; a deliberate Windows difference is noted in code.

## Non-goals

Servers or accounts of our own, ads, telemetry, a "trending" feed we'd have to scrape heavily, posting or editing works, off-device recommendation, images on by default, auto-hiding reader chrome, and haptics (hidden on Windows on purpose).

## How items are written

Each item is a heading `### RM-nnn — Title` followed by a `Status:` line that `.github/scripts/roadmap.sh` reads. IDs are permanent: never renumber, never reuse. New ideas get the next free number from RM-101 up.

- **Status:** `open` (free to claim), `claimed` (an open PR or `roadmap/RM-nnn-*` branch exists; the PR is the claim, not this file), `done`, or `exception` (an Apple feature Windows can't support; the item says why, and it isn't built).
- **Size:** `S` is about one file plus tests, `M` is a few files plus tests. Anything bigger is split into new `S`/`M` items before it's started.
- **Validation:** `unit` = provable by `dotnet test tests/Fanficly.Core.Tests` on any OS. `windows` = also needs a person (or the UI tests) on Windows; say what to look at in the PR.

---

## Now (small, self-contained)

### RM-101 — Downloaded EPUBs don't show as Downloaded
- **Status:** done · **Size:** S · **Validation:** unit + windows
- **Why:** `AppServices` and `FanficlyBackgroundTask` construct `AO3Client` with `AppPaths.LocalData`, so `DownloadEpubAsync` writes `LocalData\<id>.epub`. `WorkPersistence.EpubPath` looks in `AppPaths.Downloads` (`WorkPersistence.LibraryFolder`). The file is downloaded, but the Library's Downloaded filter, the "Remove Download" action and the restore re-download offer never see it.
- **Scope:**
  - Give the client the same folder `WorkPersistence` uses (`AppPaths.Downloads`) in both places.
  - ~~At launch, move any `LocalData\<digits>.epub` left by earlier builds into `Downloads`.~~ Not needed: no build with the old location ever shipped.
  - Keep `AO3Client`'s constructor contract; don't make Core depend on `AppPaths`.
- **Done when:**
  - A Core test shows that a client built with `WorkPersistence.LibraryFolder` returns a path equal to `WorkPersistence.EpubTargetPath(id)` (through a fake handler).
  - On Windows, Download for Offline marks the row Downloaded.
- **Touches:** `windows/src/Fanficly.App/Services/AppServices.cs`, `Platform/BackgroundRefreshTask.cs`, `tests/Fanficly.Core.Tests/AO3ClientTests.cs`.

### RM-102 — Make the saved-search widget run saved filters
- **Status:** done · **Size:** S · **Validation:** unit
- **Why:** The Saved Searches widget sends a saved filter's JSON in `fanficly://search?query=`, as the Swift widget does. `SearchScreen.ConsumePendingQuery` reads the query as prompt syntax (`SearchSyntax.Parse`), so a tapped saved filter runs as a keyword search for its JSON. Saved searches work, because they send prompt text. The Swift app has the same gap (RM-020 on `main`).
- **Scope:** In the consumer, try `AO3SearchFilters.FromSavedJson` first when the query starts with `{`, else parse it as a prompt. Put the decision in a pure, tested helper in Core. Leave the widget's URL format alone, so links from the Swift widget's format keep working.
- **Done when:**
  - A round-trip test covers saved filters → `DeepLink.SearchUri` → pending query → equal filters.
  - A prompt query still parses as before, and malformed JSON degrades to a keyword search.
- **Touches:** `windows/src/Fanficly.App/Views/Search/SearchScreen.cs`, `windows/src/Fanficly.Core/Search/SearchSyntax.cs` (or `AO3SearchFilters.cs`), tests.

### RM-103 — Back up the Windows reader settings
- **Status:** done · **Size:** S · **Validation:** unit
- **Why:** `SettingsBackup.Fields` (in `Sync/LibraryBackup.cs`) lists the per-device reader keys for phone, pad and Mac only, and the active profile for those three. This PC's `reader.*.windows` settings and `reader.activeProfile.windows` aren't in the backup, so a restore on a new PC loses them.
- **Scope:**
  - Add `Windows` to the per-device loop and an `activeProfileWindows` field.
  - Check that the Swift app's decoder ignores keys it doesn't know (Swift's `Codable` does by default) and say so in the PR.
- **Done when:**
  - `LibraryBackupJsonTests` round-trips the new fields.
  - A backup written by the Swift app (no Windows fields) still restores.
  - A restore never overwrites a local value with a missing one.
- **Touches:** `windows/src/Fanficly.Core/Sync/LibraryBackup.cs`, `tests/Fanficly.Core.Tests/LibraryBackupJsonTests.cs`.

### RM-104 — Screenshot test looks for the wrong fandom id
- **Status:** done · **Size:** S · **Validation:** windows
- **Why:** `ScreenshotTests` waits for an automation id starting with `fandom.`, but `CategoryFandomsScreen` names its rows `browse.fandom.<i>`. The step passes only through its header-title fallback, so the `05-browse-fandoms` shot can be taken before the list has loaded.
- **Scope:** Wait for `browse.fandom.` in the step.
- **Done when:** CI's `ui-screenshots` artifact shows the fandom list populated at all three sizes.
- **Touches:** `windows/tests/Fanficly.UITests/ScreenshotTests.cs`.

### RM-120 — A visible way out of full screen
- **Status:** open · **Size:** S · **Validation:** windows
- **Why:** The Apple app's reader no longer hides its toolbar in full screen: only the bar's background goes, so the system back button and the Show reader controls item stay on screen in every reading mode (`ReaderView.swift`), because on iPhone Duo the invisible middle-of-the-page tap was the only way out and could fail, trapping the reader. Here full screen and hidden controls also leave only invisible ways back (Esc, F11, the middle third, the story's context menu; the title-bar back button only in immersive), so a tablet with no keyboard depends on the middle tap alone.
- **Scope:** While `_isUIMinimized`, keep the back button and the full-screen button visible in the standard WinUI controls (the title bar's back button and the reader header's `_fullScreenButton`, on a transparent background), labeled Show reader controls, in every reading mode, one page or two. No custom-drawn controls.
- **Done when:** a reader UI test hides the controls, finds both buttons, brings the controls back with one and leaves the reader with the other.
- **Touches:** `windows/src/Fanficly.App/Views/Reader/ReaderView.Chrome.cs`, `ReaderView.cs`, `windows/tests/Fanficly.UITests/`.

## Next

### RM-105 — Paste or drop an AO3 link to open it
- **Status:** done · **Size:** S · **Validation:** unit + windows
- **Why:** The Swift app imports links dropped on the window or pasted. On Windows only the share target and `fanficly://import` reach `ImportOverlay`, although its doc comment already mentions pasted and dropped links.
- **Scope:**
  - Accept a dropped link or text on the main window (`AllowDrop`, `DragOver`, `Drop`).
  - Accept Ctrl+V when no text box has focus (through `MainWindow`'s key handling).
  - Extract the work id with `DeepLink.WorkIdFromText`, then call `AppHost.OpenUri(DeepLink.ImportUri(...))`. A non-AO3 link shows the same warning as the share target.
  - Add the shortcut to `ShortcutsScreen`.
- **Done when:**
  - `DeepLinkTests` cover the text shapes being handled (a work URL, a chapter URL, a URL inside other text, a non-AO3 link).
  - On Windows, dropping a link from a browser opens the import.
- **Touches:** `windows/src/Fanficly.App/Shell/MainWindow.cs`, `Services/AppRouting.cs`, `Views/Settings/ShortcutsScreen.cs`, `Views/Import/ImportOverlay.cs` (comment).

### RM-106 — Hide a work and subscribe from the work page
- **Status:** done · **Size:** M · **Validation:** windows
- **Why:** Hidden works can be unhidden in Settings, and `AO3Client.SubscribeToWorkAsync` exists, but no screen hides a work or subscribes to one. In the Swift app both live in the work page's options menu.
- **Scope:**
  - Add Hide and Subscribe to `WorkDetail`'s options menu. Hide uses `HiddenWorkStore.Hide` and goes back. Subscribe is login-gated.
  - Defer any dialog until the menu has closed.
  - ~~Add a Hide action to search and browse rows' context menus.~~ Dropped for parity: the Swift app's row menus have no Hide either.
  - **Start only after the reader port has merged.**
- **Done when:**
  - A hidden work disappears from Search, Browse and Bookmarks and appears in Settings → Content & Safety → Hidden works.
  - Subscribe shows the result and the work appears in Subscriptions after a refresh.
  - Narrator announces both.
- **Touches:** `windows/src/Fanficly.App/Views/Reader/*` (the work page), `Views/Shared/WorkRow.cs`, `Views/Search/SearchScreen.cs`.

### RM-107 — Reader layout UI tests
- **Status:** done · **Size:** M · **Validation:** windows
- **Why:** The Swift app's `ReaderLayoutTests` catch page-by-page layout regressions; Windows has only the Core paginator tests with a fake measurer.
- **Scope:**
  - Add `ReaderLayoutTests` to `Fanficly.UITests`. Launch with `-demoMode` and `-demoLongChapters`, open a demo work in page-by-page, and check:
    - the page footer sits on the bottom edge;
    - the text ends within a line of it;
    - the page keeps its first words when the controls hide and show;
    - a wide window shows a two-page spread exactly when `ReaderSpread` says so.
  - Save a screenshot per step.
  - **Start only after the reader port has merged.**
- **Done when:** the tests pass in CI at the desktop and compact sizes, and CI uploads their screenshots.
- **Touches:** `windows/tests/Fanficly.UITests/`, `.github/workflows/windows-ci.yml` (one new step; ask first).

### RM-112 — Marked for Later section
- **Status:** done · **Size:** M · **Validation:** unit + windows
- **Why:** On the AO3 website a signed-in reader has a Marked for Later list (works saved with "Mark for Later" to read next). The maintainer asked (2026-10-18) for a Marked for Later section in every version of the app. The Apple app's item is RM-023 on `main`; keep the two the same in name and behavior.
- **Scope:**
  - Add `FetchMarkedForLaterAsync(username, page)` to `IAO3Client` for `/users/<name>/readings?show=to-read`, with an endpoint builder next to `UserBookmarks`. Reuse `SearchResultsParser` with the readings page's blurb selector, as `FetchBookmarksAsync` does.
  - Add a sign-in-gated "Marked for Later" tab built like `BookmarksScreen`: paginated, content filter applied, rows open the live work page.
  - Add the tab per "Add a tab" in AGENTS.md: the `SidebarItem` case after Bookmarks with raw value `markedForLater` (the Swift app's, since `app.selectedTabRaw` is shared), its title and icon (in `Symbols` if new), and its `Tabs.Register` from `AccountModule`. Ctrl+1–9 are all taken, so it gets no Ctrl+number shortcut and nothing is renumbered (the Swift app does the same); make `ShortcutLabel` show none for it rather than "Ctrl+10". Add `markedForLater` to the `-tab` values in AGENTS.md.
  - Read-only: adding or removing a mark is a later item.
- **Open question:** confirm the readings page's markup (blurb class, where the work id lives) from a real saved page before writing the fixture; don't guess it. If RM-023 lands first, use its fixture.
- **Done when:**
  - `SearchResultsParserTests` cover a real-page fixture (works listed, empty list, sign-in page fails closed) and `AO3EndpointsTests` cover the URL and paging.
  - Every `IAO3Client` implementation supports the new method (`MockAO3Client`, `DemoAO3Client`, `StubAO3Client`, `PollerFakeClient` and the tests' other doubles), or it gets a default interface implementation as `FetchWorkChapterAsync` has.
  - `SmokeTests` cover the new tab (its tab list and `-tab markedForLater`).
  - The PR lists what to check on Windows: the tab signed out (sign-in prompt) and signed in.
- **Touches:** `windows/src/Fanficly.Core/Networking/{IAO3Client,AO3Client,AO3Endpoints,MockAO3Client}.cs`, `Demo/DemoAO3Client.cs`, `Settings/SidebarItem.cs`, `windows/src/Fanficly.App/Shell/SidebarItem.cs`, `Views/Account/BookmarksScreen.cs` (pattern), `Views/Account/AccountModule.cs`, `Views/Settings/ShortcutsScreen.cs`, `UI/Symbols.cs`, `windows/tests/Fanficly.Core.Tests/`, `windows/tests/Fanficly.UITests/SmokeTests.cs`, AGENTS.md.

### RM-114 — AO3 reading history
- **Status:** done · **Size:** M · **Validation:** unit + windows
- **Why:** The Windows half of the Apple app's RM-015 (#52): a signed-in reader's AO3 history (`/users/<name>/readings`) had no place in the app. Keep the two the same in name and behavior.
- **Scope:** `FetchReadingHistoryAsync(username, page)` on `IAO3Client` with `AO3Endpoints.UserReadingHistory`, parsed by RM-112's `SearchResultsParser.ParseReadings`; an "AO3 History" tab after Marked for Later (raw value `ao3History`, the Swift app's), shown by `ReadingListScreen`, sign-in gated and read-only, with no Ctrl+number. Separate from the on-device Recently Viewed tab.
- **Done when:** parser and endpoint tests, the smoke test opening the tab from the sidebar and `-tab ao3History`, and the PR lists what to check on Windows: the tab signed out and signed in.

### RM-115 — Leave kudos
- **Status:** done · **Size:** M · **Validation:** unit + windows
- **Why:** The Windows port of the Apple app's RM-013 (`AO3Client.leaveKudos`, `KudosGiver`, `KudosStore`), so every app can leave kudos.
- **Scope:** "Leave Kudos" in the work page's options menu and the saved reader's More menu: sign-in gated, once per work and remembered per account so it reads "Kudos Left", one POST that is never retried. The request replays the work page's `form#new_kudo` to `/kudos.js`, as AO3's own button does (201, or 422 with `{"error_message": …}`); "already left kudos" counts as left.
- **Done when:** `AO3ClientTests` and `KudosTests` cover the POST, the duplicate answer, a refusal, a signed-out page, no kudos button and no retry; the PR lists what to check on Windows.
- **Touches:** `windows/src/Fanficly.Core/Networking/`, `Parsing/WorkPageParser.cs`, `Library/Kudos.cs`, `windows/src/Fanficly.App/Views/Reader/{WorkKudos,WorkDetailScreen,SavedWorkReaderScreen}.cs`, `UI/Symbols.cs`, `windows/tests/Fanficly.Core.Tests/`.

### RM-119 — Create and edit AO3 bookmarks
- **Status:** done · **Size:** M · **Validation:** unit + windows
- **Why:** The Bookmarks tab is read-only. The Apple app added "Bookmark on AO3" (RM-014 on `main`: `AO3BookmarkForm`, `BookmarkFormParser`, `AO3BookmarkSheet`); this ports it.
- **Scope:**
  - `FetchBookmarkFormAsync(workId)` reads the bookmark form AO3 renders on the work page for a signed-in user (`BookmarkFormParser`, prefilled from an existing bookmark), and `SaveBookmarkAsync(form)` posts it back to its own action (`/works/<id>/bookmarks`, or `/bookmarks/<id>` with `_method=put`) with the token. Never retried.
  - A `BookmarkScreen` (Notes, Your tags, Rec, Private bookmark; Cancel and Save), opened from "Bookmark on AO3" in the live work page's options menu and the saved reader's More menu (`work.options.bookmark`); signed out the item opens sign-in.
- **Done when:** parser and client tests cover a new and an existing bookmark, the posted fields, a login redirect, AO3's error list, and a create that stays on the form; every `IAO3Client` implementation has the two methods.
- **Touches:** `windows/src/Fanficly.Core/Networking/*`, `Parsing/WorkPageParser.cs`, `Demo/DemoAO3Client.cs`, `windows/src/Fanficly.App/Views/Account/`, `Views/Reader/{WorkDetailScreen,SavedWorkReaderScreen}.cs`, `Views/Routes.cs`, `windows/tests/Fanficly.Core.Tests/`.

## Later (needs design, or a person on Windows)

### RM-108 — Find library works from Windows Search
- **Status:** exception · **Size:** M · **Validation:** windows
- **Why:** The Swift app puts every library work in Spotlight and opens a tapped result (RM-016 in `apple/docs/ROADMAP.md`). Core calls `LibraryHooks.SearchIndexer` (`IWorkSearchIndexer`) for this, but Windows installs no indexer.
- **Why it's an exception:** Windows 11 has no public API for an app to add its own items to Windows Search. The taskbar and Start search show apps, settings, files in indexed folders and web results only. The public WinRT `Windows.Storage.Search.ContentIndexer` builds an index only the app itself can query; its items never appear in taskbar or Start search. The Windows App SDK's `AppContentIndex` is a limited-access feature (it needs a token from Microsoft) and is queried by the app itself, not shown in Windows Search. The only workaround is to write a shortcut file per work into an indexed folder such as Documents, which clutters a folder the user sees and, when OneDrive backs up Documents, uploads the library's titles, against principle 1.
- **Already covered:** the App Shortcut half of RM-016 ("Continue Reading") is the jump list's "Continue “<title>”" entry and the Continue reading widget, both opening `fanficly://resume/<id>`.
- **Revisit when:** Windows offers a public search-provider API for packaged apps, or `AppContentIndex` leaves limited access and its results reach Windows Search.

### RM-109 — Localization groundwork
- **Status:** done · **Size:** M · **Validation:** windows
- **Why:** Every string is English and inline in C#.
- **Scope:**
  - Add a `.resw` resource file and a small lookup helper.
  - Move one screen's strings (Settings → About) to it as the pattern.
  - Document the pattern in AGENTS.md.
  - Check it under Native AOT and in the MSIX (MakePri runs only on Windows).
- **Done when:** the About screen reads its strings from resources in the packaged Release build, with no change in English.
- **Touches:** `windows/src/Fanficly.App/Views/Settings/AboutScreen.cs`, a new resource file, `Fanficly.App.csproj` if needed.

### RM-117 — Move the remaining screens' strings to the resource table
- **Status:** open · **Size:** M (one screen per PR) · **Validation:** unit + windows
- **Why:** RM-109 added `Strings/en-US/Resources.resw` and `Strings.Get`, and moved Settings → About. Every other screen's text is still inline C#.
- **Scope:** One screen (or screen family) per PR, following the convention in AGENTS.md: the rest of Settings, Search and its filters, Browse and Popular, the reader, Library and Stats, Subscriptions and Bookmarks, sign-in, dialogs, toasts and the widget. Do not translate. AO3 tag and category names stay verbatim.
- **Done when:** each screen's user-facing literals are `Strings.Get` keys with entries in the table, `ResourceStringsTests` passes, and English reads the same.
- **Touches:** the screen's file under `src/Fanficly.App/Views/`, `Strings/en-US/Resources.resw`.
- **Apple counterpart:** RM-024 (after RM-017).

### RM-110 — Move the Windows app onto `main` (one branch, a folder per platform)
- **Status:** done · maintainer only · **Size:** M · **Validation:** windows
- **Why:** A long-lived `windows` branch drifts from `main`, and every shared fix (docs, assets, release notes, AGENTS.md) has to be copied by hand. One `main` with a folder per platform keeps the separation without that cost. Do this when the Windows app is ready to ship from `main`.
- **Scope:**
  - First `git rm -r website` on `windows`: it's only a placeholder so Vercel (Root Directory `website`) skips builds of `windows` PRs. With it gone, the merge brings in `main`'s real `website/` without an add/add conflict; resolving that conflict for the windows side would quietly replace the site's `vercel.json` with `ignoreCommand: "exit 0"` and stop production deploys.
  - Merge `windows` into `main` (a merge, not a squash, so history stays) with the Windows app in `windows/` beside the Apple code; optionally move the Apple app into `apple/` in its own PR first.
  - Keep one `main` branch; give each platform's CI path filters so a change only builds its own app (`windows/**` for the Windows workflows, the Apple folders for `ci.yml`), and point `windows-store.yml`'s tag trigger and checkouts at `main`.
  - Keep shared docs and assets at the root: one README that links both apps, AGENTS.md with a section per platform (CLAUDE.md still only `@AGENTS.md`), PRIVACY.md, `docs/screenshots/{ios,mac,windows}`, the icon.
  - Remove the Swift reference copy this branch carries only if it now duplicates `main`'s.
  - Delete the `windows` branch once `main` builds, tests and publishes the Windows app.
- **Done when:** `main` builds and tests both apps with path-filtered CI, a `windows-v*` tag on `main` runs the Store release, and the `windows` branch is gone.
- **Touches:** the repository layout, `.github/workflows/*`, README.md, AGENTS.md, MICROSOFT_STORE.md.
- **Result:** `windows` is merged into `main`, and each app has its own folder: the Apple app moved into `apple/` (with its scripts, roadmap, screenshots and docs), the Windows app is in `windows/`. Each folder has its own README, AGENTS.md (with a CLAUDE.md that imports it), ACCESSIBILITY.md, CONTRIBUTING.md and roadmap. The root keeps a README, AGENTS.md and CONTRIBUTING.md for both apps, plus the Apple privacy policy at `PRIVACY.md`, because the App Store listing links there. CI is path-filtered (`ci.yml` for `apple/**`, `windows-*.yml` for `windows/**`) and the Store workflow runs from `main`. **Left for the maintainer:** the first `windows-v*` tag on `main`, then deleting the `windows` branch. Until that Store submission goes out, the live listing's privacy policy and website links still point at the `windows` branch.

### RM-111 — Scripted Store trailer video
- **Status:** open · **Size:** M · **Validation:** windows
- **Why:** The Store listing can show a trailer, and the first submission went out without one. The Apple app records its App Store previews automatically (`apple/bin/record-app-previews.sh` driving the `PreviewTourTests` UI test); nothing records the Windows app yet.
- **Scope:**
  - Add a demo-mode tour to `Fanficly.UITests` (search, open a work, read page by page, Listen, Library, Stats), in the spirit of the Swift `PreviewTourTests`.
  - Record the window while the tour runs and post-process with ffmpeg to the Store's trailer spec: MP4, H.264, 16:9 at 1920×1080 or 3840×2160, under 60 seconds, with captions in the Store art's look (`windows/store-art/`).
  - Run it from `windows-screenshots.yml` (or a sibling manual workflow) so the video is built with the screenshots; uploading it to Partner Center stays manual, with the 16:9 Super hero art as its thumbnail.
  - Document the steps in `MICROSOFT_STORE.md`.
- **Done when:** one manual workflow run produces a Store-ready trailer MP4 as an artifact, with no hand editing.
- **Touches:** `windows/tests/Fanficly.UITests/`, `windows/scripts/`, `.github/workflows/windows-screenshots.yml` (ask first), `MICROSOFT_STORE.md`.

### RM-119 — Tag and author blocklist
- **Status:** done · **Size:** M · **Validation:** unit + windows
- **Why:** Ports the Apple app's RM-006 (`apple/`, PR #100): the only block was one work at a time (`HiddenWork`).
- **Scope:** `BlockedTerm` (table `blocked_terms`, schema v2), `Blocklist` in `ContentFilter.Apply` for Search, Browse and author lists, block/unblock from a tag chip's or byline's context menu and Settings → Content & Safety, and the backup's `blocked` array in the Swift format, merged as a union.
- **Done when:** Core tests cover tag match (case-insensitive, AO3 names), author and co-author match, no match, an empty list and lifting; a backup test shows two devices union their lists.
- **Touches:** `Settings/ContentFilter.cs`, `Library/*`, `Sync/*`, `Views/Account/ContentSafetyViews.cs`, the reader header, Search, Browse and author screens.

### RM-121 — Keep story titles off the Windows lock screen
- **Status:** open · **Size:** S (M with the Settings fallback) · **Validation:** windows
- **Why:** Ports the Apple app's fix for #141, which redacts titles, authors, summaries, tags, folder names and saved-search names in its widgets while the device is locked. Windows 11 is rolling out lock-screen widgets that take small Widgets-board widgets, third-party ones included (Settings → Personalization → Lock screen; reported by Windows Latest in February 2025, so verify on a current build first), and the small Continue reading, Subscriptions, Recommendation, Folder Shortcuts and Saved Searches cards show that text. Adaptive Cards have no redaction, and the widget provider isn't told which host shows the card.
- **Scope:** First check whether the current Windows App SDK tells a provider that a widget is on the lock screen (or lets a definition opt out of it). If it does, render the small cards without the personal text there. If not, add a Settings → Privacy switch, "Hide story details in widgets", that leaves out that text in every card, and file the matching Apple item so both apps offer it. The jump list's "Continue “<title>”" entry is a separate issue.
- **Done when:** a Core test covers the card data with the text hidden (move the choice of card text into Core so it can be tested); on Windows, a small widget added to the lock screen shows no title.
- **Touches:** `windows/src/Fanficly.App/Platform/Widgets/*`, `Package.appxmanifest` if a definition can opt out, Settings → Privacy.

## Ideas from the Apple roadmap

The Apple app's roadmap on `main` has features that apply here too once they ship there: series pages, bulk download for a folder, and notes and personal tags (kudos is RM-115, creating AO3 bookmarks RM-119). Port each one after it lands on `main`, as a new `RM-1nn` item that names the Swift change it follows.

## Engineering health (any release)

Not features, but worth doing. Add them as items when started.

- `AGENTS.md` is the canonical agent guide; `CLAUDE.md` only points at it.
- Keep the unit-test count in AGENTS.md roughly honest when a PR adds a test class.
- Every new `IAO3Client` method lands with `MockAO3Client`, `DemoAO3Client`, `StubAO3Client` and `PollerFakeClient` support in the same PR.
- Release housekeeping is done by the maintainer through `MICROSOFT_STORE.md`, never by a roadmap PR. That covers:
  - the version in `windows/store/version.txt`;
  - Store listing text and screenshots in `windows/store/`;
  - the README screenshots in `windows/docs/screenshots/` and the Store pictures, which the manual **Windows screenshots** workflow (`.github/workflows/windows-screenshots.yml`) captures and commits.
