#!/usr/bin/env python3
"""
Turn raw simulator screenshots into App Store marketing images.

Reads the deterministic demo-mode shots captured by
`FanficlyUITests/ScreenshotTests` from docs/screenshots/{iphone,ipad,mac}/ and
builds each App Store screenshot as a web page (bin/store-art/screenshot.html +
brand.css), rendered to the exact App Store size with headless Chrome. The
look matches the product-page header and search-results art: indigo mesh
gradient with paper grain and floating pages, a letter-spaced label, a New York
serif headline with a gold italic accent, and the app in a genuine Apple bezel
(fastlane frameit's downloaded frames). Each image is written to:
  - screenshots/final/{iphone,ipad,mac}/ — the tracked marketing set (README)
  - fastlane/screenshots/en-US/          — what `fastlane deliver` uploads (iOS)
  - fastlane/screenshots-mac/en-US/      — what `fastlane release_mac` uploads (macOS)
…at exact App Store pixel sizes (deliver picks the slot by resolution). It also
rebuilds screenshots/showcase.png, the README hero strip, from the first three
iPhone shots.

The "Mac" raws are a landscape iPad split view (there's no Catalyst simulator).
They carry EXIF orientation 6, and the iPad status bar plus rounded display
corners are cropped off before the shot goes into the MacBook Pro bezel.

Run:
    bin/.venv/bin/python bin/frame-screenshots.py
    bin/.venv/bin/python bin/frame-screenshots.py --device iphone --only 1

Requires Pillow, Google Chrome, and frameit's frames (`fastlane frameit
download_frames`, already present after any frameit run).
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store_art  # noqa: E402

REPO = store_art.REPO
RAW = os.path.join(REPO, "docs", "screenshots")
OUT = os.path.join(REPO, "fastlane", "screenshots", "en-US")   # what `deliver` uploads (iOS)
# Mac shots live in their own tree: deliver matches screenshots to App Store
# slots by pixel size, and 2560×1600 is a Mac App Store size the iOS listing
# rejects. `fastlane release_mac` uploads this tree with platform "osx".
OUT_MAC = os.path.join(REPO, "fastlane", "screenshots-mac", "en-US")
FINAL = os.path.join(REPO, "screenshots", "final")             # tracked marketing set (README)
SHOWCASE = os.path.join(REPO, "screenshots", "showcase.png")   # README hero strip
GITHUB_URL = "github.com/yennster/fanficly"
SHOWCASE_FONT = "/Library/Fonts/SF-Pro-Display-Regular.otf"

# (raw basename, output slug, label, headline). *word* is the gold italic
# accent and "|" the line break (the landscape Mac layout joins the lines). Output order = this order; deliver sorts by filename, so the NN prefix
# preserves it. The App Store caps a device at 10 screenshots — keep ≤10.
SLIDES = [
    ("02-search-results",  "search-plain-english",  "Smart search",        "Find your|next *fic.*"),
    ("08-privacy",         "zero-tracking",         "Private by design",   "Zero tracking.|*Zero ads.*"),
    ("07-reader-settings", "customize-every-page",  "Your reader",         "Make every|page *yours.*"),
    ("03-reader",          "read-offline",          "Offline reading",     "Read anywhere,|*even offline.*"),
    ("04-library",         "never-miss-chapter",    "Chapter alerts",      "Never miss|a *chapter.*"),
    ("05-browse",          "browse-fandoms",        "Every fandom",        "Browse by|*fandom.*"),
    ("09-tts",             "listen-on-the-go",      "Listen",              "Let the story|*read to you.*"),
    ("10-popular",         "discover-popular",      "Discover",            "See what's|*popular.*"),
    ("11-comments",        "join-the-conversation", "Community",           "Join the|*conversation.*"),
    ("12-bookmarks",       "your-bookmarks",        "Your account",        "All your AO3|*bookmarks.*"),
]

# Exact App Store output sizes per device family.
SIZES = {"iphone": (1320, 2868), "ipad": (2064, 2752), "mac": (2560, 1600)}

MAC_STATUS_BAR = 52     # px of iPad status bar at the top of a landscape capture
MAC_EDGE_CROP = 18      # px of rounded iPad display corner on the other edges
MAC_SCREEN_ASPECT = 16 / 10


def mac_screen(shot: Image.Image) -> Image.Image:
    """Crop a landscape iPad capture to a 16:10 'Mac window', top-anchored."""
    w, h = shot.size
    shot = shot.crop((MAC_EDGE_CROP, MAC_STATUS_BAR, w - MAC_EDGE_CROP, h - MAC_EDGE_CROP))
    w, h = shot.size
    if w / h < MAC_SCREEN_ASPECT:
        return shot.crop((0, 0, w, round(w / MAC_SCREEN_ASPECT)))
    new_w = round(h * MAC_SCREEN_ASPECT)
    return shot.crop(((w - new_w) // 2, 0, (w - new_w) // 2 + new_w, h))


def make_slide(device: str, index: int, raw_path: str, label: str, headline: str,
               work: str, out_path: str) -> None:
    w, h = SIZES[device]
    shot = store_art.load_raw(raw_path).convert("RGB")
    if device == "mac":
        shot = mac_screen(shot)
    framed = os.path.join(work, f"{device}-{index:02d}-device.png")
    store_art.frame_device(shot, device).save(framed)
    page = os.path.join(work, f"{device}-{index:02d}.html")
    with open(page, "w", encoding="utf-8") as fh:
        fh.write(store_art.fill(
            "screenshot.html", w=str(w), h=str(h), device=device,
            device_png="file://" + framed,
            label=store_art.html.escape(label),
            headline=store_art.headline_html(headline, one_line=device == "mac"),
            pages=store_art.pages_html(seed=index * 7 + len(device), width=w, height=h)))
    store_art.render(page, w, h, out_path)


def make_showcase(paths, out_path):
    """README hero strip: up to 3 marketing shots side-by-side + the GitHub URL."""
    target_h, pad, gap, bar = 800, 60, 40, 100
    scaled = [Image.open(p).convert("RGB") for p in paths]
    scaled = [im.resize((round(im.width * target_h / im.height), target_h), Image.LANCZOS)
              for im in scaled]
    W = sum(s.width for s in scaled) + gap * (len(scaled) - 1) + pad * 2
    H = target_h + pad * 2 + bar
    canvas = Image.new("RGB", (W, H), (255, 255, 255))
    x = pad
    for s in scaled:
        canvas.paste(s, (x, pad))
        x += s.width + gap
    font = (ImageFont.truetype(SHOWCASE_FONT, 40) if os.path.exists(SHOWCASE_FONT)
            else ImageFont.load_default())
    ImageDraw.Draw(canvas).text((W // 2, pad + target_h + bar // 2), GITHUB_URL,
                                fill="#000000", font=font, anchor="mm")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    canvas.save(out_path)
    print(f"  ✓ {os.path.relpath(out_path, REPO)}")


def parse_args():
    parser = argparse.ArgumentParser(description="Build App Store marketing screenshots.")
    parser.add_argument("--device", action="append", choices=sorted(SIZES), dest="devices",
                        help="Limit to one device family. Can be passed more than once.")
    parser.add_argument("--only", type=int, action="append",
                        help="Only build slide N (1-based). Can be passed more than once.")
    return parser.parse_args()


def main():
    args = parse_args()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(OUT_MAC, exist_ok=True)
    made, iphone_finals = 0, []
    work = tempfile.mkdtemp(prefix="store-art-")
    for device in args.devices or SIZES:
        src = os.path.join(RAW, device)
        if not os.path.isdir(src):
            print(f"skip {device}: {src} not found")
            continue
        final_dir = os.path.join(FINAL, device)
        os.makedirs(final_dir, exist_ok=True)
        for i, (base, slug, label, headline) in enumerate(SLIDES, start=1):
            if args.only and i not in args.only:
                continue
            raw = os.path.join(src, f"{base}.png")
            if not os.path.exists(raw):
                print(f"  missing {raw}")
                continue
            name = f"{i:02d}-{slug}"
            final_out = os.path.join(final_dir, f"{name}.png")
            make_slide(device, i, raw, label, headline, work, final_out)
            deliver_dir = OUT_MAC if device == "mac" else OUT
            shutil.copy(final_out, os.path.join(deliver_dir, f"{device}-{name}.png"))
            print(f"  ✓ {device}-{name}.png")
            made += 1
            if device == "iphone":
                iphone_finals.append(final_out)
    shutil.rmtree(work, ignore_errors=True)
    if len(iphone_finals) >= 3 and not args.only:
        make_showcase(iphone_finals[:3], SHOWCASE)
    print(f"Done — {made} images → screenshots/final/, fastlane/screenshots/en-US/ (iOS) "
          "and fastlane/screenshots-mac/en-US/ (Mac)")


if __name__ == "__main__":
    main()
