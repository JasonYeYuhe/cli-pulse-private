#!/usr/bin/env bash
# Build a Developer ID notarized .pkg of the Python helper for v1.16
# managed-CLI distribution. Output is consumed by the MAS app's
# HelperInstaller.swift via download → NSWorkspace.open → Installer.app.
#
# See PROJECT_PLAN_v1.16_phase4e_helper_production.md §1.3 / §1.4 for the
# full pipeline narrative.
#
# Usage:
#   scripts/build_helper_pkg.sh [--arch arm64|x86_64]
#                               [--skip-notarize]
#                               [--skip-sign]
#                               [--dry-run]
#                               [--output-dir DIR]
#
# Defaults:
#   --arch          host arch (`uname -m`)
#   output dir      build/v1.16-pkg/
#   sign + notarize ON (require DEV_ID_APP, DEV_ID_INSTALLER, NOTARY_PROFILE env)
#
# Required env (full sign + notarize):
#   DEV_ID_APP        e.g. "Developer ID Application: Yuhe Ye (KHMK6Q3L3K)"
#   DEV_ID_INSTALLER  e.g. "Developer ID Installer: Yuhe Ye (KHMK6Q3L3K)"
#   NOTARY_PROFILE    keychain profile name created via `xcrun notarytool
#                     store-credentials`
#
# Outputs (under --output-dir):
#   cli-pulse-helper-<version>-<arch>.pkg    (signed + stapled if not skipped)
#   cli-pulse-helper-<version>-<arch>.pkg.sha256
#   manifest-fragment-<arch>.json            (for the public mirror repo)
#
# Exit codes:
#   0  success
#   1  argument error
#   2  prerequisite missing (pyinstaller, codesign, etc.)
#   3  signing failure
#   4  pkg build failure
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
            sed -n '2,40p' "$0" | sed 's/^# \?//'
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
HELPER_DIR="$PROJECT_ROOT/helper"
PKG_SCRIPTS_DIR="$SCRIPT_DIR/pkg-scripts"
SPEC_FILE="$HELPER_DIR/cli_pulse_helper_pkg.spec"
: "${OUTPUT_DIR:=$PROJECT_ROOT/build/v1.16-pkg}"
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
# PyInstaller cannot cross-compile — to build x86_64 you must run this
# script under Rosetta or on an Intel Mac, and to build arm64 you must
# run on Apple Silicon. CI splits the two builds across two runners;
# the manifest-fragment files are merged by the publish step.
if [[ "$ARCH" != "$HOST_ARCH" ]]; then
    echo "error: requested --arch $ARCH but host is $HOST_ARCH." >&2
    echo "       PyInstaller can't cross-compile. To build $ARCH, run this" >&2
    echo "       script on a $ARCH host (or under Rosetta if $ARCH=x86_64)." >&2
    exit 1
fi

# === Read version from helper source ===
HELPER_VERSION="$(cd "$HELPER_DIR" && python3 -c 'from system_collector import HELPER_VERSION; print(HELPER_VERSION)')"
if [[ -z "$HELPER_VERSION" ]]; then
    echo "error: could not read HELPER_VERSION from helper/system_collector.py" >&2
    exit 2
fi

PKG_IDENTIFIER="yyh.cli-pulse.helper"
PKG_NAME="cli-pulse-helper-${HELPER_VERSION}-${ARCH}.pkg"
PKG_OUT="$OUTPUT_DIR/$PKG_NAME"
COMPONENT_PKG="$OUTPUT_DIR/cli-pulse-helper-${HELPER_VERSION}-${ARCH}-component.pkg"
PKG_UNSIGNED="$OUTPUT_DIR/cli-pulse-helper-${HELPER_VERSION}-${ARCH}-unsigned.pkg"
DISTRO_XML="$OUTPUT_DIR/distribution-${ARCH}.xml"
STAGING="$OUTPUT_DIR/staging-${ARCH}"

echo "=== build_helper_pkg.sh v1.16 ==="
echo "Helper version : $HELPER_VERSION"
echo "Arch           : $ARCH"
echo "Skip notarize  : $SKIP_NOTARIZE"
echo "Skip sign      : $SKIP_SIGN"
echo "Output dir     : $OUTPUT_DIR"
echo "Staging        : $STAGING"
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
require python3
require pkgbuild
[[ $SKIP_SIGN -eq 0 ]] && { require codesign; require productsign; }
[[ $SKIP_NOTARIZE -eq 0 ]] && { require xcrun; }

if ! python3 -c 'import PyInstaller' 2>/dev/null; then
    echo "error: PyInstaller not installed. Run: pip3 install pyinstaller" >&2
    exit 2
fi

if [[ $SKIP_SIGN -eq 0 ]]; then
    : "${DEV_ID_APP:?Set DEV_ID_APP env (e.g. 'Developer ID Application: Your Name (TEAMID)') or pass --skip-sign}"
    : "${DEV_ID_INSTALLER:?Set DEV_ID_INSTALLER env or pass --skip-sign}"
fi
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    : "${NOTARY_PROFILE:?Set NOTARY_PROFILE env (created via xcrun notarytool store-credentials) or pass --skip-notarize}"
fi

# === Step 2: pyinstaller build ===
echo
echo "--- Step 2: PyInstaller (onedir mode) ---"
PYI_BUILD="$OUTPUT_DIR/pyinstaller-build-${ARCH}"
PYI_DIST="$OUTPUT_DIR/pyinstaller-dist-${ARCH}"
run rm -rf "$PYI_BUILD" "$PYI_DIST"
run mkdir -p "$PYI_BUILD" "$PYI_DIST"

# CRITICAL: MACOSX_DEPLOYMENT_TARGET=13.0 ensures any C-extension (cryptography
# .so files) compiled-in by PyInstaller is ABI-compatible with the minimum
# supported macOS version. Without this, .so files link against the build
# host's SDK and crash on older Macs. (Plan §1.3 P1 blocker fix.)
(
    cd "$HELPER_DIR"
    # NOTE: --target-arch is incompatible with passing a .spec file
    # (pyinstaller error: "makespec options not valid when a .spec file
    # is given"). Host-arch build only — guarded above.
    run env MACOSX_DEPLOYMENT_TARGET=13.0 \
        python3 -m PyInstaller \
        --clean \
        --noconfirm \
        --workpath "$PYI_BUILD" \
        --distpath "$PYI_DIST" \
        "$SPEC_FILE"
)

# pyinstaller --onedir produces a directory at $PYI_DIST/cli_pulse_helper/
HELPER_BUNDLE="$PYI_DIST/cli_pulse_helper"
if [[ $DRY_RUN -eq 0 ]] && [[ ! -x "$HELPER_BUNDLE/cli_pulse_helper" ]]; then
    echo "error: pyinstaller did not produce $HELPER_BUNDLE/cli_pulse_helper" >&2
    exit 2
fi

# === Step 3: Stage payload tree ===
echo
echo "--- Step 3: Stage payload tree ---"
# pkgbuild --root <root> + --install-location <path> means: "drop the entire
# contents of <root> into <path> on the user's Mac". So <root> is a synthetic
# tree that mirrors the install destination.
run rm -rf "$STAGING"
run mkdir -p "$STAGING"
# Copy the pyinstaller bundle as the entire payload (no extra wrapper dir —
# pkgbuild --install-location handles relocation).
run cp -R "$HELPER_BUNDLE/." "$STAGING/"

# Drop a version.txt so the Helper Uninstaller.app + diagnostic UI can read it
# without invoking the binary.
run sh -c "echo '$HELPER_VERSION' > '$STAGING/version.txt'"

# === Step 3b: Build + embed Helper Uninstaller.app ===
echo
echo "--- Step 3b: Build + embed Uninstaller.app ---"
UNINSTALLER_OUT="$OUTPUT_DIR/uninstaller-build"
UNINSTALLER_FLAGS=(--output-dir "$UNINSTALLER_OUT")
[[ $SKIP_SIGN -eq 1 ]] && UNINSTALLER_FLAGS+=(--skip-sign)
[[ $DRY_RUN -eq 1 ]] && UNINSTALLER_FLAGS+=(--dry-run)
run "$SCRIPT_DIR/build_helper_uninstaller.sh" "${UNINSTALLER_FLAGS[@]}"
UNINSTALLER_APP="$UNINSTALLER_OUT/CLI Pulse Helper Uninstaller.app"
if [[ $DRY_RUN -eq 0 ]] && [[ ! -d "$UNINSTALLER_APP" ]]; then
    echo "error: build_helper_uninstaller.sh did not produce $UNINSTALLER_APP" >&2
    exit 4
fi
run cp -R "$UNINSTALLER_APP" "$STAGING/"

# === Step 4: Sign every Mach-O individually ===
if [[ $SKIP_SIGN -eq 0 ]]; then
    echo
    echo "--- Step 4: Sign Mach-O binaries (DEV_ID_APP=$DEV_ID_APP) ---"
    # Find every .so / .dylib / .framework binary + the entry executable.
    # Sign INSIDE-OUT: leaf binaries first, then enclosing ones, then the entry.
    # (codesign rejects re-signing nested signed code if the outer is already
    # signed.) Use `xargs -n1` to keep error visibility per-file.
    if [[ $DRY_RUN -eq 0 ]]; then
        find "$STAGING" -type f \( -name '*.so' -o -name '*.dylib' \) -print0 \
            | xargs -0 -I{} codesign --force --timestamp --options runtime \
                --sign "$DEV_ID_APP" {}
        # Sign the entry executable LAST.
        codesign --force --timestamp --options runtime \
            --sign "$DEV_ID_APP" "$STAGING/cli_pulse_helper"
        # Verify the entry passes a strict check (warning-only is too loose
        # for a release pipeline — fail loudly if any signature is bad).
        codesign --verify --strict --verbose=2 "$STAGING/cli_pulse_helper"
    else
        echo "+ (dry-run) sign all .so / .dylib + cli_pulse_helper"
    fi
fi

# === Step 5: Build the component .pkg ===
echo
echo "--- Step 5a: pkgbuild (component) ---"
# Component pkg — gets wrapped by productbuild below for user-domain install.
# pkgbuild without --component-plist defaults to auth="root" (which would
# trigger an admin password prompt). The productbuild wrapper overrides
# this via Distribution.xml's pkg-ref auth="none" + domains element so the
# user gets a no-admin-password install in Installer.app.
run pkgbuild \
    --root "$STAGING" \
    --install-location "~/Library/CLI-Pulse-Helper" \
    --scripts "$PKG_SCRIPTS_DIR" \
    --identifier "$PKG_IDENTIFIER" \
    --version "$HELPER_VERSION" \
    --min-os-version "13.0" \
    "$COMPONENT_PKG"

# === Step 5b: Generate Distribution.xml + productbuild wrapper ===
echo
echo "--- Step 5b: productbuild distribution ---"
# domains: only the current user's home is allowed; anywhere/localSystem
#          are disabled — guarantees no admin password prompt
# pkg-ref auth="none": override pkgbuild's default root auth
# customize="never": single-page Installer UI (no choice list)
# rootVolumeOnly="false": user-domain installs are not on root volume
if [[ $DRY_RUN -eq 0 ]]; then
    cat > "$DISTRO_XML" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>CLI Pulse Helper</title>
    <organization>yyh.cli-pulse</organization>
    <options
        customize="never"
        require-scripts="true"
        rootVolumeOnly="false"
        hostArchitectures="$ARCH"
    />
    <domains
        enable_anywhere="false"
        enable_currentUserHome="true"
        enable_localSystem="false"
    />
    <choices-outline>
        <line choice="default">
            <line choice="$PKG_IDENTIFIER"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$PKG_IDENTIFIER" visible="false">
        <pkg-ref id="$PKG_IDENTIFIER"/>
    </choice>
    <pkg-ref
        id="$PKG_IDENTIFIER"
        version="$HELPER_VERSION"
        auth="none"
    >$(basename "$COMPONENT_PKG")</pkg-ref>
    <product
        id="$PKG_IDENTIFIER"
        version="$HELPER_VERSION"
    />
</installer-gui-script>
EOF
fi
run productbuild \
    --distribution "$DISTRO_XML" \
    --package-path "$OUTPUT_DIR" \
    "$PKG_UNSIGNED"

# === Step 6: productsign ===
if [[ $SKIP_SIGN -eq 0 ]]; then
    echo
    echo "--- Step 6: productsign ---"
    run productsign --sign "$DEV_ID_INSTALLER" "$PKG_UNSIGNED" "$PKG_OUT"
    run rm -f "$PKG_UNSIGNED"
else
    run mv "$PKG_UNSIGNED" "$PKG_OUT"
fi
# Cleanup intermediate component
run rm -f "$COMPONENT_PKG"

# === Step 7: notarytool ===
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    echo
    echo "--- Step 7: notarytool submit + wait ---"
    run xcrun notarytool submit "$PKG_OUT" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    echo
    echo "--- Step 8: stapler staple ---"
    run xcrun stapler staple "$PKG_OUT"
fi

# === Step 9: Verification ===
if [[ $SKIP_SIGN -eq 0 ]] && [[ $DRY_RUN -eq 0 ]]; then
    echo
    echo "--- Step 9: spctl --assess ---"
    if [[ $SKIP_NOTARIZE -eq 0 ]]; then
        # Stapled + notarized = should pass offline.
        spctl --assess --type install --verbose "$PKG_OUT"
    else
        # productsign-only = signature exists but no notarization ticket;
        # spctl --assess will reject (Gatekeeper would refuse this on a
        # user's Mac). Fine for dev / CI signing dry runs.
        echo "(skipping spctl --assess — pkg is signed but not notarized)"
    fi
fi

# === Step 10: Manifest fragment ===
echo
echo "--- Step 10: Generate manifest fragment ---"
if [[ $DRY_RUN -eq 0 ]]; then
    SHA256="$(shasum -a 256 "$PKG_OUT" | awk '{print $1}')"
    echo "$SHA256  $PKG_NAME" > "$PKG_OUT.sha256"

    cat > "$OUTPUT_DIR/manifest-fragment-${ARCH}.json" <<EOF
{
  "version": "$HELPER_VERSION",
  "arch": "$ARCH",
  "url": "https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v$HELPER_VERSION/$PKG_NAME",
  "sha256": "$SHA256",
  "size_bytes": $(stat -f%z "$PKG_OUT" 2>/dev/null || stat -c%s "$PKG_OUT"),
  "min_os_version": "13.0",
  "release_notes_url": "https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/tag/v$HELPER_VERSION"
}
EOF
fi

echo
echo "=== build_helper_pkg.sh complete ==="
echo "Output: $PKG_OUT"
[[ $DRY_RUN -eq 0 ]] && [[ -f "$PKG_OUT.sha256" ]] && cat "$PKG_OUT.sha256"
