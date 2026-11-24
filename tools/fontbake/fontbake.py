"""One-off: Anvil.woff2 -> assets/anvil.bin, the 8x8 bitmaps the atlas packs.

Anvil is drawn on a 100-unit pixel grid, each glyph in an 800-unit square cell
from y = 0 to 800, so sampling each pixel's centre is exact. Writes
characters 32-126, 8 bytes each (one per row, top first, bit 7 leftmost).

  python3 -I tools/fontbake/fontbake.py web/assets/Anvil.woff2 assets/anvil.bin

Needs fontTools and brotli: nix shell --impure --expr 'with import <nixpkgs> {};
python3.withPackages (p: [p.fonttools p.brotli])'
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen

font = TTFont(sys.argv[1])
glyphs = font.getGlyphSet()
cmap = font.getBestCmap()


def contours(name):
    pen = RecordingPen()
    glyphs[name].draw(pen)
    out, cur = [], []
    for op, pts in pen.value:
        if op == 'moveTo':
            cur = [pts[0]]
        elif op == 'lineTo':
            cur.append(pts[0])
        elif op in ('closePath', 'endPath'):
            out.append(cur)
        else:
            raise SystemExit(f'{name}: unexpected {op}')
    return out


def inside(polys, x, y):
    winding = 0
    for poly in polys:
        for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1]):
            if (y0 <= y) != (y1 <= y):
                if x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
                    winding += 1 if y1 > y0 else -1
    return winding != 0


out = bytearray()
for ch in range(32, 127):
    polys = contours(cmap[ch]) if ch in cmap else []
    for row in range(8):
        y = 800 - 100 * row - 50
        out.append(sum(0x80 >> col for col in range(8) if inside(polys, 100 * col + 50, y)))
open(sys.argv[2], 'wb').write(out)
