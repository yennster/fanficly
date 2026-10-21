#!/usr/bin/env python3
"""Render the App Store creative assets from the demo-mode captures:

    fastlane/creative/en-US/header-3840x1646.png   product-page header
    fastlane/creative/en-US/search-3840x2560.png   search results

Same look as the screenshots (bin/store-art/brand.css): indigo canvas, floating
pages, glass trope chips, a New York headline with the gold accent, and big
iPhones in genuine Apple bezels running off the canvas edges, laid out by
bin/store-art/creative.html. The header puts a sepia reader and a dark reader
either side of the headline; search results puts the headline, copy and a
search bar on the left and fans the search, sepia and dark iPhones out to the
right. The reader themes are tinted from the light captures, so new
screenshots flow straight in. The headline stays in Apple's centered safe
areas (header 1646x661, search 2168x1030). Run after the screenshots lane so
docs/screenshots/ is current; upload with bin/upload-creative-assets.py (the
upload_store_art lane does both).

Run:  bin/.venv/bin/python bin/make-creative-assets.py
"""
from __future__ import annotations

import html
import os
import shutil
import tempfile

from PIL import Image, ImageChops

import store_art

REPO = store_art.REPO
RAW = os.path.join(REPO, "docs", "screenshots", "iphone")
OUT = os.path.join(REPO, "fastlane", "creative", "en-US")

# Trope chips: (text, style, x, y, rotation in degrees). Styles are brand.css
# chip classes; "far" chips are blurred and faint, "small" ones smaller.
HEADER_CHIPS = [
    ("Slow Burn", "", 1420, 200, -3), ("Found Family", "far small", 1960, 130, 0),
    ("Mutual Pining", "warm", 2440, 275, 3), ("Fluff", "far small", 1790, 395, 0),
    ("Enemies to Lovers", "accent", 1480, 1390, 3), ("Coffee Shop AU", "", 2400, 1330, -3),
    ("Soulmates", "far small", 1240, 1560, 0), ("Hurt/Comfort", "far small", 1980, 1545, 0),
]
SEARCH_CHIPS = [
    ("Mutual Pining", "far small", 1150, 327, -3), ("Hurt/Comfort", "warm", 1638, 471, 3),
    ("Fluff", "far small", 1620, 2007, 0), ("Enemies to Lovers", "", 978, 2139, 3),
]

# kind, file, size, safe area, label, label class, headline, sub, chips,
# the iPhones front to back as (capture, theme)
ASSETS = [
    ("header", "header-3840x1646.png", (3840, 1646), (1646, 661),
     "A calm place to read", "", "Lose yourself|in a good *fic.*",
     "Search, save and read fanfiction — offline, ad-free and private.", HEADER_CHIPS,
     [("03-reader", "sepia"), ("09-tts", "dark")]),
    ("search", "search-3840x2560.png", (3840, 2560), (2168, 1030),
     "Search · Save · Read · Listen", "bare", "Find your|next *fic.*",
     "Search every fandom, ship and trope. Read offline or listen hands-free — no ads, no tracking.",
     SEARCH_CHIPS, [("02-search-results", "light"), ("03-reader", "sepia"), ("09-tts", "dark")]),
]

SEPIA = (247, 236, 214)  # the reader's sepia page
INK = (62, 42, 24)       # and its brown text


def themed(shot: Image.Image, theme: str) -> Image.Image:
    """A light capture as the reader's sepia or dark theme: sepia maps each
    channel from brown ink (black) to the sepia page (white), so the blue
    accents stay blue; dark inverts the brightness but keeps each hue, onto a
    near-black page."""
    shot = shot.convert("RGB")
    if theme == "sepia":
        return Image.merge("RGB", [band.point(lambda x, lo=lo, hi=hi: lo + x * (hi - lo) // 255)
                                   for band, lo, hi in zip(shot.split(), INK, SEPIA)])
    if theme == "dark":
        h, s, v = ImageChops.invert(shot).convert("HSV").split()
        inverted = Image.merge("HSV", (h.point(lambda x: (x + 128) % 256), s, v)).convert("RGB")
        return inverted.point(lambda x: 28 + x * (232 - 28) // 255)
    return shot


def chips_html(chips) -> str:
    return "\n".join(
        f'  <div class="chip {style}" style="left: {x}px; top: {y}px; --r: {r}deg;">{html.escape(text)}</div>'
        for text, style, x, y, r in chips)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    work = tempfile.mkdtemp(prefix="creative-")
    for kind, name, (w, h), (sw, sh), label, label_class, headline, sub, chips, phones in ASSETS:
        fields = {"phone1": "", "phone2": "", "phone3": ""}
        for i, (base, theme) in enumerate(phones, 1):
            shot = themed(store_art.load_raw(os.path.join(RAW, f"{base}.png")), theme)
            path = os.path.join(work, f"{kind}-{i}.png")
            store_art.frame_device(shot, "iphone").save(path)
            fields[f"phone{i}"] = "file://" + path
        page = os.path.join(work, f"{kind}.html")
        with open(page, "w", encoding="utf-8") as fh:
            fh.write(store_art.fill(
                "creative.html", kind=kind, w=str(w), h=str(h), safe_w=str(sw), safe_h=str(sh),
                label=html.escape(label), label_class=label_class,
                headline=store_art.headline_html(headline), sub=html.escape(sub),
                chips=chips_html(chips),
                pages=store_art.pages_html(seed=len(kind) * 11, width=w, height=h, count=14),
                **fields))
        store_art.render(page, w, h, os.path.join(OUT, name))
        print(f"  ✓ {os.path.relpath(os.path.join(OUT, name), REPO)}")
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
