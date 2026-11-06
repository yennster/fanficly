# Privacy Policy

Effective: 2026-11-06

This policy covers Fanficly for iPhone, iPad and Mac (the app in [`apple/`](apple/)). Fanficly for Windows has its own policy: [windows/PRIVACY.md](windows/PRIVACY.md).

## What we collect

**Nothing.**

Fanficly has no servers. There is no analytics, no crash reporting, no telemetry, no advertising SDKs, no device identifiers logged anywhere outside your device.

## What is stored on your device

- **Your AO3 sign-in**: your AO3 username and the cookies AO3 sets when you log in (its session cookie `_otwarchive_session` and its "remember me" cookie `remember_user_token`), kept in the Keychain so you stay logged in between launches. Your password is sent once to AO3 when you log in and is never stored. Logging out deletes the username and cookies
- **Works you've saved offline**, your reading position, custom folders, your own notes and personal tags on saved works, followed authors, and your bookmark/history/subscription cache, kept in your app's private SwiftData store and Documents directory
- **Your preferences** (theme, font size, reader profiles, library sort order, etc.) and which works you've left kudos on (forgotten when you log out), kept in app storage
- **Your searches** — recent searches stay on this device only (never synced or backed up; clear them from the Search screen); saved searches, and for those with new-fic alerts on the ids of the works the alerts have already seen, are kept in app storage and included in the optional iCloud library backup
- **Widget data**, kept in a private app-group container shared only between the app and its widgets: the story you read last and how far you got, your reading streak (the days you read), and short lists of your saved searches, folders, subscription updates and the works the recommendation widget picks from (title, author, a short summary and a few tags)
- **The title, author, summary and tags of each work in your Library**, in your device's on-device Spotlight index so you can find them from system search; a work leaves the index when you remove it from your Library

None of this is ever sent to us — there is no Fanficly server. On its own, the only place any of it goes off-device is your own iCloud account, described next. Like any app's data, it is also included in your device's own iCloud or computer backup if you have one turned on. You can also choose to export your library as a file (Settings → Library File); that file goes only where you send or save it, and importing one only reads the file you pick.

## iCloud sync (your iCloud, not ours)

If your device is signed into iCloud, Fanficly syncs some data between **your own devices** through Apple's iCloud:

- **Library backups** (saved works with your notes and personal tags, folders, reading positions, preferences) — only if you turn on *Sync Library to iCloud* in Settings; the same screen lets you restore or delete the backup
- **Reader settings profiles**, **last-read progress** (story, chapter, and paragraph — what the widget shows) and **the days you read** (the last 100, for your reading streak) — synced automatically via iCloud key-value storage, whether or not library sync is on

This data lives in your private iCloud account and is covered by Apple's iCloud terms. We cannot access, read, or delete it — Fanficly has no servers and no access to your Apple ID. Signing out of iCloud on the device stops all syncing. The library backup can be deleted from Fanficly's settings at any time (Settings → iCloud Sync → Clear iCloud Data); the small key-value data stays in your iCloud account, managed by Apple.

## What your device sends to AO3

The app makes HTTP requests directly to `archiveofourown.org` on your behalf, the same way a web browser would:
- To read works, the app fetches `/works/<id>` and downloads `/downloads/<id>/...epub` files
- To search, the app submits queries to `/works/search`. For saved searches you've turned new-fic alerts on for, it also runs the search in the background (and when you open the Search screen, if it hasn't for a few hours) to tell you about new fics, with a notification created on your device. While you type in the search box, the last few words you've typed are sent to AO3's tag autocomplete (`/autocomplete/tag`) to suggest exact tags — the same lookup AO3's own search form makes
- To log in, the app POSTs your username and password to `/users/login` and stores the cookies AO3 returns
- To sync your account state, the app fetches your bookmarks, history, and subscriptions pages while logged in
- To tell you about new chapters and works, the app checks the pages of works and authors you follow, your subscriptions list (at most once a day, if you're logged in) and the saved searches you've turned alerts on for. Your device runs these checks in the background when the system chooses (Fanficly asks for no more than one run every four hours), and the Subscriptions screen also checks when you open or refresh it. Notifications are created on your device; nothing passes through a notification server of ours
- To subscribe to a work, leave kudos, post a chapter comment, or save an AO3 bookmark — only when you're logged in and choose to (these are user-initiated and happen only when you tap the button) — the app POSTs that action to AO3 on your behalf; any comment text, and a bookmark's notes and tags, go only to AO3, which hosts them (and moderates comments)

We never store your AO3 password. Only your username and AO3's cookies are kept, as described above.

## Embedded story images (optional)

Some authors embed images in their works, hosted on third-party sites of their choosing (not AO3). If you turn on **Show images in stories** (Settings → Reader — it is **off** by default), the app fetches those images directly from the author's image host, exactly as a web browser would — which exposes your IP address to that host. The app only ever loads `https` image URLs, never sends your AO3 session cookie to image hosts, and adds no identifying headers. iOS may keep a temporary cache of loaded images on your device. Works you download for offline reading stay text-only regardless of this setting. Leave the toggle off and no third-party image request is ever made.

## Clipboard, drag and drop, and sharing

- **Paste (Mac):** Fanficly reads the clipboard only when you press ⌘V in its window, just to find an AO3 work link to open. Nothing else is kept.
- **Drag and drop (iPad and Mac):** Fanficly reads a link or text only when you drop it on its window, for the same reason.
- **Share sheet:** when you share an AO3 link to Fanficly from another app, it receives only that link.

## Cookies

The only cookies stored are AO3's own, set by AO3 when you log in. Under GDPR/ePrivacy this falls under "strictly necessary for a service explicitly requested by the user" — no consent banner is required for these cookies.

We do not set any first-party cookies of our own.

## Your rights under GDPR / CCPA

Because Fanficly has no servers and collects no data, there is no copy of your information held by us to provide, correct, or delete. Your data exists exclusively on your device and — if you use iCloud sync — in your own private iCloud account, which only you control.

**To delete everything Fanficly stored:**

1. **Log out of AO3** in Fanficly (Settings → Account). This asks AO3 to end the session and deletes your username and AO3's cookies from the Keychain. iOS can keep an app's Keychain entries after the app is deleted; if you skip this step, Fanficly erases them the first time it opens after a reinstall.
2. **Delete the iCloud backup** if you turned on library sync: Settings → iCloud Sync → Clear iCloud Data, or Fanficly's data in your device's iCloud storage settings.
3. **Delete the app.** This removes all of its on-device storage and its widget data.

A copy can still exist in your device's own iCloud or computer backups until those are replaced or deleted, and the small iCloud key-value data (reader profiles, last-read progress, reading days) stays with your iCloud account.

**To export your AO3 account data:** request it directly from AO3 — they are the data controller for your account.

## Children's privacy

AO3 itself requires users to be 13 or older. Fanficly's App Store age rating is 17+ because explicit-rated works are reachable through search.

## Changes

If we ever begin collecting data (we don't intend to), we will publish a new version of this policy on this page, increment the version in the app, and surface the changes in the Settings screen before continuing.

## Contact

Issues and questions: [github.com/yennster/fanficly/issues](https://github.com/yennster/fanficly/issues).
