# Fanficly → App Store: submission checklist

Hybrid flow: **fastlane** pushes metadata + screenshots + the build; the few
things `deliver` can't do are done live in App Store Connect (you have it open
and logged in). Work top to bottom. Steps marked **[portal]** are clicks in the
App Store Connect web app; **[local]** are commands here.

Prepared assets already in the repo:
- ASO copy → `fastlane/metadata/` (name, subtitle, keywords, description, etc.)
- Framed marketing screenshots (6.9" + 13") → `fastlane/screenshots/en-US/`
- Reviewer notes → `fastlane/metadata/review_information/notes.txt`
- Version bumped to **1.5.0 (build 21)** in `project.yml`

---

## 0. One-time local setup  [local]

```bash
# fastlane (the bundled brew build ships its own Ruby — simplest on modern macOS)
brew install fastlane imagemagick   # imagemagick is required by `frameit` for the framed screenshots

# Screenshots venv already exists at bin/.venv; if not:
python3 -m venv bin/.venv && bin/.venv/bin/pip install Pillow
```

> The screenshot framing (`fastlane screenshots`) uses `fastlane frameit` (real
> Apple device bezels) + ImageMagick, then composites the ASO headline. If you
> prefer the Ruby `bundle exec fastlane` path, `bundle install` also works on a
> modern Ruby (the system Ruby 2.6 is too old).

## 1. App Store Connect API key  [portal] → [local]

1. App Store Connect → **Users and Access** → **Integrations** tab →
   **App Store Connect API** → **+** to create a key with **App Manager** role.
2. Note the **Key ID** and **Issuer ID**; download the **`.p8`** (one chance!).
3. Create `fastlane/api_key.json` from the template:
   ```bash
   cp fastlane/api_key.json.example fastlane/api_key.json
   ```
   Fill in `key_id`, `issuer_id`, and paste the `.p8` contents into `key`
   (newlines as `\n`, all on one line). This file is git-ignored.

## 2. Create the app record  [portal]

App Store Connect → **Apps** → **+** → **New App**:
- Platform: **iOS**
- Name: **Fanficly** (display name; the longer ASO name is set via metadata)
- Primary language: **English (U.S.)**
- Bundle ID: **io.github.yennster.fanficly** (must already exist in the Developer
  portal; if not, create it there first as an explicit App ID)
- SKU: `fanficly` (any unique string)
- User access: Full

## 3. Pricing & availability  [portal]

- Pricing → **Free**
- Availability → all territories (or your choice)

## 4. Age rating  [portal]

App → **Age Rating** → Edit → answer the questionnaire so the result is **17+**.
Use the answers in `appstore/app-review.md` (Sexual Content and Mature Themes =
Frequent/Intense; Unrestricted Web Access = Yes; Made for Kids = No).

## 5. App Privacy  [portal]

App → **App Privacy** → **Data Not Collected** (one answer: you do not collect
data). Set the **Privacy Policy URL**. Details in `appstore/privacy.md`.

## 6. Build the binary  [local]

Either let fastlane build it (needs your signing set up — `Signing.xcconfig`):
```bash
bundle exec fastlane build
```
…or archive in Xcode: **Product → Archive** → Organizer → **Distribute App →
App Store Connect → Upload**. Processing takes a few minutes.

> Export compliance is pre-answered (`ITSAppUsesNonExemptEncryption = false`).

## 7. Push metadata + screenshots + attach build  [local]

```bash
# Everything (build + metadata + screenshots), no auto-submit:
bundle exec fastlane release

# Or, if you uploaded the build in step 6 and only want copy/images:
bundle exec fastlane metadata_only
```
`deliver` uploads `fastlane/metadata` and `fastlane/screenshots/en-US`, sets the
categories (Books / Entertainment), and attaches the build. It does **not** submit.

## 8. Final review & submit  [portal]

In App Store Connect → your **1.5.0** version:
- Confirm name/subtitle/description/keywords/promotional text look right.
- Confirm the 6.9" and 13" screenshots are in the slots you want (reorder if needed).
- Select the processed **Build**.
- Reviewer notes are pre-filled from `notes.txt`; no demo account needed.
- Click **Add for Review** → **Submit for Review**.

---

## Likely rejection triggers (worth a glance first)

1. **Guideline 4.1(a) copycats / branding** — the app icon and marketing
   screenshots use the app's own **indigo** brand color (`#3B2E8C`), *not* AO3's
   signature maroon, so the art no longer resembles AO3's branding. (1.5.0 build
   20 was first rejected here while the art was maroon; rebranded to indigo in
   build 21.) Keep "AO3" mentions in metadata **descriptive** ("read works from
   Archive of Our Own"), never implying affiliation — the description's
   "not affiliated with AO3 / OTW" disclaimer must stay.
2. **Keyword "ao3"** (`fastlane/metadata/en-US/keywords.txt`) — "AO3"/"Archive of
   Our Own" is a trademark of the Organization for Transformative Works. Apple
   *sometimes* flags third-party trademarks in keywords. It's high-value for ASO.
   Safe replacement if you'd rather not risk it: swap `ao3` for `webnovel` (keeps
   the field full). The app **name/subtitle** are deliberately trademark-clean.
3. **Guideline 2.5.4 background audio** — the `audio` UIBackgroundMode is backed
   by the "Listen" TTS reader (persistent lock-screen playback). 1.5.0 build 20
   was flagged because the reviewer couldn't find it; the **Notes** field now
   includes the repro steps + a screen recording (see `app-review.md` →
   "Background audio"). Do **not** remove the `audio` mode — it's a real feature.
4. **Guideline 1.2 (UGC)** — covered by the in-app safeguards; the reviewer notes
   point to each. No action unless asked.
5. **Trademark / IP** — description carries the "not affiliated with AO3 / OTW"
   disclaimer; keep it.

## Re-running later (updates)

Bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml`, run
`xcodegen generate`, update `release_notes.txt`, re-shoot if UI changed
(`bundle exec fastlane screenshots`), then `bundle exec fastlane release`.

## Mac App Store (Mac Catalyst)

One-time: add the **macOS** platform to the app record in App Store Connect
(app page → Add Platform). Then `fastlane release_mac` archives the Catalyst
build as a `.pkg` and uploads it plus metadata and the `2560×1600` Mac
screenshots (`fastlane/screenshots-mac/en-US/`) to the macOS listing. Same
bundle ID → universal purchase. Does not auto-submit.
