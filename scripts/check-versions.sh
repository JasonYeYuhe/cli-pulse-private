#!/usr/bin/env bash
# v1.21 G6 — CI version-drift gate.
#
# Compares the MARKETING_VERSION declared in the Apple xcodeproj against
# the versionName declared in Android's build.gradle.kts. Fails the
# pipeline if they diverge so a Mac-only or Android-only bump can never
# silently ship.
#
# Unlike scripts/sync-versions.sh, this script does NOT require ASC
# credentials — it never touches the App Store Connect API, only reads
# the source tree. Safe to run in any CI lane.
#
# Exit codes:
#   0  versions match
#   1  versions diverge (or the script could not extract one of them)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pbxproj="${repo_root}/CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj"
gradle="${repo_root}/android/app/build.gradle.kts"

if [[ ! -f "$pbxproj" ]]; then
  echo "::error::pbxproj not found at $pbxproj" >&2
  exit 1
fi
if [[ ! -f "$gradle" ]]; then
  echo "::error::build.gradle.kts not found at $gradle" >&2
  exit 1
fi

# Apple: the pbxproj contains one MARKETING_VERSION = X.Y.Z; line per
# build configuration. We require ALL of them to agree on a single
# value. If a previous bump only touched the Release config the script
# catches that here.
apple_versions=$(
  grep -oE "MARKETING_VERSION = [^;]+;" "$pbxproj" \
    | sed -E 's/MARKETING_VERSION = //; s/;$//; s/[[:space:]]//g' \
    | sort -u
)
if [[ -z "$apple_versions" ]]; then
  echo "::error::could not extract MARKETING_VERSION from pbxproj" >&2
  exit 1
fi
if [[ $(printf '%s\n' "$apple_versions" | wc -l) -gt 1 ]]; then
  echo "::error::pbxproj has inconsistent MARKETING_VERSION values:" >&2
  printf '  %s\n' "$apple_versions" >&2
  exit 1
fi
apple="$apple_versions"

# Android: versionName = "X.Y.Z" in build.gradle.kts. Use [[:space:]]
# rather than \s — macOS sed (BSD) doesn't recognise \s.
android=$(
  grep -E '^[[:space:]]*versionName[[:space:]]*=' "$gradle" \
    | head -1 \
    | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/'
)
if [[ -z "$android" ]]; then
  echo "::error::could not extract versionName from build.gradle.kts" >&2
  exit 1
fi

echo "Apple MARKETING_VERSION:  $apple"
echo "Android versionName:      $android"

if [[ "$apple" != "$android" ]]; then
  echo "::error::version drift — Apple ($apple) ≠ Android ($android). Run scripts/sync-versions.sh." >&2
  exit 1
fi

# Android versionCode monotonicity — Google Play REJECTS a build whose
# versionCode did not strictly increase. If this change bumps versionName vs
# origin/main, versionCode must have increased too. Degrades gracefully: if the
# origin/main baseline can't be read (offline / no remote), it skips rather than
# emitting a false failure. (Play rejects non-incrementing codes anyway; this
# just catches it in CI before an upload round-trip.)
git -C "$repo_root" fetch --quiet --depth=1 origin main 2>/dev/null || true
base_gradle=$(git -C "$repo_root" show origin/main:android/app/build.gradle.kts 2>/dev/null || true)
cur_code=$(grep -E '^[[:space:]]*versionCode[[:space:]]*=' "$gradle" | head -1 | grep -oE '[0-9]+' | head -1)
if [[ -n "$base_gradle" && -n "$cur_code" ]]; then
  base_code=$(printf '%s\n' "$base_gradle" | grep -E '^[[:space:]]*versionCode[[:space:]]*=' | head -1 | grep -oE '[0-9]+' | head -1)
  base_name=$(printf '%s\n' "$base_gradle" | grep -E '^[[:space:]]*versionName[[:space:]]*=' | head -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
  if [[ -n "$base_code" && "$android" != "$base_name" && "$cur_code" -le "$base_code" ]]; then
    echo "::error::versionName changed ($base_name → $android) but Android versionCode did not increase ($base_code → $cur_code). Google Play will reject this. Bump versionCode in android/app/build.gradle.kts." >&2
    exit 1
  fi
  echo "Android versionCode:      $cur_code (origin/main baseline $base_code)"
else
  echo "Android versionCode:      ${cur_code:-?} (no origin/main baseline — monotonicity check skipped)"
fi

echo "OK — versions match."
