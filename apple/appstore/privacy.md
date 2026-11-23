# App Privacy — nutrition label answers

Set these in App Store Connect → your app → **App Privacy**. They match
`Fanficly/PrivacyInfo.xcprivacy` and `PRIVACY.md`.

## Data collection

**Do you or your third-party partners collect data from this app?** → **No**

That single answer produces the **"Data Not Collected"** label. Rationale:

- No analytics, crash reporting, ads, or SDKs with a network side-channel.
- No account is required. If the user logs into AO3, their AO3 username and
  AO3's cookies are stored only in the Keychain on-device and are never sent
  anywhere except archiveofourown.org. The password is never stored.
- Saved works, reading position, hidden works, folders, followed authors, and
  preferences live in on-device storage. iCloud sync (the optional library
  backup, and the automatic reader profiles, last-read progress for the widget
  and reading-streak days) goes only to the user's
  **own** iCloud account — never to the developer or any third party — so it is
  not "data collection" under App Privacy definitions (data must be sent off
  device to you or your partners to count).
- AO3 account bookmarks and chapter comments are fetched live from AO3 for
  display and never stored off-device; a posted comment is sent only to AO3.

## URLs

- **Privacy Policy URL:** https://github.com/yennster/fanficly/blob/main/PRIVACY.md
  - (Optional upgrade: publish `PRIVACY.md` via GitHub Pages for a cleaner URL.)
- **Support URL:** https://fanficly.app
- **Marketing URL (optional):** https://fanficly.app

## Privacy manifest

`Fanficly/PrivacyInfo.xcprivacy` already declares zero tracking and zero
collected data types; nothing to change.
