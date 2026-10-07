#!/bin/sh

# trim the ttf into a subset (U+0020..007E), its just to embed fonts that are actually
# rendered, since we have NERD fonts and shit, they can be quite large

set -e
IN="$1"
OUT="$2"
python3 -m fontTools.subset "$IN" \
  --unicodes=U+0020-007E \
  --no-hinting --glyph-names \
  --output-file="$OUT"
echo "wrote $OUT"
