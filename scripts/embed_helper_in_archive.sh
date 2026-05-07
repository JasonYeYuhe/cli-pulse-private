#!/bin/bash
# Phase 4E Slice 4 follow-up (Codex P0 fix, 2026-05-07):
# Post-process an `xcodebuild archive`-produced .xcarchive to embed
# the Swift `cli_pulse_helper` LaunchAgent binary + plist into the
# .app inside the archive, sign the helper, re-sign the .app while
# preserving its existing entitlements (sandbox + app-group + .xcent
# Xcode emitted at archive time).
#
# `xcodebuild archive` does NOT trigger Run Script / Copy Files
# build phases for the Swift package's executable target unless those
# phases are wired into the Xcode project. The project has never
# had them — instead the canonical path was `scripts/build_signed_app.sh`
# which only handles Debug builds, not archives. The result was the
# Release archive (and consequently every ASC submission since v1.10)
# shipped without the LaunchAgent helper. Codex caught this on
# v1.13.0 archive verification.
#
# This script is invoked AFTER `xcodebuild archive` to enrich the
# archive in-place. CI / build-appstore.sh both call it.
#
# Usage:
#   ./scripts/embed_helper_in_archive.sh <archive-path>
#
# The archive's app must already be signed by Xcode with the
# automatic signing flow — we re-sign with `--preserve-metadata=
# entitlements,requirements,flags` so the existing Xcode-emitted
# entitlements (and any provisioning profile binding) survive.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <archive-path>" >&2
    exit 2
fi

ARCHIVE_PATH="$1"
if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "error: archive not found at $ARCHIVE_PATH" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT_PKG_DIR="$PROJECT_ROOT/HelperSwift"
PLIST_TEMPLATE="$PROJECT_ROOT/CLI Pulse Bar/CLI Pulse Bar/HelperAgent.plist"
HELPER_ENTITLEMENTS="$SWIFT_PKG_DIR/cli_pulse_helper.entitlements"

# Locate the .app inside the archive.
APP_PATH="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -type d -name "*.app" | head -1)"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "error: no .app found inside $ARCHIVE_PATH/Products/Applications" >&2
    exit 2
fi
echo "==> Archive .app: $APP_PATH"

# Build the Swift helper in release mode.
echo "==> [1/5] Building Swift helper (release) ..."
cd "$SWIFT_PKG_DIR"
swift build -c release
HELPER_BIN="$SWIFT_PKG_DIR/.build/release/cli_pulse_helper"
[[ -x "$HELPER_BIN" ]] || { echo "error: helper binary missing at $HELPER_BIN" >&2; exit 1; }
echo "    built: $HELPER_BIN ($(du -h "$HELPER_BIN" | cut -f1))"
cd "$PROJECT_ROOT"

# Detect the existing signing identity Xcode used for the archive.
# We sign the helper with the same identity so the embedded child
# inherits the trust chain; Apple Distribution (App Store), Developer
# ID Application (notarised distribution), or ad-hoc `-` (CI without
# signing) are all valid input here.
echo "==> [2/5] Resolving signing identity from existing app ..."
SIGN_IDENTITY=""
# Use process substitution + non-fatal grep to avoid SIGPIPE
# under `set -e -o pipefail`. Plain `grep -m1` triggers SIGPIPE
# on codesign (it's still writing more lines when grep exits)
# and pipefail then kills the script silently.
AUTHORITY=""
while IFS= read -r line; do
    if [[ "$line" == Authority=* ]]; then
        AUTHORITY="${line#Authority=}"
        break
    fi
done < <(codesign -dvv "$APP_PATH" 2>&1)
if [[ -n "$AUTHORITY" ]]; then
    SIGN_IDENTITY="$AUTHORITY"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    # Archive wasn't signed with a real cert (e.g. CI without
    # Apple credentials). Fall back to ad-hoc so verification can
    # still pass — ASC won't accept it but the bundle structure is
    # what we want to verify.
    SIGN_IDENTITY="-"
    echo "    warning: archive has no Authority= line; using ad-hoc identity '-'"
else
    echo "    identity: $SIGN_IDENTITY"
fi

# Embed helper at Contents/Helpers/.
echo "==> [3/5] Embedding helper at Contents/Helpers/ ..."
mkdir -p "$APP_PATH/Contents/Helpers"
cp "$HELPER_BIN" "$APP_PATH/Contents/Helpers/cli_pulse_helper"
chmod +x "$APP_PATH/Contents/Helpers/cli_pulse_helper"

# Embed LaunchAgent plist at Contents/Library/LaunchAgents/.
mkdir -p "$APP_PATH/Contents/Library/LaunchAgents"
cp "$PLIST_TEMPLATE" "$APP_PATH/Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist"

# Strip xattrs that codesign rejects on nested helper targets.
xattr -cr "$APP_PATH" 2>/dev/null || true

# Sign the embedded helper with its own minimal entitlements
# (Hardened Runtime on, no sandbox — it's a LaunchAgent).
echo "==> [4/5] Codesigning helper + re-signing .app ..."
codesign --force --options runtime --timestamp=none \
    --entitlements "$HELPER_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH/Contents/Helpers/cli_pulse_helper"

# Re-sign the .app preserving its existing entitlements + flags +
# requirements. --preserve-metadata=entitlements means the .xcent
# Xcode emitted at archive time (sandbox, app-group, etc.) survives
# unchanged. We do NOT use --deep — that would re-apply the parent's
# entitlements onto every nested binary, including overwriting the
# helper's just-applied minimal set.
codesign --force --options runtime --timestamp=none \
    --preserve-metadata=entitlements,requirements,flags \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

# Verify.
echo "==> [5/5] Verifying bundle ..."
test -x "$APP_PATH/Contents/Helpers/cli_pulse_helper" || { echo "missing helper" >&2; exit 1; }
test -f "$APP_PATH/Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist" || { echo "missing plist" >&2; exit 1; }
codesign --verify --deep --strict "$APP_PATH" || { echo "codesign verify failed" >&2; exit 1; }

# Pin sandbox + app-group on the parent app's entitlements.
APP_ENT="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
if ! grep -q "com.apple.security.app-sandbox" <<< "$APP_ENT"; then
    echo "error: app sandbox entitlement was stripped — abort" >&2
    exit 1
fi
if ! grep -q "group.yyh.CLI-Pulse" <<< "$APP_ENT"; then
    echo "error: app-group entitlement was stripped — abort" >&2
    exit 1
fi

# Helper MUST NOT have the app's sandbox entitlement (it's a
# LaunchAgent that runs unsandboxed — sandbox would block ps,
# vm_stat, ~/.claude reads, git scans).
HELPER_ENT="$(codesign -d --entitlements :- "$APP_PATH/Contents/Helpers/cli_pulse_helper" 2>/dev/null || true)"
if grep -q "com.apple.security.app-sandbox" <<< "$HELPER_ENT"; then
    echo "error: helper accidentally inherited app-sandbox entitlement — abort" >&2
    exit 1
fi

# Pin the LaunchAgent plist's BundleProgram value points at the
# embedded helper path. If the plist drifts away from
# "Contents/Helpers/cli_pulse_helper" the runtime registration
# will silently no-op.
PLIST="$APP_PATH/Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist"
BUNDLE_PROGRAM="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$PLIST" 2>/dev/null || true)"
if [[ "$BUNDLE_PROGRAM" != "Contents/Helpers/cli_pulse_helper" ]]; then
    echo "error: plist BundleProgram is '$BUNDLE_PROGRAM', expected 'Contents/Helpers/cli_pulse_helper'" >&2
    exit 1
fi

echo "    OK: archive $ARCHIVE_PATH now contains:"
echo "    - $APP_PATH/Contents/Helpers/cli_pulse_helper (signed)"
echo "    - $APP_PATH/Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist"
