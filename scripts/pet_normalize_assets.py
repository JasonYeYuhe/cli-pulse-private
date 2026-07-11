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
    from PIL import Image, ImageDraw, ImageFilter
    import numpy as np
except ImportError as e:
    sys.exit(f"pet_normalize_assets: missing dependency ({e.name}) — pip install Pillow numpy")

CANVAS = 512
MARGIN = 40           # transparent margin around trimmed content
WHITE_THRESHOLD = 245  # pixels brighter than this on all channels → transparent

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(REPO, "CLI Pulse Bar", "CLIPulseCore", "Sources", "CLIPulseCore", "Resources", "Pet")

CAT_STATES = {"idle_0", "idle_1", "active_0", "active_1", "sleep_0"}
EGG_STATES = {"idle_0", "idle_1", "crack1", "crack2", "crack3", "hatch_burst"}
FORMS = {"loaf", "polite", "smash", "pop", "long", "huh",
         "sulk", "wail", "chonk", "boss", "smug", "egg"}


def white_to_alpha(im, kernel=5):
    """STICKER-style background removal: only the OUTER white background (the
    region flood-connected to the image border) becomes transparent; whites
    INSIDE the subject (the cat's body) stay opaque. A globally white→alpha
    pass made the body see-through, so black line-art vanished on dark
    wallpapers / dark mode — the die-cut-sticker look keeps it legible anywhere.
    """
    rgb = im.convert("RGB")
    w, h = rgb.size
    gray = rgb.convert("L")
    # 0. The algorithm assumes a light background; a mid/dark backdrop can't be
    #    told apart from ink, so refuse it loudly rather than emit garbage.
    corners = [gray.getpixel(p) for p in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]]
    corner = max(corners)
    if corner < 200:
        raise ValueError(f"background too dark (corner={corner}) — need light background")
    # 1. Close hairline gaps in the ink outline before flood filling: MinFilter(5)
    #    dilates dark lines ~2px, so the fill can't leak into the body through a
    #    1-4px break in a stroke (which turned whole cats transparent).
    barrier = gray.filter(ImageFilter.MinFilter(kernel))
    # Pad with the SAMPLED corner shade (not hardcoded white) so an off-white
    #    backdrop still flood-connects to the padding ring (agy M3#2).
    padded = Image.new("RGB", (w + 4, h + 4), (corner, corner, corner))
    padded.paste(Image.merge("RGB", (barrier, barrier, barrier)), (2, 2))
    sentinel = (255, 0, 255)
    ImageDraw.floodfill(padded, (0, 0), sentinel, thresh=256 - WHITE_THRESHOLD + 30)
    arr = np.array(padded)
    bg_small = (arr[:, :, 0] == 255) & (arr[:, :, 1] == 0) & (arr[:, :, 2] == 255)
    # 2. Dilate the (conservatively small) background mask back out so the
    #    transparent region hugs the true line edge again. Dilate on the FULL
    #    padded mask and slice afterwards — slicing first would drop the
    #    padding ring, the only background left beside a border-touching
    #    subject, leaving an opaque halo (agy M3#1).
    grown = Image.fromarray((bg_small * 255).astype("uint8")).filter(ImageFilter.MaxFilter(kernel))
    bg = np.array(grown)[2:-2, 2:-2] > 0
    # 3. …but never eat actual ink: dark pixels always stay opaque.
    bg &= np.array(gray) > 200
    out_arr = np.array(im.convert("RGBA"))
    out_arr[bg] = (255, 255, 255, 0)
    return Image.fromarray(out_arr, "RGBA")


def leaked(im, form, state):
    """Leak validation (codex M3#1): if the flood fill invaded the subject (an
    outline gap ≥5px the MinFilter couldn't close), the CENTER of the frame goes
    transparent. Detect that and refuse to write a destructive result. The
    hatch-burst effect is legitimately hollow-centered — exempt."""
    if state == "hatch_burst":
        return False
    a = np.array(im)[:, :, 3]
    h, w = a.shape
    center = a[int(h * 0.40):int(h * 0.65), int(w * 0.38):int(w * 0.62)]
    return float((center == 0).mean()) > 0.5


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
            # Accept the ART_ASSET_LIST single-frame egg names that carry a
            # trailing "_0" (crack1_0, crack2_0, crack3_0, hatch_burst_0) which
            # map to the frame-less runtime state (Codex M2#7).
            if state.endswith("_0") and state[:-2] in valid:
                return form, state[:-2]
    return None


def _selftest():
    cases = {
        "egg/crack1_0.png": ("egg", "crack1"),
        "egg/hatch_burst_0.png": ("egg", "hatch_burst"),
        "egg/idle_1.png": ("egg", "idle_1"),
        "loaf/active_0.png": ("loaf", "active_0"),
        "pop_idle_0.png": ("pop", "idle_0"),
        "unknown/thing.png": None,
    }
    ok = True
    for rel, expect in cases.items():
        got = parse_target(os.path.join("/in", rel), "/in")
        status = "ok" if got == expect else "FAIL"
        if got != expect: ok = False
        print(f"  [{status}] {rel} -> {got} (expected {expect})")
    print("selftest passed" if ok else "selftest FAILED")
    return ok


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: pet_normalize_assets.py <input_dir> | --selftest")
    if sys.argv[1] == "--selftest":
        sys.exit(0 if _selftest() else 1)
    root = sys.argv[1]
    done = 0
    bad = 0
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
            # Adaptive gap-closing: sketchy/fluffy outlines have larger breaks
            # than the default 2px closure; escalate the kernel until the fill
            # stops leaking into the subject, and only then give up.
            src_img = Image.open(src)
            im = None
            try:
                for kernel in (5, 7, 9, 11):
                    candidate = trim_and_center(white_to_alpha(src_img, kernel=kernel))
                    if not leaked(candidate, form, state):
                        im = candidate
                        if kernel > 5:
                            print(f"  note: {form}_{state} needed kernel={kernel} gap-closing")
                        break
            except ValueError as e:
                print(f"  REJECT {form}_{state}: {e}")
                bad += 1
                continue
            if im is None:
                print(f"  REJECT {form}_{state}: flood fill leaked into the subject "
                      f"even with 11px gap-closing — NOT writing a see-through frame")
                bad += 1
                continue
            # 64-color palette quantization: line-art is black/white/gray, so this
            # is visually lossless and ~10x smaller (3.9MB → 0.4MB for the set).
            im = im.quantize(colors=64, method=Image.FASTOCTREE)
            # Flat <form>_<state>.png — SPM .process flattens basenames, so nested
            # names would collide (matches scripts/pet_art/export.sh).
            os.makedirs(DEST, exist_ok=True)
            im.save(os.path.join(DEST, f"{form}_{state}.png"), optimize=True)
            print(f"  {form}_{state}.png")
            done += 1
    print(f"normalized {done} asset(s) → {DEST}")
    if bad:
        sys.exit(f"pet_normalize_assets: {bad} asset(s) REJECTED — regenerate those frames")


if __name__ == "__main__":
    main()
