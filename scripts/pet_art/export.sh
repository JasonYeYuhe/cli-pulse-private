#!/bin/bash
# Pulse Cat art export (v1.42 M2). Generates the in-house SVG line-art, then
# rasterizes each frame to a transparent 512px PNG into the app's Pet resources.
# Line art downscales cleanly, so one 512px master per frame serves every display
# scale (the panel renders at ~120pt).
#
# Robust (Codex M2#8): preflights deps and stages into a temp dir; the shipped
# Resources/Pet is only replaced AFTER all frames rasterize successfully — a
# missing rsvg-convert can never leave the app with empty/half art.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DEST="$REPO/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources/Pet"

command -v python3 >/dev/null 2>&1 || { echo "export: python3 not found" >&2; exit 1; }
command -v rsvg-convert >/dev/null 2>&1 || { echo "export: rsvg-convert (librsvg) not found — install it (brew install librsvg)" >&2; exit 1; }

SVG_TMP="$(mktemp -d)"; PNG_TMP="$(mktemp -d)"
trap 'rm -rf "$SVG_TMP" "$PNG_TMP"' EXIT

python3 "$HERE/pet_art_gen.py" "$SVG_TMP"

# Rasterize into the staging dir with flat <form>_<state>.png names (SPM
# .process flattens basenames; nested would collide since every form has idle_0).
find "$SVG_TMP" -name '*.svg' | while read -r svg; do
  rel="${svg#$SVG_TMP/}"; rel="${rel%.svg}"
  rsvg-convert -w 512 -h 512 "$svg" -o "$PNG_TMP/${rel//\//_}.png"
done

count=$(ls "$PNG_TMP"/*.png 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -lt 36 ]; then
  echo "export: only $count/36 frames rasterized — NOT touching $DEST" >&2; exit 1
fi

# Atomic-ish replace only after a full, validated export.
mkdir -p "$DEST"
rm -f "$DEST"/*.png
cp "$PNG_TMP"/*.png "$DEST"/
echo "exported $count PNGs → $DEST"
