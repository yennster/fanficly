#!/usr/bin/env python3
"""
Frame raw simulator screenshots into App Store marketing images.

Reads the deterministic demo-mode shots captured by
`FanficlyUITests/ScreenshotTests` from docs/screenshots/{iphone,ipad}/ and
composes each onto a branded gradient with a short headline caption and a
rounded, shadowed device card. Output goes to fastlane/screenshots/en-US/ at
the exact App Store pixel sizes, so `fastlane deliver` can upload them directly
(it picks the 6.9"/13" slot by resolution).

Run:
    bin/.venv/bin/python bin/frame-screenshots.py
Requires Pillow (installed into bin/.venv by the setup step).
"""

from __future__ import annotations
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(REPO, "docs", "screenshots")
OUT = os.path.join(REPO, "fastlane", "screenshots", "en-US")

# Brand gradient (top → bottom), in the app's purple accent family.
GRAD_TOP = (74, 50, 130)     # deep violet
GRAD_BOTTOM = (150, 110, 224)  # lavender
CAPTION_RGB = (255, 255, 255)

# (raw basename, caption). Output order follows this list (deliver sorts by name).
SLIDES = [
    ("02-search-results", "Search in plain English"),
    ("03-reader",         "A reader built for long nights"),
    ("04-library",        "Your library, fully offline"),
    ("07-reader-settings","Make it yours — themes & type"),
    ("05-browse",         "Browse every fandom"),
    ("06-recently-viewed","Pick up where you left off"),
]

FONT_CANDIDATES = [
    "/System/Library/Fonts/SFNSRounded.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
]


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            font = ImageFont.truetype(path, size)
            # Variable SF fonts: nudge to a bold-ish instance when available.
            try:
                font.set_variation_by_name("Bold")
            except Exception:
                pass
            return font
    return ImageFont.load_default()


def vertical_gradient(w: int, h: int) -> Image.Image:
    base = Image.new("RGB", (w, h), GRAD_TOP)
    top = Image.new("RGB", (w, h), GRAD_TOP)
    bottom = Image.new("RGB", (w, h), GRAD_BOTTOM)
    mask = Image.new("L", (1, h))
    for y in range(h):
        mask.putpixel((0, y), int(255 * y / max(1, h - 1)))
    mask = mask.resize((w, h))
    return Image.composite(bottom, top, mask)


def rounded(img: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, img.size[0], img.size[1]], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def wrap(draw, text, font, max_w):
    words, lines, cur = text.split(), [], ""
    for word in words:
        trial = (cur + " " + word).strip()
        if draw.textlength(trial, font=font) <= max_w:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def frame(raw_path: str, caption: str, out_path: str):
    shot = Image.open(raw_path).convert("RGB")
    W, H = shot.size
    is_pad = W / H > 0.6

    canvas = vertical_gradient(W, H)
    draw = ImageDraw.Draw(canvas)

    # Caption.
    font = load_font(int(W * (0.040 if is_pad else 0.050)))
    side = int(W * 0.08)
    lines = wrap(draw, caption, font, W - 2 * side)
    line_h = int(font.size * 1.18)
    y = int(H * (0.05 if is_pad else 0.055))
    for line in lines:
        tw = draw.textlength(line, font=font)
        draw.text(((W - tw) / 2, y), line, font=font, fill=CAPTION_RGB)
        y += line_h
    caption_bottom = y + int(H * 0.012)

    # Device card: scale to a fraction of width, place below the caption.
    target_w = int(W * (0.74 if is_pad else 0.80))
    scale = target_w / W
    target_h = int(H * scale)
    card = shot.resize((target_w, target_h), Image.LANCZOS)
    radius = int(target_w * 0.045)
    card = rounded(card, radius)

    cx = (W - target_w) // 2
    # Vertically center the card in the space between the caption and the
    # bottom margin (so iPad's shorter aspect doesn't leave a big gap below).
    bottom_limit = H - int(H * 0.04)
    avail = bottom_limit - caption_bottom
    cy = caption_bottom + max(0, (avail - target_h) // 2)

    # Soft drop shadow.
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    pad = int(W * 0.02)
    sd.rounded_rectangle(
        [cx - pad // 2, cy + pad, cx + target_w + pad // 2, cy + target_h + pad * 2],
        radius=radius, fill=(20, 10, 40, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(W * 0.018)))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow)
    canvas.alpha_composite(card, (cx, cy))

    canvas.convert("RGB").save(out_path, "PNG")


def main():
    os.makedirs(OUT, exist_ok=True)
    made = 0
    for device in ("iphone", "ipad"):
        src = os.path.join(RAW, device)
        if not os.path.isdir(src):
            print(f"skip {device}: {src} not found")
            continue
        for i, (base, caption) in enumerate(SLIDES, start=1):
            raw = os.path.join(src, f"{base}.png")
            if not os.path.exists(raw):
                print(f"  missing {raw}")
                continue
            slug = base.split("-", 1)[1]
            out = os.path.join(OUT, f"{device}-{i:02d}-{slug}.png")
            frame(raw, caption, out)
            print(f"  ✓ {os.path.basename(out)}")
            made += 1
    print(f"Done — {made} framed images in {OUT}")


if __name__ == "__main__":
    main()
