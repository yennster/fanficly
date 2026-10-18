# App Review notes & age rating

The concise version of this lives in `fastlane/metadata/review_information/notes.txt`
and is uploaded automatically. This file is the fuller reference.

## What to put in "Notes for Reviewer"

(Already in `notes.txt` — uploaded by `fastlane release`/`metadata_only`.)

Key points: Fanficly is a privacy-first **reader** for fiction published on
Archive of Our Own (AO3). **No login or demo account is needed** to review the
full app. All works are hosted and moderated by AO3; Fanficly does not host
content. A few optional features sign in to AO3 (subscribing on AO3, viewing
your own AO3 bookmarks, and posting a chapter comment), but none are required
to review the app.

## Why this passes Guideline 1.2 (user-generated content)

App Review expects five things for apps that surface UGC. We have all five:

| Requirement | Where it is |
|---|---|
| Method to filter objectionable material | Settings → Content & Safety → "Filter mature & explicit works" (ON by default) |
| Mechanism to report content | Work "…" menu → "Report this work" (opens AO3's abuse form) |
| Mechanism to block/hide | Work "…" menu → "Hide this work" (managed in Settings → Hidden works) |
| Published contact info | Settings → Send feedback; Content policy → Email the developer |
| Act on reports promptly | Content policy states a 24-hour review commitment |

Plus a **17+ age confirmation** on first launch.

**Comments.** The app can display a work's AO3 comment thread and, only when the
user is logged into their own AO3 account, post a comment. Comments are hosted
and moderated by AO3 — Fanficly stores none of them and adds no comment system
of its own. Posting goes through AO3's standard endpoint (and its moderation),
and the same in-app "Report this work" path opens AO3's abuse form, which also
handles comments. So the five Guideline 1.2 safeguards above still cover this
surface.

## Age rating questionnaire → 17+

Answer the App Store Connect age-rating questions so the result is **17+**.
Suggested answers (set to the level that yields 17+, typically "Frequent/Intense"
for the mature-themes axis since AO3 hosts adult fiction):

- Cartoon or Fantasy Violence: None
- Realistic Violence: None
- Sexual Content or Nudity: **Frequent/Intense** (works can be Explicit)
- Profanity or Crude Humor: Infrequent/Mild
- Mature/Suggestive Themes: **Frequent/Intense**
- Horror/Fear, Medical, Alcohol/Tobacco/Drugs, Gambling, Contests: None
- Unrestricted Web Access: **Yes** (the in-app abuse-report form and AO3 links
  open archiveofourown.org)
- Made for Kids: **No**

This yields a 17+ rating, consistent with the in-app age gate.

## Background audio (Guideline 2.5.4)

The `audio` value in `UIBackgroundModes` is required by a real feature: the
**"Listen" text-to-speech reader**. It narrates a work aloud and is designed to
keep playing while the app is backgrounded and the screen is locked, with
lock-screen / Control Center transport controls and chapter auto-advance — the
same persistent-audio behavior as an audiobook or podcast app. It is 100%
on-device (`AVSpeechSynthesizer`), so it holds the privacy posture.

How to reach it (no login needed):

1. Open any work and tap to start reading.
2. Switch the reader to **paginated** mode (typography "Aa" menu) — the
   **"Listen"** bar appears at the bottom. Tap **Listen** to start narration.
3. Press the side button to **lock the device**: audio keeps playing, and the
   Now Playing controls (play/pause, skip) appear on the Lock Screen.

For the reviewer recording, capture steps 2–3 on a physical device, then press
the Home gesture to show the app backgrounded while audio continues. Attach the
recording in the **Notes** field of App Review Information.

Implementation: `Fanficly/Reader/SpeechController.swift` (the `AVAudioSession`
`.playback` / `.spokenAudio` session + `MPNowPlayingInfoCenter` /
`MPRemoteCommandCenter` wiring), surfaced by the "Listen" bar in
`Fanficly/Reader/ReaderView.swift`.

## Branding (Guideline 4.1(a))

Fanficly is an independent third-party **reader** for works on Archive of Our
Own; it is not made by, affiliated with, or endorsed by AO3 / the Organization
for Transformative Works, and the description carries that disclaimer. The app
icon and marketing screenshots use the app's own **indigo** brand color — they
do not reuse AO3's branding, logo, or signature maroon. Where the metadata names
"AO3" it does so descriptively, to state what the app reads (as many third-party
reader apps do), not to imply affiliation.

## Export compliance

`ITSAppUsesNonExemptEncryption = false` is set in `Fanficly/Info.plist`, so the
export-compliance question is auto-answered (standard HTTPS only).
