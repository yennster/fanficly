# What's New

`whats-new.json` is every release's highlights, written once for every Fanficly app
(#422). Both apps bundle it, so nothing is fetched:

- **The pop-up.** The first time someone opens the app after an update, it shows the
  newest release's themes once (a sheet on iPhone, iPhone Duo, iPad and Mac, a dialog
  on Windows), with Continue and See All Updates. A fresh install shows nothing, and a
  launch that opened a story or a link waits for the next ordinary launch. Each device
  remembers the newest release it has shown under `whatsNew.lastSeenVersion`.
- **Settings → About → What's New** lists every release, newest first.
- **The store notes.** `apple/bin/release-notes.py` turns the entry whose `version` is
  `MARKETING_VERSION` into the App Store and Microsoft Store notes, one `• Title: detail`
  line per theme, while that version has no `v*` tag yet.
- **On Windows** the dialog and the list go by date, not version: the entries carry the
  Apple app's version numbers, and the Windows app's own differ.

## Writing an entry

Add it at the top of `releases`, in the PR that bumps the version or one before it:

```json
{
  "version": "1.14.0",
  "date": "2026-11-24",
  "themes": [
    { "icon": "magnifyingglass", "title": "Find in this story", "detail": "Search the words of the story you're reading." },
    { "icon": "bell", "title": "Never miss a chapter", "detail": "…", "platforms": ["apple"] }
  ]
}
```

- **Short and by theme.** Three to five themes per app, each a few words of title and one
  line. Group the release's changes; don't list every pull request.
- **`platforms`** (`"apple"`, `"windows"`) on a theme shows it only in those apps; on a
  release, it applies to every theme that names none. Without either, a theme shows
  everywhere. An app shows a release only when at least one theme is for it.
- **`icon`** is an SF Symbol name that the Windows app also maps
  (`windows/src/Fanficly.App/UI/Symbols.cs`); both apps' tests fail for an icon either
  can't draw.
- **`date`** is `yyyy-MM-dd`, the day it ships. The apps show only dated entries (and the
  Apple app none newer than its own version), so an entry written ahead of a release stays
  hidden from builds shipped before it: add the date in the PR that bumps the version.
- The text is shown as written (it isn't in either app's string tables).
