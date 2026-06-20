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
| SwiftData `@Model`s | Room entities + DAOs |
| `@AppStorage` reader keys | `SettingsStore` (DataStore) |
| Keychain `CredentialStore` | `PersistentCookieJar` (EncryptedSharedPreferences) |
| `ReaderView` (continuous) | `WorkScreen` |
| `HTMLToAttributed` | `HtmlRender` |
| `fanficly://import` + share ext | `ACTION_VIEW`/`ACTION_SEND` intent filters |

## What's ported in this first cut

Implemented: smart-ish search (free-text query + sort), infinite-scroll results,
work reading (continuous scroll with saved reading position), save-to-library
(local follow, no login), the library with All/Starred/Downloaded filters,
reader typography/theme settings, AO3 share-in / deep-link to open a work, and
form-based login plumbing with a persisted session cookie.

Known follow-ups (present on iOS, not yet on Android): the rules-based
`SearchPromptParser` smart search, browse-by-fandom / Popular tabs, comments
(view/post), AO3 subscriptions + the background "new chapter" poller, the
last-read home-screen widget, paginated / page-by-page reading modes, and
on-device TTS ("Listen"). These map cleanly onto the structure above — add a
parser under `net/parse/`, a method on `AO3Client`, and a screen under `ui/`.

## Tests

`./gradlew test` runs the JVM unit tests under `app/src/test/` — fixture-based
parser and search-filter tests ported from the iOS `FanficlyTests` suite
(`SearchResultsParserTest`, `AO3SearchFiltersTest`). Add tests here as you port
more parsers, the same way the iOS app keeps its parsers pure and fixture-tested.
