# Accessibility: Fanficly for Windows

Fanficly is meant to be a calm, flexible reading app. You can use it with a mouse, a keyboard, a touch screen, an Xbox controller or Narrator. It pays particular attention to readers who need **larger text** or a **darker interface**.

## Narrator and other screen readers

Fanficly is built from standard WinUI controls, so Narrator and other UI Automation screen readers can see its buttons, lists, menus and text.

- **Labels.** Every icon-only button has a spoken name, and the same name shows as its tooltip.
- **Headings.** Screen titles and section headers are marked as headings, so you can move between them with Narrator's heading navigation.
- **Rows.** A work in a search or browse list is read by its title and author, then whether it's in your Library, how far you've read, or that you finished it. Its inline save button is a separate item with its own name, so it can still be reached. Progress bars and decorative details in Library rows are hidden from Narrator.
- **Announcements** for things that otherwise happen silently:
  - search results arriving
  - a filter being added from a suggestion
  - switching tabs with a controller's bumpers
  - changing the zoom or the story's text size
  - in the reader: changing chapter, showing or hiding the controls, stopping Listen, applying a profile, saving to the Library and hiding a work
  - slow downloads and exports starting
  - messages such as "Downloaded for offline reading"
- **Icons that only decorate** text are hidden from Narrator so they aren't read twice.
- **Dialogs** are standard Windows dialogs and open one at a time.

## Keyboard

Every screen can be used from the keyboard. Settings → Input → Keyboard shortcuts lists them all.

- **Tabs:**
  - Ctrl+1 Search, Ctrl+2 Browse, Ctrl+3 Popular, Ctrl+4 Library, Ctrl+5 Recently Viewed
  - Ctrl+6 Authors, Ctrl+7 Bookmarks, Ctrl+8 Subscriptions, Ctrl+9 Stats
  - Ctrl+, Settings
- **Getting around:**
  - Alt+Left, Esc or the mouse's back button go back.
  - Tab and Shift+Tab move focus; Enter or Space activate.
  - Shift+F10 or the Menu key open a context menu.
- **Search:** Ctrl+F or F3 jump to the search box.
- **Open a link:** Ctrl+V outside a text box opens a copied AO3 work link (so does dropping one on the window).
- **Reader:** see [Turning pages](#reading-comfort-the-reader) below, plus Ctrl+L to listen.
- **Library:**
  - Enter opens a work, Delete removes it, F2 renames a folder.
  - Ctrl+F searches the library; Ctrl+Shift+N makes a new folder.
- **View:** Ctrl+Plus and Ctrl+Minus make the story text bigger or smaller, Ctrl+Shift+Plus and Ctrl+Shift+Minus zoom, Ctrl+0 resets the zoom, and F11 toggles full screen.

## Xbox controller

Plug in or pair a controller and it works throughout the app. Settings → Input shows the full map.

- The D-pad or left stick moves focus.
- A selects, B goes back, and the right stick scrolls.
- LB and RB switch tabs (Narrator announces the new tab).
- Menu shows or hides the sidebar, and View toggles full screen.
- LT and RT are passed to the screen you're on. In the reader, LT and RT and the D-pad's left and right turn pages, and LB and RB change chapter instead of switching tabs.

## Seeing the screen

- **Zoom.** The whole interface zooms from 50 % to 200 % in 10 % steps with Ctrl+Shift+Plus and Ctrl+Shift+Minus. The zoom is remembered between sessions.
- **Light and dark.** Settings → Appearance follows Windows or forces Light or Dark, and the title bar follows suit.
- **High contrast.** When a Windows contrast theme is on, the app's colours switch to the system's contrast colours, and the brand colours step aside. Reader settings suggests the "Match System" or "Dracula Navy" reading theme so story text stays readable.
- **Larger text.** Settings → Accessibility → Text size in Windows enlarges the app's text up to 225 %. From 150 % up, titles, authors and other lines that are otherwise cut to one or two lines wrap in full, settings controls move under their labels sooner, and the Library, Stats, Subscriptions and Settings screens keep their text from running off the edge. A Text size change applies to a screen's layout when the screen next rebuilds, for example when you open it again.
- **Window sizes.** The layout works from a narrow 360-pixel window up to full screen. In a narrow window the sidebar folds into a menu button in the title bar.

## Reading comfort (the reader)

The reader's settings are in its Aa menu (quick presets) and in Settings → Theme & typography (sliders, with a live preview).

- **Larger text:**
  - Story text goes from 12 to 30 points.
  - Line spacing, paragraph spacing, character spacing and margins each have their own control.
  - **Bold text** gives heavier strokes.
  - Zooming the interface with Ctrl+Shift+Plus doesn't change the story's text size, so you can set the two separately.
- **Fonts:** a choice of serif, sans-serif, rounded and monospaced faces, including Sitka (designed for reading on screen), Georgia, Segoe UI and Cascadia Mono.
- **Six reading themes:** Light, Sepia, Dark, OLED Black, Dracula Navy and Match System. They give you a low-glare or true-black page for reading in the dark.
- **Profiles:** a complete typography setup can be saved under a name, for different readers or different lighting. Windows keeps its own settings, separate from your iPhone, iPad and Mac.
- **Reading modes:**
  - continuous scroll, one chapter at a time, or page by page;
  - on a wide window, page by page can show two pages side by side like a book;
  - "Page-turn animation" can be turned off, and pages never slide when Windows' animation effects are off.
- **Turning pages:**
  - Keyboard: Left and Right, Page Up and Page Down, or Space and Shift+Space. Ctrl+Left and Ctrl+Right change chapter; Home and End go to the start or end of the chapter.
  - Mouse, pen and touch: click or tap the outer third of the page, swipe, or use the mouse wheel. The middle of the page shows or hides the reader's controls.
  - Controller: the triggers or the D-pad turn pages, and the bumpers change chapter.
- **Narrator:** the story's context menu (Shift+F10, the Menu key, or right-click) has Next and Previous page, Next and Previous chapter, Show or Hide reader controls, and Listen. Narrator announces the new page ("Page 3 of 12, chapter 2"), chapter or controls state. The page footer, the chapter indicator and the Listen bar have spoken names, and headings mark the work title and each chapter.
- **Full screen:** F11 or the full-screen button hides everything but the story. Esc brings the controls back.
- **Listen:**
  - The reader can read any chapter aloud with the voices installed in Windows (Ctrl+L, or Listen in the Aa menu), and moves on to the next chapter by itself.
  - The paragraph being spoken is highlighted and kept in view.
  - The Listen bar has play and pause, previous and next paragraph, a chapter picker, a speed from 0.5× to 2×, and stop. Your keyboard's media keys and Windows' media controls work too.
  - Voice and speed are in Settings → Theme & typography, which also links to Windows Settings for adding voices.
  - Speech is generated on your PC.
- **Keep screen awake** (on by default) stops the display from turning off while you read.
- **Your place is kept:** your position is saved down to the paragraph and restored when you come back.

## Feedback

Accessibility is never finished. If something doesn't work with Narrator, the keyboard, a controller or a contrast theme, please open an issue at <https://github.com/yennster/fanficly/issues> and say which Windows version you're on.
