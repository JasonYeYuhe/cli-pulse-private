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
    # All target×config entries must agree (sync-versions.sh keeps them in
    # lockstep). Guard against divergence instead of silently taking head -1:
    # emit nothing on a multi-value mismatch so the caller fails closed.
    # Mirrors the Apple-side guard in scripts/check-versions.sh.
    local vals
    vals=$(grep -E "^\s+$1 = " "$PBXPROJ" | sed -E "s/.*$1 = ([^;]+);.*/\1/" | tr -d ' \t' | sort -u)
    if [[ -n "$vals" && "$(printf '%s\n' "$vals" | wc -l | tr -d ' ')" -gt 1 ]]; then
        echo "error: inconsistent $1 in pbxproj — run scripts/sync-versions.sh:" >&2
        printf '  %s\n' "$vals" >&2
        return 0
    fi
    printf '%s' "$vals"
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

# === Sentry dSYM upload (R4 — symbolicate v1.34 DEVID prod crashes) ===
# The MAS path (CLI Pulse Bar/scripts/build-appstore.sh) uploads dSYMs from its
# xcarchive; the DEVID DMG path did NOT, so Developer-ID production crashes came
# back unsymbolicated. Mirror the MAS approach here. macOS uses the `apple-macos`
# Sentry project (slug == display name). Auth token lives outside the repo in the
# standard secrets dir (chmod 600); see reference_sentry. Best-effort: every guard
# below skips cleanly (returns 0) when sentry-cli / the token / dSYMs are absent,
# so CI and unsigned local runs are unaffected — the DMG build itself never fails
# on a dSYM-upload problem.
SENTRY_ORG="jason-yeyuhe"
SENTRY_PROJECT="apple-macos"
SENTRY_AUTH_TOKEN_FILE="$HOME/Library/Application Support/CLI-Pulse-Secrets/sentry-cli-auth-token-2026-04-29.txt"

load_sentry_auth_token() {
    if [[ -n "${SENTRY_AUTH_TOKEN:-}" ]]; then
        return 0
    fi
    if [[ ! -f "$SENTRY_AUTH_TOKEN_FILE" ]]; then
        return 1
    fi
    # File format: one line `SENTRY_AUTH_TOKEN=sntrys_...` plus prose around it.
    # `|| true`: under `set -euo pipefail` a no-match grep (exit 1) or a head
    # SIGPIPE (141) would otherwise abort the ENTIRE build via the `extracted=$(…)`
    # assignment — this loader must stay best-effort (empty => return 1 => skip).
    local extracted
    extracted=$(grep -E '^SENTRY_AUTH_TOKEN=' "$SENTRY_AUTH_TOKEN_FILE" | head -1 | cut -d= -f2- || true)
    if [[ -z "$extracted" ]]; then
        return 1
    fi
    export SENTRY_AUTH_TOKEN="$extracted"
}

# Collect every top-level *.dSYM the Release build produced (the app's dSYM plus
# each embedded framework's) into a flat dir and upload it, then finalize the
# Sentry release so crashes attribute to "first seen in <version>". Unlike the
# MAS xcarchive (which bundles a dSYMs/ dir), build_signed_app.sh runs
# `xcodebuild build`, so the dSYMs sit alongside the .app in the Products dir.
# Args: $1 = DerivedData Release Products dir.
upload_dsyms_to_sentry() {
    local PRODUCTS_DIR="$1"

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
    if [[ ! -d "$PRODUCTS_DIR" ]]; then
        echo "  ⚠ Products dir $PRODUCTS_DIR not found — skipping dSYM upload."
        return 0
    fi

    local DSYMS_DIR="$OUTPUT_DIR/dSYMs"
    rm -rf "$DSYMS_DIR"
    mkdir -p "$DSYMS_DIR"
    # Top-level only: the app + framework dSYMs are siblings of the .app in a
    # `build` (non-archive) Products dir. -maxdepth 1 avoids walking into the
    # .app bundle itself (whose stripped Mach-O carries no useful debug info).
    find "$PRODUCTS_DIR" -maxdepth 1 -name "*.dSYM" -exec cp -R {} "$DSYMS_DIR/" \; 2>/dev/null || true
    if ! ls "$DSYMS_DIR"/*.dSYM >/dev/null 2>&1; then
        echo "  ⚠ No *.dSYM found in $PRODUCTS_DIR — skipping dSYM upload."
        echo "    (Release must emit DEBUG_INFORMATION_FORMAT=dwarf-with-dsym.)"
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

    # Finalize the release so Sentry attributes "first seen in <version>".
    # Idempotent: re-running for the same version is a no-op once finalized.
    local RELEASE="cli-pulse@${APP_VERSION}+${APP_BUILD}"
    echo "  ↗ Finalizing Sentry release $RELEASE for project $SENTRY_PROJECT..."
    sentry-cli releases --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
        new "$RELEASE" 2>&1 | sed 's/^/    /' || true
    sentry-cli releases --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
        finalize "$RELEASE" 2>&1 | sed 's/^/    /' || true
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

# === Step 2b: Upload dSYMs to Sentry (R4) ===
# Done here, from the DerivedData Products dir, BEFORE notarization — codesign /
# notarization do NOT change the Mach-O LC_UUID, so dSYMs from the pre-notarized
# build match the shipped binary exactly. Only for real signed release builds
# (a --skip-sign run is a throwaway test, not shipped); the upload itself is
# best-effort and no-ops without sentry-cli / a token.
if [[ $SKIP_SIGN -eq 0 ]] && [[ $DRY_RUN -eq 0 ]]; then
    echo
    echo "--- Step 2b: dSYM upload (Sentry) ---"
    upload_dsyms_to_sentry "$(dirname "$INNER_APP_PATH")"
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
