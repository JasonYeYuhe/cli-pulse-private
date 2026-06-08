#!/usr/bin/env python3
"""Composite real CLI Pulse Bar screenshots onto ASC-compliant 2880x1800 marketing panels.

Style matches the existing App Store screenshots: dark navy background, large
white title + subtitle at top, screenshot centered below. No extra drop shadow
or rounded corners on the pasted screenshot (the sources already include their
native macOS window chrome / popover corners).

Input:  screenshots/macos/NN_*.png
Output: screenshots/macos/composed/NN_*_2880x1800.png
"""

from __future__ import annotations
import os
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageChops

CANVAS_W, CANVAS_H = 2880, 1800

# Dark navy with a barely-perceptible tint of blue at the top — matches the
# existing App Store marketing panels closely.
BG_TOP    = (16, 20, 42)   # #10142A
BG_BOTTOM = (8, 10, 22)    # #080A16

TITLE_COLOR    = (255, 255, 255)
SUBTITLE_COLOR = (175, 182, 200)

# Fonts — SF Pro system font for a native macOS marketing look.
FONT_TITLE_PATH = "/System/Library/Fonts/SFNS.ttf"
FONT_TITLE_SIZE = 110
FONT_SUBTITLE_SIZE = 48

# Layout
TEXT_TOP_MARGIN = 150
TITLE_TO_SUB_GAP = 32
TEXT_TO_SHOT_GAP = 90
SIDE_MARGIN = 140

# Per-screenshot marketing copy. Keys match the numeric prefix of each source.
COPY = {
    "01_overview":          ("Everything at a glance",     "Usage, spend, and forecast across every provider"),
    "02_providers":         ("Live quotas, real costs",    "Claude, Codex, Gemini, and 48+ more in one place"),
    "03_sessions":          ("Every CLI run tracked",      "Real-time session monitoring from your menu bar"),
    "04_cost_detail":       ("Know exactly what you spend", "Exact cost, real value, and a month-end forecast"),
    "05_alerts_history":    ("Stay ahead of every alert",  "Runaway CPU, quota limits, and more — caught early"),
    "06_settings":          ("Tune every detail",          "Per-provider credentials, cadence, and notifications"),
    "07_provider_settings": ("Configure any provider",     "API keys, cookies, OAuth — with one-click test"),
    "08_about":             ("Built for CLI pros",         "Privacy-first — all data stays on your Mac"),
    "09_subscription":      ("CLI Pulse Pro",              "Unlimited providers, devices, and priority support"),
}

SCRIPT_DIR = Path(__file__).resolve().parent
REPO = SCRIPT_DIR.parent
IN_DIR = REPO / "screenshots" / "macos"
OUT_DIR = IN_DIR / "composed"


def make_vertical_gradient(w: int, h: int, top: tuple[int, int, int], bot: tuple[int, int, int]) -> Image.Image:
    """Fast vertical gradient via 1xN palette resize."""
    small = Image.new("RGB", (1, 2))
    small.putpixel((0, 0), top)
    small.putpixel((0, 1), bot)
    return small.resize((w, h), Image.BICUBIC)


def load_font(size: int, weight: str = "regular") -> ImageFont.FreeTypeFont:
    """Load SFNS (system font) at the given size. SFNS is a variable font; PIL
    can't pick a weight axis, so for bold we rely on the regular glyphs at
    larger size. macOS renders SFNS.ttf as Regular by default, which looks
    clean for marketing titles."""
    try:
        return ImageFont.truetype(FONT_TITLE_PATH, size)
    except OSError:
        # Fallback
        return ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size)


def crop_black_padding(img: Image.Image, threshold: int = 15) -> Image.Image:
    """Trim near-black borders around a screenshot. macOS `screencapture -w`
    can include a flat black halo where the window shadow was; we remove it so
    the screenshot sits cleanly on the dark navy panel without a visible ring.
    If the trim would remove >40% of any dimension, we bail and return the
    original (defensive — don't crop actual content)."""
    if img.mode != "RGB":
        img = img.convert("RGB")
    # Build a grayscale mask of "not black" pixels.
    gray = img.convert("L")
    bbox = gray.point(lambda v: 255 if v > threshold else 0, mode="L").getbbox()
    if bbox is None:
        return img
    x0, y0, x1, y1 = bbox
    w, h = img.size
    trimmed_w = x1 - x0
    trimmed_h = y1 - y0
    if trimmed_w < w * 0.6 or trimmed_h < h * 0.6:
        # Crop removes too much — likely this is a dark-themed screenshot with
        # legit dark pixels along the edges. Leave as-is.
        return img
    return img.crop(bbox)


def draw_centered_text(draw: ImageDraw.ImageDraw, y: int, text: str, font: ImageFont.FreeTypeFont,
                       color: tuple[int, int, int]) -> int:
    """Draw text centered horizontally at y; return bottom y of the text block."""
    bbox = draw.textbbox((0, 0), text, font=font, anchor="lt")
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    x = (CANVAS_W - tw) // 2
    draw.text((x, y), text, font=font, fill=color, anchor="lt")
    return y + th


def compose_one(src_path: Path, dst_path: Path):
    print(f"  {src_path.name}", end=" ")
    key = src_path.stem  # e.g. "01_overview"
    title, subtitle = COPY.get(key, ("CLI Pulse Bar", "Monitor your AI coding tools"))

    # Background
    canvas = make_vertical_gradient(CANVAS_W, CANVAS_H, BG_TOP, BG_BOTTOM).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    # Title + subtitle (top)
    title_font = load_font(FONT_TITLE_SIZE, "bold")
    sub_font = load_font(FONT_SUBTITLE_SIZE, "regular")

    y = TEXT_TOP_MARGIN
    y = draw_centered_text(draw, y, title, title_font, TITLE_COLOR)
    y += TITLE_TO_SUB_GAP
    y = draw_centered_text(draw, y, subtitle, sub_font, SUBTITLE_COLOR)
    text_bottom = y

    # Screenshot — trim any flat-black padding, then fit inside remaining area.
    shot = Image.open(src_path).convert("RGB")
    shot = crop_black_padding(shot)

    available_top = text_bottom + TEXT_TO_SHOT_GAP
    available_h = CANVAS_H - available_top - 80  # 80px bottom margin
    available_w = CANVAS_W - SIDE_MARGIN * 2

    scale = min(available_w / shot.width, available_h / shot.height)
    new_size = (int(shot.width * scale), int(shot.height * scale))
    shot = shot.resize(new_size, Image.LANCZOS)

    px = (CANVAS_W - shot.size[0]) // 2
    py = available_top + (available_h - shot.size[1]) // 2

    canvas.alpha_composite(shot.convert("RGBA"), (px, py))

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
        dst = OUT_DIR / f"{src.stem}_2880x1800.png"
        compose_one(src, dst)
    print(f"\nDone. Output: {OUT_DIR}")


if __name__ == "__main__":
    main()
