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

echo "OK — versions match."
