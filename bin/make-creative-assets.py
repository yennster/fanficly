#!/usr/bin/env python3
"""Render the App Store creative assets from the demo-mode captures:

    fastlane/creative/en-US/header-3840x1646.png   product-page header
    fastlane/creative/en-US/search-3840x2560.png   search results

Same look as the screenshots (bin/store-art/brand.css): indigo canvas, floating
pages, a New York headline with the gold accent, and the app in genuine Apple
bezels, laid out by bin/store-art/creative.html. The headline and devices sit in
Apple's centered safe areas (header 1646x661, search 2168x1030). Run after the
screenshots lane so docs/screenshots/ is current; upload with
bin/upload-creative-assets.py (the upload_store_art lane does both).

Run:  bin/.venv/bin/python bin/make-creative-assets.py
"""
from __future__ import annotations

import importlib.util
import os
import shutil
import tempfile

import store_art

REPO = store_art.REPO
RAW = os.path.join(REPO, "docs", "screenshots")
OUT = os.path.join(REPO, "fastlane", "creative", "en-US")

# (kind, file, size, safe area, label, headline, {device: raw capture})
ASSETS = [
    ("header", "header-3840x1646.png", (3840, 1646), (1646, 661),
     "Smart search", "Find your next *fic.*",
     {"ipad": "04-library", "iphone": "03-reader"}),
    ("search", "search-3840x2560.png", (3840, 2560), (2168, 1030),
     "Private by design", "Zero tracking. *Zero ads.*",
     {"ipad": "10-popular", "iphone": "03-reader", "mac": "02-search-results"}),
]


def frame_screenshots():
    """bin/frame-screenshots.py, for its Mac-window crop (the name has a hyphen)."""
    spec = importlib.util.spec_from_file_location(
        "frame_screenshots", os.path.join(REPO, "bin", "frame-screenshots.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    frames = frame_screenshots()
    work = tempfile.mkdtemp(prefix="creative-")
    for kind, name, (w, h), (sw, sh), label, headline, shots in ASSETS:
        devices = {}
        for device, base in shots.items():
            shot = store_art.load_raw(os.path.join(RAW, device, f"{base}.png")).convert("RGB")
            if device == "mac":
                shot = frames.mac_screen(shot)
            path = os.path.join(work, f"{kind}-{device}.png")
            store_art.frame_device(shot, device).save(path)
            devices[f"{device}_png"] = "file://" + path
        page = os.path.join(work, f"{kind}.html")
        with open(page, "w", encoding="utf-8") as fh:
            fh.write(store_art.fill(
                "creative.html", kind=kind, w=str(w), h=str(h), safe_w=str(sw), safe_h=str(sh),
                label=store_art.html.escape(label),
                headline=store_art.headline_html(headline, one_line=True),
                pages=store_art.pages_html(seed=len(kind) * 11, width=w, height=h, count=14),
                **{"ipad_png": "", "iphone_png": "", "mac_png": "", **devices}))
        store_art.render(page, w, h, os.path.join(OUT, name))
        print(f"  ✓ {os.path.relpath(os.path.join(OUT, name), REPO)}")
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
