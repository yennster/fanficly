# Reply to App Review — Fanficly 1.5.1 (build 22)

Paste these into the Resolution Center reply for the corresponding guidelines.
The Mac (macOS) build of 1.5.0 was already approved; the indigo rebrand ships
to Mac as 1.5.1 (build 22), and iOS resubmits as 1.5.1 (build 22) too.

---

## Guideline 2.5.4 — Background audio

Thank you for the review. The `audio` background mode is required by a real,
shipping feature, so we'd like to keep it and have made it easy to verify.

Fanficly includes a built-in **text-to-speech reader ("Listen")** that narrates
a story aloud. Like an audiobook or podcast app, it is designed to keep playing
while the app is in the background and the device is locked, and it provides
Lock Screen / Control Center transport controls (play/pause, skip) and
automatically advances to the next chapter. Playback is entirely on-device
(AVSpeechSynthesizer) — there is no streaming — which is why it relies on the
`audio` background mode for uninterrupted playback.

To reproduce (no account or login required):

1. Open any story and tap to begin reading.
2. In the typography menu ("Aa"), switch the reader to **Paginated** mode — a
   **"Listen"** bar appears at the bottom of the page. Tap **Listen** to start
   narration.
3. Lock the device (side button). Narration continues, and the Now Playing
   controls appear on the Lock Screen. Returning to the Home Screen with audio
   still playing shows the background mode in use.

We have attached a screen recording of the above on a physical device in the
Notes field of the App Review Information section.

---

## Guideline 4.1(a) — Design - Copycats

Thank you for flagging this. Fanficly is an independent, third-party **reader**
for fan works published on Archive of Our Own (AO3). It is not made by,
affiliated with, or endorsed by AO3 or the Organization for Transformative
Works, and the App Store description states this explicitly.

To remove any resemblance to AO3's branding, we have **rebranded the app icon
and all marketing screenshots to our own indigo color scheme** (previously they
used a maroon palette). The app does not use AO3's logo, name styling, or brand
colors.

We have also revised the store listing to remove the trademark from the
foreground: the app **name** is now "Fanficly: Fanfiction Reader" (it no longer
leads with "AO3"), and we removed "AO3"/"Archive of Our Own" from the **keywords**.

Where the metadata still mentions "AO3" / "Archive of Our Own" — in the subtitle
("unofficial AO3 reader") and the description — it is purely descriptive: it tells
users which site's publicly available works the app can read, the same way many
third-party reader apps describe the content source, and the word "unofficial"
makes the lack of affiliation explicit. The app hosts no content of its own; all
works are hosted and moderated by AO3.

Please let us know if any specific phrase in the metadata should be revised
further and we'll be happy to adjust it.
