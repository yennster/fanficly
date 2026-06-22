# Fanficly for Android

A Kotlin + Jetpack Compose port of the [Fanficly](../) AO3 reader. It mirrors
the iOS app's architecture and, crucially, its **privacy posture**: everything
runs on-device, the only network the app touches is `archiveofourown.org` over
HTTPS, and there are no analytics, ad, or crash-reporting SDKs.

Because AO3 has no JSON API, the app talks to AO3 by **scraping HTML with
[Jsoup](https://jsoup.org/)** over a single shared [OkHttp](https://square.github.io/okhttp/)
client with a custom `User-Agent` and a **1 request/second throttle** — the same
contract the iOS app keeps with SwiftSoup + URLSession.

> To publish this to the Play Store, see
> [`../docs/ANDROID_PUBLISHING.md`](../docs/ANDROID_PUBLISHING.md).

## Requirements

- JDK 17
- Android SDK with API 35 (compile/target), min API 26 (Android 8.0)
- Android Studio Ladybug+ (or just the SDK + the committed Gradle wrapper)

## Build & run

```bash
cd android
./gradlew assembleDebug        # build the debug APK
./gradlew installDebug         # install to a connected device/emulator
./gradlew test                 # JVM unit tests (parsers, search filters)
./gradlew lint                 # Android lint
./gradlew bundleRelease        # release AAB (needs signing env — see publishing doc)
```

> Building requires network access to Google's Maven repo (for the Android
> Gradle Plugin) plus a local Android SDK. In an offline sandbox the plugin
> resolution step will fail — that's expected.

> **Downloadable builds:** publishing a GitHub Release runs
> [`.github/workflows/android-release.yml`](../.github/workflows/android-release.yml),
> which builds the APK and attaches it to that release as `fanficly-<tag>.apk`
> (signed if the keystore secrets are set, debug otherwise). See
> [the publishing doc](../docs/ANDROID_PUBLISHING.md#github-releases-a-downloadable-apk).

## Architecture

The module mirrors the iOS layering one-to-one. The **only seam to the network**
is `AO3Client`; UI never touches OkHttp directly, exactly like the iOS
`@Environment(\.ao3Client)` rule.

```
android/app/src/main/java/io/github/yennster/fanficly/
  FanficlyApplication.kt      # Application; builds the AppContainer
  AppContainer.kt             # manual DI: one AO3Client, Room repo, settings store
  MainActivity.kt             # Compose host + bottom-nav + AO3 share/deep-link intent
  model/
    Models.kt                 # WorkSummary / WorkPayload / ChapterPayload / errors
    AO3SearchFilters.kt       # 1:1 map of AO3's /works/search fields (+ quirks)
  net/
    AO3Endpoints.kt           # URL builders (incl. AO3 path/term encoding quirks)
    ThrottleInterceptor.kt    # 1 req/sec throttle (OkHttp interceptor)
    AO3Client.kt              # interface + LiveAO3Client (OkHttp + Jsoup)
    MockAO3Client.kt          # offline stand-in for previews/tests
    PersistentCookieJar.kt    # session cookie in EncryptedSharedPreferences
    parse/
      SearchResultsParser.kt  # li.work.blurb / li.bookmark.blurb listings
      WorkPageParser.kt       # full work page → chapters + metadata
      LoginParser.kt          # CSRF token + logged-in username
      MediaCategoryParser.kt  # /media/<cat>/fandoms → fandoms + work counts
      WorkFiltersParser.kt    # /tags/<tag>/works facet sidebar → ships/chars
      CommentsParser.kt       # comment thread + new-comment form/pseud
      SubscriptionsParser.kt  # /users/<name>/subscriptions → works/series/users
  subscriptions/
    SubscriptionPoller.kt     # followed-works new-chapter check
    SubscriptionWorker.kt     # WorkManager periodic poll (~6h)
    Notifications.kt          # "new chapter" notification channel + post
  widget/
    FanficlyWidgetProvider.kt # last-read App Widget (RemoteViews) + resume tap
    WidgetProgressStore.kt    # last-read snapshot in SharedPreferences
  tts/
    SpeechController.kt       # TextToSpeech narrator (whole-work, auto-advance)
    SpeechService.kt          # foreground service + playback notification
  search/
    SearchPromptParser.kt     # rules-based prompt → AO3SearchFilters
    KnownTags.kt              # curated freeform/fandom/rating/… dictionaries
    TagResolver.kt            # canonical tag resolution via autocomplete
  browse/
    FandomCatalog.kt          # 10 media categories + curated seeds (PopularTags)
    PopularStore.kt           # cached daily PopularSnapshot (SharedPreferences)
  data/
    db/                       # Room: SavedWork + ReadingProgress entities, DAOs
    LibraryRepository.kt      # follow/save + reading-position persistence
    SettingsStore.kt          # reader typography/theme via DataStore
  ui/
    theme/Theme.kt            # Material 3 AO3-maroon color scheme
    reader/ReaderTheme.kt     # reader palettes/fonts (port of iOS ReaderTheme)
    reader/HtmlRender.kt      # chapter HTML → styled paragraphs (port of HTMLToAttributed)
    components/WorkRow.kt     # one work in a list (+ inline save toggle)
    search/                   # SearchScreen + SearchViewModel
    browse/                   # Browse + Popular + CategoryFandoms + FandomWorks
    comments/                 # CommentsScreen + ViewModel (view/post)
    bookmarks/                # BookmarksScreen + ViewModel (login-gated)
    subscriptions/            # SubscriptionsScreen + ViewModel (login-gated)
    authors/                  # AuthorWorks + FollowedAuthors (the Authors tab)
    work/                     # WorkScreen (detail + continuous reader) + ViewModel
    library/                  # LibraryScreen + ViewModel
    settings/                 # SettingsScreen + ViewModel
```

### iOS → Android mapping

| iOS (Swift) | Android (Kotlin) |
| --- | --- |
| `AO3ClientProtocol` / `AO3Client` actor | `AO3Client` interface / `LiveAO3Client` |
| `ThrottleActor` (1 req/sec) | `ThrottleInterceptor` |
| SwiftSoup parsers | Jsoup parsers (`net/parse/`) |
| `AO3SearchFilters` | `AO3SearchFilters` (same `work_search[*]` mapping) |
| `SearchPromptParser` / `KnownTags` | `SearchPromptParser` / `KnownTags` (`search/`) |
| `TagResolver` (autocomplete canonicalize) | `TagResolver` (`search/`) |
| SwiftData `@Model`s | Room entities + DAOs |
| `@AppStorage` reader keys | `SettingsStore` (DataStore) |
| Keychain `CredentialStore` | `PersistentCookieJar` (EncryptedSharedPreferences) |
| `ReaderView` (continuous) | `WorkScreen` |
| `HTMLToAttributed` | `HtmlRender` |
| `fanficly://import` + share ext | `ACTION_VIEW`/`ACTION_SEND` intent filters |

## What's ported

Implemented:

- **Smart search** — the rules-based `SearchPromptParser` (a prompt like
  `edward/bella romance all human complete` → structured AO3 filters shown as
  removable chips), with `TagResolver` canonicalizing tags via AO3's autocomplete
  and a sort bar (column + direction).
- **Browse & Popular tabs** — browse AO3's 10 media categories → live fandom
  lists (with the curated `FandomCatalog` seed as fallback) → works; a Popular
  tab (fandoms / ships / characters) ranked from AO3's work counts (`PopularStore`,
  cached ~daily, curated `PopularTags` fallback). Tapping a tag opens its works.
- **Comments** — view a work's comment thread (`CommentsParser`, threaded depth,
  guest comments) and, when logged in, post one (scraped-form CSRF flow), from a
  button in the reader's top bar. v1 is work-level (the work page's first thread);
  the client/`commentsPageUrl` already accept a `chapterId`, so per-chapter
  threading on multi-chapter works is a small UI follow-up (thread the current
  chapter's id through the route + chapter-aware title/empty-state copy).
- **Subscriptions, Bookmarks & the background poller** — view your AO3
  subscriptions (`SubscriptionsParser`, login-gated) and bookmarks (login-gated,
  infinite scroll) from the Library top bar; a WorkManager periodic worker
  (`SubscriptionWorker`, ~6h) polls **locally-followed works** for new chapters
  and fires a local notification (works fully logged out). `lastSeenChapterCount`
  on `SavedWorkEntity` (Room v2 additive migration) is the per-work baseline.
- **Followed authors (the Authors tab)** — open an author from a work's byline
  ("more by this author", `ui/authors/AuthorWorksScreen.kt`) and Follow them
  (local-only, no login); the Authors tab (Library top bar) lists followed
  authors, and the poller's `checkFollowedAuthors` notifies on newly-published
  works. `FollowedAuthorEntity` (Room **v3** migration) seeds `knownWorkIds` at
  follow time so the first poll skips the back catalogue.
- **Last-read home-screen widget** — an App Widget (`FanficlyWidgetProvider`,
  RemoteViews) showing the last-read story's title/author/progress on the maroon
  gradient; tapping it resumes the work via the AO3-URL `VIEW` intent.
  `WidgetProgressStore` persists the snapshot (fed by every reading-position
  save); on-device only, so it drops the iOS app-group + iCloud KVS mirroring.
- **Paginated reading mode** — a Reading Mode setting (Settings) toggles the
  reader between continuous scroll and **swipe-by-chapter** (a `HorizontalPager`,
  one vertically-scrollable chapter per page), the iOS "Swipe by chapter" mode.
  Reading position + the widget fraction are preserved across both modes. iOS's
  measured page-by-page mode is a follow-up.
- **On-device TTS ("Listen")** — `tts/SpeechController.kt` wraps the framework
  `TextToSpeech` (the device's local engine — no network, so the privacy posture
  holds), narrating the whole work and auto-advancing chapters; a foreground
  `tts/SpeechService.kt` keeps playback alive in the background with a
  play/pause/stop notification. The reader has a Listen toggle, a control bar
  (¶ x / y), karaoke highlight + auto-scroll of the spoken paragraph (continuous
  mode), and a speed setting. A full MediaSession/MediaStyle lock-screen
  treatment (needs `androidx.media`) and karaoke in paginated mode are follow-ups.
- Infinite-scroll results, work reading (continuous scroll with saved reading
  position), save-to-library (local follow, no login), the library with
  All/Starred/Downloaded filters, reader typography/theme settings, AO3 share-in
  / deep-link to open a work, and form-based login with a persisted session
  cookie. The launcher icon is the adaptive-icon twin of the iOS app icon (maroon
  gradient + open-book glyph with ruled text lines).

Known follow-ups / refinements (present on iOS, not yet on Android): measured
page-by-page reading mode (the swipe-by-chapter paginated mode is done); a full
MediaSession lock-screen treatment for "Listen" (basic notification controls are
done); and polling AO3-account work subscriptions for new chapters (the
local-follow + followed-author pollers, and the subscriptions/bookmarks/authors
UI, are done). These map cleanly onto the structure above — add a parser under
`net/parse/` (or `search/` for prompt parsing), a method on `AO3Client`, and a
screen under `ui/`.

## Tests

`./gradlew test` runs the JVM unit tests under `app/src/test/` — fixture-based
parser and search tests ported from the iOS `FanficlyTests` suite:
`SearchResultsParserTest`, `AO3SearchFiltersTest`, `SearchPromptParserTest`
(every smart-search prompt case), `TagResolverTest` (canonical resolution + ship
character-fallback, via the scriptable `StubAO3Client`), `MediaCategoryParserTest`
/ `WorkFiltersParserTest` / `FandomCatalogTest` (Browse/Popular), `CommentsParserTest`
(thread depth, guest comments, pseud id, new-comment form), `SubscriptionsParserTest`
(works/series/users + dedupe), `FollowedAuthorTest` (known-id storage + new-work
diff), and `PromptTextTest`
(`promptText()` chip-removal round-trip). Add tests here as you port more
parsers, the same way the iOS app keeps its parsers pure and fixture-tested.
