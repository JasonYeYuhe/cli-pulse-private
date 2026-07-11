#!/usr/bin/env python3
"""pet_normalize_assets.py — v1.42 Pulse Cat M2.

Ingests owner-supplied AI-generated PNGs (see ART_ASSET_LIST_v1.42_pulse_cat.md)
into the SAME PetAssets/ layout the in-house SVG pipeline produces, so the app
never knows the source. Per image: white→alpha, content trim, square-center on a
transparent canvas, resize to 512, and drop it at
  CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources/Pet/<form>/<state>.png

Usage:
  python3 scripts/pet_normalize_assets.py <input_dir>
where <input_dir> holds files named "<form>/<state>.png" or "<form>_<state>.png"
(form ∈ loaf/polite/smash/pop/long/huh/egg; state ∈ idle_0/idle_1/active_0/
active_1/sleep_0 for cats, idle_0/idle_1/crack1/crack2/crack3/hatch_burst for egg).

Requires Pillow. IP: the AI-gen prompts must obey the §1.3 red lines (no meme
names/likeness); this script only normalizes geometry, it does not create art.
"""
import os, sys, re

try:
    from PIL import Image
except ImportError:
    sys.exit("pet_normalize_assets: needs Pillow (pip install Pillow)")

CANVAS = 512
MARGIN = 40           # transparent margin around trimmed content
WHITE_THRESHOLD = 245  # pixels brighter than this on all channels → transparent

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(REPO, "CLI Pulse Bar", "CLIPulseCore", "Sources", "CLIPulseCore", "Resources", "Pet")

CAT_STATES = {"idle_0", "idle_1", "active_0", "active_1", "sleep_0"}
EGG_STATES = {"idle_0", "idle_1", "crack1", "crack2", "crack3", "hatch_burst"}
FORMS = {"loaf", "polite", "smash", "pop", "long", "huh", "egg"}


def white_to_alpha(im):
    im = im.convert("RGBA")
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if r >= WHITE_THRESHOLD and g >= WHITE_THRESHOLD and b >= WHITE_THRESHOLD:
                px[x, y] = (r, g, b, 0)
    return im


def trim_and_center(im):
    bbox = im.getbbox()   # bbox of non-zero (non-transparent) region
    if bbox:
        im = im.crop(bbox)
    w, h = im.size
    scale = (CANVAS - 2 * MARGIN) / max(w, h)
    im = im.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(im, ((CANVAS - im.width) // 2, (CANVAS - im.height) // 2), im)
    return canvas


def parse_target(path, root):
    rel = os.path.relpath(path, root)
    stem = os.path.splitext(rel)[0]
    parts = re.split(r"[/_]", stem)
    # find the form token, the rest is the state
    for i, p in enumerate(parts):
        if p in FORMS:
            form = p
            state = "_".join(parts[i + 1:])
            valid = EGG_STATES if form == "egg" else CAT_STATES
            if state in valid:
                return form, state
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: pet_normalize_assets.py <input_dir>")
    root = sys.argv[1]
    done = 0
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if not fn.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
                continue
            src = os.path.join(dirpath, fn)
            tgt = parse_target(src, root)
            if not tgt:
                print(f"  skip (unrecognized name): {os.path.relpath(src, root)}")
                continue
            form, state = tgt
            im = trim_and_center(white_to_alpha(Image.open(src)))
            # Flat <form>_<state>.png — SPM .process flattens basenames, so nested
            # names would collide (matches scripts/pet_art/export.sh).
            os.makedirs(DEST, exist_ok=True)
            im.save(os.path.join(DEST, f"{form}_{state}.png"))
            print(f"  {form}_{state}.png")
            done += 1
    print(f"normalized {done} asset(s) → {DEST}")


if __name__ == "__main__":
    main()
