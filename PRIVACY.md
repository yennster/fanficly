# Privacy Policy

Effective: 2026-05-31

## What we collect

**Nothing.**

Fanficly has no servers. There is no analytics, no crash reporting, no telemetry, no advertising SDKs, no device identifiers logged anywhere outside your device.

## What is stored on your device

- **Your AO3 session cookie** (`_otwarchive_session`), kept in the iOS Keychain so you stay logged in between sessions
- **Works you've saved offline**, your reading position, and your bookmark/history/subscription cache, kept in your app's private SwiftData store and Documents directory
- **Your preferences** (theme, font size, etc.), kept in app storage

None of this leaves your device.

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

Because Fanficly has no servers and collects no data, there is no remote copy of your information for us to provide, correct, or delete. Your data exists exclusively on your device.

**To delete all locally stored data:** delete the app. iOS removes all sandboxed app storage, including the Keychain entries created by the app. This is the erasure mechanism.

**To export your AO3 account data:** request it directly from AO3 — they are the data controller for your account.

## Children's privacy

AO3 itself requires users to be 13 or older. Fanficly's App Store age rating is 17+ because explicit-rated works are reachable through search.

## Changes

If we ever begin collecting data (we don't intend to), we will publish a new version of this policy on this page, increment the version in the app, and surface the changes in the Settings screen before continuing.

## Contact

Issues and questions: [github.com/yennster/fanficly/issues](https://github.com/yennster/fanficly/issues).
