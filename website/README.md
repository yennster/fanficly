# Fanficly website

The marketing site at <https://fanficly.app>: one static page
(`index.html` + `styles.css`) with no build step, hosted on Vercel.

## Preview locally

```bash
npx serve website
```

## Deploy

The Vercel project `fanficly` is connected to this GitHub repo with its Root
Directory set to `website`. Merging into `main` publishes to
https://fanficly.app; every other branch gets a preview URL. `vercel.json`'s
`ignoreCommand` skips the build when a commit doesn't touch this folder, so app
commits don't redeploy the site.

`www.fanficly.app` and the old `fanficly.jennyspeelman.dev` redirect to
`fanficly.app` (also in `vercel.json`).

## Shared work links and the App Clip

`https://fanficly.app/works/<id>` (optionally `?chapter=n`) is the link the
Apple app's App Clip opens (#292; `apple/Fanficly/WorkLink.swift`). On an
iPhone or iPad iOS opens the installed app or the App Clip; anywhere else
`vercel.json` rewrites every `/works/` path to `work.html`, which links to the
work on AO3 and carries Safari's App Clip banner. It makes no requests of its
own and isn't indexed.

`/.well-known/apple-app-site-association` lists the app's universal links and
the App Clip, served as `application/json` (`vercel.json`). It holds the Apple
team ID, so the **App Clip** workflow writes it (task `website-association`,
`apple/bin/app-clip.py`) and pushes it to a branch to merge; Apple's CDN
fetches it from here, so it must stay on `fanficly.app`, not behind a redirect.
CI checks it against `apple/project.yml`.

## Images

Everything in `assets/` comes from the app's own screenshots, resized and
saved as JPEG so the page stays light:

| File | Source |
| --- | --- |
| `iphone-*.jpg`, `ipad-reader.jpg` | `apple/docs/screenshots/{iphone,ipad}/` (demo-mode captures) |
| `mac-reader.jpg` | `apple/docs/screenshots/mac/03-reader.png`, rotated upright and cropped below the status bar to 16:10 |
| `windows-*.jpg` | The app window cropped out of the Microsoft Store screenshots (`windows/store/screenshots/en-us/`, 3840×2160) |
| `og.jpg` | Microsoft Store screenshot `01-read-like-a-book.png` at 1200×675 |
| `icon.png`, `apple-touch-icon.png`, `favicon-64.png` | `apple/Fanficly/Assets.xcassets/AppIcon.appiconset/icon-1024.png` |

When the app's screenshots change, regenerate these rather than linking the
full-size PNGs.

Copy on the page follows the App Store and Microsoft Store listings. Don't add
features the apps don't have.

## Search and answer engines

`index.html` carries the title, description, Open Graph tags and JSON-LD
(a `WebSite` node that gives Google the site name, `SoftwareApplication`, and
an `FAQPage` that mirrors the FAQ section word for word; keep the two in sync).
`robots.txt`, `sitemap.xml` (which also lists the page's screenshots for image
search; add a new one there and bump `lastmod` when the page changes) and
`llms.txt` (a plain summary for AI assistants) sit next to it. Update `llms.txt` and the JSON-LD
`featureList` when the apps gain or lose a feature.
