#!/usr/bin/env python3
# this just turns the linxu console fonts which are C arrays into psf1 fonts
# that i can load on disk since half of my psf1 fonts are stolen from there.
#
# usage: genfonts.py <font_8x16.c> <out.psf> [height]

import re
import sys


def parse_c(path):
    text = open(path).read()
    cut = text.index("}, {")
    body = text[cut + 4 :]
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    bytes_ = [int(m, 16) for m in re.findall(r"0x([0-9a-fA-F]{2})", body)]
    return bytes_

def write_psf1(rows, height, out):
    count = len(rows) // height
    if count < 256:
        rows = rows + [0] * (height * (256 - count))
        count = 256
    if count not in (256, 512):
        rows = rows[: height * 256]
        count = 256
    mode = 0x00 if count == 256 else 0x01  # bit0 set => 512 glyphs
    header = bytes([0x36, 0x04, mode, height])
    with open(out, "wb") as f:
        f.write(header)
        f.write(bytes(rows[: height * count]))

def main():
    src, out = sys.argv[1], sys.argv[2]
    height = int(sys.argv[3]) if len(sys.argv) > 3 else int(re.search(r"8x(\d+)", src).group(1))
    rows = parse_c(src)
    write_psf1(rows, height, out)
    print(f"{out}: psf1 8x{height}, {len(rows) // height} glyphs in")

if __name__ == "__main__":
    main()
