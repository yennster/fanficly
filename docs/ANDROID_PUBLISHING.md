# Publishing Fanficly for Android to the Google Play Store

This guide walks through everything needed to ship the Android port (in
[`android/`](../android)) to the Google Play Store — from a clean machine to a
production release. It is written to mirror the privacy posture and content
realities of the iOS app: **the app collects nothing off-device**, and AO3
hosts user-generated fiction including mature/explicit work, which shapes the
content-rating and data-safety answers below.

> TL;DR for a returning maintainer:
> 1. Bump `versionCode`/`versionName` in `android/app/build.gradle.kts`.
> 2. `cd android && ./gradlew bundleRelease` (with signing env vars set).
> 3. Upload `android/app/build/outputs/bundle/release/app-release.aab` to the
>    Play Console, fill in release notes, roll out.

---

## 1. Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| JDK | 17 | AGP 8.7 requires JDK 17. `java -version` should say 17. |
| Android Studio | Ladybug (2024.2) or newer | Bundles the right AGP & SDK manager. |
| Android SDK | API 35 (compileSdk/targetSdk) | Install via Android Studio → SDK Manager. |
| Build tools | 35.0.0 | Pulled automatically by the SDK manager. |

A **Google Play Developer account** is required: one-time **US$25**
registration at <https://play.google.com/console/signup>. Allow a day or two for
identity verification. Individual accounts now also require D-U-N-S/identity
checks for new registrations — start this early.

> **CI note:** this repo's iOS CI does not build the Android app. The Android
> module is self-contained under `android/`; wire up a separate workflow
> (`./gradlew test lint bundleRelease`) if you want CI coverage. The Gradle
> wrapper is committed, so CI only needs JDK 17 + the Android SDK.

---

## 2. One-time: create the upload keystore

Google Play uses **Play App Signing**: Google holds the real app-signing key,
and you sign each upload with an **upload key**. Generate that upload key once
and guard it — losing it means contacting Play support to reset.

```bash
keytool -genkeypair -v \
  -keystore fanficly-upload.keystore \
  -alias fanficly \
  -keyalg RSA -keysize 2048 -validity 9125 \
  -storetype PKCS12
```

Store the resulting `fanficly-upload.keystore` **outside the repo** (a password
manager vault or an encrypted drive). Never commit it.

The build reads signing credentials from Gradle properties **or** environment
variables (see `android/app/build.gradle.kts`). Provide them out-of-band:

```bash
export FANFICLY_STORE_FILE=/secure/path/fanficly-upload.keystore
export FANFICLY_STORE_PASSWORD=…
export FANFICLY_KEY_ALIAS=fanficly
export FANFICLY_KEY_PASSWORD=…
```

…or put them in `~/.gradle/gradle.properties` (user-level, not the repo's
`android/gradle.properties`):

```properties
FANFICLY_STORE_FILE=/secure/path/fanficly-upload.keystore
FANFICLY_STORE_PASSWORD=…
FANFICLY_KEY_ALIAS=fanficly
FANFICLY_KEY_PASSWORD=…
```

If no keystore is configured, `bundleRelease` still produces an **unsigned**
bundle (handy for CI smoke builds) — you just can't upload it.

---

## 3. Version the release

Edit `android/app/build.gradle.kts`:

```kotlin
versionCode = 2        // MUST increase on every upload (integer)
versionName = "1.5.1"  // human-facing; keep in lockstep with the iOS app
```

`versionCode` is the number Play orders releases by — it must strictly increase
and can never be reused, even across tracks. `versionName` is cosmetic; keep it
matching the iOS `CFBundleShortVersionString` so the two platforms read the same.

---

## 4. Build the release bundle (AAB)

Play requires the **Android App Bundle** format (`.aab`), not an APK.

```bash
cd android
./gradlew clean bundleRelease
```

Output: `android/app/build/outputs/bundle/release/app-release.aab`.

Sanity-check it locally with `bundletool` (optional) or just run the debug build
on a device first:

```bash
./gradlew installDebug      # sideload the debug build to a connected device
./gradlew test              # run the JVM unit tests (parsers, filters)
./gradlew lint              # Android lint
```

---

## 5. Create the app in the Play Console

1. Go to <https://play.google.com/console> → **Create app**.
2. App name: **Fanficly**. Default language: English (US).
3. App or game: **App**. Free or paid: **Free**.
4. Accept the Developer Program Policies & US export laws declarations.

The package name **`io.github.yennster.fanficly`** is locked in at first upload
and can never change — make sure it matches `applicationId`.

---

## 6. Complete the required declarations

Play will not let you publish until every section under **Policy → App content**
is green. Fill them out to match Fanficly's actual behavior:

### 6.1 Privacy policy
Provide a public URL. The repo's [`PRIVACY.md`](../PRIVACY.md) is the source of
truth — publish it (e.g. GitHub Pages) and paste the link.

### 6.2 Data safety
This is the most important form given the app's posture. Answer truthfully:

- **Does your app collect or share any user data?** → **No.**
  Fanficly stores everything on-device. The only persisted secret is the AO3
  session cookie, kept in encrypted on-device storage and never transmitted to
  anyone but AO3. There are no analytics, ad, or crash-reporting SDKs (verify:
  the only network dependency is OkHttp talking to `archiveofourown.org`).
- **Is all data encrypted in transit?** → **Yes** (HTTPS only).
- **Do you provide a way to request data deletion?** → On-device only; users
  clear data by logging out / uninstalling.

> If you later add iCloud-style cloud backup, this form must change to declare
> what's backed up and where.

### 6.3 Content rating (IARC questionnaire)
AO3 is a repository of user-generated fiction that **includes mature and
explicit sexual content and graphic violence**. Answer the IARC questionnaire
honestly: the app surfaces user-generated content you don't moderate, and that
content can be sexual/violent. Expect a **Mature 17+ / PEGI 18** rating. Do not
under-declare — misrating is a suspension risk.

### 6.4 Target audience and content
- Target age group: **18+**. Do **not** include any under-18 bracket, or you
  trigger Families policy requirements the app can't meet (it shows unmoderated
  adult fiction).
- Confirm the app is **not** designed for children.

### 6.5 Ads
**Contains ads? → No.**

### 6.6 App access
Some features (your bookmarks, posting comments, subscribing, private/explicit
works behind login) require an AO3 account. Under **App access**, choose
"All or some functionality is restricted" and provide either:
- demo AO3 credentials for the review team, **or**
- a note explaining that an AO3 account (free, at archiveofourown.org) is needed
  for account-gated features, while search/reading work logged out.

### 6.7 Government apps / financial / health
All **No**.

---

## 7. Store listing assets

Under **Grow → Store presence → Main store listing**:

| Asset | Requirement |
| --- | --- |
| App icon | 512×512 PNG, 32-bit. The in-app adaptive icon lives in `res/mipmap`; export a 512² version for the listing. |
| Feature graphic | 1024×500 PNG/JPG. Reuse the AO3-maroon (`#990000`) brand canvas from the iOS marketing shots. |
| Phone screenshots | 2–8, 16:9 or 9:16, min 320 px. Capture Search, Reader, Library, Settings. |
| 7"/10" tablet shots | Optional but recommended (the app is responsive). |
| Short description | ≤80 chars, e.g. "Read AO3 fanfiction. Private, on-device, no trackers." |
| Full description | Lead with the privacy posture and reader features. |

The iOS app's `bin/frame-screenshots.py` headlines and the AO3-maroon canvas are
a good reference for copy and color so the two listings feel like one product.

---

## 8. Roll out through testing tracks

Promote gradually — don't ship straight to production the first time:

1. **Internal testing** (up to 100 testers, instant): upload the AAB, add
   testers by email, install via the opt-in link. Smoke-test login, search,
   reading, save-to-library, deep links (sharing an AO3 URL into the app).
2. **Closed testing**: a larger invited group. (New personal developer accounts
   must run a closed test with ~12 testers for ~14 days before they can apply
   for production access — budget for this.)
3. **Open testing** (optional public beta).
4. **Production**: create a release on the Production track, attach the same (or
   a newer) AAB, write **release notes**, then **Review release → Roll out**.
   Use a **staged rollout** (e.g. 10% → 50% → 100%) to catch crashes early.

First-time review typically takes a few hours to a few days.

---

## 9. Each subsequent release

1. Make changes on a branch; merge.
2. Bump `versionCode` (and usually `versionName`).
3. `./gradlew clean test bundleRelease`.
4. Play Console → Production (or a testing track) → **Create new release** →
   upload the AAB → release notes → staged rollout.

Keep the upload keystore backed up. If it's ever lost, request an upload-key
reset in the Play Console (Play App Signing means your published apps keep
working — only the key you sign uploads with changes).

---

## 10. Being a good AO3 citizen (don't skip)

The app scrapes `archiveofourown.org` because AO3 has no public JSON API. The
client mirrors the iOS app's etiquette and **must keep doing so**:

- **1 request/second throttle** — enforced by `ThrottleInterceptor`. Never
  bypass it.
- **Honest `User-Agent`** — `Fanficly/<version> (+github.com/yennster/fanficly)`
  so AO3 ops can identify and contact us.
- **No bulk scraping / no servers** — every request is user-initiated on-device.

Respect AO3's Terms of Service. If AO3 ever asks the app to change behavior,
that takes priority over any feature.

---

## Appendix: troubleshooting

- **"Plugin com.android.application not found" during build** — the machine has
  no network access to Google's Maven repo, or no Android SDK. Building requires
  both. (This is expected to fail in sandboxes without `ANDROID_HOME` set.)
- **"You uploaded an APK or Android App Bundle that is signed with a key that is
  also used to sign other releases"** — you reused the upload key across apps;
  that's fine, ignore, or generate a dedicated key.
- **"Version code N has already been used"** — bump `versionCode`.
- **Upload rejected for target API level** — Play periodically raises the
  minimum `targetSdk`. Bump `compileSdk`/`targetSdk` in `app/build.gradle.kts`.
