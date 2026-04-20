#!/usr/bin/env python3
"""Composite real Apple Watch Ultra screenshots into ASC-compliant marketing
panels in the same dark-navy style as the macOS/iPad composites.

Input:  screenshots/watch/NN_*.png       (422x514 native Apple Watch Ultra)
Output: screenshots/watch/composed/NN_*_410x502.png  (APP_WATCH_ULTRA)

Layout:
  - dark navy vertical gradient background
  - short title + subtitle stacked at top
  - watch screenshot centered below with rounded corners

Canvas is 410x502 (logical) = 820x1004 pixels at 2x. We emit 2x PNG, which
is the size ASC accepts for `APP_WATCH_ULTRA`.
"""

from __future__ import annotations
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

# 2x of Apple Watch Ultra point size (410x502)
CANVAS_W, CANVAS_H = 820, 1004

BG_TOP    = (16, 20, 42)   # #10142A
BG_BOTTOM = (8, 10, 22)    # #080A16

TITLE_COLOR    = (255, 255, 255)
SUBTITLE_COLOR = (175, 182, 200)

FONT_TITLE_PATH = "/System/Library/Fonts/SFNS.ttf"
FONT_TITLE_SIZE = 56     # smaller than macOS/iPad because canvas is smaller
FONT_SUBTITLE_SIZE = 28

TEXT_TOP_MARGIN = 46
TITLE_TO_SUB_GAP = 12
TEXT_TO_SHOT_GAP = 34
SIDE_MARGIN = 30
BOTTOM_MARGIN = 34
CORNER_RADIUS = 56  # Watch screens are visibly rounded; stronger radius reads better at small size

COPY = {
    "01_home":     ("Your CLI usage, on your wrist", "A glanceable dashboard for every AI coding tool"),
    "02_overview": ("Live usage, cost, quotas",     "Today's activity — everywhere you code"),
    "03_sessions": ("Every session, in real time",  "See what's running across your devices"),
    "04_alerts":   ("Warnings before you hit the wall", "Smart quota alerts, right on your wrist"),
    "05_providers":("Quota for every provider",     "Codex, Claude, Gemini — at a glance"),
}

SCRIPT_DIR = Path(__file__).resolve().parent
REPO = SCRIPT_DIR.parent
IN_DIR = REPO / "screenshots" / "watch"
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


def wrap(text: str, font: ImageFont.FreeTypeFont, max_w: int, draw: ImageDraw.ImageDraw) -> list[str]:
    """Simple greedy word-wrap used when a title/subtitle would overflow
    the narrow Watch canvas."""
    words = text.split()
    lines, cur = [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        tw = draw.textbbox((0, 0), trial, font=font, anchor="lt")[2]
        if tw <= max_w or not cur:
            cur = trial
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def draw_centered_lines(draw: ImageDraw.ImageDraw, y: int, lines: list[str],
                        font: ImageFont.FreeTypeFont, color, line_gap: int = 4) -> int:
    for line in lines:
        bbox = draw.textbbox((0, 0), line, font=font, anchor="lt")
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        x = (CANVAS_W - tw) // 2
        draw.text((x, y), line, font=font, fill=color, anchor="lt")
        y += th + line_gap
    return y


def round_corners(img: Image.Image, radius: int) -> Image.Image:
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

    max_text_w = CANVAS_W - SIDE_MARGIN * 2
    title_lines = wrap(title, title_font, max_text_w, draw)
    sub_lines = wrap(subtitle, sub_font, max_text_w, draw)

    y = TEXT_TOP_MARGIN
    y = draw_centered_lines(draw, y, title_lines, title_font, TITLE_COLOR, line_gap=6)
    y += TITLE_TO_SUB_GAP
    y = draw_centered_lines(draw, y, sub_lines, sub_font, SUBTITLE_COLOR, line_gap=4)
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
    print(f"Composing {len(srcs)} Apple Watch screenshot(s) at {CANVAS_W}x{CANVAS_H}")
    for src in srcs:
        dst = OUT_DIR / f"{src.stem}_{CANVAS_W}x{CANVAS_H}.png"
        compose_one(src, dst)
    print(f"\nDone. Output: {OUT_DIR}")


if __name__ == "__main__":
    main()
