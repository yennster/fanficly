"""Draws every glyph in the installed icon fonts (Segoe Fluent Icons, Segoe MDL2
Assets) as labelled charts, so an icon can be picked by eye from what the font
really contains. Usage: python Chart-IconFont.py <out-dir>. Needs fonttools and
pillow."""
import os
import sys

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

FONTS = {
    "fluent": ["SegoeIcons.ttf"],
    "mdl2": ["segmdl2.ttf"],
}
DIRS = [
    os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts"),
    os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "Windows", "Fonts"),
]
COLS, ROWS, CELL_W, CELL_H = 16, 24, 72, 64


def find(names):
    for d in DIRS:
        for n in names:
            p = os.path.join(d, n)
            if os.path.exists(p):
                return p
    return None


def main(out):
    os.makedirs(out, exist_ok=True)
    label = ImageFont.truetype(os.path.join(DIRS[0], "segoeui.ttf"), 12)
    for key, names in FONTS.items():
        path = find(names)
        if not path:
            print(f"{key}: not installed")
            continue
        cps = sorted(c for c in TTFont(path).getBestCmap() if 0xE000 <= c <= 0xF8FF)
        print(f"{key}: {path}, {len(cps)} glyphs, U+{cps[0]:04X}..U+{cps[-1]:04X}")
        glyph = ImageFont.truetype(path, 28)
        per = COLS * ROWS
        for page in range((len(cps) + per - 1) // per):
            img = Image.new("RGB", (COLS * CELL_W, ROWS * CELL_H), "white")
            d = ImageDraw.Draw(img)
            for i, cp in enumerate(cps[page * per:(page + 1) * per]):
                x, y = (i % COLS) * CELL_W, (i // COLS) * CELL_H
                d.rectangle([x, y, x + CELL_W - 1, y + CELL_H - 1], outline="#dddddd")
                d.text((x + CELL_W / 2, y + 22), chr(cp), font=glyph, fill="black", anchor="mm")
                d.text((x + CELL_W / 2, y + CELL_H - 10), f"{cp:04X}", font=label, fill="#c00000", anchor="mm")
            img.save(os.path.join(out, f"{key}-{page + 1:02d}.png"))


if __name__ == "__main__":
    main(sys.argv[1])
