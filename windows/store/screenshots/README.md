# Store screenshots

Screenshots for the Microsoft Store listing, one folder per listing language,
named the same as the folders in `../listing/` (for example `en-us/`).

They come from the CI screenshot job: the Windows CI workflow launches the app
in demo mode and uploads the captures as the `launch-screenshot` artifact.
Download them from the workflow run, check them, and commit the ones you want
here, for example `en-us/01-library.png`, `en-us/02-reader.png`.

- PNG only, at most 10 per language. They're uploaded in file-name order, so
  prefix the names with numbers.
- The Store needs desktop screenshots of at least 1366 × 768 (landscape or
  portrait); 3840 × 2160 or 2560 × 1440 look best. Each file must be under 50 MB.
- Optional captions go in `en-us/captions.txt`, one line per screenshot in the
  same order (a blank line means no caption, 200 characters at most).

Nothing here is uploaded unless you ask: run the Store workflow with
**Upload screenshots** ticked, or run
`windows/scripts/store/Publish-StoreScreenshots.ps1` yourself. See
`MICROSOFT_STORE.md` at the repository root.
