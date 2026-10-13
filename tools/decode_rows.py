#!/usr/bin/env python3
# JTDX-VU GUI tests: list the Band Activity rows in a screenshot of the main window
# (screencapture -l of a -r test copy): image y-centre of each line and its
# background colour - (211,211,211) is a separator line, (192,0,192) a CQ / call to us.
# Screen y = image y + the window top (kCGWindowBounds). Rows are ~12 px apart.
# usage: tools/decode_rows.py shot.png
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
x0, x1 = 8, 240
rows = []; y = 75
prev = None
def kind(y):
    px = [im.getpixel((x, y)) for x in range(x0, x1)]
    dark = sum(1 for p in px if sum(p) < 300)
    bg = max(set(px), key=px.count)
    return dark, bg
y = 78
while y < 560:
    dark, bg = kind(y)
    if dark > 3:
        top = y
        while y < 560 and kind(y)[0] > 0: y += 1
        mid = (top + y) // 2
        d, b = kind(mid)
        rows.append((mid, b))
    y += 1
for m, b in rows: print(m, b)
