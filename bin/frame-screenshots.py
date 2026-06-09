#!/usr/bin/env python3
"""
Frame raw simulator screenshots into App Store marketing images.

Reads the deterministic demo-mode shots captured by
`FanficlyUITests/ScreenshotTests` from docs/screenshots/{iphone,ipad}/ (and the
hand-captured Mac shots from docs/screenshots/mac/) and turns each into a
high-converting App Store screenshot: a real Apple device frame (via
`fastlane frameit`, for iPhone/iPad) on a solid brand-maroon canvas with a bold
two-line headline (action verb + benefit). Each image is written to BOTH:
  - screenshots/final/{iphone,ipad,mac}/ — the tracked marketing set (README)
  - fastlane/screenshots/en-US/          — what `fastlane deliver` uploads
…at exact App Store pixel sizes (deliver picks the slot by resolution).
It also (re)builds screenshots/showcase.png — the README hero strip — from the
first three iPhone shots, so re-running keeps the README assets in sync.

Pipeline per screenshot:
  1. Load the raw shot and apply its EXIF orientation (`exif_transpose`). Some
     captures — notably the hand-taken Mac shots — store rotated pixels plus an
     orientation flag; honoring it is what keeps content upright instead of
     sideways. iPhone/iPad shots have no flag, so this is a harmless no-op there.
  2a. iPhone/iPad: `frameit` wraps the shot in a genuine Apple bezel → device-on-
      transparent PNG. (iPad's 13" 2064x2752 isn't in frameit's frame set, so we
      frame at the supported iPad Pro 12.9" size 2048x2732, then composite onto
      the 13" canvas.)
  2b. Mac: the raws are portrait, carry a uniform black band at the bottom, and
      have no Apple bezel in frameit. We trim the black band and wrap the shot in
      a rounded-corner "floating window" with a soft drop shadow instead.
  3. Composite the framed device onto the maroon canvas and draw the headline,
     scaling the device to fit inside the canvas (never clipped) for landscape
     Mac sizes.

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
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "docs", "screenshots")
OUT = os.path.join(REPO, "fastlane", "screenshots", "en-US")   # what `deliver` uploads
FINAL = os.path.join(REPO, "screenshots", "final")             # tracked marketing set (README)
SHOWCASE = os.path.join(REPO, "screenshots", "showcase.png")   # README hero strip
GITHUB_URL = "github.com/yennster/fanficly"

BG = (0x99, 0x00, 0x00)  # AO3 Maroon Red — the ASO brand background
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

# Per-device geometry. `out_w/out_h` are the exact App Store dimensions we emit.
# iPhone/iPad go through frameit, so they carry `frame_w/frame_h` (a size frameit
# has a frame for — iPad 13" has none, so we frame at 12.9" and composite onto the
# 13" canvas). Mac doesn't use frameit; the floating window is sized large and
# allowed to bleed off the bottom edge (like the iPhone device), so omit `fit`.
# (`fit=True` would instead clamp it fully inside the canvas — smaller.)
DEVICES = {
    "iphone": dict(out_w=1320, out_h=2868, frame_w=1320, frame_h=2868,
                   text_top=0.045, verb_max=232, verb_min=120, desc=116,
                   dev_w=0.86, dev_top=0.275),
    "ipad":   dict(out_w=2064, out_h=2752, frame_w=2048, frame_h=2732,
                   text_top=0.052, verb_max=300, verb_min=150, desc=150,
                   dev_w=0.70, dev_top=0.300),
    "mac":    dict(out_w=2560, out_h=1600,
                   text_top=0.050, verb_max=175, verb_min=100, desc=82,
                   dev_w=0.88, dev_top=0.230),
}


def load_raw(path):
    """Open a raw shot upright: apply any EXIF orientation, then drop the flag.

    Hand-captured Mac shots store rotated pixels + an orientation tag; PIL reads
    the raw (sideways) pixels unless we transpose. iPhone/iPad shots have no tag,
    so this returns them unchanged.
    """
    return ImageOps.exif_transpose(Image.open(path))


def trim_black_band(img, thresh=60):
    """Crop a uniform near-black band off the bottom and right edges.

    The Mac captures pad the real content (top-left) with a solid black band.
    We scan inward from each edge and crop the contiguous fully-dark margin,
    auto-adapting to whatever the band height happens to be.
    """
    rgb = img.convert("RGB")
    w, h = rgb.size
    px = rgb.load()
    fracs = (0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)

    bottom = h
    for y in range(h - 1, -1, -1):
        if all(sum(px[int(w * f), y][:3]) < thresh for f in fracs):
            bottom = y
        else:
            break

    right = w
    for x in range(w - 1, -1, -1):
        if all(sum(px[x, int(h * f)][:3]) < thresh for f in fracs):
            right = x
        else:
            break

    if bottom < h or right < w:
        return img.crop((0, 0, right, bottom))
    return img


def float_frame(content, radius=34, pad=72, shadow_blur=44, shadow_alpha=95, shadow_dy=14):
    """Wrap an upright screenshot in a rounded-corner card with a soft drop shadow.

    Used for the Mac set in place of an Apple device bezel: the result reads as a
    clean floating app window on the brand canvas. Returns RGBA with transparent
    padding around the card so the shadow has room to bleed.
    """
    img = content.convert("RGBA")
    w, h = img.size

    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)
    rounded = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rounded.paste(img, (0, 0), mask)

    canvas = Image.new("RGBA", (w + 2 * pad, h + 2 * pad), (0, 0, 0, 0))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [pad, pad + shadow_dy, pad + w, pad + h + shadow_dy], radius=radius,
        fill=(0, 0, 0, shadow_alpha))
    shadow = shadow.filter(ImageFilter.GaussianBlur(shadow_blur))

    out = Image.alpha_composite(canvas, shadow)
    out.alpha_composite(rounded, (pad, pad))
    return out


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
    # Landscape (Mac) canvases are shorter than a portrait device, so clamp the
    # device to the space below the headline — never let it spill off the canvas.
    if g.get("fit"):
        max_h = int(H * (1.0 - g["dev_top"]) - H * 0.05)
        if th > max_h:
            th = max_h
            tw = int(dev.width * th / dev.height)
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
        # Stage slug-named screenshots, upright and (for frameit devices) at the
        # exact frame size. Mac stays at native aspect — no distortion.
        staged = []
        for i, (base, out_slug, verb, desc) in enumerate(SLIDES, start=1):
            raw = os.path.join(src, f"{base}.png")
            if not os.path.exists(raw):
                print(f"  missing {raw}")
                continue
            slug = f"{i:02d}-{out_slug}"
            shot = load_raw(raw).convert("RGB")
            if device == "mac":
                shot = trim_black_band(shot)
            elif shot.size != (g["frame_w"], g["frame_h"]):
                shot = shot.resize((g["frame_w"], g["frame_h"]), Image.LANCZOS)
            shot.save(os.path.join(work, f"{slug}.png"))
            staged.append((slug, verb, desc))
        if not staged:
            shutil.rmtree(work, ignore_errors=True)
            continue
        if device != "mac":
            run_frameit(work)
        else:
            # No Apple bezel for Mac — wrap each upright shot in a floating
            # rounded-window card with a drop shadow.
            for slug, verb, desc in staged:
                shot = Image.open(os.path.join(work, f"{slug}.png"))
                float_frame(shot).save(os.path.join(work, f"{slug}_framed.png"))
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
