# Accessibility

This covers Fanficly for iPhone, iPad and Mac. For the Windows app, see [windows/ACCESSIBILITY.md](../windows/ACCESSIBILITY.md).

Fanficly is built to be a calm, flexible reading app, with particular attention
to readers who need **larger text** or a **darker interface**.

## Larger Text

- Story text runs from 12 to 60 points, more than three times the 18-point
  default, with independent **line-spacing**, **paragraph-spacing**, and
  **column-width** controls to space it for comfortable reading.
- Story text starts at your device's **text size** (Settings › Accessibility ›
  Display & Text Size › Larger Text, or the Text Size control): 18 points at
  the standard size, and up to 56 points at the largest accessibility size.
  Once you've set a size or saved a profile, the reader keeps your choice.
- **Bold text** and **character-spacing (kerning)** controls give heavier
  strokes and looser letterforms for readers who need them. When **Bold Text**
  is on in your device's accessibility settings, story text is bold too.
- Several font families are available, including highly legible choices.

## Dark Interface

- Six reading themes — **Light**, **Sepia**, **Dark**, **OLED Black**,
  **Dracula Navy**, and **Match System** — let you choose a low-glare or
  true-black background for low-light reading and reduced eye strain.
- The reader's navigation bar and chapter indicator are themed to match, so
  there are no bright flashes when opening or leaving a story.

## Listen aloud

- **"Listen"** reads any chapter aloud with your device's high-quality
  text-to-speech, for hands-free reading or readers who prefer audio. It
  advances chapter to chapter on its own and keeps playing in the background and
  from the lock screen, with standard Now Playing controls.
- The spoken paragraph is **highlighted and scrolled into view** as it's read,
  so it's easy to follow along.
- Voice and speaking rate are adjustable in Reader settings, and on supported
  devices you can narrate with your own **Personal Voice**. Narration is fully
  on-device — no network, no data usage.

## More reading-comfort features

- Continuous-scroll, swipe-by-chapter, or page-by-page reading modes.
- A **Keep screen awake** toggle stops the display from dimming or locking while
  you read.
- Your exact reading position is saved and restored, down to the paragraph, so
  you never lose your place.
- **Reader profiles** save complete typography setups under a name, and
  iPhone, iPad, and Mac each keep their own settings — useful when different
  readers (or different lighting conditions) need very different text.
- **Keyboard support**: in the reader, the arrow keys, Page Up / Page Down
  and Space (Shift+Space back) turn pages or scroll a screenful with a
  hardware keyboard or a Bluetooth page turner, and the Mac app has a global interface zoom in the View menu (⇧⌘+ / ⇧⌘−; ⌘0 for actual size), separate from the story's text size (⌘= / ⌘− in the Reader menu).
- All reading preferences persist across the app and between sessions.

## Native by design

Fanficly is built with native SwiftUI, so the rest of the app inherits system
accessibility behaviors such as Dynamic Type, Bold Text, and Dark Mode. The
reader keeps its own text size (so you can read larger or smaller than the rest
of your device), starting from your system text size and following Bold Text as
described above. Improving support for assistive technologies like VoiceOver is
an ongoing effort.

## Feedback

Accessibility is never "done." If something isn't working for you, please open
an issue at <https://github.com/yennster/fanficly/issues> — we want to hear
about it.
