#!/usr/bin/env python3
"""
Frame raw simulator screenshots into App Store marketing images.

Reads the deterministic demo-mode shots captured by
`FanficlyUITests/ScreenshotTests` from docs/screenshots/{iphone,ipad}/ and
turns each into a high-converting App Store screenshot: a real Apple device
frame (via `fastlane frameit`) on a solid brand-violet canvas with a bold
two-line headline (action verb + benefit). Each image is written to BOTH:
  - screenshots/final/{iphone,ipad}/   — the tracked marketing set (README)
  - fastlane/screenshots/en-US/        — what `fastlane deliver` uploads
…at exact App Store pixel sizes (deliver picks the 6.9"/13" slot by resolution).
It also (re)builds screenshots/showcase.png — the README hero strip — from the
first three iPhone shots, so re-running keeps the README assets in sync.

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
OUT = os.path.join(REPO, "fastlane", "screenshots", "en-US")   # what `deliver` uploads
FINAL = os.path.join(REPO, "screenshots", "final")             # tracked marketing set (README)
SHOWCASE = os.path.join(REPO, "screenshots", "showcase.png")   # README hero strip
GITHUB_URL = "github.com/yennster/fanficly"

BG = (0x6D, 0x28, 0xD9)  # Electric Violet — the ASO brand background
FONT = "/Library/Fonts/SF-Pro-Display-Black.otf"
# Caption font for the showcase strip (falls back to the headline font, then default).
SHOWCASE_FONTS = ["/Library/Fonts/SF-Pro-Display-Regular.otf", FONT]

# (raw basename, output slug, action verb, benefit descriptor). Output order =
# this order; deliver sorts by filename, so the NN prefix preserves it.
SLIDES = [
    ("02-search-results",  "search-plain-english", "SEARCH",        "IN PLAIN ENGLISH"),
    ("08-privacy",         "zero-tracking",        "ZERO TRACKING", "ZERO ADS"),
    ("07-reader-settings", "customize-every-page", "CUSTOMIZE",     "EVERY PAGE"),
    ("03-reader",          "read-offline",         "READ",          "ANYWHERE, OFFLINE"),
    ("04-library",         "never-miss-chapter",   "NEVER MISS",    "A CHAPTER"),
    ("05-browse",          "browse-fandoms",       "BROWSE",        "BY FANDOM"),
    ("09-tts",             "listen-on-the-go",     "LISTEN",        "ON THE GO"),
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


def make_showcase(paths, out_path):
    """README hero strip: up to 3 marketing shots side-by-side + the GitHub URL."""
    target_h, pad, gap, bar = 800, 60, 40, 100
    scaled = [Image.open(p).convert("RGBA") for p in paths]
    scaled = [im.resize((round(im.width * target_h / im.height), target_h), Image.LANCZOS)
              for im in scaled]
    W = sum(s.width for s in scaled) + gap * (len(scaled) - 1) + pad * 2
    H = target_h + pad * 2 + bar
    canvas = Image.new("RGB", (W, H), (255, 255, 255))
    x = pad
    for s in scaled:
        canvas.paste(s, (x, pad), s)
        x += s.width + gap
    font = next((ImageFont.truetype(f, 40) for f in SHOWCASE_FONTS if os.path.exists(f)),
                ImageFont.load_default())
    ImageDraw.Draw(canvas).text((W // 2, pad + target_h + bar // 2), GITHUB_URL,
                                fill="#000000", font=font, anchor="mm")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    canvas.save(out_path)
    print(f"  ✓ {os.path.relpath(out_path, REPO)}")


def main():
    os.makedirs(OUT, exist_ok=True)
    made = 0
    iphone_finals = []
    for device, g in DEVICES.items():
        src = os.path.join(RAW, device)
        if not os.path.isdir(src):
            print(f"skip {device}: {src} not found")
            continue
        final_dir = os.path.join(FINAL, device)
        os.makedirs(final_dir, exist_ok=True)
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
            shutil.rmtree(work, ignore_errors=True)
            continue
        run_frameit(work)
        for slug, verb, desc in staged:
            framed = os.path.join(work, f"{slug}_framed.png")
            final_out = os.path.join(final_dir, f"{slug}.png")
            compose(g, verb, desc, framed, final_out)              # tracked marketing image
            shutil.copy(final_out, os.path.join(OUT, f"{device}-{slug}.png"))  # deliver upload
            print(f"  ✓ {device}-{slug}.png")
            made += 1
            if device == "iphone":
                iphone_finals.append(final_out)
        shutil.rmtree(work, ignore_errors=True)
    if iphone_finals:
        make_showcase(iphone_finals[:3], SHOWCASE)
    print(f"Done — {made} framed images → screenshots/final/ and fastlane/screenshots/en-US/")


if __name__ == "__main__":
    main()
