# Store screenshots

Screenshots for the Microsoft Store listing, one folder per listing language,
named the same as the folders in `../listing/` (for example `en-us/`). The
Store art (hero, box and poster images) is in `../images/`, laid out the same way.

Don't edit these by hand: they're built by `windows/scripts/make_store_art.py`
from the UI tests' 4K captures, and the **Windows screenshots** workflow
(`.github/workflows/windows-screenshots.yml`; push a commit to `windows` with
`[screenshots]` in its message, or run it from the Actions tab once the file is
on the default branch) commits them here: `en-us/01-read-like-a-book.png` …
`en-us/10-your-bookmarks.png` at 3840 × 2160, with `en-us/captions.txt`. To
change a slide's headline, caption or order, edit `SLIDES` in that script.
Look the new ones over before uploading them.

- PNG only, at most 10 per language. They're uploaded in file-name order, so
  the names start with numbers.
- The Store needs desktop screenshots of at least 1366 × 768 (landscape or
  portrait); 3840 × 2160 looks best. Each file must be under 50 MB.
- Captions go in `en-us/captions.txt`, one line per screenshot in the same
  order (a blank line means no caption, 200 characters at most).

Nothing here is uploaded unless you ask: run the Store workflow with
**Upload screenshots** ticked, or run
`windows/scripts/store/Publish-StoreScreenshots.ps1` yourself. See
"Screenshots and Store art" in `MICROSOFT_STORE.md` at the repository root.
