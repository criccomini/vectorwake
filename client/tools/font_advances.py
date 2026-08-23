#!/usr/bin/env python3
"""How wide each character draws, read off a font file.

The interface measures its own type: a caret goes after the last letter, a
field behind a word is as wide as the word, and both need a number before
anything is drawn. One of the two faces is monospace and one number covers it.
The menu's face is not, so this reads the advances out of the file and writes
them as a Lua table.

    python3 client/tools/font_advances.py client/ui/menu.ttf > client/arena/menu_face.lua

Run it again if the face is ever replaced. Nothing runs it at build time on
purpose: the font is vendored and the table is small enough to read, so a
generated file in the tree beats a step somebody has to remember.

Advances come out in ems, which is what the drawing wants: a size in points
times the advance is the width in points, whatever size the atlas was baked
at. Only printable ASCII, because that is what a call sign, a hull name and a
menu word can hold; anything else falls back to the widest of them.
"""

import struct
import sys

FIRST, LAST = 32, 126


def tables(data):
    count = struct.unpack(">H", data[4:6])[0]
    out = {}
    for i in range(count):
        at = 12 + 16 * i
        tag = data[at:at + 4].decode("latin1")
        off, length = struct.unpack(">II", data[at + 8:at + 16])
        out[tag] = (off, length)
    return out


def cmap4(data, off):
    """Character to glyph, out of the one subtable format everything has."""
    seg_x2 = struct.unpack(">H", data[off + 6:off + 8])[0]
    segs = seg_x2 // 2
    ends = off + 14
    starts = ends + seg_x2 + 2
    deltas = starts + seg_x2
    ranges = deltas + seg_x2
    out = {}
    for i in range(segs):
        end = struct.unpack(">H", data[ends + 2 * i:ends + 2 * i + 2])[0]
        start = struct.unpack(">H", data[starts + 2 * i:starts + 2 * i + 2])[0]
        delta = struct.unpack(">h", data[deltas + 2 * i:deltas + 2 * i + 2])[0]
        offset = struct.unpack(">H", data[ranges + 2 * i:ranges + 2 * i + 2])[0]
        for c in range(max(start, FIRST), min(end, LAST) + 1):
            if offset == 0:
                out[c] = (c + delta) & 0xFFFF
            else:
                at = ranges + 2 * i + offset + 2 * (c - start)
                g = struct.unpack(">H", data[at:at + 2])[0]
                if g:
                    g = (g + delta) & 0xFFFF
                out[c] = g
    return out


def advances(path):
    data = open(path, "rb").read()
    t = tables(data)
    head, _ = t["head"]
    upem = struct.unpack(">H", data[head + 18:head + 20])[0]
    hhea, _ = t["hhea"]
    metrics = struct.unpack(">H", data[hhea + 34:hhea + 36])[0]
    hmtx, _ = t["hmtx"]

    cmap, _ = t["cmap"]
    count = struct.unpack(">H", data[cmap + 2:cmap + 4])[0]
    sub = None
    for i in range(count):
        at = cmap + 4 + 8 * i
        plat, enc, off = struct.unpack(">HHI", data[at:at + 8])
        fmt = struct.unpack(">H", data[cmap + off:cmap + off + 2])[0]
        if fmt == 4 and (plat, enc) in ((3, 1), (0, 3), (0, 4), (0, 6)):
            sub = cmap + off
            break
    if sub is None:
        raise SystemExit("no format 4 cmap in " + path)
    glyphs = cmap4(data, sub)

    out = {}
    for c in range(FIRST, LAST + 1):
        g = glyphs.get(c, 0)
        i = min(g, metrics - 1)
        adv = struct.unpack(">H", data[hmtx + 4 * i:hmtx + 4 * i + 2])[0]
        out[c] = adv / upem
    return out


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: font_advances.py <font.ttf>")
    path = sys.argv[1]
    adv = advances(path)
    widest = max(adv.values())
    print("-- How wide each character of the menu's face draws, in ems.")
    print("--")
    print("-- Generated from " + path + " by client/tools/font_advances.py,")
    print("-- which says why. Do not edit: run the tool again instead.")
    print("--")
    print("-- Keyed by byte, printable ASCII only. `widest` is what anything")
    print("-- outside that measures as, so a name in a script this face does")
    print("-- not carry is over-measured rather than run into what is beside")
    print("-- it.")
    print("local M = {widest = %.4f, adv = {" % widest)
    line = "   "
    for c in range(FIRST, LAST + 1):
        piece = " [%d] = %.4f," % (c, adv[c])
        if len(line) + len(piece) > 78:
            print(line)
            line = "   "
        line += piece
    if line.strip():
        print(line)
    print("}}")
    print("")
    print("return M")


if __name__ == "__main__":
    main()
