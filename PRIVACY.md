# Privacy Policy

Effective: 2026-06-09

## What we collect

**Nothing.**

Fanficly has no servers. There is no analytics, no crash reporting, no telemetry, no advertising SDKs, no device identifiers logged anywhere outside your device.

## What is stored on your device

- **Your AO3 session cookie** (`_otwarchive_session`), kept in the iOS Keychain so you stay logged in between sessions
- **Works you've saved offline**, your reading position, custom folders, and your bookmark/history/subscription cache, kept in your app's private SwiftData store and Documents directory
- **Your preferences** (theme, font size, reader profiles, etc.), kept in app storage
- **Your last-read story and its progress**, kept in a private app-group container shared only between the app and its home-screen widget

None of this is ever sent to us — there is no Fanficly server. The only place any of it can go off-device is your own iCloud account, described next.

## iCloud sync (your iCloud, not ours)

If your device is signed into iCloud, Fanficly syncs some data between **your own devices** through Apple's iCloud:

- **Library backups** (saved works, folders, reading positions, preferences) — only if you turn on *Sync Library to iCloud* in Settings; the same screen lets you restore or delete the backup
- **Reader settings profiles** and **last-read progress** (story, chapter, and paragraph — what the widget shows) — synced automatically via iCloud key-value storage

This data lives in your private iCloud account and is covered by Apple's iCloud terms. We cannot access, read, or delete it — Fanficly has no servers and no access to your Apple ID. Signing out of iCloud on the device stops all syncing, and the library backup can be deleted from Fanficly's settings at any time.

## What your device sends to AO3

The app makes HTTP requests directly to `archiveofourown.org` on your behalf, the same way a web browser would:
- To read works, the app fetches `/works/<id>` and downloads `/downloads/<id>/...epub` files
- To search, the app submits queries to `/works/search`
- To log in, the app POSTs your username and password to `/users/login` and stores the resulting session cookie
- To sync your account state, the app fetches your bookmarks, history, and subscriptions pages while logged in

We never store your AO3 username or password. The session cookie is sufficient for authenticated requests.

## Cookies

The only cookie stored is AO3's own session cookie, set by AO3's login response. Under GDPR/ePrivacy this falls under "strictly necessary for a service explicitly requested by the user" — no consent banner is required for these cookies.

We do not set any first-party cookies of our own.

## Your rights under GDPR / CCPA

Because Fanficly has no servers and collects no data, there is no copy of your information held by us to provide, correct, or delete. Your data exists exclusively on your device and — if you use iCloud sync — in your own private iCloud account, which only you control.

**To delete all locally stored data:** delete the app. iOS removes all sandboxed app storage, including the Keychain entries created by the app. This is the erasure mechanism. If you enabled iCloud library sync, delete the backup from Fanficly's settings (or manage it in iOS Settings → iCloud storage) before removing the app.

**To export your AO3 account data:** request it directly from AO3 — they are the data controller for your account.

## Children's privacy

AO3 itself requires users to be 13 or older. Fanficly's App Store age rating is 17+ because explicit-rated works are reachable through search.

## Changes

If we ever begin collecting data (we don't intend to), we will publish a new version of this policy on this page, increment the version in the app, and surface the changes in the Settings screen before continuing.

## Contact

Issues and questions: [github.com/yennster/fanficly/issues](https://github.com/yennster/fanficly/issues).
