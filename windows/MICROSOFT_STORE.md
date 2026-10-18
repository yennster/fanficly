# Publishing Fanficly to the Microsoft Store

This is how the Windows app (`windows/`) gets from the repository to the
Microsoft Store, and how to do each release. The iPhone and Mac apps use
fastlane for this; the Windows side uses Microsoft's own tools wherever they
exist, and one small script where they don't.

In short: after a one-time setup and a first submission by hand, a release is
"edit the release notes, push a `windows-vX.Y.Z` tag". GitHub Actions builds
the package, checks it, uploads it with the listing text, and submits it for
certification.

## The tools, and what each one does

| Job | iOS (fastlane) | Windows |
|---|---|---|
| Upload the build, submit for review | `deliver` | **Microsoft Store Developer CLI** (`msstore`), installed in CI by Microsoft's **`microsoft/microsoft-store-apppublisher`** GitHub Action |
| Listing text and release notes in the repo | `fastlane/metadata/` | `windows/store/listing/<language>/*.txt`, turned into the CLI's JSON by `New-StoreListingJson.ps1` |
| Version number | `increment_build_number` | `windows/store/version.txt` + `Set-AppVersion.ps1` |
| Check the build before submitting | `precheck` | **Windows App Certification Kit** (WACK, `appcert.exe` from the Windows SDK), run by `Test-StorePackage.ps1` |
| Marketing screenshots and art | `fastlane screenshots` + `apple/bin/frame-screenshots.py` | UI tests at 4K + `make_store_art.py` (see [Screenshots and Store art](#screenshots-and-store-art)) |
| Upload screenshots and art | `deliver` | `Publish-StoreScreenshots.ps1` (home-baked, see below) |
| Developer portal | App Store Connect | **Partner Center** (partner.microsoft.com/dashboard) |

**msstore** is Microsoft's open-source command-line tool for the Store
(github.com/microsoft/msstore-cli). It signs in to Partner Center with an Entra
ID app (a service account), uploads `.msixupload` packages, edits the draft
submission's listing, commits the submission for certification, handles
package flights and gradual rollout, and reports status. It's the native
equivalent of fastlane deliver, and Microsoft documents it as the way to
publish from GitHub Actions.

**Partner Center** is where the app lives: name reservation, package identity,
pricing, age rating, store listing, certification results. Everything the CLI
does, you can also see and do there.

**WACK** runs the technical tests the Store's certification also runs (manifest,
package layout, binaries, launch, crash on suspend…) on your own machine or
runner, before the package goes anywhere.

**The one home-baked piece is image upload.** The msstore CLI uploads
packages and listing text but not listing images. `Publish-StoreScreenshots.ps1`
fills that gap for the screenshots and the Store art with Microsoft's documented Store submission API
(`manage.devcenter.microsoft.com`), the same API the CLI uses. It's opt-in:
images change rarely, so it runs only when you ask.

All the scripts are in `windows/scripts/store/`, are PowerShell 7, and have
built-in help (`Get-Help ./Set-AppVersion.ps1 -Full`):

| Script | What it does |
|---|---|
| `Set-AppVersion.ps1` | Writes the package version (A.B.C.0) into `Package.appxmanifest`. |
| `Set-StoreIdentity.ps1` | Writes the Partner Center package identity into `Package.appxmanifest`. |
| `New-StoreListingJson.ps1` | Checks the listing files against the Store's limits and builds the JSON for `msstore submission updateMetadata`. |
| `Test-StorePackage.ps1` | Runs WACK on the package and writes its report. |
| `Publish-StoreScreenshots.ps1` | Replaces the listing screenshots and Store art in the draft submission. |

The workflow is `.github/workflows/windows-store.yml`.

## One-time setup

### 1. Partner Center account

Start at **storedeveloper.microsoft.com → Get started for free** and pick
**Individual developer**. Sign in with the personal Microsoft account
(outlook.com, hotmail.com, live.com or a personal account on another address)
you want to own the app, then verify your identity with a government ID and a
selfie. Registration is free for individuals. When it's done, **Go to Partner
Center dashboard** and pick the same account; you land on Apps & Games (if not,
wait a few minutes and open aka.ms/submitwindowsapp).

Don't sign up from partner.microsoft.com itself: that's the older flow, and its
"become a partner" path can enroll you in the Microsoft AI Cloud Partner Program,
which asks for a work account and doesn't include the Windows & Xbox (Store)
program, so an account made that way can't publish apps. Pick **Company** only if
the app is published by a registered business; an individual account can't be
converted to a company one later.

### 2. Reserve the names

In Partner Center: **Apps and games → New product → MSIX or PWA app**, and
reserve **Fanficly**. Then, on the app's **Product management → Manage app
names** page, also reserve **Fanficly: Fanfiction Reader**.

You need both: the package's display name (`Fanficly`, in
`Package.appxmanifest`) and the Store listing title (`windows/store/listing/en-us/title.txt`)
each have to be one of the app's reserved names. If "Fanficly" is already
taken, reserve another name and change `DisplayName` in the manifest to match.

### 3. Product identity

Open **Product management → Product identity**. Note these four values:

| Partner Center | Goes to |
|---|---|
| Package/Identity/Name | variable `STORE_PACKAGE_IDENTITY_NAME` |
| Package/Identity/Publisher (starts with `CN=`) | variable `STORE_PUBLISHER` |
| Package/Properties/PublisherDisplayName | variable `STORE_PUBLISHER_DISPLAY_NAME` |
| Store ID (12 characters, starts with 9) | secret `STORE_PRODUCT_ID` |

The committed manifest has placeholder values; the workflow writes these into it
before building. A package with a different identity is rejected on upload.

### 4. Properties, pricing and age rating

These are set once in Partner Center and kept from one submission to the next.

- **Pricing and availability**: Free, all markets (or the ones you want),
  public visibility. Keep the app free: Microsoft documents CI updates for free
  apps.
- **Properties**: category **Books + reference**. Privacy policy URL:
  `https://github.com/yennster/fanficly/blob/main/windows/PRIVACY.md` (the Store
  requires one because the app uses the internet). Website and support contact
  info are on the same pages; the values are in
  `windows/store/listing/en-us/website.txt` and `support_contact.txt`. The
  CLI's listing update doesn't carry these three fields, so Partner Center is
  where they live.
- **Age ratings**: Partner Center uses the IARC questionnaire. Answer it so the
  rating matches the iOS app's 17+:
  - The app shows content published by other people on the web (Archive of Our
    Own) without restriction, and some of it is explicit: sexual content,
    violence and mature themes. Answer yes to unrestricted internet access /
    user-generated content and to the mature-content questions.
  - Users can interact: signed-in users can post comments on AO3.
  - No purchases, no location sharing, no personal information shared by the app.

  Expect a mature rating (for example ESRB Mature 17+, PEGI 18). If IARC rates it
  higher, accept that rather than understating the content.
- **Submission options**: the manifest declares the restricted capability
  `runFullTrust`. Partner Center asks why; answer: "Fanficly is a WinUI 3
  desktop app packaged with MSIX. runFullTrust is the standard capability for
  packaged desktop apps; the app doesn't use it for anything else."
  Under **Notes for certification**: "No sign-in is needed to review the app.
  Fanficly reads works published on Archive of Our Own (archiveofourown.org);
  it hosts no content of its own. Signing in to AO3 is optional (bookmarks,
  subscriptions, comments)."

### 5. An Entra ID app for CI

CI signs in to Partner Center as an Entra ID (Azure AD) application with the
**Manager** role.

1. In Partner Center, **Account settings → Organization profile → Tenants**:
   associate a Microsoft Entra tenant, or create one there if you don't have
   one.
   This is the one place a work account belongs: a tenant's admin is a work
   account (name@yourtenant.onmicrosoft.com), separate from the personal
   Microsoft account that owns the developer account. If you already made a
   work account somewhere else, its tenant can be associated here instead of
   creating a new one.
2. **Account settings → User management → Microsoft Entra applications → Add
   Microsoft Entra application**. Create a new one (name it e.g.
   "Fanficly GitHub Actions") and give it the **Manager** role.
3. Open the app there and **Add new key**. Copy the key (the client secret)
   right away; it's shown once. Note when it expires and set a reminder: CI
   stops signing in after that, and you add a new key and update the secret.

### 6. Collect the IDs

| Secret | Where |
|---|---|
| `AZURE_AD_TENANT_ID` | The Entra application's page in Partner Center (Tenant ID), or the Entra admin center's overview page |
| `AZURE_AD_APPLICATION_CLIENT_ID` | The Entra application's page in Partner Center (Client ID) |
| `AZURE_AD_APPLICATION_SECRET` | The key from step 5 |
| `SELLER_ID` | **Account settings → Legal info → Developer** (Seller ID) |
| `STORE_PRODUCT_ID` | **Product management → Product identity** (Store ID) |

### 7. GitHub secrets, variables and environment

In the repository: **Settings → Environments → New environment**, name it
**`microsoft-store`**.

- Under **Deployment protection rules**, tick **Required reviewers** and add
  yourself. Every publish then waits for your click in the Actions tab, so a
  stray tag can't ship anything. (Optionally also limit **Deployment branches
  and tags** to `main` and `windows-v*`.)
- Under **Environment secrets**, add the five secrets above. As environment
  secrets, only the publish job can read them, and only after approval.

The three identity values are **repository variables** (not secrets, and not
environment variables, because the build job runs outside the environment):
**Settings → Secrets and variables → Actions → Variables**.

| Name | Kind | Example |
|---|---|---|
| `AZURE_AD_TENANT_ID` | environment secret | `00000000-0000-0000-0000-000000000000` |
| `AZURE_AD_APPLICATION_CLIENT_ID` | environment secret | `00000000-0000-0000-0000-000000000000` |
| `AZURE_AD_APPLICATION_SECRET` | environment secret | (the key) |
| `SELLER_ID` | environment secret | `12345678` |
| `STORE_PRODUCT_ID` | environment secret | `9NXXXXXXXXXX` |
| `STORE_PACKAGE_IDENTITY_NAME` | repository variable | `12345JennySpeelman.Fanficly` |
| `STORE_PUBLISHER` | repository variable | `CN=00000000-0000-0000-0000-000000000000` |
| `STORE_PUBLISHER_DISPLAY_NAME` | repository variable | `Jenny Speelman` |

With the GitHub CLI:

```powershell
gh secret set AZURE_AD_TENANT_ID --env microsoft-store
gh secret set AZURE_AD_APPLICATION_CLIENT_ID --env microsoft-store
gh secret set AZURE_AD_APPLICATION_SECRET --env microsoft-store
gh secret set SELLER_ID --env microsoft-store
gh secret set STORE_PRODUCT_ID --env microsoft-store
gh variable set STORE_PACKAGE_IDENTITY_NAME --body "12345JennySpeelman.Fanficly"
gh variable set STORE_PUBLISHER --body "CN=00000000-0000-0000-0000-000000000000"
gh variable set STORE_PUBLISHER_DISPLAY_NAME --body "Jenny Speelman"
```

(`gh secret set` asks for the value, so it doesn't end up in your shell history.)

## The first submission (by hand)

The Store doesn't let a tool create an app's first submission: the first one is
made in Partner Center, and CI takes over once the app is live. Do this once.

**1. Get the package.** Either way gives the same `.msixupload`:

- **From CI** (easiest): with the variables from step 7 set, run the workflow
  by hand without submitting: **Actions → Windows Store release → Run
  workflow** on `main` with **Submit** unticked, or
  `gh workflow run "Windows Store release" --ref main -f submit=false`.
  (A push to `main` with `[store-package]` in its message also builds without
  publishing, but only when the push touches `windows/` or the Windows
  workflows; an empty commit doesn't run anything.) Download the
  **store-package** artifact from the run and unzip it. The WACK report is in
  the **wack-report** artifact.
- **Locally**, on Windows with Visual Studio (the **WinUI application
  development** and **Desktop development with C++** workloads; the C++ tools
  are needed for Native AOT), the .NET 10 SDK and PowerShell 7. In a
  **Developer PowerShell for VS**, from the repository root:

  ```powershell
  ./windows/scripts/store/Set-StoreIdentity.ps1 -Name "<Package/Identity/Name>" -Publisher "<CN=…>" -PublisherDisplayName "<PublisherDisplayName>"
  ./windows/scripts/store/Set-AppVersion.ps1 -Version 1.0.0
  cd windows
  msbuild src/Fanficly.App/Fanficly.App.csproj /t:Restore /p:Configuration=Release
  msbuild src/Fanficly.App/Fanficly.App.csproj /p:Configuration=Release /p:Platform=x64 /p:AppxBundle=Always "/p:AppxBundlePlatforms=x64|arm64" /p:UapAppxPackageBuildMode=StoreUpload "/p:AppxPackageDir=$PWD\..\artifacts\AppPackages\" /p:GenerateAppxPackageOnBuild=true /p:AppxPackageSigningEnabled=false
  cd ..
  ```

  The package is `artifacts/AppPackages/Fanficly.App_1.0.0.0_x64_arm64_bundle.msixupload`
  (the exact name follows the version). To run the certification kit on it, in
  an **administrator** PowerShell 7:

  ```powershell
  ./windows/scripts/store/Test-StorePackage.ps1 -Package artifacts/AppPackages -ReportPath artifacts/wack/wack-report.xml
  ```

  The scripts edit `Package.appxmanifest`; put it back afterwards with
  `git checkout -- windows/src/Fanficly.App/Package.appxmanifest`.

**2. Submit it.** In Partner Center, open the app and **Start your submission**:

- **Packages**: upload the `.msixupload`. Device families: Desktop.
- **Store listings → English (United States)**: paste from
  `windows/store/listing/en-us/`: `title.txt` as the product name,
  `description.txt`, `short_description.txt`, `release_notes.txt` (What's new),
  one line of `features.txt` per product feature, one line of `keywords.txt`
  per search term, `copyright.txt`. Add at least one screenshot (see
  [Screenshots and Store art](#screenshots-and-store-art)).
- Check Pricing and availability, Properties, Age ratings and Submission options
  from step 4, then **Submit to the Store**.

Certification usually takes from a few hours to three business days. When the
app is live, CI can do the rest.

## Every release after that

1. Write the release notes in `windows/store/listing/en-us/release_notes.txt`
   (at most 1,500 characters). Change any other listing file if you like; the
   whole listing is updated on every release.
2. For a new major or minor version, change `windows/store/version.txt`
   (e.g. `1.1`).
3. Check the listing locally if you changed it (this is also run in CI):

   ```powershell
   ./windows/scripts/store/New-StoreListingJson.ps1
   ```

4. Commit, then tag and push:

   ```powershell
   git tag windows-v1.1.0
   git push origin windows-v1.1.0
   ```

5. In **Actions → Windows Store release**, approve the publish job when it asks.

What the workflow does then:

1. **Build**: sets the version from the tag (`windows-v1.1.0` → `1.1.0.0`)
   and the identity from the variables, checks the listing, and builds the
   x64 + ARM64 bundle with Native AOT (the same msbuild command as Windows CI).
2. **App Certification Kit**: runs WACK on the bundle and uploads the report as
   the **wack-report** artifact. A failure here doesn't stop the release (it is a
   warning, as with precheck), but read the report: what fails WACK usually
   fails certification.
3. **Publish** (after your approval):
   - `msstore publish <package> --appId <id> --noCommit` uploads the package
     into a new draft submission (replacing any old draft).
   - `msstore submission get` + `New-StoreListingJson.ps1 -BaseSubmission` +
     `msstore submission updateMetadata` update the listing text in the draft.
   - Optionally `Publish-StoreScreenshots.ps1` replaces the screenshots.
   - `msstore submission publish` commits the draft for certification, and
     `msstore submission poll` follows it until the Store has accepted it.
4. **GitHub Release** (tag runs only): creates a release for the tag with the
   release notes and the `.msixupload` attached.

### Running it by hand instead of with a tag

Run it from **Actions → Windows Store release → Run workflow**, on `main`, or
from the GitHub CLI:

```sh
gh workflow run "Windows Store release" --ref main -f submit=false
```

The inputs (`-f name=value` with `gh`):

| Input | Meaning |
|---|---|
| `version` | e.g. `1.1.2`. Empty: `version.txt` + the run number, e.g. `1.1.57.0`. |
| `submit` | On (default): submit for certification. Off: stop at a draft in Partner Center, to look it over and click Submit there yourself. |
| `upload_screenshots` | Replace the listing screenshots and Store art with `windows/store/screenshots/` and `windows/store/images/`. |
| `flight_id` | Publish to this package flight instead of to everyone. |
| `rollout_percentage` | Gradual rollout: only this percentage of users get the update at first. |

Manual runs don't create a GitHub Release.

### Draft or submit

With `submit` off, the package and listing are in a draft in Partner Center.
Review it there and press **Submit to the Store**, or from a terminal:

```powershell
msstore submission publish <productId>
```

To throw a draft away: `msstore submission delete <productId> --no-confirm`.

### Package flights

A package flight sends a package to a group of testers (a known user group
you set up in Partner Center) instead of to everyone. Create the flight in
Partner Center (**Package flights**), find its ID with
`msstore flights list <productId>`, and run the workflow with `flight_id` set.
Flight releases upload only the package: no listing text or screenshots. Give
flight packages a higher version than the current public one, or testers get
the public package.

Checking on it: `msstore flights submission status <productId> <flightId>`.

### Gradual rollout

Set `rollout_percentage` (e.g. `20`) to offer an update to that share of users
first. Rollout applies to updates, not to an app's first release. Afterwards:

```powershell
msstore submission rollout get <productId>
msstore submission rollout update <productId> 50
msstore submission rollout halt <productId>
msstore submission rollout finalize <productId>
```

(For a flight: `msstore flights submission rollout …` with the flight ID.)
Note that the Store doesn't let you start a new submission while a rollout is
in progress: finalize or halt it first.

### Checking status

```powershell
msstore submission status <productId>
```

or the app's page in Partner Center. Certification can take up to three
business days; the workflow stops following once the Store has taken the
submission into certification.

### Doing a release from your own machine

Everything the workflow does works locally too. Install the CLI once:

```powershell
winget install "Microsoft Store Developer CLI"
msstore settings --enableTelemetry false
msstore reconfigure --tenantId <tenant> --sellerId <seller> --clientId <client> --clientSecret <secret>
```

Build the package as in [the first submission](#the-first-submission-by-hand)
(with the next version), then:

```powershell
$id = "<STORE_PRODUCT_ID>"
$package = (Get-ChildItem artifacts/AppPackages -Recurse -Filter *.msixupload).FullName
msstore publish $package --appId $id --noCommit
msstore submission get $id > submission.json
./windows/scripts/store/New-StoreListingJson.ps1 -BaseSubmission submission.json -OutFile submission-update.json
msstore submission updateMetadata $id submission-update.json
msstore submission publish $id
msstore submission poll $id
```

## Versioning

- Store package versions are four numbers, **A.B.C.0**. The Store reserves the
  last one (it must be 0); `Set-AppVersion.ps1` refuses anything else.
- Every package must have a **higher version** than the one before it (for the
  same architecture), or the upload is rejected.
- A tag `windows-vA.B.C` gives `A.B.C.0`. A manual run without a version gives
  `version.txt`'s A.B plus the run number as C (the run number only goes up).
  Each number can be at most 65535.
- Pick one scheme per A.B: if you tag `windows-v1.1.3` after manual runs made
  `1.1.40.0`, 1.1.3 is lower and gets rejected. When switching, bump
  `version.txt` to the next minor version first.
- The version is written into the manifest in CI only; the committed manifest
  stays at `1.0.0.0`.

## The listing files

`windows/store/listing/<language>/`, one folder per Store listing language
(folder names like `en-us`). Adding a language folder adds that language's
listing, which the Store only accepts when the package declares that language.

| File | Store field | Limit |
|---|---|---|
| `title.txt` | Product name | must be a reserved name |
| `short_description.txt` | Short description | 1,000 characters |
| `description.txt` | Description | 10,000 characters, required |
| `features.txt` | Product features, one per line | 20, 200 characters each |
| `keywords.txt` | Search terms, one per line | 7, 40 characters each, 21 words in all |
| `release_notes.txt` | What's new in this version | 1,500 characters |
| `copyright.txt` | Copyright and trademark info | 200 characters |
| `privacy_policy_url.txt`, `website.txt`, `support_contact.txt` | set once in Partner Center (step 4) | https URLs |

Keep keywords trademark-clean: no "AO3" or "Archive of Our Own" (the script
refuses them). The description names Archive of Our Own only to say what the
app reads, and carries the "not affiliated with AO3 or the Organization for
Transformative Works" line.

## Screenshots and Store art

The listing's pictures are built the way the iOS ones are (`fastlane
screenshots`, then `apple/bin/frame-screenshots.py`): the app is photographed in demo
mode, then each picture is laid out as a web page on the brand canvas and
rendered at the Store's exact size by headless Chrome.

| Output | Size | What it is |
|---|---|---|
| `windows/store/screenshots/en-us/NN-slug.png` | 3840 × 2160 | Ten listing screenshots: a label, a serif headline with a gold accent, and the app in a Windows 11 window (one slide adds an upright tablet beside the desktop) |
| `windows/store/screenshots/en-us/captions.txt` | | One caption per screenshot |
| `windows/store/images/en-us/PromotionalArt16x9.png` | 3840 × 2160 | Hero image: the reader as an open book, tilted, with the app icon; no text, since the Store sets the name over it |
| `windows/store/images/en-us/StoreLogoSquare.png` | 2160 × 2160 | Box art: icon and name |
| `windows/store/images/en-us/StoreLogo9x16.png` | 1440 × 2160 | Poster art: icon, name, "Your AO3 reader for Windows." and the reader |
| `docs/screenshots/windows/showcase.jpg` | | The first three screenshots side by side, for the README |

How it fits together:

1. **Capture.** `ScreenshotTests` runs the demo app at a `store` size (a
   1200 × 750 window, `-captureScale 2.4`) and a `store-tablet` size
   (834 × 1112, `-captureScale 2`). Capture mode (demo only,
   `Platform/CaptureMode.cs`) draws the whole window at that scale, title bar included, and lets the window be larger
   than the screen, so a 1024 × 768 CI runner still produces 2880 × 1800
   pictures. The system caption buttons can't scale, so they're hidden and
   drawn as plain glyphs. `CaptureReaderPages` opens the reader page by page
   on a mid-chapter spread (`13-reader-spread`).
2. **Lay out.** `windows/scripts/make_store_art.py` (Python 3 with Pillow, and
   Chrome, Edge or Chromium) fills `windows/store-art/screenshot.html` and
   `promo.html` with each capture and renders them. The slides' order, labels,
   headlines and captions are the `SLIDES` list at the top of the script
   (`*word*` is the gold accent); the hero, box and poster are `PROMOS`.
3. **Commit.** The **Windows screenshots** workflow
   (`.github/workflows/windows-screenshots.yml`) does both steps on a Windows
   runner and commits the results with the README pictures. Run it from the
   Actions tab (on a PR branch to commit the pictures to that PR, or on
   `main`), or push to `main` with `[screenshots]` in the last commit's
   message; that push must touch `windows/` or the Windows workflows. A
   commit the workflow pushes doesn't start CI, so push again to re-check a
   PR. CI also builds the art on
   every push (without committing it) and prints it into the job log, so a
   layout problem shows up early.

To build them on your own PC (Windows, from `windows/`):

```powershell
dotnet build src/Fanficly.App -p:Platform=x64 -p:WindowsPackageType=None -p:WindowsAppSDKSelfContained=true -p:RuntimeIdentifier=win-x64 -o ../artifacts/app-x64
dotnet build tests/Fanficly.UITests
$env:FANFICLY_SCREENSHOTS = "$PWD\..\artifacts\ui-screenshots"
dotnet test tests/Fanficly.UITests --no-build --filter "FullyQualifiedName~ScreenshotTests"
python scripts/make_store_art.py --raw ../artifacts/ui-screenshots              # into the repository
python scripts/make_store_art.py --raw ../artifacts/ui-screenshots --out art   # or somewhere to look first
```

`--only N` re-renders one slide while you tune its copy.

The Store's rules, which the script follows: screenshots are PNG, at least
1366 × 768, under 50 MB, at most 10 per language, uploaded in file-name order;
captions are at most 200 characters. The hero image is 1920 × 1080 or
3840 × 2160, the box art 1080 or 2160 square, the poster 720 × 1080 or
1440 × 2160.

### Uploading them

Nothing is uploaded unless you ask: run the Store workflow with
**upload_screenshots** on, or locally after a `--noCommit` publish:

```powershell
$env:STORE_PRODUCT_ID = "<id>"; $env:AZURE_AD_TENANT_ID = "<tenant>"
$env:AZURE_AD_APPLICATION_CLIENT_ID = "<client>"; $env:AZURE_AD_APPLICATION_SECRET = "<secret>"
./windows/scripts/store/Publish-StoreScreenshots.ps1 -PackagePath artifacts/AppPackages -WhatIf   # check first
./windows/scripts/store/Publish-StoreScreenshots.ps1 -PackagePath artifacts/AppPackages
```

It replaces that language's screenshots, and each Store art type it has a file
for (trailers and other image types are left alone). `-PackagePath` matters: a
draft holds one upload, so the package that `msstore publish --noCommit` put
there goes into the same upload as the images.

## Troubleshooting

**"The STORE_PRODUCT_ID secret isn't set" / "Missing secrets" / "Missing
repository variables".** Set them as in [step 7](#7-github-secrets-variables-and-environment).
The secrets must be in the `microsoft-store` environment (or the repository);
the identity values must be repository variables.

**Partner Center sign-in fails (401/403).** The client secret has expired, or
the Entra app lost the Manager role. Add a new key in Partner Center
(**User management → Microsoft Entra applications**) and update
`AZURE_AD_APPLICATION_SECRET`.

**The package identity doesn't match** ("Invalid package identity name",
"Invalid package family name", "Invalid package publisher name"). The variables
don't match **Product identity** in Partner Center exactly; copy them again,
including every character of the `CN=` publisher.

**"The package version must be higher…"** Some earlier package (perhaps from
a manual run) had a higher version. Use a higher tag, or bump `version.txt`.
See [Versioning](#versioning).

**"We don't support first submission loose MSIX files."** The app has no live
submission yet. Do [the first submission](#the-first-submission-by-hand) in
Partner Center.

**Can't create a submission because one is in progress.** A submission in
certification, or a gradual rollout that isn't finished, blocks new ones. Wait,
cancel the submission in Partner Center, or finalize/halt the rollout.

**Paid apps.** Microsoft documents CI updates for free apps only. Fanficly is
free; if that ever changes, the updates have to go through Partner Center.

**`updateMetadata` says the JSON has no Pricing.** `msstore submission get`
didn't return the draft (the upload step may have failed). Look at the
earlier step's log.

**Certification fails.** Partner Center lists the reasons on the submission.
The technical ones (crashes, manifest problems, banned APIs) almost always
show up in the WACK report too: download the **wack-report** artifact from the
run, open `wack-report.xml` and look for tests with `RESULT` FAIL, fix, and
release a new version. Content policy failures (age rating, listing text,
the AO3 trademark) are explained in the certification report.

**Screenshot captions disappeared after a release.** The listing update goes
through the CLI's copy of the submission, which may not carry captions; run the
next release with **upload_screenshots** on to put them back.
