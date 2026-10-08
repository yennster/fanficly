"""Shared helpers for Fanficly's App Store art (screenshots, preview captions).

Art is designed as HTML/CSS in bin/store-art/ (brand.css plus a template per
asset kind) and rendered to exact pixel sizes with headless Chrome, the same
way the product-page header and search-results images were made. This module:

  render()        screenshot an HTML file at an exact size (opaque or transparent)
  frame_device()  put a raw screenshot in a genuine Apple bezel (fastlane frameit's
                  downloaded frames) and return a device-on-transparent image
  pages_html()    the faint floating "pages" (the app icon's motif) used as depth

CLI, used by bin/record-app-previews.sh for the video captions:
  python bin/store_art.py caption --label L --headline "Find your next *fic.*" \
      --width 1230 --size 96 --out cap.png [--align left|center|right]
"""
from __future__ import annotations

import argparse
import html
import json
import os
import random
import re
import shutil
import subprocess
import tempfile
from string import Template

from PIL import Image, ImageDraw, ImageOps

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(REPO, "bin", "store-art")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FRAMES = os.path.join(os.path.expanduser("~"), ".fastlane", "frameit", "latest")

# Bezel file, frameit offsets key, and the raw size the screen hole expects.
BEZELS = {
    "iphone": ("Apple iPhone 17 Pro Max Silver.png", "iPhone 17 Pro Max", (1320, 2868), 0.144),
    "ipad": ("Apple iPad Pro (12.9-inch) (4th generation) Silver.png",
             "iPad Pro (12.9 inch) (4th generation)", (2048, 2732), 0.0),
    "mac": ("Apple MacBook Pro 16 Silver.png", "MacBook Pro 16", (3072, 1920), 0.0),
}


def chrome() -> str:
    path = CHROME if os.path.exists(CHROME) else shutil.which("google-chrome") or shutil.which("chromium")
    if not path:
        raise RuntimeError("Google Chrome is required to render the store art (install it in /Applications).")
    return path


def render(html_path: str, width: int, height: int, out_png: str, transparent: bool = False) -> Image.Image:
    """Screenshot `html_path` at exactly width×height. Opaque output is RGB, since
    App Store Connect rejects images with an alpha channel."""
    args = [chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars",
            "--allow-file-access-from-files", "--force-device-scale-factor=1",
            # Finish every compositor stage before capturing: without it, big
            # drop-shadow layers sometimes left an unpainted white tile.
            "--run-all-compositor-stages-before-draw",
            "--virtual-time-budget=5000", f"--window-size={width},{height}",
            f"--screenshot={out_png}"]
    if transparent:
        args.append("--default-background-color=00000000")
    args.append("file://" + os.path.abspath(html_path))
    subprocess.run(args, check=True, capture_output=True, timeout=180)
    img = Image.open(out_png)
    if img.size != (width, height):
        raise RuntimeError(f"{html_path} rendered at {img.size}, wanted {(width, height)}")
    img = img.convert("RGBA") if transparent else img.convert("RGB")
    img.save(out_png)
    return img


def fill(template: str, **fields) -> str:
    with open(os.path.join(ART, template), encoding="utf-8") as fh:
        return Template(fh.read()).safe_substitute(css="file://" + os.path.join(ART, "brand.css"), **fields)


def headline_html(text: str, one_line: bool = False) -> str:
    """Escape a headline, turn *accent* into the gold italic <em>, and "|" into
    a line break (or a space when the layout wants one line)."""
    out = re.sub(r"\*(.+?)\*", r"<em>\1</em>", html.escape(text))
    return out.replace("|", " " if one_line else "<br>")


def _offsets() -> dict:
    with open(os.path.join(FRAMES, "offsets.json"), encoding="utf-8") as fh:
        return json.load(fh)["portrait"]


def frame_device(shot: Image.Image, device: str) -> Image.Image:
    """Place `shot` (already upright and at the hole's aspect) in the device bezel."""
    name, key, size, radius = BEZELS[device]
    path = os.path.join(FRAMES, name)
    if not os.path.exists(path):
        raise RuntimeError(f"Missing {path}. Run `fastlane frameit download_frames` once.")
    bezel = Image.open(path).convert("RGBA")
    spec = _offsets()[key]
    ox, oy = (int(n) for n in re.findall(r"\d+", spec["offset"]))
    shot = shot.convert("RGB").resize(size, Image.LANCZOS)
    mask = Image.new("L", size, 255)
    if radius:
        mask = Image.new("L", size, 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1],
                                               radius=int(size[0] * radius), fill=255)
    out = Image.new("RGBA", bezel.size, (0, 0, 0, 0))
    out.paste(shot, (ox, oy), mask)
    out.alpha_composite(bezel)
    return out


def load_raw(path: str) -> Image.Image:
    """Open a raw capture upright (landscape sim captures carry EXIF orientation 6)."""
    return ImageOps.exif_transpose(Image.open(path))


def pages_html(seed: int, width: int, height: int, count: int = 9) -> str:
    """Faint floating pages scattered across the canvas, deterministic per seed."""
    rng = random.Random(seed)
    out = []
    for _ in range(count):
        size = rng.uniform(.06, .16) * min(width, height) * (1.4 if width > height else 1.0)
        out.append(
            f'  <div class="page" style="left: {rng.uniform(.02, .98) * width:.0f}px; '
            f'top: {rng.uniform(.02, .98) * height:.0f}px; --ps: {size:.0f}px; '
            f'--r: {rng.uniform(-24, 24):.0f}deg; --o: {rng.uniform(.045, .085):.3f}; '
            f'--b: {rng.uniform(2, 9):.1f}px;"></div>')
    return "\n".join(out)


def caption(label: str, headline: str, width: int, out_png: str, align: str = "left",
            size: int = 96) -> Image.Image:
    """Render a preview-video caption card on transparency, cropped to the card."""
    work = tempfile.mkdtemp(prefix="caption-")
    page = os.path.join(work, "caption.html")
    with open(page, "w", encoding="utf-8") as fh:
        fh.write(fill("caption.html", label=html.escape(label), headline=headline_html(headline),
                      width=str(width), size=str(size),
                      align={"left": "flex-start", "right": "flex-end"}.get(align, "center")))
    canvas_w, canvas_h = width + 4 * size, int(width * 0.9)
    img = render(page, canvas_w, canvas_h, out_png, transparent=True)
    box = img.getchannel("A").getbbox()
    img = img.crop(box) if box else img
    img.save(out_png)
    shutil.rmtree(work, ignore_errors=True)
    return img


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    cap = sub.add_parser("caption", help="render a preview caption card")
    cap.add_argument("--label", required=True)
    cap.add_argument("--headline", required=True)
    cap.add_argument("--width", type=int, required=True, help="max card width in px")
    cap.add_argument("--align", default="left", choices=["left", "center", "right"])
    cap.add_argument("--size", type=int, default=96, help="headline size in px")
    cap.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.cmd == "caption":
        img = caption(args.label, args.headline, args.width, args.out, args.align, args.size)
        print(f"{args.out} {img.size[0]}x{img.size[1]}")


if __name__ == "__main__":
    main()
