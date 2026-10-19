# Privacy Policy: Fanficly for Windows

Effective: 2026-10-18

This policy covers Fanficly for Windows, the app in the Microsoft Store. The iPhone, iPad and Mac app has its own policy, [`PRIVACY.md`](../PRIVACY.md) at the root of this repository.

## What we collect

**Nothing.**

Fanficly has no servers. It has no analytics, crash reporting, telemetry or advertising SDKs, and it logs no device identifiers anywhere off your PC.

## What is stored on your PC

Everything below lives in Fanficly's own app storage: the package's local data folder when installed from the Microsoft Store, or `%LOCALAPPDATA%\Fanficly` when run from a developer build.

- **Your AO3 session.** If you sign in, your AO3 username and AO3's session cookies are stored encrypted with Windows Data Protection (DPAPI) for your Windows account only. Another Windows user on the same PC can't read them. Your password is sent once to AO3 when you sign in and is never stored. Signing out deletes the cookies and username.
- **Your library.** In a database file (`library.sqlite`) on your PC:
  - works you've saved, and their chapter text if you downloaded it
  - folders, stars and pins
  - reading positions, recently viewed works and reading stats
  - followed works and authors, and the list of your AO3 subscriptions
  - saved searches and filters, works you've hidden, and tags and authors you've blocked
- **Downloads.** EPUB files you downloaded for offline reading, in a `Downloads` folder next to the library.
- **Your preferences** (theme, reader profiles and typography, sort order, voice and so on) are kept in a settings file. That file also holds:
  - your last 10 searches, which are never synced or backed up;
  - whether you confirmed you're 17 or older;
  - which works you've left kudos on, as work numbers only, deleted when you sign out;
  - the size and position of the window.
- **Widget data.** The story you read last, your reading streak, your folders, saved searches, subscriptions and a recommendation are kept in a small file that Fanficly's own widgets read, so the Windows Widgets board can show them.
- **A local diagnostic log** (`Logs\fanficly.log`). It records errors, which can include a work's title, a fandom name or a web address. It never records passwords or cookies. It's capped at 512 KB, and Fanficly never sends it anywhere.
- **The taskbar jump list.** Right-clicking Fanficly on the taskbar shows "Continue “title”" for the story you read last. Windows keeps that list on your PC.
- **A cached Popular list.** This is the daily snapshot of popular fandoms, ships and characters.

None of this is sent to us. There is no Fanficly server. The only way any of it leaves your PC is the optional sync described next.

## Sync (your folder, not ours)

Sync is **off** until you turn it on in Settings → Sync and choose a folder. That folder is usually one that a cloud service you already use keeps in sync, such as OneDrive, Google Drive, Dropbox, Box or iCloud Drive (with iCloud for Windows). If you turn sync on without choosing one, Fanficly uses a Fanficly folder in your OneDrive when OneDrive is set up on the PC. While sync is on, Fanficly writes two files there:

- **`library_backup.json`.** It holds:
  - your saved works, including downloaded chapter text
  - folders, reading positions and reading stats
  - your AO3 bookmarks and subscriptions lists
  - saved searches and filters, hidden works, and blocked tags and authors
  - your reader settings, your content settings, and whether you confirmed you're 17 or older
- **`fanficly-settings-sync.json`.** It holds:
  - your reader profiles
  - the story you read last and how far you got (its title, author, chapter and paragraph)
  - your reading-streak days

These files are as private as the folder you chose. They are governed by the terms of whichever service syncs that folder, which may be Microsoft for OneDrive, Google for Google Drive, Dropbox, Box or Apple for iCloud. We can't access, read or delete them. Turning sync off stops Fanficly from writing to the folder. **Clear Synced Data** in Settings → Sync deletes the library backup from the folder; delete `fanficly-settings-sync.json` yourself if you want that gone too. Uninstalling Fanficly doesn't touch the sync folder.

## What your PC sends to AO3

Fanficly makes requests directly to `archiveofourown.org` on your behalf, the way a web browser does. Every request identifies the app in its User-Agent (`Fanficly/<version>`, with a link to this repository), and the app never sends more than one request a second.

- **Reading:** the app fetches a work's pages, downloads its EPUB when you choose to download it for offline reading, and downloads the format you pick when you export it. "Report this work" opens AO3's report page in your web browser.
- **Search, Browse and Popular:** the app fetches AO3's search, fandom and tag pages. While you type in the search box, the last few words you typed are sent to AO3's tag autocomplete to suggest exact tags. AO3's own search form does the same lookup. Popular refreshes at most once a day.
- **Signing in:** the app sends your username and password to AO3's login form and keeps the session cookie AO3 returns.
- **Your account pages:** the app fetches your bookmarks, Marked for Later, reading history and subscriptions pages, but only while you're signed in and only when you open them or the app checks for updates.
- **New-chapter checks:** the app fetches the pages of works and authors you follow, and your subscriptions list if you're signed in, so it can tell you about new chapters and works. This happens while Fanficly is open, about every four hours. When installed from the Store it also happens from a Windows background task with the same interval, which needs an internet connection and skips its run while Fanficly is open.
- **Comments, kudos, bookmarks and subscribing:** if you're signed in and choose to post a comment, leave kudos, save an AO3 bookmark or subscribe to a work, the app sends that action to AO3. Comment text and bookmark notes and tags go only to AO3, which hosts them and moderates comments.

Notifications about new chapters are created on your PC and shown by Windows. Nothing passes through a notification server of ours.

## Microsoft and Windows

- **The Store.** Fanficly is distributed through the Microsoft Store. The Store handles installs, updates and ratings under Microsoft's own privacy statement. When you choose to rate Fanficly, the rating dialog belongs to the Store.
- **Crash reports.** Like any Windows app, Windows' own error reporting may send crash data to Microsoft, depending on your Windows diagnostic data settings. Microsoft can share aggregated crash reports with app publishers. Fanficly adds nothing to those reports and has no crash reporter of its own.
- **Voices.** Listen uses the voices installed in Windows, and speech is generated on your PC.
- **Clipboard and drag and drop.** Fanficly reads the clipboard only when you press Ctrl+V outside a text box, and reads a dropped item only when you drop it on its window, in both cases just to find an AO3 work link to open. Nothing else is kept.

## Reader features

- **Story images (optional).** Some authors embed images in their works. Those images are hosted on third-party sites the author chose, not on AO3.
  - **Show images in stories** is **off** by default.
  - When it's on, the app fetches those images directly from the image host while you read, the way a web browser would, and that host sees your IP address.
  - The app loads only `https` images, never loads one from AO3 itself, and never sends your AO3 session cookie to an image host.
  - Images are never saved with works you download for offline reading.
  - With the setting off, the app never requests anything from a third-party image host.
- **Export.** Exporting a work downloads AO3's own EPUB, AZW3, MOBI, PDF or HTML file into a temporary folder on your PC, then hands it to the Windows share sheet, or copies it to a location you pick with "Save a copy as". Where it goes from there is up to you.
- **Listen.** Read-aloud uses Windows' on-device speech synthesis. No story text is sent anywhere to be spoken. While it plays, Windows' media controls show the chapter, author and work title, on your PC only.
- **Reading position and time.** Where you are in each story, and how long you've spent reading, are recorded on your PC as described above. They leave the PC only through the optional sync.
- **Keep screen awake.** While you read, Fanficly asks Windows to keep the display on (you can turn this off in Settings). Nothing is recorded.

## Cookies

The only cookies Fanficly stores are AO3's own, set by AO3 when you sign in. Under GDPR and ePrivacy rules these are strictly necessary for a service you explicitly asked for, so no consent banner is needed. Fanficly sets no cookies of its own.

## Your rights under GDPR and CCPA

Fanficly has no servers and collects no data, so we hold no copy of your information to give you, correct or delete. Your data is only on your PC and, if you turned sync on, in the folder you chose.

**To delete everything Fanficly stored on your PC,** uninstall it. Windows then removes the app's local data folder, which holds the library, settings, downloads, log and encrypted sign-in. If you turned sync on, use **Clear Synced Data** first, or delete the Fanficly files from your sync folder yourself. If you ran a developer build, also delete `%LOCALAPPDATA%\Fanficly`.

**To get or delete your AO3 account data,** ask AO3 directly. They are responsible for your account.

## Age

AO3 requires its users to be at least 13. Fanficly is rated for ages 17 and up, because explicit works can be found through search, and it asks you to confirm your age the first time it starts. "Filter mature & explicit works" is on by default.

## Changes

If Fanficly ever starts collecting data (we don't intend to), we will:

1. publish a new version of this policy here;
2. update the app;
3. explain the change in the app before it takes effect.

## Contact

Issues and questions: [github.com/yennster/fanficly/issues](https://github.com/yennster/fanficly/issues).
