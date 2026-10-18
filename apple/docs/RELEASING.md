# Releasing Fanficly (iOS, iPad, Mac)

Releases run in GitHub Actions on macOS runners, so no particular Mac is
needed. Two workflows, both started by hand from the Actions tab (or
`gh workflow run`). Nothing runs on a push, a merge to `main` or a pull
request, so merging never ships anything.

| Workflow | What it does | Secrets |
| --- | --- | --- |
| **Release** (`release.yml`) | Signed builds to TestFlight or the App Store version, metadata, signing setup | yes, after approval |
| **Store assets** (`store-assets.yml`) | Regenerates screenshots, app previews and creative art; optionally uploads them | only the optional upload job |

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

Only when the maintainer asks for one.

1. Bump `MARKETING_VERSION` in `project.yml` in a PR and merge it. The
   build number is automatic (one past the highest on TestFlight for iOS or
   Mac, or `CURRENT_PROJECT_VERSION`), and both platforms share it.
2. Write the What's New text from what merged since the last release:
   `bin/release-notes.sh` (needs `gh`) lists the merged PRs and closed
   issues since the last `v*` tag into `build/release/changes.md`.
3. Run **Release** with lane `release`, platform `both`, and the notes:
   ```bash
   gh workflow run release.yml -f lane=release -f platform=both -F notes=@notes.txt
   ```
   Approve the job when GitHub asks. It builds and uploads both apps, pushes
   the metadata and screenshots with the new What's New text, then tags
   `vX.Y.Z` and publishes the GitHub release (the notes plus the list of
   merged PRs and closed issues). Left blank, the notes default to the merged
   PR titles.
4. Submit for review in App Store Connect. No lane submits.

Lane `beta` builds and uploads to TestFlight only, with the same notes as
the TestFlight "What to Test", and doesn't tag. `metadata_only` pushes copy
and screenshots without a build.

## Regenerating the store art

Run **Store assets**:

- `store_art` (default) captures every screenshot in demo mode on the
  simulators (iPhone 17 Pro Max, iPad Pro 13-inch portrait, the landscape iPad
  standing in for the Mac, and iPhone Duo when the runner's Xcode has it),
  frames them, records the three app-preview videos with their captions, and
  renders the product-page header and search-results art.
- Tick **upload** to put it all on the editable App Store versions (iOS and
  Mac screenshots, previews, Duo screenshots, creative assets). The upload job
  waits for approval in `app-store`. An editable version must exist: run a
  `release` or `metadata_only` first.
- The `store-art` artifact has every image and video; check
  `build/preview-contact-sheets/`, since the preview captions are timed to the
  recordings (`bin/record-app-previews.sh` explains how to re-tune them).

Limits: the iPhone Duo's pose can only be set by hand in Device Hub, so CI
captures the display it boots on and reframes the committed captures for the
other. The art needs Apple's SF Pro and New York fonts, which the workflow
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

Xcode Cloud builds what is committed, and the committed `Fanficly.xcodeproj`
only lists the files it had when XcodeGen last ran. So
`ci_scripts/ci_post_clone.sh` installs XcodeGen and regenerates the project
from `project.yml` before every Xcode Cloud build, as GitHub CI does; new
Swift files build there without a Mac.

## Running lanes on a Mac

`cd apple`, `bundle install`, then the same lanes. Put the API key in
`fastlane/api_key.json` (`key_id`, `issuer_id`, `key` = the `.p8` text) and
`fastlane/AuthKey_<key_id>.p8` (both git-ignored), and export
`APPLE_TEAM_ID` and `MATCH_PASSWORD`. Release lanes rewrite
`Signing.xcconfig` for the build and put it back afterwards.
