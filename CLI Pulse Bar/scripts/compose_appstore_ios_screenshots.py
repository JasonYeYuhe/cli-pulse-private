#!/usr/bin/env python3
"""Composite iPhone screenshots onto ASC-compliant 1290x2796 marketing panels.

Matches the macOS compose style: dark navy gradient background, white title +
grey subtitle at the top, the device screenshot centered below with rounded
corners (the iPhone photo itself has no device chrome — we add a subtle corner
radius so it doesn't look like a bare bitmap).

Input:  screenshots/ios/NN_*.png  (1290x2796 iPhone screenshots)
Output: screenshots/ios/composed/NN_*_1290x2796.png
"""

from __future__ import annotations
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

CANVAS_W, CANVAS_H = 1290, 2796

BG_TOP    = (16, 20, 42)
BG_BOTTOM = (8, 10, 22)

TITLE_COLOR    = (255, 255, 255)
SUBTITLE_COLOR = (175, 182, 200)

FONT_PATH = "/System/Library/Fonts/SFNS.ttf"
FONT_TITLE_SIZE = 100
FONT_SUBTITLE_SIZE = 44

TEXT_TOP_MARGIN = 140
TITLE_TO_SUB_GAP = 24
TEXT_TO_SHOT_GAP = 70
SIDE_MARGIN = 80
SHOT_CORNER_RADIUS = 56

COPY = {
    "01_overview":  ("Everything at a glance",  "Usage, spend, and forecast across every provider"),
    "02_providers": ("Live quotas, real costs", "Claude, Codex, Gemini, and 48+ more in one place"),
    "03_sessions":  ("Every CLI run tracked",   "Real-time session monitoring in your pocket"),
    "04_alerts":    ("Never miss a quota limit","Smart alerts before you hit the wall"),
    "05_settings":  ("Tune every detail",       "Per-provider credentials, cadence, and display"),
}

SCRIPT_DIR = Path(__file__).resolve().parent
REPO = SCRIPT_DIR.parent
IN_DIR = REPO / "screenshots" / "ios"
OUT_DIR = IN_DIR / "composed"


def make_vertical_gradient(w: int, h: int, top, bot) -> Image.Image:
    small = Image.new("RGB", (1, 2))
    small.putpixel((0, 0), top)
    small.putpixel((0, 1), bot)
    return small.resize((w, h), Image.BICUBIC)


def load_font(size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except OSError:
        return ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size)


def draw_centered_text(draw, y, text, font, color) -> int:
    bbox = draw.textbbox((0, 0), text, font=font, anchor="lt")
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    x = (CANVAS_W - tw) // 2
    draw.text((x, y), text, font=font, fill=color, anchor="lt")
    return y + th


def rounded_corners(img: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([(0, 0), img.size], radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def compose_one(src_path: Path, dst_path: Path):
    print(f"  {src_path.name}", end=" ")
    key = src_path.stem
    title, subtitle = COPY.get(key, ("CLI Pulse", "Monitor your AI coding tools"))

    canvas = make_vertical_gradient(CANVAS_W, CANVAS_H, BG_TOP, BG_BOTTOM).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    title_font = load_font(FONT_TITLE_SIZE)
    sub_font = load_font(FONT_SUBTITLE_SIZE)

    y = TEXT_TOP_MARGIN
    y = draw_centered_text(draw, y, title, title_font, TITLE_COLOR)
    y += TITLE_TO_SUB_GAP
    y = draw_centered_text(draw, y, subtitle, sub_font, SUBTITLE_COLOR)
    text_bottom = y

    shot = Image.open(src_path).convert("RGB")

    available_top = text_bottom + TEXT_TO_SHOT_GAP
    available_h = CANVAS_H - available_top - 80
    available_w = CANVAS_W - SIDE_MARGIN * 2

    scale = min(available_w / shot.width, available_h / shot.height)
    new_size = (int(shot.width * scale), int(shot.height * scale))
    shot = shot.resize(new_size, Image.LANCZOS)
    shot = rounded_corners(shot, SHOT_CORNER_RADIUS)

    px = (CANVAS_W - shot.size[0]) // 2
    py = available_top + (available_h - shot.size[1]) // 2

    canvas.alpha_composite(shot, (px, py))
    canvas.convert("RGB").save(dst_path, "PNG", optimize=True)
    print(f"→ {dst_path.name}")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    srcs = sorted(p for p in IN_DIR.glob("[0-9][0-9]_*.png") if p.parent.name != "composed")
    if not srcs:
        print(f"No source screenshots in {IN_DIR}")
        return
    print(f"Composing {len(srcs)} screenshot(s) at {CANVAS_W}x{CANVAS_H}")
    for src in srcs:
        dst = OUT_DIR / f"{src.stem}_1290x2796.png"
        compose_one(src, dst)
    print(f"\nDone. Output: {OUT_DIR}")


if __name__ == "__main__":
    main()
