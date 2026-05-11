#!/bin/bash
set -euo pipefail

# CLI Pulse — Cross-Platform Version Sync
# Compares iOS and Android versions, bumps the lower one, builds & publishes.
# iOS → App Store Connect | Android → GitHub Releases (public repo)
#
# Usage: ./scripts/sync-versions.sh [--dry-run]
# Designed to run as a daily scheduled task.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$PROJECT_DIR")"
ANDROID_DIR="$REPO_ROOT/android"
PBXPROJ="$PROJECT_DIR/CLI Pulse Bar.xcodeproj/project.pbxproj"
GRADLE_FILE="$ANDROID_DIR/app/build.gradle.kts"
# All five Info.plists that ship in the iOS-bound archive. They each
# carry hardcoded CFBundleShortVersionString + CFBundleVersion (not
# $(MARKETING_VERSION) substitution), so the bump path MUST update
# every one of them — otherwise the version pbxproj reports diverges
# from what ASC actually receives. Per `feedback_archive_embedding_gap.md`
# helper Info.plist is the easiest one to forget.
IOS_PLIST_PATHS=(
    "$PROJECT_DIR/CLI Pulse Bar iOS/Info.plist"
    "$PROJECT_DIR/CLI Pulse Bar/Info.plist"
    "$PROJECT_DIR/CLI Pulse Bar Watch/Info.plist"
    "$PROJECT_DIR/CLI Pulse Widgets/Info.plist"
    "$PROJECT_DIR/CLIPulseHelper/Info.plist"
)
# Source-of-truth Info.plist for read functions (the iOS app target —
# it's what ASC's iOS submission consumes).
IOS_INFO_PLIST="$PROJECT_DIR/CLI Pulse Bar iOS/Info.plist"

# App Store Connect credentials — set via environment or .env file
API_KEY_ID="${ASC_API_KEY_ID:?Set ASC_API_KEY_ID environment variable}"
API_ISSUER="${ASC_API_ISSUER:?Set ASC_API_ISSUER environment variable}"
API_KEY_PATH="${ASC_API_KEY_PATH:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_${API_KEY_ID}.p8}"
TEAM_ID="${ASC_TEAM_ID:?Set ASC_TEAM_ID environment variable}"
APP_ID="${ASC_APP_ID:?Set ASC_APP_ID environment variable}"

# Public repo for Android releases
PUBLIC_REPO="JasonYeYuhe/cli-pulse"

# Java for Android builds
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ============================================================
# Version reading
# ============================================================

read_ios_version() {
    # Read from Info.plist (source of truth for what ASC sees) rather
    # than `grep MARKETING_VERSION | head -1` of pbxproj. The pbxproj
    # has 40+ MARKETING_VERSION lines across targets; if they ever
    # drift out of sync `head -1` returns whichever sorts first by
    # file order (per feedback_sync_versions_script.md the 2026-05-11
    # incident read 1.16.0 while iOS app was actually at 1.18.0).
    plutil -extract CFBundleShortVersionString raw "$IOS_INFO_PLIST"
}

read_ios_build() {
    plutil -extract CFBundleVersion raw "$IOS_INFO_PLIST"
}

read_android_version() {
    grep 'versionName' "$GRADLE_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/'
}

read_android_build() {
    grep 'versionCode' "$GRADLE_FILE" | head -1 | sed 's/[^0-9]//g'
}

# Compare semver: returns 0 if equal, 1 if a > b, 2 if a < b
compare_versions() {
    local a="$1" b="$2"
    if [[ "$a" == "$b" ]]; then echo 0; return; fi
    local IFS=.
    local -a av=($a) bv=($b)
    for i in 0 1 2; do
        local ai="${av[$i]:-0}" bi="${bv[$i]:-0}"
        if (( ai > bi )); then echo 1; return; fi
        if (( ai < bi )); then echo 2; return; fi
    done
    echo 0
}

# ============================================================
# Version bumping
# ============================================================

bump_ios_version() {
    local new_version="$1"
    local old_build
    old_build=$(read_ios_build)
    local new_build=$((old_build + 1))

    log "Bumping iOS: $(read_ios_version) (build $old_build) → $new_version (build $new_build)"
    if $DRY_RUN; then return; fi

    # pbxproj sed kept for `agvtool what-marketing-version` and any
    # tooling that reads build settings.
    sed -i '' "s/MARKETING_VERSION = .*/MARKETING_VERSION = $new_version;/g" "$PBXPROJ"
    sed -i '' "s/CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $new_build;/g" "$PBXPROJ"

    # Critical: the 5 Info.plists carry HARDCODED CFBundleShortVersionString
    # + CFBundleVersion strings, not $(MARKETING_VERSION) substitution.
    # Without writing them, the bump above is invisible to the actual
    # archive shipped to ASC. plutil -replace creates the key if it's
    # somehow missing, which is safer than a sed pattern.
    for plist in "${IOS_PLIST_PATHS[@]}"; do
        if [[ ! -f "$plist" ]]; then
            log "  ⚠ Skipping missing Info.plist: $plist"
            continue
        fi
        plutil -replace CFBundleShortVersionString -string "$new_version" "$plist"
        plutil -replace CFBundleVersion -string "$new_build" "$plist"
        log "  ✓ Bumped $(basename "$(dirname "$plist")")/Info.plist"
    done
}

bump_android_version() {
    local new_version="$1"
    local old_build
    old_build=$(read_android_build)
    local new_build=$((old_build + 1))

    log "Bumping Android: $(read_android_version) (code $old_build) → $new_version (code $new_build)"
    if $DRY_RUN; then return; fi

    sed -i '' "s/versionName = \".*\"/versionName = \"$new_version\"/" "$GRADLE_FILE"
    sed -i '' "s/versionCode = .*/versionCode = $new_build/" "$GRADLE_FILE"
}

# ============================================================
# iOS: Build + Upload to App Store Connect
# ============================================================

build_and_upload_ios() {
    local version="$1"
    log "Building iOS $version for App Store..."
    if $DRY_RUN; then log "[DRY RUN] Would build and upload iOS"; return 0; fi

    # Delegate to build-appstore.sh rather than reimplementing the
    # archive + export pipeline inline. The shared script handles:
    #   * MAS helper strip (ITMS-90296 — feedback_mas_vs_devid_helper.md)
    #   * Sentry dSYM upload + release finalize
    #   * Correct ExportOptions plist (`app-store` not the deprecated
    #     `app-store-connect`)
    #   * MAS-archive-no-LaunchAgent verification (Phase 4D fallout)
    #
    # Capture output AND exit code without letting `set -e` fire on
    # build-appstore.sh's non-zero (Gemini plan-review SHOULD_FIX:
    # we need both the output and the chance to grep for closed-train
    # patterns before the script aborts).
    local build_output
    local build_exit_code=0
    build_output=$("$SCRIPT_DIR/build-appstore.sh" ios --upload 2>&1) \
        || build_exit_code=$?

    # Echo through the captured output so the daily log captures the
    # full xcodebuild + upload trail (debugging breaks otherwise).
    echo "$build_output"

    if [[ "$build_exit_code" -ne 0 ]]; then
        log "ERROR: build-appstore.sh ios --upload failed (exit $build_exit_code)"
        # Closed-train detection (Gap 2): ASC returns these when we try
        # to upload to a version that's already approved or in review.
        # Auto-bump-and-retry would risk infinite cascade if ASC
        # misclassifies, so we surface a clear instruction instead.
        if grep -qE "ITMS-90186|ITMS-90062|already submitted|Invalid Pre-Release Train|must contain a higher version" <<< "$build_output"; then
            log ""
            log "════════════════════════════════════════════════════"
            log "  CLOSED TRAIN — manual bump required"
            log ""
            log "  ASC has rejected v$version because the build is"
            log "  already submitted, in review, or otherwise closed."
            log "  Auto-bumping is suppressed to avoid version cascade."
            log ""
            log "  To unblock the daily sync:"
            log "    1. Bump iOS Info.plists past the submitted version"
            log "       (e.g. 1.18.1 → 1.19.0) on a hotfix branch"
            log "    2. Re-run sync-versions.sh manually to verify"
            log "    3. Merge the bump commit when ASC accepts"
            log "════════════════════════════════════════════════════"
        fi
        return 1
    fi

    log "✓ iOS $version uploaded to App Store Connect"
}

# ============================================================
# Android: Build APK + Upload to GitHub Releases
# ============================================================

build_and_upload_android() {
    local version="$1"
    log "Building Android $version..."
    if $DRY_RUN; then log "[DRY RUN] Would build and upload Android"; return 0; fi

    cd "$ANDROID_DIR"

    # Check Java
    if ! java -version &>/dev/null; then
        log "ERROR: Java not found. Set JAVA_HOME or install JDK."
        return 1
    fi

    # Clean first so stale intermediates can't poison the next build (and a
    # failed build can't leave a previous-version APK in outputs/ that we'd
    # then ship by mistake).
    if ! ./gradlew clean --no-daemon -q 2>&1; then
        log "ERROR: gradle clean failed"
        return 1
    fi

    # Build release APK — must check exit status. A previous bug shipped a
    # stale APK because the script ignored gradle's failure here.
    if ! ./gradlew assembleRelease --no-daemon 2>&1; then
        log "ERROR: gradle assembleRelease failed"
        return 1
    fi

    local APK_PATH
    APK_PATH=$(find "$ANDROID_DIR/app/build/outputs/apk/release" -name "*.apk" | head -1)
    if [[ -z "$APK_PATH" ]]; then
        log "ERROR: APK not found after build"
        return 1
    fi

    # Sanity check: verify the APK we're about to ship has the expected version.
    local META="$ANDROID_DIR/app/build/outputs/apk/release/output-metadata.json"
    if [[ -f "$META" ]]; then
        local APK_VERSION
        APK_VERSION=$(grep -o '"versionName": *"[^"]*"' "$META" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
        if [[ "$APK_VERSION" != "$version" ]]; then
            log "ERROR: APK versionName ($APK_VERSION) does not match target ($version) — aborting upload"
            return 1
        fi
    fi

    local RELEASE_NAME="CLI-Pulse-Android-v${version}.apk"
    cp "$APK_PATH" "/tmp/$RELEASE_NAME"

    # Upload to GitHub Releases on public repo
    local TAG="android-v${version}"
    gh release create "$TAG" "/tmp/$RELEASE_NAME#$RELEASE_NAME" \
        --repo "$PUBLIC_REPO" \
        --title "CLI Pulse Android v${version}" \
        --notes "Android release v${version} — synced with iOS version." \
        --latest=false

    rm -f "/tmp/$RELEASE_NAME"
    log "✓ Android $version uploaded to GitHub Releases ($PUBLIC_REPO)"
}

# ============================================================
# Main
# ============================================================

log "=== CLI Pulse Version Sync ==="
log "Dry run: $DRY_RUN"

IOS_VERSION=$(read_ios_version)
IOS_BUILD=$(read_ios_build)
ANDROID_VERSION=$(read_android_version)
ANDROID_BUILD=$(read_android_build)

log "iOS:     v$IOS_VERSION (build $IOS_BUILD)"
log "Android: v$ANDROID_VERSION (code $ANDROID_BUILD)"

CMP=$(compare_versions "$IOS_VERSION" "$ANDROID_VERSION")

if [[ "$CMP" == "0" ]]; then
    log "✓ Versions already in sync. Nothing to do."
    exit 0
fi

SYNC_OK=false

if [[ "$CMP" == "1" ]]; then
    # iOS is ahead — bump Android
    log "iOS ($IOS_VERSION) is ahead of Android ($ANDROID_VERSION)"
    TARGET_VERSION="$IOS_VERSION"
    bump_android_version "$TARGET_VERSION"

    # Build and publish Android
    if build_and_upload_android "$TARGET_VERSION"; then
        log "✓ Android synced to v$TARGET_VERSION"
        SYNC_OK=true
    else
        log "⚠ Android build/upload failed — manual intervention needed"
    fi

elif [[ "$CMP" == "2" ]]; then
    # Android is ahead — bump iOS
    log "Android ($ANDROID_VERSION) is ahead of iOS ($IOS_VERSION)"
    TARGET_VERSION="$ANDROID_VERSION"
    bump_ios_version "$TARGET_VERSION"

    # Build and publish iOS
    if build_and_upload_ios "$TARGET_VERSION"; then
        log "✓ iOS synced to v$TARGET_VERSION"
        SYNC_OK=true
    else
        log "⚠ iOS build/upload failed — manual intervention needed"
    fi
fi

# Build the list of files touched by the bump path. The 5 Info.plists
# are each only added if they exist on disk (avoids `git add` /
# `git checkout` pathspec errors per Gemini SHOULD_FIX).
BUMP_FILES=("$PBXPROJ" "$GRADLE_FILE")
for plist in "${IOS_PLIST_PATHS[@]}"; do
    [[ -f "$plist" ]] && BUMP_FILES+=("$plist")
done

# Only commit + push the version bump if the build/upload actually succeeded.
# Otherwise we'd be advertising a synced version that doesn't exist on the
# distribution channel.
if $SYNC_OK && ! $DRY_RUN; then
    cd "$REPO_ROOT"
    if [[ -n "$(git status --porcelain "${BUMP_FILES[@]}" 2>/dev/null)" ]]; then
        git add "${BUMP_FILES[@]}"
        git commit -m "chore: sync versions to v$TARGET_VERSION (iOS ↔ Android)"
        git push origin main
        log "✓ Version bump committed and pushed"
    fi
elif ! $SYNC_OK && ! $DRY_RUN; then
    # Roll back ALL bumped files (pbxproj + gradle + 5 Info.plists)
    # so a future sync run will retry from a clean state. Without
    # this the Info.plists carry the failed-upload version on disk
    # and confuse the next read pass (Gemini CRITICAL fix).
    cd "$REPO_ROOT"
    if [[ -n "$(git status --porcelain "${BUMP_FILES[@]}" 2>/dev/null)" ]]; then
        log "Rolling back local version-file changes (build failed)"
        git checkout -- "${BUMP_FILES[@]}"
    fi
    log "=== Sync FAILED ==="
    exit 1
fi

log "=== Sync complete ==="
