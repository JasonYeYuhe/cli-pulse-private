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
API_KEY_PATH="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_${API_KEY_ID}.p8"
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

VERSION=$(defaults read "$PROJECT_DIR/CLI Pulse Bar/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")
BUILD_NUM=$(defaults read "$PROJECT_DIR/CLI Pulse Bar/Info.plist" CFBundleVersion 2>/dev/null || echo "0")

# --- Sentry dSYM upload config ---
# Auth token is stored outside the repo in the standard CLI Pulse secrets dir
# (chmod 600). The org token has scope `org:ci` (Source Map Upload, Release
# Creation, Code Mappings) — sufficient for `debug-files upload` and
# `releases finalize`, insufficient for anything destructive. Generate at
# https://jason-yeyuhe.sentry.io/settings/auth-tokens/ if it's missing.
#
# iOS+Watch share Sentry project `apple-ios` (distinguished by platform_family
# tag at the SDK level). macOS uses `apple-macos`. Android uses `android`
# (handled by the Sentry Gradle plugin, not this script).
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

    echo "[1/3] Archiving macOS target..."
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

    echo "[2/3] Exporting for App Store..."
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
        -quiet 2>&1 || true

    echo "  ✓ Export: $EXPORT"

    upload_dsyms_to_sentry "$ARCHIVE" "apple-macos"

    if [[ "$UPLOAD" == true ]]; then
        echo "[3/3] Uploading macOS to App Store Connect..."
        upload_to_appstore "$ARCHIVE" "$EXPORT" "macos"
    else
        echo "[3/3] Skipping upload (use --upload to enable)"
    fi
    echo ""
}

# --- iOS Build (includes Widgets) ---
build_ios() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Building iOS (includes Widgets)..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local ARCHIVE="$BUILD_DIR/CLIPulse-iOS.xcarchive"
    local EXPORT="$BUILD_DIR/ios-export"

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
        -quiet 2>&1 || true

    echo "  ✓ Export: $EXPORT"

    upload_dsyms_to_sentry "$ARCHIVE" "apple-ios"

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
        -quiet 2>&1 || true

    echo "  ✓ Export: $EXPORT"

    # watchOS reuses the apple-ios Sentry project (per CLI Pulse memory:
    # iOS+Watch share DSN, distinguished by platform_family tag).
    upload_dsyms_to_sentry "$ARCHIVE" "apple-ios"

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
        build_watchos
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
