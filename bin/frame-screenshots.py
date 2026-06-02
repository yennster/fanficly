#!/usr/bin/env python3
"""
Frame raw simulator screenshots into App Store marketing images.

Reads the deterministic demo-mode shots captured by
`FanficlyUITests/ScreenshotTests` from docs/screenshots/{iphone,ipad}/ and
turns each into a high-converting App Store screenshot: a real Apple device
frame (via `fastlane frameit`) on a solid brand-violet canvas with a bold
two-line headline (action verb + benefit). Output goes to
fastlane/screenshots/en-US/ at exact App Store pixel sizes, so
`fastlane deliver` can upload them directly (it picks the 6.9"/13" slot by
resolution).

Pipeline per screenshot:
  1. frameit wraps the raw shot in a genuine Apple bezel → device-on-transparent
     PNG. (iPad's 13" 2064x2752 isn't in frameit's frame set, so we frame at the
     supported iPad Pro 12.9" size 2048x2732, then composite onto the 13" canvas.)
  2. We composite that framed device onto the violet canvas and draw the headline.

Run:
    bin/.venv/bin/python bin/frame-screenshots.py     # (or: python3 bin/frame-screenshots.py)

Requires: Pillow, a working `fastlane` (frameit) on PATH, and ImageMagick
(frameit's image engine). On macOS: `brew install fastlane imagemagick`.
"""

from __future__ import annotations
import os
import shutil
import subprocess
import tempfile
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "docs", "screenshots")
OUT = os.path.join(REPO, "fastlane", "screenshots", "en-US")

BG = (0x6D, 0x28, 0xD9)  # Electric Violet — the ASO brand background
FONT = "/Library/Fonts/SF-Pro-Display-Black.otf"

# (raw basename, output slug, action verb, benefit descriptor). Output order =
# this order; deliver sorts by filename, so the NN prefix preserves it.
SLIDES = [
    ("02-search-results",  "search-plain-english", "SEARCH",        "IN PLAIN ENGLISH"),
    ("08-privacy",         "zero-tracking",        "ZERO TRACKING", "ZERO ADS"),
    ("07-reader-settings", "customize-every-page", "CUSTOMIZE",     "EVERY PAGE"),
    ("03-reader",          "read-offline",         "READ",          "ANYWHERE, OFFLINE"),
    ("04-library",         "never-miss-chapter",   "NEVER MISS",    "A CHAPTER"),
]

# Per-device geometry. `out_w/out_h` are the exact App Store dimensions we emit;
# `frame_w/frame_h` are what we feed frameit (must be a size frameit has a frame
# for — iPad 13" has none, so we frame at 12.9" and composite onto the 13" canvas).
DEVICES = {
    "iphone": dict(out_w=1320, out_h=2868, frame_w=1320, frame_h=2868,
                   text_top=0.045, verb_max=232, verb_min=120, desc=116,
                   dev_w=0.86, dev_top=0.275),
    "ipad":   dict(out_w=2064, out_h=2752, frame_w=2048, frame_h=2732,
                   text_top=0.052, verb_max=300, verb_min=150, desc=150,
                   dev_w=0.70, dev_top=0.300),
}


def wrap(draw, text, font, max_w):
    out, cur = [], ""
    for w in text.split():
        t = f"{cur} {w}".strip()
        if draw.textlength(t, font=font) <= max_w:
            cur = t
        else:
            if cur:
                out.append(cur)
            cur = w
    if cur:
        out.append(cur)
    return out


def fit_font(text, max_w, smax, smin):
    d = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    for s in range(smax, smin - 1, -4):
        f = ImageFont.truetype(FONT, s)
        if d.textbbox((0, 0), text, font=f)[2] <= max_w:
            return f
    return ImageFont.truetype(FONT, smin)


def centered(draw, cx, y, text, font, max_w, gap):
    for line in wrap(draw, text, font, max_w):
        b = draw.textbbox((0, 0), line, font=font)
        draw.text((cx, y - b[1]), line, fill="white", font=font, anchor="mt")
        y += (b[3] - b[1]) + gap
    return y


def run_frameit(workdir: str):
    """Frame every PNG in workdir into a device-on-transparent *_framed.png."""
    fastlane = shutil.which("fastlane") or "/opt/homebrew/bin/fastlane"
    env = {**os.environ, "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"}
    res = subprocess.run([fastlane, "frameit"], cwd=workdir, env=env,
                         capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError("frameit failed:\n" + res.stdout[-2000:] + res.stderr[-2000:])


def compose(g, verb, desc, framed_path, out_path):
    W, H = g["out_w"], g["out_h"]
    canvas = Image.new("RGBA", (W, H), (*BG, 255))
    d = ImageDraw.Draw(canvas)
    cx, mw, gap = W // 2, int(W * 0.88), int(W * 0.012)

    vf = fit_font(verb.upper(), mw, g["verb_max"], g["verb_min"])
    df = ImageFont.truetype(FONT, g["desc"])
    y = int(H * g["text_top"])
    y = centered(d, cx, y, verb.upper(), vf, mw, gap)
    y += gap
    centered(d, cx, y, desc.upper(), df, mw, gap)

    dev = Image.open(framed_path).convert("RGBA")
    tw = int(W * g["dev_w"])
    th = int(dev.height * tw / dev.width)
    dev = dev.resize((tw, th), Image.LANCZOS)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    layer.alpha_composite(dev, ((W - tw) // 2, int(H * g["dev_top"])))
    Image.alpha_composite(canvas, layer).convert("RGB").save(out_path, "PNG")


def main():
    os.makedirs(OUT, exist_ok=True)
    made = 0
    for device, g in DEVICES.items():
        src = os.path.join(RAW, device)
        if not os.path.isdir(src):
            print(f"skip {device}: {src} not found")
            continue
        work = tempfile.mkdtemp(prefix=f"frameit-{device}-")
        # Stage slug-named (and frame-sized) screenshots for frameit.
        staged = []
        for i, (base, out_slug, verb, desc) in enumerate(SLIDES, start=1):
            raw = os.path.join(src, f"{base}.png")
            if not os.path.exists(raw):
                print(f"  missing {raw}")
                continue
            slug = f"{i:02d}-{out_slug}"
            shot = Image.open(raw).convert("RGB")
            if shot.size != (g["frame_w"], g["frame_h"]):
                shot = shot.resize((g["frame_w"], g["frame_h"]), Image.LANCZOS)
            shot.save(os.path.join(work, f"{slug}.png"))
            staged.append((slug, verb, desc))
        if not staged:
            continue
        run_frameit(work)
        for slug, verb, desc in staged:
            framed = os.path.join(work, f"{slug}_framed.png")
            out = os.path.join(OUT, f"{device}-{slug}.png")
            compose(g, verb, desc, framed, out)
            print(f"  ✓ {os.path.basename(out)}")
            made += 1
        shutil.rmtree(work, ignore_errors=True)
    print(f"Done — {made} framed images in {OUT}")


if __name__ == "__main__":
    main()
