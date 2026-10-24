# Releasing Fanficly (iOS, iPad, Mac)

Releases run in GitHub Actions on macOS runners, so no particular Mac is
needed. Two workflows, both started by hand from the Actions tab (or
`gh workflow run`). Nothing runs on a push, a merge to `main` or a pull
request, so merging never ships anything.

| Workflow | What it does | Secrets |
| --- | --- | --- |
| **Release** (`release.yml`) | Signed builds to TestFlight or the App Store version, metadata, signing setup | yes, after approval |
| **Store assets** (`store-assets.yml`) | Regenerates screenshots (captured in Xcode Cloud), app previews and creative art; optionally uploads them | the Xcode Cloud capture and the optional upload |
| **Restore the creative art** (`creative-restore.yml`) | Downloads the live iOS version's header and search-results art, keeps it in git, and puts it back on the editable version | yes, after approval |

Every job that touches secrets runs in the **`app-store` environment**: it
waits until the repo owner approves it, and only runs from `main`. The
secrets live only in that environment. The workflows also refuse to run for
anyone but the owner.

## Where things live

Paths here are relative to `apple/`, where the Apple app lives; the workflows
are in the repo root's `.github/workflows/` and run every step from `apple/`.

- **Lanes:** `fastlane/Fastfile` (tracked; nothing secret in it).
- **Store copy:** `fastlane/metadata/` (iOS) and `fastlane/metadata-mac/`
  (Mac), tracked. The App Review contact details and demo login are not: they come from
  secrets at upload time.
- **Certificates and profiles:** fastlane match, encrypted with
  `MATCH_PASSWORD`, in the private repo `yennster/fanficly-certificates`.
  The workflows reach it with a deploy key.
- **App Store Connect:** an API key (Admin role, because match creates
  certificates with it).
- **Generated art:** built in CI and kept as workflow artifacts, never
  committed, except the raw captures (`docs/screenshots/`) and the README set
  (`screenshots/final/`), which the Store assets run pushes to a
  `store-assets/run-N` branch to merge with a PR.

## One-time setup

1. App Store Connect → Users and Access → Integrations → App Store Connect API
   → **+**, role **Admin**. Download the `.p8` (only once) and note the Key ID
   and Issuer ID.
2. On your own computer, with `gh` logged in as the repo owner:
   ```bash
   bin/setup-release-secrets.sh
   ```
   It creates the certificates repo and the environment if they're missing,
   adds the deploy key, generates `MATCH_PASSWORD` (save it in your password
   manager), and stores the API key, Team ID and App Review contact as
   environment secrets. Nothing goes through a file in the repo.
3. Run **Release** with lane `signing_setup` once. It creates an Apple
   Distribution certificate, a Mac Installer Distribution certificate, and
   App Store profiles for the app, widget and share extension on iOS and Mac
   Catalyst, and stores them in the match repo. Run it again when a
   certificate expires. Apple allows a few distribution certificates per
   team; if it says the limit is reached, revoke an old one in the Developer
   portal first (that can't be undone, and builds signed with it keep
   working).
4. Run **Release** with lane `pull_metadata`. It downloads the live store
   copy for both platforms as the `metadata` artifact; commit it to
   `fastlane/metadata/` and `fastlane/metadata-mac/`.

## Cutting a release

Only when the maintainer asks for one. One release ships every app with one
set of notes: iPhone, iPad and Mac through App Store Connect, Windows through
the Microsoft Store, and a refresh of every platform's screenshots and docs.

1. Bump `MARKETING_VERSION` in `apple/project.yml` (and
   `windows/store/version.txt` if Windows moves to a new version) in a PR and
   merge it. Apple build numbers are automatic: Xcode Cloud numbers each
   archive with its build-run number, so iOS and Mac get different ones (the
   GitHub release lists both). They count up across every Xcode Cloud build,
   so they stay above the 1.11.1 Mac build (141) that the runner built.
2. The What's New text writes itself: the Release run's first job runs
   `apple/bin/release-notes.py`, which reads everything that landed on `main`
   since the last `v*` tag (every merged PR, any commit pushed without one,
   and every issue closed as completed) and writes into
   `apple/build/release/`:
   - `notes.txt`, the App Store "What's New": the PRs that changed the Apple
     app's code (`apple/Fanficly*/`);
   - `notes-windows.txt`, the Microsoft Store's (1,500 characters at most):
     the PRs that changed `windows/src/`;
   - `changes.md`, the full list, for the GitHub release.
   Tests, docs, CI and website changes stay out of the store notes. Each line
   is the PR title, tidied, and a feature that landed in both apps is listed
   once. When a title doesn't read well in a store, give the PR a line
   `Release note: <text>` in its description, or add it to
   `.github/release-notes.tsv` (`none` leaves it out). Check the notes before
   releasing with `GITHUB_REPOSITORY=yennster/fanficly apple/bin/release-notes.py`
   (needs `gh`), or on the run's summary page.
3. Run **Release** with lane `release` and platform `all`:
   ```bash
   gh workflow run release.yml -f lane=release -f platform=all
   ```
   `-f notes="…"` replaces the generated text in every store.
   Approve the runs as GitHub asks: `app-store` for the builds, `app-store`
   again for the store art upload, then `microsoft-store`. It:
   - builds and uploads the iPhone/iPad and Mac apps and pushes the store
     copy with the new What's New (no App Store submit);
   - starts **Windows screenshots** and **Store assets** onto a
     `release-docs/vX.Y.Z` branch and waits for both; Store assets uploads
     the new Apple screenshots, previews and art to the editable versions;
   - starts **Windows Store release** from that branch with the Windows notes
     and the new screenshots, which submits to the Microsoft Store for
     certification;
   - meanwhile, once the Apple builds are up, tags `vX.Y.Z` and publishes the
     GitHub release (both stores' notes plus `changes.md`). That tag is where the next release's notes start, for
     every app.
   Platform `apple`, `ios`, `mac` or `windows` releases just that part, with
   no art refresh.
4. Once the Store assets upload has finished, Submit for Review in App Store
   Connect (iOS and macOS). No lane submits there, and submitting earlier
   locks the version before the new art is on it.
5. Update any doc text that changed with the release on the
   `release-docs/vX.Y.Z` branch, and merge it with a PR.

Lane `beta` builds and uploads to TestFlight only, with the same notes as
the TestFlight "What to Test", and doesn't tag. `metadata_only` pushes copy
and screenshots without a build.

## Regenerating the store art

Run **Store assets**:

- `store_art` (default) captures every screenshot in demo mode in Xcode
  Cloud, on the newest Xcode 27+ like every build (iPhone 17 Pro Max, iPad Pro
  13-inch portrait, the landscape iPad standing in for the Mac, and iPhone
  Duo; `bin/xcode-cloud-store-art.py`), frames them, records the three
  app-preview videos with their captions, and renders the product-page header
  and search-results art. The capture job waits for approval in `app-store`
  (it needs the API key) and pushes a temporary `store-art/capture-*` branch
  for Xcode Cloud to build, deleted when it's done.
- Tick **upload** to put it all on the editable App Store versions (iOS and
  Mac screenshots, previews, Duo screenshots, creative assets). The upload job
  waits for approval in `app-store`. An editable version must exist: run a
  `release` or `metadata_only` first.
- The `store-art` artifact has every image and video; check
  `build/preview-contact-sheets/`, since the preview captions are timed to the
  recordings (`bin/record-app-previews.sh` explains how to re-tune them).

Limits: the iPhone Duo's pose can only be set by hand in Device Hub, so Xcode
Cloud captures the display it boots on and the committed captures stay for the
other. Xcode Cloud has no `simctl` for the test itself, so the 9:41 status bar
is set by `ci_scripts/ci_pre_xcodebuild.sh` before the tests, best effort; a
simulator it misses shows the real time. A device that errors keeps its
committed captures; the run's `capture-results` artifact has its Xcode Cloud
log bundle. The app previews are simulator video
recordings, which Xcode Cloud can't make, so they still record on GitHub's
runner (they show the iPhone and iPad, not the Duo). The art needs Apple's SF Pro and New York fonts, which the workflow
installs from developer.apple.com.

## Xcode Cloud

Xcode Cloud also builds the app, configured in App Store Connect (Xcode Cloud →
Manage Workflows), not in this repo. Each workflow stores the project's path,
which must be `apple/Fanficly.xcodeproj`. If a build fails with "Fanficly.xcodeproj
does not exist at the root of the repository", run the **Xcode Cloud project
path** workflow (`xcode-cloud.yml`, `bin/xcode-cloud-project-path.py`): without
"apply" it lists each workflow's path, with it it points the outdated ones at
`apple/`. It uses the same `app-store` secrets, so it only runs from `main`.
Any start conditions that filter on file paths are edited in App Store Connect.

The **Duo tests** workflow is the exception: `bin/xcode-cloud-duo.py` makes and
updates it through the API, because GitHub's runners have no Xcode with the
iPhone Duo yet. It runs `ReaderLayoutTests` (scheme `FanficlyReaderLayout`) on
the Duo simulator, in the pose it boots in, for every pull request into `main`
that touches `apple/`, and Xcode Cloud shows it on the PR as a check. When that
check ends, the **Xcode Cloud Duo tests** workflow (`xcode-cloud-duo.yml`, run
from `main` with the `app-store` secrets) downloads the result bundle, uploads
its screenshots as the `duo-tests` artifact and links that run from the PR's
commit as the "Duo screenshots" status. Started by hand, it brings the Xcode
Cloud workflow up to date (the newest Xcode with a Duo) and, given a branch,
tests that branch and waits for the screenshots. Run it once by hand after a
new Xcode lands. The PR builds use Xcode Cloud compute hours.

Xcode Cloud builds what is committed, and the committed `Fanficly.xcodeproj`
only lists the files it had when XcodeGen last ran. So
`ci_scripts/ci_post_clone.sh` installs XcodeGen and regenerates the project
from `project.yml` before every Xcode Cloud build, as GitHub CI does; new
Swift files build there without a Mac.

### Xcode 27 or later for every build

An iOS app built with an SDK older than a device runs in compatibility mode on
that device. 1.11.0 was built with the GitHub runner's Xcode 26.6, so the
iPhone Duo showed it as a letterboxed iPhone app instead of its Duo layout.
So every Apple build uses the newest Xcode 27 or later, which for now means
Xcode Cloud, kept in code:

- **Release (iOS)** and **Release (Mac)** (`bin/xcode-cloud-release.py`):
  **Release** archives both at once, Xcode Cloud signs them with cloud-managed
  signing (`ci_post_clone.sh` writes its team into `Signing.xcconfig`) and
  uploads them, and fastlane attaches each build to its App Store version, or
  gives it its TestFlight notes (`ios_build:`, `mac_build:`).
- **CI** (`bin/xcode-cloud-ci.py`): the unit and UI tests that GitHub's
  `ci.yml` used to run, on every PR into `main` and push to `main` touching
  `apple/`.
- **Store art** (`bin/xcode-cloud-store-art.py`): the App Store screenshots,
  started only by **Store assets**.
- **Duo tests**, below.

Each uses Xcode Cloud's "Latest Release" Xcode when it has the iPhone Duo,
else the newest Xcode 27+ that does (`bin/xcode_cloud.py`). The **Xcode Cloud
workflows** workflow (`xcode-cloud-setup.yml`) updates all of them when their
scripts change on `main`, and by hand; **Release** refreshes its two first.
Older Xcodes are refused by `bin/xcode_cloud.py`, by `ci_post_clone.sh` in
every Xcode Cloud build, and by fastlane's `check_xcode` (`build_signed`,
`unit_tests`, `reader_layout_tests`). Only the app-preview videos still build
on GitHub's runner (see Regenerating the store art). All of this uses Xcode
Cloud compute hours.

## Running lanes on a Mac

`cd apple`, `bundle install`, then the same lanes. Put the API key in
`fastlane/api_key.json` (`key_id`, `issuer_id`, `key` = the `.p8` text) and
`fastlane/AuthKey_<key_id>.p8` (both git-ignored), and export
`APPLE_TEAM_ID` and `MATCH_PASSWORD`. Release lanes rewrite
`Signing.xcconfig` for the build and put it back afterwards.
