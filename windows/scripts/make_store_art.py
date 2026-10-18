#!/usr/bin/env python3
"""
Builds the Microsoft Store art from the UI tests' raw captures: the Windows
counterpart of bin/frame-screenshots.py (fastlane screenshots) on main.

The raws come from `ScreenshotTests.CaptureMainScreens("store" | "store-tablet")`,
which draws the demo app enlarged ("-captureScale 2.4"), so a 1200x750 window
is captured at 2880x1800 on any runner. Each image is a web page
(windows/store-art/*.html + brand.css) rendered at the Store's exact size by
headless Chrome: the brand canvas, a label, a serif headline with a gold
accent, and the app in a Windows 11 window card.

Writes:
  windows/store/screenshots/en-us/NN-slug.png  3840x2160 listing screenshots
  windows/store/screenshots/en-us/captions.txt one caption per screenshot
  windows/store/images/en-us/PromotionalArt16x9.png  3840x2160 hero image
  windows/store/images/en-us/StoreLogoSquare.png     2160x2160 box art
  windows/store/images/en-us/StoreLogo9x16.png       1440x2160 poster art
  docs/screenshots/windows/showcase.jpg        README strip of the first three
windows/scripts/store/Publish-StoreScreenshots.ps1 uploads the first two folders.

Run (Python 3 with Pillow, and Google Chrome or Chromium):
  python windows/scripts/make_store_art.py --raw artifacts/ui-screenshots
  python windows/scripts/make_store_art.py --raw … --only 1 --only 3
CHROME=<path> picks the browser.
"""
from __future__ import annotations

import argparse
import html
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile
from string import Template

from PIL import Image

WINDOWS = pathlib.Path(__file__).resolve().parent.parent
REPO = WINDOWS.parent
ART = WINDOWS / "store-art"
ICON = REPO / "Fanficly" / "Assets.xcassets" / "AppIcon.appiconset" / "icon-1024.png"
SHOTS_OUT = WINDOWS / "store" / "screenshots" / "en-us"
IMAGES_OUT = WINDOWS / "store" / "images" / "en-us"
SHOWCASE = REPO / "docs" / "screenshots" / "windows" / "showcase.jpg"

SIZE = (3840, 2160)
PAD = 200  # extra window size, cropped off (see render)

# (raw name, slug, label, headline, Store caption, tablet raw for the "pair" layout).
# *word* is the gold italic accent. The Store shows at most 10; order = file order.
SLIDES = [
    ("13-reader-spread", "read-like-a-book", "Page by page", "Every story, *beautifully set.*",
     "Read page by page, two pages side by side on a wide window, or scroll.", None),
    ("02-search-results", "find-your-next-fic", "Smart search", "Find your next *fic.*",
     "Search AO3 by fandom, ship, character or trope, with the filters AO3 has.", None),
    ("05-browse", "desktop-and-tablet", "Made for Windows", "At your desk or *on the couch.*",
     "Built for Windows: mouse, keyboard, touch, pen and Xbox controllers.", "13-reader-spread"),
    ("08-privacy", "zero-tracking", "Private by design", "Zero tracking. *Zero ads.*",
     "No accounts, no ads and no tracking. Everything stays on your PC.", None),
    ("07-reader-settings", "make-it-yours", "Your reader", "Make every page *yours.*",
     "Themes, fonts, spacing and margins, saved as profiles you can switch between.", None),
    ("04-library", "never-miss-a-chapter", "Chapter alerts", "Never miss a *chapter.*",
     "Save stories offline, sort them into folders and get told when new chapters arrive.", None),
    ("09-tts", "listen", "Listen", "Let the story *read to you.*",
     "Listen to any chapter with Windows' own voices, right on your PC.", None),
    ("10-popular", "discover", "Discover", "See what's *popular.*",
     "See the fandoms, ships and characters with the most works on AO3.", None),
    ("11-comments", "join-the-conversation", "Community", "Join the *conversation.*",
     "Read chapter comments and leave your own when you're signed in.", None),
    ("12-bookmarks", "your-bookmarks", "Your account", "All your AO3 *bookmarks.*",
     "Your AO3 bookmarks and subscriptions, with sign-in kept safe on this PC.", None),
]

PROMOS = [
    ("PromotionalArt16x9", "hero", (3840, 2160)),
    ("StoreLogoSquare", "box", (2160, 2160)),
    ("StoreLogo9x16", "poster", (1440, 2160)),
]


def chrome() -> str:
    candidates = [
        os.environ.get("CHROME", ""),
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        shutil.which("google-chrome") or "", shutil.which("chromium") or "",
        *sorted(str(p) for p in pathlib.Path("/opt/pw-browsers").glob("chromium-*/chrome-linux/chrome")),
    ]
    for path in candidates:
        if path and os.path.exists(path):
            return path
    raise SystemExit("Google Chrome (or Chromium / Edge) is needed; set CHROME to its path.")


def shown(path: pathlib.Path) -> str:
    try:
        return str(path.relative_to(REPO))
    except ValueError:
        return str(path)


def render(page: pathlib.Path, size: tuple[int, int], out: pathlib.Path) -> None:
    """Screenshot `page` at exactly `size`, as an opaque RGB PNG."""
    width, height = size
    shot = page.with_suffix(".png")
    subprocess.run([
        chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-sandbox",
        "--allow-file-access-from-files", "--force-device-scale-factor=1",
        # Finish every compositor stage first, or big shadows can leave a blank tile.
        "--run-all-compositor-stages-before-draw",
        # Time for the web fonts and the headline fitting script.
        # Some Chrome builds give the page a viewport a little smaller than the
        # window, which leaves a white band; render larger and crop.
        "--virtual-time-budget=15000", f"--window-size={width + PAD},{height + PAD}",
        f"--screenshot={shot}", page.as_uri(),
    ], check=True, capture_output=True, timeout=240)
    img = Image.open(shot)
    if img.width < width or img.height < height:
        raise RuntimeError(f"{page.name} rendered at {img.size}, wanted {size}")
    img = img.crop((0, 0, width, height))
    out.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(out, optimize=True)


def fill(template: str, **fields: str) -> str:
    text = (ART / template).read_text(encoding="utf-8")
    return Template(text).safe_substitute(css=(ART / "brand.css").as_uri(), **fields)


def headline_html(text: str) -> str:
    return re.sub(r"\*(.+?)\*", r"<em>\1</em>", html.escape(text))


def pages_html(seed: int, width: int, height: int, count: int = 11) -> str:
    """The app icon's floating pages, faint, for depth (deterministic per seed)."""
    rng = random.Random(seed)
    out = []
    for _ in range(count):
        size = rng.uniform(.06, .15) * min(width, height) * (1.4 if width > height else 1.0)
        out.append(
            f'  <div class="page" style="left: {rng.uniform(.02, .98) * width:.0f}px; '
            f'top: {rng.uniform(.02, .98) * height:.0f}px; --ps: {size:.0f}px; '
            f'--r: {rng.uniform(-24, 24):.0f}deg; --o: {rng.uniform(.045, .085):.3f}; '
            f'--b: {rng.uniform(2, 9):.1f}px;"></div>')
    return "\n".join(out)


def window_png(raw: pathlib.Path, work: pathlib.Path) -> str:
    """The capture, trimmed of any off-screen strip PrintWindow left black."""
    img = Image.open(raw).convert("RGB")
    box = img.point(lambda v: 255 if v > 4 else 0).convert("L").getbbox()
    if box and (box[2] - box[0]) * (box[3] - box[1]) < img.width * img.height * .98:
        print(f"  note: {raw.name} has a blank edge; trimmed to {box}")
        img = img.crop(box)
    out = work / f"{raw.parent.name}-{raw.name}"
    img.save(out)
    return out.as_uri()


def make_slide(index: int, slide: tuple, raw_dir: pathlib.Path, work: pathlib.Path) -> pathlib.Path | None:
    name, slug, label, headline, _caption, side = slide
    main = raw_dir / "store" / f"{name}.png"
    if not main.exists():
        print(f"  missing {main}")
        return None
    side_html, layout = "", "single"
    if side:
        tablet = raw_dir / "store-tablet" / f"{side}.png"
        if tablet.exists():
            side_html = f'<div class="win side"><img src="{window_png(tablet, work)}"></div>'
            layout = "pair"
        else:
            print(f"  missing {tablet}; {slug} shows the desktop window alone")
    page = work / f"slide-{index:02d}.html"
    page.write_text(fill(
        "screenshot.html", w=str(SIZE[0]), h=str(SIZE[1]), layout=layout,
        main_png=window_png(main, work), side=side_html, label=html.escape(label),
        headline=headline_html(headline), pages=pages_html(index * 7 + 3, *SIZE)), encoding="utf-8")
    out = SHOTS_OUT / f"{index:02d}-{slug}.png"
    render(page, SIZE, out)
    print(f"  ok {shown(out)}")
    return out


def make_promo(kind: str, layout: str, size: tuple[int, int], raw_dir: pathlib.Path, work: pathlib.Path) -> None:
    reader = raw_dir / "store" / "13-reader-spread.png"
    window = f'<div class="win"><img src="{window_png(reader, work)}"></div>' if reader.exists() and layout != "box" else ""
    name = '<div class="name">Fanficly</div>' if layout in ("box", "poster") else ""
    tag = '<div class="tag">Your AO3 reader<br><em>for Windows.</em></div>' if layout == "poster" else ""
    page = work / f"promo-{layout}.html"
    page.write_text(fill(
        "promo.html", w=str(size[0]), h=str(size[1]), layout=layout, window=window,
        icon_png=ICON.as_uri(), name=name, tag=tag,
        pages=pages_html(len(layout) * 11, *size, count=9)), encoding="utf-8")
    out = IMAGES_OUT / f"{kind}.png"
    render(page, size, out)
    print(f"  ok {shown(out)}")


def make_showcase(paths: list[pathlib.Path]) -> None:
    """README strip: the first three screenshots side by side."""
    height, gap = 540, 24
    imgs = [Image.open(p).convert("RGB") for p in paths]
    imgs = [im.resize((round(im.width * height / im.height), height), Image.LANCZOS) for im in imgs]
    canvas = Image.new("RGB", (sum(i.width for i in imgs) + gap * (len(imgs) - 1), height), (255, 255, 255))
    x = 0
    for im in imgs:
        canvas.paste(im, (x, 0))
        x += im.width + gap
    SHOWCASE.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(SHOWCASE, quality=88, optimize=True)
    print(f"  ok {shown(SHOWCASE)}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the Microsoft Store screenshots and art.")
    parser.add_argument("--raw", default=str(REPO / "artifacts" / "ui-screenshots"),
                        help="the UI tests' output folder (with store/ and store-tablet/)")
    parser.add_argument("--only", type=int, action="append", help="only slide N (1-based)")
    parser.add_argument("--no-promo", action="store_true", help="skip the hero, box and poster art")
    parser.add_argument("--out", help="write everything under this folder instead of the repository "
                                      "(screenshots/, images/, showcase.jpg), to look before committing")
    args = parser.parse_args()
    if args.out:
        global SHOTS_OUT, IMAGES_OUT, SHOWCASE
        out = pathlib.Path(args.out).resolve()
        SHOTS_OUT, IMAGES_OUT, SHOWCASE = out / "screenshots", out / "images", out / "showcase.jpg"
    raw_dir = pathlib.Path(args.raw).resolve()
    if not (raw_dir / "store").is_dir():
        sys.exit(f"No raw Store captures in {raw_dir / 'store'}. Run the ScreenshotTests first.")

    work = pathlib.Path(tempfile.mkdtemp(prefix="fanficly-store-art-"))
    try:
        SHOTS_OUT.mkdir(parents=True, exist_ok=True)
        if not args.only:
            for old in SHOTS_OUT.glob("*.png"):
                old.unlink()
        made = []
        for i, slide in enumerate(SLIDES, start=1):
            if args.only and i not in args.only:
                continue
            if out := make_slide(i, slide, raw_dir, work):
                made.append((i, out))
        if not args.only:
            captions = [SLIDES[i - 1][4] for i, _ in made]
            (SHOTS_OUT / "captions.txt").write_text("\n".join(captions) + "\n", encoding="utf-8")
            if len(made) >= 3:
                make_showcase([p for _, p in made[:3]])
        if not args.no_promo and not args.only:
            for kind, layout, size in PROMOS:
                make_promo(kind, layout, size, raw_dir, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"Done: {len(made)} screenshots in {shown(SHOTS_OUT)}")


if __name__ == "__main__":
    main()
