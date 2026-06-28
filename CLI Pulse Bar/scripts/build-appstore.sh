#!/bin/bash
set -euo pipefail

# CLI Pulse - App Store Build & Upload Script
# Usage: ./scripts/build-appstore.sh [macos|ios|all] [--upload]
#
# Prerequisites:
#   - Valid Apple Developer signing certificates
#   - API key at: ~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_DMMFP6XTXX.p8
#   - App Store Connect app created (ID: 6761163709)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_DIR/CLI Pulse Bar.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build/appstore"

# App Store Connect credentials
API_KEY_ID="DMMFP6XTXX"
API_ISSUER="c5671c11-49ec-47d9-bd38-5e3c1a249416"
# API key path: honor an ASC_KEY_PATH override, else prefer the local
# ~/.appstoreconnect/private_keys copy. The iCloud Drive copy
# (com~apple~CloudDocs) is TCC-protected and reads as "Operation not
# permitted" under headless / sandboxed runs, so it can't be the only source.
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    API_KEY_PATH="$ASC_KEY_PATH"
elif [[ -f "$HOME/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8" ]]; then
    API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8"
else
    API_KEY_PATH="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_${API_KEY_ID}.p8"
fi
TEAM_ID="KHMK6Q3L3K"

# Parse arguments
PLATFORM="${1:-all}"
UPLOAD=false
if [[ "${2:-}" == "--upload" ]] || [[ "${1:-}" == "--upload" ]]; then
    UPLOAD=true
    if [[ "${1:-}" == "--upload" ]]; then
        PLATFORM="all"
    fi
fi

# v1.20 A8: source plists now use $(MARKETING_VERSION) /
# $(CURRENT_PROJECT_VERSION) substitutions, so `defaults read` on the
# raw plist would return the literal `$(MARKETING_VERSION)` string.
# Read from xcodebuild -showBuildSettings instead, which resolves the
# build settings the same way an actual archive does.
_read_build_setting() {
    xcodebuild -project "$PROJECT" -target "CLI Pulse Bar" -configuration Release -showBuildSettings -json 2>/dev/null \
        | python3 -c "import sys,json; data=json.load(sys.stdin); print(data[0]['buildSettings'].get('$1',''))"
}
VERSION="$(_read_build_setting MARKETING_VERSION)"
BUILD_NUM="$(_read_build_setting CURRENT_PROJECT_VERSION)"
[[ -z "$VERSION" ]] && VERSION="0.1.0"
[[ -z "$BUILD_NUM" ]] && BUILD_NUM="0"

# --- Sentry dSYM upload config ---
# Auth token is stored outside the repo in the standard CLI Pulse secrets dir
# (chmod 600). The org token has scope `org:ci` (Source Map Upload, Release
# Creation, Code Mappings) — sufficient for `debug-files upload` and
# `releases finalize`, insufficient for anything destructive. Generate at
# https://jason-yeyuhe.sentry.io/settings/auth-tokens/ if it's missing.
#
# iOS+Watch share one Sentry project whose display name is "apple-ios" but
# whose actual slug is `tokyohelp-ios` (distinguished by platform_family tag at
# the SDK level). sentry-cli --project takes the SLUG, not the display name —
# passing `apple-ios` here 400s with "Invalid project ids or slugs". macOS uses
# `apple-macos` (slug == name there). Android uses `android` (handled by the
# Sentry Gradle plugin, not this script). To re-verify the slug if uploads ever
# break again: `sentry-cli projects list --org jason-yeyuhe` (needs a token with
# project:read — e.g. the one in ~/.sentryclirc, not the upload-only org token).
SENTRY_ORG="jason-yeyuhe"
SENTRY_AUTH_TOKEN_FILE="$HOME/Library/Application Support/CLI-Pulse-Secrets/sentry-cli-auth-token-2026-04-29.txt"

load_sentry_auth_token() {
    if [[ -n "${SENTRY_AUTH_TOKEN:-}" ]]; then
        return 0
    fi
    if [[ ! -f "$SENTRY_AUTH_TOKEN_FILE" ]]; then
        return 1
    fi
    # File format: one line `SENTRY_AUTH_TOKEN=sntrys_...` plus prose around it.
    local extracted
    extracted=$(grep -E '^SENTRY_AUTH_TOKEN=' "$SENTRY_AUTH_TOKEN_FILE" | head -1 | cut -d= -f2-)
    if [[ -z "$extracted" ]]; then
        return 1
    fi
    export SENTRY_AUTH_TOKEN="$extracted"
}

# Upload dSYMs from a finished xcarchive to the matching Sentry project.
# Args: $1 = path to .xcarchive, $2 = sentry project slug.
upload_dsyms_to_sentry() {
    local ARCHIVE_PATH="$1"
    local SENTRY_PROJECT="$2"

    if ! command -v sentry-cli >/dev/null 2>&1; then
        echo "  ⚠ sentry-cli not installed — skipping dSYM upload."
        echo "    Install: brew install getsentry/tools/sentry-cli"
        return 0
    fi
    if ! load_sentry_auth_token; then
        echo "  ⚠ SENTRY_AUTH_TOKEN not available — skipping dSYM upload."
        echo "    Expected at: $SENTRY_AUTH_TOKEN_FILE"
        return 0
    fi

    local DSYMS_DIR="$ARCHIVE_PATH/dSYMs"
    if [[ ! -d "$DSYMS_DIR" ]]; then
        echo "  ⚠ No dSYMs/ directory in archive — skipping dSYM upload."
        return 0
    fi

    echo "  ↗ Uploading dSYMs to Sentry (org=$SENTRY_ORG project=$SENTRY_PROJECT)..."
    if sentry-cli debug-files upload \
            --org "$SENTRY_ORG" \
            --project "$SENTRY_PROJECT" \
            --include-sources \
            "$DSYMS_DIR" 2>&1 | sed 's/^/    /'; then
        echo "  ✓ dSYMs uploaded"
    else
        echo "  ⚠ dSYM upload failed — see above. Build itself is unaffected."
    fi

    # Mark this version+build as a finalized release so Sentry can attribute
    # "first seen in 1.11.x" properly. Idempotent: re-running for the same
    # version is a no-op once finalized.
    local RELEASE="cli-pulse@${VERSION}+${BUILD_NUM}"
    echo "  ↗ Finalizing Sentry release $RELEASE for project $SENTRY_PROJECT..."
    sentry-cli releases \
        --org "$SENTRY_ORG" \
        --project "$SENTRY_PROJECT" \
        new "$RELEASE" 2>&1 | sed 's/^/    /' || true
    sentry-cli releases \
        --org "$SENTRY_ORG" \
        --project "$SENTRY_PROJECT" \
        finalize "$RELEASE" 2>&1 | sed 's/^/    /' || true
}

echo "================================================"
echo "  CLI Pulse - App Store Build v${VERSION}"
echo "  Platform: ${PLATFORM}"
echo "  Upload: ${UPLOAD}"
echo "================================================"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- macOS Build ---
build_macos() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Building macOS..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local ARCHIVE="$BUILD_DIR/CLIPulseBar-macOS.xcarchive"
    local EXPORT="$BUILD_DIR/macos-export"

    rm -rf "$ARCHIVE" "$EXPORT"

    echo "[1/4] Archiving macOS target..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "CLI Pulse Bar" \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        -quiet \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic

    echo "  ✓ Archive: $ARCHIVE"

    # Mac App Store rule ITMS-90296 requires every nested executable
    # inside a sandboxed app to also be sandboxed. The Swift
    # `cli_pulse_helper` LaunchAgent intentionally runs unsandboxed
    # for the future Developer ID distribution path, so it MUST NOT
    # be present in the MAS-bound archive. Developer ID/debug helper
    # embedding is still covered by `scripts/build_signed_app.sh`.
    echo "[2/4] Verifying MAS archive excludes Swift LaunchAgent helper..."
    verify_mas_archive_has_no_launchagent "$ARCHIVE"
    echo "  ✓ MAS archive contains no unsandboxed LaunchAgent helper"

    if [[ "$UPLOAD" == true ]]; then
        echo "[3/4] Skipping local export (upload path exports with ASC API key)"
    else
        echo "[3/4] Exporting for App Store..."
        cat > "$BUILD_DIR/ExportOptions-macOS.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>KHMK6Q3L3K</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

        xcodebuild -exportArchive \
            -archivePath "$ARCHIVE" \
            -exportOptionsPlist "$BUILD_DIR/ExportOptions-macOS.plist" \
            -exportPath "$EXPORT" \
            -allowProvisioningUpdates \
            -quiet

        echo "  ✓ Export: $EXPORT"
    fi

    upload_dsyms_to_sentry "$ARCHIVE" "apple-macos"

    if [[ "$UPLOAD" == true ]]; then
        echo "[4/4] Uploading macOS to App Store Connect..."
        upload_to_appstore "$ARCHIVE" "$EXPORT" "macos"
    else
        echo "[4/4] Skipping upload (use --upload to enable)"
    fi
    echo ""
}

verify_mas_archive_has_no_launchagent() {
    local ARCHIVE_PATH="$1"
    local APP_PATH="$ARCHIVE_PATH/Products/Applications/CLI Pulse Bar.app"

    if [[ ! -d "$APP_PATH" ]]; then
        echo "  ERROR: app not found in archive: $APP_PATH" >&2
        return 1
    fi

    # v1.18.0: the project's "Embed Helper Binary" + "Embed Helper
    # LaunchAgent" copy-files build phases run on every archive (they're
    # required for the Developer ID DMG flow), so the unsandboxed Swift
    # helper + plist always show up here. For the MAS archive we strip
    # them and re-sign the .app with Apple Distribution while preserving
    # entitlements. The strip is idempotent — `rm -f` on a missing path
    # is a no-op, and absent the helper this whole function is just the
    # LoginItem-sandbox-entitlement assertion below.
    local NEEDS_RESIGN=0
    if [[ -e "$APP_PATH/Contents/Helpers/cli_pulse_helper" ]]; then
        echo "  Stripping unsandboxed helper for MAS submission..."
        rm -f "$APP_PATH/Contents/Helpers/cli_pulse_helper"
        rmdir "$APP_PATH/Contents/Helpers" 2>/dev/null || true
        NEEDS_RESIGN=1
    fi
    if [[ -e "$APP_PATH/Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.agent.plist" ]]; then
        echo "  Stripping LaunchAgent plist for MAS submission..."
        rm -f "$APP_PATH/Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.agent.plist"
        rmdir "$APP_PATH/Contents/Library/LaunchAgents" 2>/dev/null || true
        NEEDS_RESIGN=1
    fi
    if [[ "$NEEDS_RESIGN" == "1" ]]; then
        # The strip invalidates the .app's Sealed Resources hash — re-sign
        # with the Apple Distribution identity, preserving Xcode-emitted
        # entitlements + provisioning profile binding.
        local DIST_IDENTITY
        DIST_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Apple Distribution: .*\)"/\1/p' | head -n 1)
        if [[ -z "$DIST_IDENTITY" ]]; then
            echo "  ERROR: no Apple Distribution identity found in keychain — can't re-sign after strip" >&2
            return 1
        fi
        echo "  Re-signing $APP_PATH with $DIST_IDENTITY..."
        codesign --force --sign "$DIST_IDENTITY" \
            --preserve-metadata=entitlements,requirements,flags \
            --options runtime --timestamp "$APP_PATH" || {
            echo "  ERROR: codesign re-sign failed after strip" >&2
            return 1
        }
        codesign --verify --deep --strict "$APP_PATH" || {
            echo "  ERROR: codesign verify failed after re-sign" >&2
            return 1
        }
    fi

    # Codex review (PR #39): assert every nested executable inside the MAS
    # bundle is sandboxed. ITMS-90296 rejects ANY unsandboxed nested binary,
    # not just the Swift LaunchAgent helper. The CLIPulseHelper.app LoginItem
    # is the only nested binary that ships in MAS archives; verify its signed
    # entitlements include app-sandbox=true. This catches accidental drift in
    # ENABLE_APP_SANDBOX project settings or future nested binaries that
    # someone forgets to sandbox.
    local LOGIN_ITEM="$APP_PATH/Contents/Library/LoginItems/CLIPulseHelper.app"
    local LOGIN_ITEM_BIN="$LOGIN_ITEM/Contents/MacOS/CLIPulseHelper"
    if [[ ! -d "$LOGIN_ITEM" ]]; then
        echo "  ERROR: MAS archive missing CLIPulseHelper.app LoginItem at $LOGIN_ITEM" >&2
        return 1
    fi
    if [[ ! -x "$LOGIN_ITEM_BIN" ]]; then
        echo "  ERROR: MAS archive missing LoginItem binary at $LOGIN_ITEM_BIN" >&2
        return 1
    fi
    local LOGIN_ITEM_ENT
    LOGIN_ITEM_ENT="$(codesign -d --entitlements :- "$LOGIN_ITEM_BIN" 2>/dev/null || true)"
    if [[ -z "$LOGIN_ITEM_ENT" ]]; then
        echo "  WARN: could not read LoginItem entitlements via codesign (likely an unsigned CI build)" >&2
        # Fall back to source entitlements file when binary is unsigned.
        local SRC_ENT="${SRCROOT:-$(pwd)}/CLIPulseHelper/CLIPulseHelper.entitlements"
        if [[ ! -f "$SRC_ENT" ]]; then
            SRC_ENT="$(dirname "$0")/../CLIPulseHelper/CLIPulseHelper.entitlements"
        fi
        if [[ -f "$SRC_ENT" ]]; then
            LOGIN_ITEM_ENT="$(cat "$SRC_ENT")"
        fi
    fi
    if ! grep -q "com.apple.security.app-sandbox" <<< "$LOGIN_ITEM_ENT"; then
        echo "  ERROR: CLIPulseHelper LoginItem is not sandboxed (missing app-sandbox entitlement)" >&2
        echo "  Mac App Store rejects unsandboxed nested binaries with ITMS-90296." >&2
        return 1
    fi
    # Confirm it's set to <true/>, not just present. v1.18.0: codesign
    # in macOS 14+ emits the plist as a single line, so the previous
    # awk-line-state approach (which expected key on one line and value
    # on the next) reported false-negatives. Use a simple substring
    # check for `<key>app-sandbox</key><true/>` against the whole blob,
    # tolerant of whitespace between the elements.
    if ! grep -qE "<key>com\.apple\.security\.app-sandbox</key>[[:space:]]*<true/>" <<< "$LOGIN_ITEM_ENT"; then
        echo "  ERROR: CLIPulseHelper LoginItem app-sandbox entitlement is not <true/>" >&2
        echo "  Entitlements were:" >&2
        echo "$LOGIN_ITEM_ENT" >&2 | head -3
        return 1
    fi
}

# --- iOS Build (includes Widgets) ---
build_ios() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Building iOS (includes Widgets)..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local ARCHIVE="$BUILD_DIR/CLIPulse-iOS.xcarchive"
    local EXPORT="$BUILD_DIR/ios-export"

    rm -rf "$ARCHIVE" "$EXPORT"

    echo "[1/3] Archiving iOS target..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "CLI Pulse iOS" \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        -destination "generic/platform=iOS" \
        -quiet \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic

    echo "  ✓ Archive: $ARCHIVE"

    if [[ "$UPLOAD" == true ]]; then
        echo "[2/3] Skipping local export (upload path exports with ASC API key)"
    else
        echo "[2/3] Exporting for App Store..."
        cat > "$BUILD_DIR/ExportOptions-iOS.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>KHMK6Q3L3K</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

        xcodebuild -exportArchive \
            -archivePath "$ARCHIVE" \
            -exportOptionsPlist "$BUILD_DIR/ExportOptions-iOS.plist" \
            -exportPath "$EXPORT" \
            -allowProvisioningUpdates \
            -quiet

        echo "  ✓ Export: $EXPORT"
    fi

    upload_dsyms_to_sentry "$ARCHIVE" "tokyohelp-ios"

    if [[ "$UPLOAD" == true ]]; then
        echo "[3/3] Uploading iOS to App Store Connect..."
        upload_to_appstore "$ARCHIVE" "$EXPORT" "ios"
    else
        echo "[3/3] Skipping upload (use --upload to enable)"
    fi
    echo ""
}

# --- watchOS Build ---
build_watchos() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Building watchOS..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local ARCHIVE="$BUILD_DIR/CLIPulse-watchOS.xcarchive"
    local EXPORT="$BUILD_DIR/watchos-export"

    rm -rf "$ARCHIVE" "$EXPORT"

    echo "[1/3] Archiving watchOS target..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "CLI Pulse Watch" \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        -destination "generic/platform=watchOS" \
        -quiet \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic

    echo "  ✓ Archive: $ARCHIVE"

    if [[ "$UPLOAD" == true ]]; then
        echo "[2/3] Skipping local export (upload path exports with ASC API key)"
    else
        echo "[2/3] Exporting for App Store..."
        cat > "$BUILD_DIR/ExportOptions-watchOS.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>KHMK6Q3L3K</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

        xcodebuild -exportArchive \
            -archivePath "$ARCHIVE" \
            -exportOptionsPlist "$BUILD_DIR/ExportOptions-watchOS.plist" \
            -exportPath "$EXPORT" \
            -allowProvisioningUpdates \
            -quiet

        echo "  ✓ Export: $EXPORT"
    fi

    # watchOS reuses the iOS Sentry project (iOS+Watch share DSN, distinguished
    # by platform_family tag). Display name is "apple-ios"; the slug sentry-cli
    # wants is `tokyohelp-ios`.
    upload_dsyms_to_sentry "$ARCHIVE" "tokyohelp-ios"

    if [[ "$UPLOAD" == true ]]; then
        echo "[3/3] Uploading watchOS to App Store Connect..."
        upload_to_appstore "$ARCHIVE" "$EXPORT" "watchos"
    else
        echo "[3/3] Skipping upload (use --upload to enable)"
    fi
    echo ""
}

# --- Upload function ---
upload_to_appstore() {
    local ARCHIVE_PATH="$1"
    local EXPORT_DIR="$2"
    local PLATFORM="$3"

    if [[ ! -f "$API_KEY_PATH" ]]; then
        echo "  ERROR: API key not found at $API_KEY_PATH"
        echo "  Download from App Store Connect > Users and Access > Keys"
        return 1
    fi

    echo "  Uploading via xcodebuild -exportArchive (destination: upload)..."

    if [[ "$PLATFORM" == "macos" ]]; then
        verify_mas_archive_has_no_launchagent "$ARCHIVE_PATH"
    fi

    local EXPORT_PLIST="$BUILD_DIR/ExportOptions-${PLATFORM}-upload.plist"
    cat > "$EXPORT_PLIST" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>KHMK6Q3L3K</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        -exportPath "$EXPORT_DIR" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$API_KEY_PATH" \
        -authenticationKeyID "$API_KEY_ID" \
        -authenticationKeyIssuerID "$API_ISSUER" \
        2>&1

    echo "  ✓ Upload complete for $PLATFORM"
}

# --- Execute ---
case "$PLATFORM" in
    macos)
        build_macos
        ;;
    ios)
        build_ios
        ;;
    watchos)
        build_watchos
        ;;
    all)
        build_macos
        build_ios
        # v1.18.0: standalone watchOS upload is redundant — the Watch
        # app already ships embedded inside `CLI Pulse.app/Watch/` from
        # the iOS archive, so ASC receives it as part of the iOS build.
        # The standalone path also breaks on newer Xcode (`method` no
        # longer accepts `app-store-connect`). Pass `watchos` explicitly
        # if you really want to test the standalone build.
        ;;
    *)
        echo "Usage: $0 [macos|ios|watchos|all] [--upload]"
        exit 1
        ;;
esac

# --- Summary ---
echo "================================================"
echo "  Build Complete!"
echo "================================================"
echo ""
echo "  Archives:"
ls -1 "$BUILD_DIR"/*.xcarchive 2>/dev/null | while read f; do echo "    $f"; done
echo ""
echo "  Exports:"
ls -1d "$BUILD_DIR"/*-export 2>/dev/null | while read f; do echo "    $f"; done
echo ""
if [[ "$UPLOAD" == false ]]; then
    echo "  To upload: $0 $PLATFORM --upload"
fi
echo ""
