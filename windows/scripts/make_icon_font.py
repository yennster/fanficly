#!/usr/bin/env python3
"""
Builds windows/src/Fanficly.App/Assets/FanficlyIcons.ttf: the few icons the
app needs that Segoe Fluent Icons doesn't have (it has no bookmark ribbon),
drawn on the same 2048-unit grid and stroke weight so they sit beside Fluent
glyphs. The app lists this font after the system icon fonts, so it only
supplies these code points (Supplementary Private Use Area-A, which neither
system font uses). UI/Symbols.cs maps the icon names to them.

Run after changing a glyph: python windows/scripts/make_icon_font.py
"""
from __future__ import annotations

import pathlib

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

OUT = pathlib.Path(__file__).resolve().parent.parent / "src" / "Fanficly.App" / "Assets" / "FanficlyIcons.ttf"
EM = 2048
STROKE = 128          # 1 px at 16 px, like Fluent's regular icons
RADIUS = 192

# The ribbon: rounded top corners, a V notch at the foot.
LEFT, RIGHT, TOP, BOTTOM, NOTCH = 448, 1600, 1856, 160, 640


def offset_polygon(points, d):
    """Offsets a convex-cornered polygon's edges inward by d (counter-clockwise input
    in y-up coordinates means inward is to the left)."""
    import math
    n = len(points)
    lines = []
    for i in range(n):
        (x1, y1), (x2, y2) = points[i], points[(i + 1) % n]
        dx, dy = x2 - x1, y2 - y1
        length = math.hypot(dx, dy)
        nx, ny = -dy / length, dx / length          # left normal
        lines.append(((x1 + nx * d, y1 + ny * d), (dx, dy)))
    out = []
    for i in range(n):
        (p, r), (q, s) = lines[i - 1], lines[i]
        cross = r[0] * s[1] - r[1] * s[0]
        t = ((q[0] - p[0]) * s[1] - (q[1] - p[1]) * s[0]) / cross
        out.append((p[0] + t * r[0], p[1] + t * r[1]))
    return out


def ribbon(pen, inset=0.0, clockwise=True, radius=RADIUS):
    """One ribbon contour, optionally inset (the hole of the outline)."""
    # Counter-clockwise corner list (y-up): top-left, bottom-left, notch, bottom-right, top-right.
    corners = [(LEFT, TOP), (LEFT, BOTTOM), (1024, NOTCH), (RIGHT, BOTTOM), (RIGHT, TOP)]
    if inset:
        corners = offset_polygon(corners, inset)
    (tlx, tly), (blx, bly), (nx, ny), (brx, bry), (trx, try_) = corners
    r = max(0.0, radius - inset)
    rnd = lambda p: (round(p[0]), round(p[1]))
    if clockwise:
        pen.moveTo(rnd((tlx + r, tly)))
        pen.lineTo(rnd((trx - r, try_)))
        pen.qCurveTo(rnd((trx, try_)), rnd((trx, try_ - r)))
        pen.lineTo(rnd((brx, bry)))
        pen.lineTo(rnd((nx, ny)))
        pen.lineTo(rnd((blx, bly)))
        pen.lineTo(rnd((tlx, tly - r)))
        pen.qCurveTo(rnd((tlx, tly)), rnd((tlx + r, tly)))
    else:
        pen.moveTo(rnd((tlx + r, tly)))
        pen.qCurveTo(rnd((tlx, tly)), rnd((tlx, tly - r)))
        pen.lineTo(rnd((blx, bly)))
        pen.lineTo(rnd((nx, ny)))
        pen.lineTo(rnd((brx, bry)))
        pen.lineTo(rnd((trx, try_ - r)))
        pen.qCurveTo(rnd((trx, try_)), rnd((trx - r, try_)))
    pen.closePath()


def bar(pen, x1, y1, x2, y2, width):
    """A straight bar from (x1, y1) to (x2, y2), clockwise."""
    import math
    dx, dy = x2 - x1, y2 - y1
    length = math.hypot(dx, dy)
    nx, ny = -dy / length * width / 2, dx / length * width / 2
    pts = [(x1 - nx, y1 - ny), (x2 - nx, y2 - ny), (x2 + nx, y2 + ny), (x1 + nx, y1 + ny)]
    pen.moveTo((round(pts[0][0]), round(pts[0][1])))
    for p in pts[1:]:
        pen.lineTo((round(p[0]), round(p[1])))
    pen.closePath()


def glyph(draw):
    pen = TTGlyphPen(None)
    draw(pen)
    return pen.glyph()


GLYPHS = {
    # name: (code point, drawing)
    "bookmark": (0xF0001, lambda p: (ribbon(p), ribbon(p, STROKE, clockwise=False))),
    "bookmarkFill": (0xF0002, lambda p: ribbon(p)),
    "bookmarkSlash": (0xF0003, lambda p: (ribbon(p), ribbon(p, STROKE, clockwise=False),
                                          bar(p, 256, 1900, 1792, 100, STROKE))),
}


def main():
    order = [".notdef"] + list(GLYPHS)
    fb = FontBuilder(EM, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({cp: name for name, (cp, _) in GLYPHS.items()})
    glyphs = {".notdef": glyph(lambda p: None)}
    glyphs.update({name: glyph(draw) for name, (_, draw) in GLYPHS.items()})
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics({name: (EM, 0) for name in order})
    # Same vertical metrics as Segoe Fluent Icons: the em box is the glyph box.
    fb.setupHorizontalHeader(ascent=EM, descent=0)
    fb.setupNameTable({"familyName": "Fanficly Icons", "styleName": "Regular",
                       "uniqueFontIdentifier": "Fanficly Icons Regular", "fullName": "Fanficly Icons",
                       "psName": "FanficlyIcons-Regular", "version": "Version 1.0"})
    fb.setupOS2(sTypoAscender=EM, sTypoDescender=0, sTypoLineGap=0, usWinAscent=EM, usWinDescent=0,
                achVendID="FNFC", fsType=0)
    fb.setupPost()
    fb.save(str(OUT))
    print(f"{OUT} ({OUT.stat().st_size} bytes): " + ", ".join(f"{n} U+{cp:X}" for n, (cp, _) in GLYPHS.items()))


if __name__ == "__main__":
    main()
