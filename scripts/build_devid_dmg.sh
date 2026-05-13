#!/usr/bin/env bash
# v1.19 — Build a Developer ID notarized .dmg of CLI Pulse for direct-
# download distribution. Output is hosted on a public GitHub repo
# (cli-pulse-distrib) and consumed by the macOS app's AppUpdater via
# manifest fetch → download → user drag-replace.
#
# This script orchestrates the existing scripts/build_signed_app.sh
# (which already does helper embed + bottom-up entitlements-preserving
# codesign) with the Developer ID identity + Apple timestamp service +
# notarization + DMG packaging + notarization-of-DMG. The MAS pipeline
# (CLI Pulse Bar/scripts/build-appstore.sh) is untouched.
#
# Usage:
#   scripts/build_devid_dmg.sh [--arch arm64|x86_64]
#                              [--skip-notarize]
#                              [--skip-sign]
#                              [--dry-run]
#                              [--output-dir DIR]
#
# Defaults:
#   --arch          host arch (`uname -m`)
#   output dir      build/v1.19-dmg/
#   sign + notarize ON (require DEV_ID_APP, NOTARY_PROFILE env)
#
# Required env (full sign + notarize):
#   DEV_ID_APP        e.g. "Developer ID Application: Yuhe Ye (KHMK6Q3L3K)"
#
# Notarytool credential modes (G8 — pick ONE):
#   keychain profile (local default):
#     NOTARY_PROFILE  defaults to "AC_NOTARY_PROFILE"; must exist in
#                     login keychain via xcrun notarytool store-credentials
#
#   inline (for CI; preferred when all three set):
#     APPLE_NOTARY_USER       Apple ID (e.g. "yyyyy.yeyuhe@icloud.com")
#     APPLE_NOTARY_APP_PASSWORD app-specific password (xxxx-xxxx-xxxx-xxxx)
#     APPLE_TEAM_ID           KHMK6Q3L3K
#   If any of the three is unset, script falls back to keychain profile.
#
# Outputs (under --output-dir):
#   CLI Pulse.app                                  (signed + notarized + stapled)
#   CLI-Pulse-<version>-<arch>.dmg                 (signed + notarized + stapled)
#   CLI-Pulse-<version>-<arch>.dmg.sha256
#   manifest-fragment-<arch>.json                  (for the public mirror repo)
#
# Exit codes:
#   0  success
#   1  argument error
#   2  prerequisite missing
#   3  signing failure
#   4  dmg build failure
#   5  notarization failure

set -euo pipefail

# === Defaults ===
ARCH=""
SKIP_NOTARIZE=0
SKIP_SIGN=0
DRY_RUN=0
OUTPUT_DIR=""

# === Argument parsing ===
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        --skip-sign) SKIP_SIGN=1; SKIP_NOTARIZE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,50p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# === Resolve paths ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_INFO_PLIST="$PROJECT_ROOT/CLI Pulse Bar/CLI Pulse Bar/Info.plist"
BUILD_SIGNED_APP="$SCRIPT_DIR/build_signed_app.sh"
: "${OUTPUT_DIR:=$PROJECT_ROOT/build/v1.19-dmg}"
mkdir -p "$OUTPUT_DIR"

# === Detect arch ===
HOST_ARCH="$(uname -m)"
[[ "$HOST_ARCH" == "aarch64" ]] && HOST_ARCH="arm64"
if [[ -z "$ARCH" ]]; then
    ARCH="$HOST_ARCH"
fi
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "error: unsupported arch: $ARCH (expected arm64 or x86_64)" >&2; exit 1 ;;
esac
# v1.19.0 ships arm64-only — same constraint as helper .pkg (see
# feedback_v116_helper_pkg_shipped.md §3). Universal binary in v1.19.x
# if needed.
if [[ "$ARCH" != "$HOST_ARCH" ]]; then
    echo "error: requested --arch $ARCH but host is $HOST_ARCH." >&2
    echo "       xcodebuild produces host-arch output unless ARCHS is overridden;" >&2
    echo "       cross-arch DMG must run on a $ARCH host." >&2
    exit 1
fi

# === Read app version from build settings (v1.20 A8) ===
# Source plist uses $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION)
# substitutions; `defaults read` returns the literal `$(MARKETING_VERSION)`
# string. Resolve via pbxproj grep — `xcodebuild -showBuildSettings`
# was tried but fails on macos-14 GitHub Actions runners with empty
# output (json.load → JSONDecodeError) when no signing identity is set
# up yet. The pbxproj grep is portable across local + CI, and
# sync-versions.sh keeps all 10 target × config entries in sync so
# `head -1` always returns the canonical value.
XCODE_PROJECT="$PROJECT_ROOT/CLI Pulse Bar/CLI Pulse Bar.xcodeproj"
PBXPROJ="$XCODE_PROJECT/project.pbxproj"
read_build_setting() {
    grep -E "^\s+$1 = " "$PBXPROJ" | head -1 | sed -E "s/.*$1 = ([^;]+);.*/\1/" | tr -d ' \t'
}
APP_VERSION="$(read_build_setting MARKETING_VERSION)"
APP_BUILD="$(read_build_setting CURRENT_PROJECT_VERSION)"
if [[ -z "$APP_VERSION" ]] || [[ -z "$APP_BUILD" ]]; then
    echo "error: could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from $PBXPROJ" >&2
    exit 2
fi
echo "Resolved version $APP_VERSION build $APP_BUILD from pbxproj"

DMG_NAME="CLI-Pulse-${APP_VERSION}-${ARCH}.dmg"
DMG_OUT="$OUTPUT_DIR/$DMG_NAME"
APP_NAME="CLI Pulse.app"
APP_STAGING="$OUTPUT_DIR/staging"
APP_OUT="$APP_STAGING/$APP_NAME"

echo "=== build_devid_dmg.sh v1.19 ==="
echo "App version    : $APP_VERSION (build $APP_BUILD)"
echo "Arch           : $ARCH"
echo "Skip notarize  : $SKIP_NOTARIZE"
echo "Skip sign      : $SKIP_SIGN"
echo "Output dir     : $OUTPUT_DIR"
echo

run() {
    echo "+ $*"
    if [[ $DRY_RUN -eq 0 ]]; then
        "$@"
    fi
}

# === Step 1: Prerequisite check ===
require() {
    command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' not found in PATH" >&2; exit 2; }
}
require xcodebuild
require hdiutil
require shasum
[[ -x "$BUILD_SIGNED_APP" ]] || { echo "error: $BUILD_SIGNED_APP missing or not executable" >&2; exit 2; }
[[ $SKIP_SIGN -eq 0 ]] && require codesign
[[ $SKIP_NOTARIZE -eq 0 ]] && require xcrun

if [[ $SKIP_SIGN -eq 0 ]]; then
    : "${DEV_ID_APP:?Set DEV_ID_APP env (e.g. 'Developer ID Application: Yuhe Ye (KHMK6Q3L3K)') or pass --skip-sign}"
fi

# === Step 1b: Resolve notarytool credential mode (G8) ===
# Inline mode is preferred for CI (which can't access UI-created keychain
# profiles). Local mode uses the keychain profile created via
# `xcrun notarytool store-credentials`.
NOTARY_MODE="none"
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    if [[ -n "${APPLE_NOTARY_USER:-}" ]] && [[ -n "${APPLE_NOTARY_APP_PASSWORD:-}" ]] && [[ -n "${APPLE_TEAM_ID:-}" ]]; then
        NOTARY_MODE="inline"
        echo "Notarytool mode: inline (CI-friendly: APPLE_NOTARY_USER / APPLE_NOTARY_APP_PASSWORD / APPLE_TEAM_ID)"
    else
        : "${NOTARY_PROFILE:=AC_NOTARY_PROFILE}"
        NOTARY_MODE="keychain"
        echo "Notarytool mode: keychain profile '$NOTARY_PROFILE'"
    fi
fi

# Helper: emit the right `xcrun notarytool` flags for the active mode.
notarytool_args() {
    if [[ "$NOTARY_MODE" == "inline" ]]; then
        printf -- "--apple-id %q --password %q --team-id %q" \
            "$APPLE_NOTARY_USER" "$APPLE_NOTARY_APP_PASSWORD" "$APPLE_TEAM_ID"
    else
        printf -- "--keychain-profile %q" "$NOTARY_PROFILE"
    fi
}

# === Step 2: Build the signed .app via build_signed_app.sh ===
echo
echo "--- Step 2: Build signed .app (Release, Developer ID Application) ---"
SIGN_IDENTITY_FOR_INNER="${DEV_ID_APP:--}"
TIMESTAMP_FOR_INNER=""
if [[ $SKIP_SIGN -eq 0 ]]; then
    TIMESTAMP_FOR_INNER="1"
fi
run env \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY_FOR_INNER" \
    CODESIGN_TIMESTAMP="$TIMESTAMP_FOR_INNER" \
    DEVID_BUILD_FLAG=1 \
    "$BUILD_SIGNED_APP" Release "$APP_STAGING"

# build_signed_app.sh writes to $APP_STAGING/DerivedData/Build/Products/Release/CLI Pulse Bar.app
INNER_APP_PATH="$APP_STAGING/DerivedData/Build/Products/Release/CLI Pulse Bar.app"
if [[ $DRY_RUN -eq 0 ]] && [[ ! -d "$INNER_APP_PATH" ]]; then
    echo "error: build_signed_app.sh did not produce $INNER_APP_PATH" >&2
    exit 3
fi

# Hoist the .app out of DerivedData into the staging root so the DMG is
# clean. Rename "CLI Pulse Bar.app" → "CLI Pulse.app" for user-facing
# friendliness (the bundle's CFBundleName already says "CLI Pulse"; only
# the .app filename inherits the Xcode product name).
if [[ $DRY_RUN -eq 0 ]]; then
    rm -rf "$APP_OUT"
    cp -R "$INNER_APP_PATH" "$APP_OUT"
fi

# === Step 3: Notarize the .app ===
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    echo
    echo "--- Step 3: notarytool submit (app) ---"
    APP_ZIP="$OUTPUT_DIR/app-for-notarize.zip"
    run rm -f "$APP_ZIP"
    # notarytool prefers a flat archive (zip) for upload, not a bundle.
    # `ditto -c -k --keepParent` produces the format Apple's notary
    # service expects, preserving extended attributes + symlinks.
    run ditto -c -k --keepParent "$APP_OUT" "$APP_ZIP"

    if [[ $DRY_RUN -eq 0 ]]; then
        eval "xcrun notarytool submit \"$APP_ZIP\" $(notarytool_args) --wait"
    else
        echo "+ (dry-run) xcrun notarytool submit ... --wait"
    fi
    run rm -f "$APP_ZIP"

    echo
    echo "--- Step 4: stapler staple (app) ---"
    run xcrun stapler staple "$APP_OUT"
fi

# === Step 5: Build the DMG ===
echo
echo "--- Step 5: hdiutil create DMG ---"
# UDZO = compressed read-only. HFS+ filesystem is more compatible than
# APFS for older macOS versions; CLI Pulse min OS is 13.0 (Ventura)
# which supports both, but HFS+ avoids potential mount issues on the
# fringe (e.g., user double-clicks on a 13.0 install with Time Machine
# from older). v1.19.x can polish the DMG layout (background image,
# /Applications symlink, .DS_Store positioning) — bare .app inside the
# DMG is functional for MVP.
run rm -f "$DMG_OUT"
if [[ $DRY_RUN -eq 0 ]]; then
    hdiutil create \
        -volname "CLI Pulse" \
        -srcfolder "$APP_OUT" \
        -ov \
        -format UDZO \
        -fs HFS+ \
        "$DMG_OUT"
fi

if [[ $DRY_RUN -eq 0 ]] && [[ ! -f "$DMG_OUT" ]]; then
    echo "error: hdiutil did not produce $DMG_OUT" >&2
    exit 4
fi

# === Step 6: Sign the DMG ===
if [[ $SKIP_SIGN -eq 0 ]]; then
    echo
    echo "--- Step 6: codesign DMG ---"
    run codesign --force --sign "$DEV_ID_APP" --timestamp "$DMG_OUT"
fi

# === Step 7: Notarize the DMG ===
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    echo
    echo "--- Step 7: notarytool submit (dmg) ---"
    if [[ $DRY_RUN -eq 0 ]]; then
        eval "xcrun notarytool submit \"$DMG_OUT\" $(notarytool_args) --wait"
    else
        echo "+ (dry-run) xcrun notarytool submit ... --wait"
    fi

    echo
    echo "--- Step 8: stapler staple (dmg) ---"
    run xcrun stapler staple "$DMG_OUT"
fi

# === Step 9: spctl assess ===
if [[ $SKIP_SIGN -eq 0 ]] && [[ $SKIP_NOTARIZE -eq 0 ]] && [[ $DRY_RUN -eq 0 ]]; then
    echo
    echo "--- Step 9: spctl --assess ---"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_OUT" \
        || { echo "error: spctl rejected the DMG — see output above" >&2; exit 5; }
    # Also assess the staged .app standalone (caller may inspect both).
    spctl --assess --type exec --verbose=2 "$APP_OUT" \
        || { echo "error: spctl rejected the .app — see output above" >&2; exit 5; }
fi

# === Step 10: Manifest fragment ===
echo
echo "--- Step 10: Generate manifest fragment ---"
if [[ $DRY_RUN -eq 0 ]]; then
    SHA256="$(shasum -a 256 "$DMG_OUT" | awk '{print $1}')"
    echo "$SHA256  $DMG_NAME" > "$DMG_OUT.sha256"

    cat > "$OUTPUT_DIR/manifest-fragment-${ARCH}.json" <<EOF
{
  "version": "$APP_VERSION",
  "build": "$APP_BUILD",
  "channel": "devid",
  "arch": "$ARCH",
  "url": "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v$APP_VERSION/$DMG_NAME",
  "sha256": "$SHA256",
  "size_bytes": $(stat -f%z "$DMG_OUT" 2>/dev/null || stat -c%s "$DMG_OUT"),
  "min_os_version": "13.0",
  "release_notes_url": "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/tag/app-v$APP_VERSION"
}
EOF
fi

echo
echo "=== build_devid_dmg.sh complete ==="
echo "App     : $APP_OUT"
echo "DMG     : $DMG_OUT"
[[ $DRY_RUN -eq 0 ]] && [[ -f "$DMG_OUT.sha256" ]] && cat "$DMG_OUT.sha256"
