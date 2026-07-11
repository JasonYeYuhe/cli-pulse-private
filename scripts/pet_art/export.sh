#!/bin/bash
# Pulse Cat art export (v1.42 M2). Generates the in-house SVG line-art, then
# rasterizes each frame to a transparent 512px PNG into the app's Pet resources.
# Line art downscales cleanly, so one 512px master per frame serves every display
# scale (the panel renders at ~120pt). Requires: python3, rsvg-convert (librsvg).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DEST="$REPO/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources/Pet"
SVG_TMP="$(mktemp -d)"
trap 'rm -rf "$SVG_TMP"' EXIT

python3 "$HERE/pet_art_gen.py" "$SVG_TMP"

# Flat <form>_<state>.png names: SPM's .process flattens resource basenames and
# rejects duplicates, so nested <form>/<state>.png would collide (every form has
# idle_0.png). Flat unique names keep .process happy with no Package.swift edit.
mkdir -p "$DEST"
rm -f "$DEST"/*.png
find "$SVG_TMP" -name '*.svg' | while read -r svg; do
  rel="${svg#$SVG_TMP/}"; rel="${rel%.svg}"        # e.g. loaf/idle_0
  flat="${rel//\//_}"                               # → loaf_idle_0
  rsvg-convert -w 512 -h 512 "$svg" -o "$DEST/$flat.png"   # transparent bg
done
echo "exported $(ls "$DEST"/*.png | wc -l | tr -d ' ') PNGs → $DEST"
