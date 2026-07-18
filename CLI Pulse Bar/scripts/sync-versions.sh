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
XCODEPROJ="$PROJECT_DIR/CLI Pulse Bar.xcodeproj"
PBXPROJ="$XCODEPROJ/project.pbxproj"
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

# App Store Connect credentials — set via environment, or fall back to
# the out-of-repo creds file (lets the daily scheduled task run without
# the caller pre-exporting ASC_* — the SKILL.md only runs the bare script).
ASC_ENV_FILE="${ASC_ENV_FILE:-$HOME/Library/Application Support/CLI-Pulse-Secrets/asc-sync-env-2026-05-16.sh}"
if [[ -z "${ASC_API_KEY_ID:-}" && -f "$ASC_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ASC_ENV_FILE"
fi
API_KEY_ID="${ASC_API_KEY_ID:?Set ASC_API_KEY_ID environment variable}"
API_ISSUER="${ASC_API_ISSUER:?Set ASC_API_ISSUER environment variable}"
API_KEY_PATH="${ASC_API_KEY_PATH:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_${API_KEY_ID}.p8}"
TEAM_ID="${ASC_TEAM_ID:?Set ASC_TEAM_ID environment variable}"
APP_ID="${ASC_APP_ID:?Set ASC_APP_ID environment variable}"

# Public repo for Android releases
PUBLIC_REPO="cli-pulse/cli-pulse"

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
    # v1.20 A8: source plists now use $(MARKETING_VERSION) substitution,
    # so plutil -extract on the raw plist returns the literal `$(MARKETING_VERSION)`.
    # Read from xcodebuild -showBuildSettings instead — resolves the
    # build settings the same way an actual archive does, AND avoids the
    # `grep MARKETING_VERSION | head -1` drift problem from the 2026-05-11
    # incident (per feedback_sync_versions_script.md).
    xcodebuild -project "$XCODEPROJ" -target "CLI Pulse iOS" -configuration Release -showBuildSettings -json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['buildSettings'].get('MARKETING_VERSION',''))"
}

read_ios_build() {
    xcodebuild -project "$XCODEPROJ" -target "CLI Pulse iOS" -configuration Release -showBuildSettings -json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['buildSettings'].get('CURRENT_PROJECT_VERSION',''))"
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
# Android no-op-release guard
# ============================================================
#
# Why this guard exists: 2026-05-12 09:27 JST the daily sync fired on
# an iOS-only hotfix train (v1.18.1) and published a no-op Android
# release with zero source changes. Catches that class of mistake
# without requiring per-train manual intervention.
#
# Mechanism: compare the most-recent-commit-touching-Android-source
# timestamp against the most-recent-published-android-v*-release
# timestamp. If source was touched AFTER the release, proceed; if not,
# the iOS bump is hotfix-only and rebuilding Android would publish a
# byte-identical APK (just versionCode++).
#
# Why timestamps not git-diff-vs-tag: android-v* tags are created on
# the PUBLIC distribution repo (cli-pulse), not this private dev repo.
# `gh release create` tags the public repo's HEAD, which doesn't track
# our dev-commit history at all. So `git diff android-v1.18.1 HEAD --
# android/app/src/` reports nonsense because the tag points to the
# unrelated distribution-only commit (e.g. 5d15080 `docs: add
# .nojekyll`). Timestamps sidestep this entirely.
#
# What's checked: `android/app/src/` + `android/app/proguard-rules.pro`.
# Excludes build.gradle.kts (the version file this script bumps),
# schemas/, .gitignore, AGENTS.md.
#
# Failure-safe defaults: any of (no prior release / gh API down /
# date parse failure / no prior android-touching commit) → return TRUE
# (proceed with publish). Conservatism over false-skipping.
android_source_changed_since_last_release() {
    # Last android-v* release publish timestamp from public repo.
    # IMPORTANT: gh's `createdAt` is the underlying commit date (e.g.
    # the public distribution-only commit 5d15080); `publishedAt` is
    # the actual release publish time. We want publishedAt.
    local release_iso release_epoch
    release_iso=$(gh release list --repo "$PUBLIC_REPO" --limit 50 \
        --json tagName,publishedAt 2>/dev/null \
        | jq -r '[.[] | select(.tagName | startswith("android-v"))]
                 | sort_by(.publishedAt) | last | .publishedAt // empty' \
        2>/dev/null)
    if [[ -z "$release_iso" || "$release_iso" == "null" ]]; then
        return 0  # no prior release — always proceed
    fi
    release_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$release_iso" "+%s" \
        2>/dev/null) || release_epoch=""
    if [[ -z "$release_epoch" ]]; then
        return 0  # couldn't parse — proceed (conservative)
    fi

    # Most-recent commit touching tracked Android source (Unix epoch).
    local source_epoch
    source_epoch=$(git -C "$REPO_ROOT" log -1 --format='%ct' -- \
        'android/app/src/' 'android/app/proguard-rules.pro' 2>/dev/null)
    if [[ -z "$source_epoch" ]]; then
        return 0  # no history of Android commits — proceed (conservative)
    fi

    # If the most recent Android commit is strictly newer than the last
    # release, there's real source to publish. Equal timestamps are
    # treated as "no new source" — exact equality is rare and almost
    # always means we already shipped that commit.
    if (( source_epoch > release_epoch )); then
        return 0
    fi
    return 1
}

# Echoes a short human-readable description of the most recent
# android-v* release for log messages.
last_android_release_description() {
    gh release list --repo "$PUBLIC_REPO" --limit 50 \
        --json tagName,publishedAt 2>/dev/null \
        | jq -r '[.[] | select(.tagName | startswith("android-v"))]
                 | sort_by(.publishedAt) | last
                 | "\(.tagName) (\(.publishedAt))" // "(no prior release)"' \
        2>/dev/null \
        || echo "(unknown — gh API failed)"
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

    # v1.20 A8: pbxproj is now the single source of truth for version.
    # The 5 Info.plist files use $(MARKETING_VERSION) +
    # $(CURRENT_PROJECT_VERSION) substitutions, so updating pbxproj
    # alone is sufficient — xcodebuild expands the substitutions at
    # build time. Do NOT also rewrite the plists; doing so would
    # re-introduce the hardcoded literals and defeat A8.
    sed -i '' "s/MARKETING_VERSION = .*/MARKETING_VERSION = $new_version;/g" "$PBXPROJ"
    sed -i '' "s/CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $new_build;/g" "$PBXPROJ"
    log "  ✓ Bumped pbxproj MARKETING_VERSION + CURRENT_PROJECT_VERSION (substitution-driven plists pick this up at archive time)"
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

    # B5 guard: skip if no Android source touched since last release.
    # Suppresses 2026-05-12 09:27-class no-op releases where an iOS
    # hotfix train would otherwise trigger a byte-identical-binary
    # Android publish. Uses commit-timestamp vs release-timestamp
    # comparison (NOT git-diff-against-tag — android-v* tags live on
    # the public distribution repo and don't track this dev history).
    if ! android_source_changed_since_last_release; then
        LAST_DESC=$(last_android_release_description)
        log ""
        log "════════════════════════════════════════════════════"
        log "  SKIPPING Android sync — no source changes"
        log ""
        log "  Last release: $LAST_DESC"
        log "  No commits under android/app/src/ or"
        log "  android/app/proguard-rules.pro since then."
        log ""
        log "  The iOS bump to v$TARGET_VERSION appears to be a"
        log "  Mac/iOS-only hotfix train; rebuilding Android would"
        log "  publish a versionCode-only release with byte-"
        log "  identical APK."
        log ""
        log "  To force a rebuild (signing-key rotation, build-"
        log "  system change), commit a no-op touch to"
        log "  android/app/proguard-rules.pro first, OR invoke"
        log "  gradle assembleRelease + gh release create"
        log "  manually."
        log "════════════════════════════════════════════════════"
        log "=== Sync skipped (Android no-op guard) ==="
        exit 0
    fi

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
        # main is branch-protected (required "CI Gate" check), so we can no
        # longer push the bump straight to main. Open a PR from a bump branch
        # and let auto-merge land it once CI Gate passes. This also means the
        # version bump is actually CI-validated before it hits main.
        BUMP_BRANCH="chore/sync-versions-v$TARGET_VERSION"
        git checkout -B "$BUMP_BRANCH"
        git add "${BUMP_FILES[@]}"
        git commit -m "chore: sync versions to v$TARGET_VERSION (iOS ↔ Android)"
        git push -u origin "$BUMP_BRANCH" --force-with-lease
        gh pr create --base main --head "$BUMP_BRANCH" \
            --title "chore: sync versions to v$TARGET_VERSION" \
            --body "Automated cross-platform version sync (iOS ↔ Android) to v$TARGET_VERSION. Auto-merges once CI Gate passes." \
            2>/dev/null || true
        # --auto merges when required checks pass; --admin is NOT used so the
        # gate is genuinely enforced. Needs repo 'Allow auto-merge' enabled.
        gh pr merge "$BUMP_BRANCH" --auto --merge 2>/dev/null \
            && log "✓ Version bump PR opened on $BUMP_BRANCH (auto-merge armed)" \
            || log "⚠ Version bump pushed to $BUMP_BRANCH — open/merge the PR manually"
        git checkout main
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
