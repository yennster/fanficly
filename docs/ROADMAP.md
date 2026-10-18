# Fanficly for Windows roadmap

Last reviewed: 2026-10-16, before the first Store release (`windows/store/version.txt`: 1.0). Written from the code: every item names the files it touches and what already exists.

This is the `windows` branch's backlog. The Apple app's roadmap is `docs/ROADMAP.md` on `main`. Windows items are numbered from **RM-101** so the two never share an ID, and their branches and PRs target `windows`. Agents: read [Autonomous roadmap work](../AGENTS.md#autonomous-roadmap-work) in AGENTS.md before picking anything. Humans: reorder, add and strike items freely. Claims are PRs, never issue assignments.

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
  - Per-chapter comments with a composer.
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

Each item is a heading `### RM-nnn — Title` followed by a `Status:` line that `bin/roadmap.sh` reads. IDs are permanent: never renumber, never reuse. New ideas get the next free number from RM-101 up.

- **Status:** `open` (free to claim), `claimed` (an open PR or `roadmap/RM-nnn-*` branch exists; the PR is the claim, not this file), or `done`.
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
- **Status:** open · **Size:** M · **Validation:** unit + windows
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

## Later (needs design, or a person on Windows)

### RM-108 — Find followed works from Windows Search
- **Status:** open · **Size:** M · **Validation:** windows
- **Why:** Core calls `LibraryHooks.SearchIndexer` (`IWorkSearchIndexer`) when works are followed or removed, the way the Swift app feeds Spotlight, but Windows installs no indexer.
- **Scope:**
  - Pick a Windows API that a packaged, Native AOT app can use to index its own items, and open them with a `fanficly://resume/<id>` link.
  - Write the choice in the PR before building.
  - Index followed works only, and remove them on unfollow.
- **Done when:** a followed work's title is findable in Windows Search on Windows 11 and opens the work; unfollowing removes it.
- **Touches:** a new `windows/src/Fanficly.App/Platform/` file, `Services/AppServices.cs`.

### RM-109 — Localization groundwork
- **Status:** open · **Size:** M · **Validation:** windows
- **Why:** Every string is English and inline in C#.
- **Scope:**
  - Add a `.resw` resource file and a small lookup helper.
  - Move one screen's strings (Settings → About) to it as the pattern.
  - Document the pattern in AGENTS.md.
  - Check it under Native AOT and in the MSIX (MakePri runs only on Windows).
- **Done when:** the About screen reads its strings from resources in the packaged Release build, with no change in English.
- **Touches:** `windows/src/Fanficly.App/Views/Settings/AboutScreen.cs`, a new resource file, `Fanficly.App.csproj` if needed.

### RM-110 — Move the Windows app onto `main` (one branch, a folder per platform)
- **Status:** open, maintainer only (agents don't pick this up) · **Size:** M · **Validation:** windows
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

### RM-111 — Scripted Store trailer video
- **Status:** open · **Size:** M · **Validation:** windows
- **Why:** The Store listing can show a trailer, and the first submission went out without one. The Apple app records its App Store previews automatically (`bin/record-app-previews.sh` driving the `PreviewTourTests` UI test); nothing records the Windows app yet.
- **Scope:**
  - Add a demo-mode tour to `Fanficly.UITests` (search, open a work, read page by page, Listen, Library, Stats), in the spirit of the Swift `PreviewTourTests`.
  - Record the window while the tour runs and post-process with ffmpeg to the Store's trailer spec: MP4, H.264, 16:9 at 1920×1080 or 3840×2160, under 60 seconds, with captions in the Store art's look (`windows/store-art/`).
  - Run it from `windows-screenshots.yml` (or a sibling manual workflow) so the video is built with the screenshots; uploading it to Partner Center stays manual, with the 16:9 Super hero art as its thumbnail.
  - Document the steps in `MICROSOFT_STORE.md`.
- **Done when:** one manual workflow run produces a Store-ready trailer MP4 as an artifact, with no hand editing.
- **Touches:** `windows/tests/Fanficly.UITests/`, `windows/scripts/`, `.github/workflows/windows-screenshots.yml` (ask first), `MICROSOFT_STORE.md`.

## Ideas from the Apple roadmap

The Apple app's roadmap on `main` has features that apply here too once they ship there: a tag and author blocklist, series pages, bulk download for a folder, notes and personal tags, kudos, and creating AO3 bookmarks. Port each one after it lands on `main`, as a new `RM-1nn` item that names the Swift change it follows.

## Engineering health (any release)

Not features, but worth doing. Add them as items when started.

- `AGENTS.md` is the canonical agent guide; `CLAUDE.md` only points at it.
- Keep the unit-test count in AGENTS.md roughly honest when a PR adds a test class.
- Every new `IAO3Client` method lands with `MockAO3Client`, `DemoAO3Client`, `StubAO3Client` and `PollerFakeClient` support in the same PR.
- Release housekeeping is done by the maintainer through `MICROSOFT_STORE.md`, never by a roadmap PR. That covers:
  - the version in `windows/store/version.txt`;
  - Store listing text and screenshots in `windows/store/`;
  - the README screenshots in `docs/screenshots/windows/` and the Store pictures, which the manual **Windows screenshots** workflow (`.github/workflows/windows-screenshots.yml`) captures and commits.
