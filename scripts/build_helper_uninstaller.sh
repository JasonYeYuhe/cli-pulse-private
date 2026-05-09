#!/usr/bin/env bash
# Build CLI Pulse Helper Uninstaller.app — a tiny Developer ID notarized
# Cocoa app the user clicks "Uninstall Companion CLI" from inside the
# MAS app to remove the helper. Triggered via NSWorkspace.shared.open
# from sandboxed code; runs unsandboxed (no app-sandbox entitlement)
# so it can launchctl bootout + rm -rf the helper directory.
#
# Output: <output-dir>/CLI Pulse Helper Uninstaller.app/
#         (consumed by build_helper_pkg.sh — copied into the staging
#          tree before pkgbuild)
#
# Usage:
#   scripts/build_helper_uninstaller.sh [--output-dir DIR]
#                                       [--skip-sign] [--dry-run]
#
# Required env (full sign):
#   DEV_ID_APP   "Developer ID Application: Yuhe Ye (KHMK6Q3L3K)"

set -euo pipefail

# === Defaults ===
OUTPUT_DIR=""
SKIP_SIGN=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --skip-sign) SKIP_SIGN=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) sed -n '2,25p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "error: unknown arg: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$PROJECT_ROOT/helper-uninstaller"
: "${OUTPUT_DIR:=$PROJECT_ROOT/build/v1.16-uninstaller}"

mkdir -p "$OUTPUT_DIR"

APP_NAME="CLI Pulse Helper Uninstaller.app"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME"
APP_BIN_DIR="$APP_BUNDLE/Contents/MacOS"
APP_BIN="$APP_BIN_DIR/CLIPulseHelperUninstaller"
APP_RES_DIR="$APP_BUNDLE/Contents/Resources"

run() { echo "+ $*"; [[ $DRY_RUN -eq 0 ]] && "$@"; }

if [[ $SKIP_SIGN -eq 0 ]]; then
    : "${DEV_ID_APP:?Set DEV_ID_APP env or pass --skip-sign}"
fi

echo "=== build_helper_uninstaller.sh ==="
echo "Source dir : $SRC_DIR"
echo "Output     : $APP_BUNDLE"
echo "Skip sign  : $SKIP_SIGN"

# === Step 1: Lay out the .app bundle structure ===
run rm -rf "$APP_BUNDLE"
run mkdir -p "$APP_BIN_DIR" "$APP_RES_DIR"
run cp "$SRC_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# === Step 2: Compile main.swift ===
# The Cocoa framework is system-provided; minimum macOS 13.0 (matches the
# helper pkg's --min-os-version).
run swiftc -o "$APP_BIN" \
    -target arm64-apple-macos13.0 \
    -O \
    "$SRC_DIR/main.swift"

# === Step 3: Codesign ===
if [[ $SKIP_SIGN -eq 0 ]]; then
    # Single outermost sign — codesign recursively walks the bundle.
    # --options runtime: Hardened Runtime, required for notarization.
    # --timestamp: ensures the signature remains valid past cert expiration.
    # (Per Gemini review of slice 4E.1.5: separate inner+outer sign was
    # redundant.)
    run codesign --force --timestamp --options runtime \
        --sign "$DEV_ID_APP" "$APP_BUNDLE"
    run codesign --verify --strict --verbose=2 "$APP_BUNDLE"
fi

# === Step 4: Sanity check ===
if [[ $DRY_RUN -eq 0 ]]; then
    if [[ ! -x "$APP_BIN" ]]; then
        echo "error: $APP_BIN not produced or not executable" >&2
        exit 2
    fi
    echo
    echo "Bundle contents:"
    find "$APP_BUNDLE" -type f -o -type l | head -10
fi

echo
echo "=== build_helper_uninstaller.sh complete ==="
echo "Output: $APP_BUNDLE"
