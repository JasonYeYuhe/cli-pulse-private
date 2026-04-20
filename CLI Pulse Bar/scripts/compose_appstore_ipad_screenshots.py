#!/usr/bin/env python3
"""Composite real iPad Pro 13" (M4) screenshots onto ASC-compliant marketing
panels, matching the macOS composite style (dark navy gradient + white title
and subtitle at top, centered device screenshot below).

Input:  screenshots/ipad/NN_*.png        (2752x2064 landscape iPad Pro 13" M4)
Output: screenshots/ipad/composed/NN_*_2752x2064.png

Target App Store size for iPad Pro 13" (M4) is 2752x2064 (landscape) or the
portrait equivalent. We keep the source aspect and emit landscape.
"""

from __future__ import annotations
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

CANVAS_W, CANVAS_H = 2752, 2064

BG_TOP    = (16, 20, 42)   # #10142A
BG_BOTTOM = (8, 10, 22)    # #080A16

TITLE_COLOR    = (255, 255, 255)
SUBTITLE_COLOR = (175, 182, 200)

FONT_TITLE_PATH = "/System/Library/Fonts/SFNS.ttf"
FONT_TITLE_SIZE = 120
FONT_SUBTITLE_SIZE = 54

TEXT_TOP_MARGIN = 130
TITLE_TO_SUB_GAP = 34
TEXT_TO_SHOT_GAP = 70
SIDE_MARGIN = 180
BOTTOM_MARGIN = 100
CORNER_RADIUS = 36  # round the device screenshot corners — iPads don't include chrome

COPY = {
    "01_overview":  ("Everything at a glance",       "Usage, cost, and forecast across every provider"),
    "02_providers": ("Live quotas, real costs",      "Claude, Codex, Gemini, Ollama — at full iPad width"),
    "03_sessions":  ("Every CLI run tracked",        "Real-time session monitoring across your devices"),
    "04_alerts":    ("Never miss a quota limit",     "Smart alerts before you hit the wall"),
    "05_settings":  ("Tune every detail",            "Providers, cadence, and appearance in one place"),
}

SCRIPT_DIR = Path(__file__).resolve().parent
REPO = SCRIPT_DIR.parent
IN_DIR = REPO / "screenshots" / "ipad"
OUT_DIR = IN_DIR / "composed"


def make_vertical_gradient(w: int, h: int, top, bot) -> Image.Image:
    small = Image.new("RGB", (1, 2))
    small.putpixel((0, 0), top)
    small.putpixel((0, 1), bot)
    return small.resize((w, h), Image.BICUBIC)


def load_font(size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(FONT_TITLE_PATH, size)
    except OSError:
        return ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size)


def draw_centered_text(draw: ImageDraw.ImageDraw, y: int, text: str,
                       font: ImageFont.FreeTypeFont, color) -> int:
    bbox = draw.textbbox((0, 0), text, font=font, anchor="lt")
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    x = (CANVAS_W - tw) // 2
    draw.text((x, y), text, font=font, fill=color, anchor="lt")
    return y + th


def round_corners(img: Image.Image, radius: int) -> Image.Image:
    """Return RGBA image with rounded corners."""
    if img.mode != "RGBA":
        img = img.convert("RGBA")
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.size[0], img.size[1]), radius=radius, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
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
    available_h = CANVAS_H - available_top - BOTTOM_MARGIN
    available_w = CANVAS_W - SIDE_MARGIN * 2

    scale = min(available_w / shot.width, available_h / shot.height)
    new_size = (int(shot.width * scale), int(shot.height * scale))
    shot = shot.resize(new_size, Image.LANCZOS)
    shot = round_corners(shot, CORNER_RADIUS)

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
    print(f"Composing {len(srcs)} iPad screenshot(s) at {CANVAS_W}x{CANVAS_H}")
    for src in srcs:
        dst = OUT_DIR / f"{src.stem}_{CANVAS_W}x{CANVAS_H}.png"
        compose_one(src, dst)
    print(f"\nDone. Output: {OUT_DIR}")


if __name__ == "__main__":
    main()
