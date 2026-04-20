#!/usr/bin/env bash
# Capture real App Store screenshots for CLI Pulse Bar (macOS).
#
# Strategy:
#  - Menu-bar popover → `screencapture -i -r` (interactive rectangle, retina).
#    macOS gives you cross-hairs; drag around the popover and it saves at 2x.
#  - Separate app Windows (Provider Settings, About, Subscription, etc.) →
#    `screencapture -w` (interactive window pick).
#
# The script guides you step-by-step: for each view it prints an instruction,
# waits for you to arrange the UI, then invokes screencapture. Drop-shadow is
# disabled on window captures so the PNG edges are tight.
#
# Output: CLI Pulse Bar/screenshots/macos/ relative to this script's repo root.
# Naming: 01_overview.png, 02_providers.png, … so ordering matches App Store.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/screenshots/macos"
mkdir -p "$OUT_DIR"

echo ""
echo "========================================"
echo " CLI Pulse Bar — real screenshot capture"
echo "========================================"
echo "Output: $OUT_DIR"
echo ""
echo "Before you start:"
echo "  1. Launch the Release build of CLI Pulse Bar (Xcode → Product → Archive, or run the .app)."
echo "  2. Sign in with a real account so the UI has live data."
echo "  3. Use light mode or dark mode — pick one and stick to it (App Store mixes fine, but consistency reads better)."
echo "  4. Cursor in the capture area: keep it tucked into a corner so it doesn't appear on screen (screencapture includes it otherwise)."
echo ""
read -r -p "Press ENTER when ready."

# Helper: popover capture (interactive rectangle). Retina by default.
capture_rect() {
    local slot="$1"
    local label="$2"
    local instruction="$3"
    echo ""
    echo "--- $slot: $label ---"
    echo "$instruction"
    echo "Then drag a rectangle around the popover. Press ESC to skip."
    local path="$OUT_DIR/${slot}_${label}.png"
    if /usr/sbin/screencapture -i -r -x "$path" 2>/dev/null && [ -s "$path" ]; then
        echo "  → saved $path"
    else
        echo "  (skipped)"
        rm -f "$path"
    fi
}

# Helper: window capture (interactive window pick, no shadow, no cursor).
capture_window() {
    local slot="$1"
    local label="$2"
    local instruction="$3"
    echo ""
    echo "--- $slot: $label ---"
    echo "$instruction"
    echo "Then click the window you want. Press ESC to skip."
    local path="$OUT_DIR/${slot}_${label}.png"
    if /usr/sbin/screencapture -w -o -x "$path" 2>/dev/null && [ -s "$path" ]; then
        echo "  → saved $path"
    else
        echo "  (skipped)"
        rm -f "$path"
    fi
}

# ----- popover tabs (menu-bar extra) -----
capture_rect "01" "overview"  "Click the menu-bar icon, switch to the Overview tab. Scroll to top."
capture_rect "02" "providers" "Switch to the Providers tab. Make sure a few provider rows are visible with live quota data."
capture_rect "03" "sessions"  "Switch to the Sessions tab. Ensure at least a few recent sessions are visible."
capture_rect "04" "alerts"    "Switch to the Alerts tab."
capture_rect "05" "settings"  "Switch to the Settings tab. Scroll to the Provider Configuration section so reviewers see it."

# ----- separate windows -----
capture_window "06" "provider_settings" \
    "From Settings → Providers, click the gear on any provider (e.g. Codex). A 'Provider Settings' window will appear. Position it somewhere clean."
capture_window "07" "about" \
    "From the menu-bar popover: press Cmd+1..5 to ensure a tab is active, then pick 'About CLI Pulse Bar' from the CLI Pulse Bar menu (or trigger via ⌘,)."
capture_window "08" "subscription" \
    "From Settings → scroll to Subscription card and click 'Manage Subscription'. The Subscription window will appear."

echo ""
echo "========================================"
echo "Done. Screenshots in: $OUT_DIR"
ls -lh "$OUT_DIR" | tail -n +2
echo ""
echo "Next steps:"
echo "  - Review each PNG. Retake with the same command by re-running this script (it overwrites)."
echo "  - App Store Connect accepts 1280×800, 1440×900, 2560×1600, or 2880×1800 for macOS."
echo "    Retina captures from a 14\"/16\" MBP land near 2880×1800; they upload as-is."
echo "  - If a capture is too small (popover captures often are), either:"
echo "      (a) upscale with sips, or"
echo "      (b) composite the popover onto a desktop background."
echo ""
