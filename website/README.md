# Fanficly website

The marketing site at <https://fanficly.jennyspeelman.dev>: one static page
(`index.html` + `styles.css`) with no build step, hosted on Vercel.

## Preview locally

```bash
npx serve website
```

## Deploy

The Vercel project's root is this folder. From the repo root:

```bash
cd website
vercel deploy --prod
```

## Images

Everything in `assets/` comes from the app's own screenshots, resized and
saved as JPEG so the page stays light:

| File | Source |
| --- | --- |
| `iphone-*.jpg`, `ipad-reader.jpg` | `docs/screenshots/{iphone,ipad}/` (demo-mode captures) |
| `mac-reader.jpg` | `docs/screenshots/mac/03-reader.png`, rotated upright and cropped below the status bar to 16:10 |
| `windows-*.jpg` | The app window cropped out of the Microsoft Store screenshots (`windows/store/screenshots/en-us/`, 3840×2160) |
| `og.jpg` | Microsoft Store screenshot `01-read-like-a-book.png` at 1200×675 |
| `icon.png`, `apple-touch-icon.png`, `favicon-64.png` | `Fanficly/Assets.xcassets/AppIcon.appiconset/icon-1024.png` |

When the app's screenshots change, regenerate these rather than linking the
full-size PNGs.

Copy on the page follows the App Store and Microsoft Store listings. Don't add
features the apps don't have.
