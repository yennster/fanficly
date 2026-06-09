# App Privacy — nutrition label answers

Set these in App Store Connect → your app → **App Privacy**. They match
`Fanficly/PrivacyInfo.xcprivacy` and `PRIVACY.md`.

## Data collection

**Do you or your third-party partners collect data from this app?** → **No**

That single answer produces the **"Data Not Collected"** label. Rationale:

- No analytics, crash reporting, ads, or SDKs with a network side-channel.
- No account is required. If the user logs into AO3, the session cookie is
  stored only in the iOS Keychain on-device and is never sent anywhere except
  archiveofourown.org.
- Saved works, reading position, hidden works, folders, and preferences live
  in on-device storage. Optional iCloud sync (library backup, reader profiles,
  last-read progress for the widget) goes only to the user's **own** iCloud
  account — never to the developer or any third party — so it is not "data
  collection" under App Privacy definitions (data must be sent off device to
  you or your partners to count).

## URLs

- **Privacy Policy URL:** https://github.com/yennster/fanficly/blob/main/PRIVACY.md
  - (Optional upgrade: publish `PRIVACY.md` via GitHub Pages for a cleaner URL.)
- **Support URL:** https://github.com/yennster/fanficly
- **Marketing URL (optional):** https://github.com/yennster/fanficly

## Privacy manifest

`Fanficly/PrivacyInfo.xcprivacy` already declares zero tracking and zero
collected data types; nothing to change.
