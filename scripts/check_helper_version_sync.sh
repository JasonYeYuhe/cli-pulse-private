#!/bin/bash
# Fail the build if the two helper version lines drift.
#
# WHY THIS EXISTS
# ---------------
# The bundled Swift helper (HelperSwift, `kHelperVersion`) and the .pkg Python
# helper (`helper/system_collector.py:HELPER_VERSION`) are kept "on the SAME
# version line" so the app has one coherent notion of "the helper version"
# regardless of which of the two owns the socket — the OAuth-injection floor
# gate reads `helper_version` for WHICHEVER helper answered hello, and (for a
# `python-pkg`/pre-v1.43 owner) refresh() compares that reported version against
# the published .pkg manifest.
#
# Historically a drift produced a PERPETUAL "Update available: <swift> →
# <python>" nag in Settings that the Update button couldn't clear — installing
# the .pkg does not evict a bundled helper that owns ~/.clipulse. This drifted
# 1.23.0 → 1.29.1 unnoticed across six helper releases (caught by the 1.42.0
# post-release audit, live-reproduced on real hardware).
#
# (v1.43: a `swift-bundled` hello owner now BYPASSES the .pkg-manifest compare
# entirely — HelperInstaller shows "built-in, updates with the app" — so this
# pin no longer drives the bundled-owner nag. It is still required for the
# python-pkg-owner compare and the floor gate above.)
#
# Like check_helper_no_container_touch.sh, the failure this guards against is
# invisible in CI and unit tests — it only appears in a shipped app's Settings
# pane. Pure grep; runs anywhere.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_FILE="$ROOT/HelperSwift/Sources/HelperKit/Protocol.swift"
PY_FILE="$ROOT/helper/system_collector.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$SWIFT_FILE" ]] || fail "missing $SWIFT_FILE"
[[ -f "$PY_FILE" ]] || fail "missing $PY_FILE"

SWIFT_V="$(grep -E '^public let kHelperVersion: String = "' "$SWIFT_FILE" \
    | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' | head -1)"
PY_V="$(grep -E '^HELPER_VERSION = "' "$PY_FILE" \
    | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' | head -1)"

[[ -n "$SWIFT_V" ]] || fail "could not extract kHelperVersion from $SWIFT_FILE (pattern changed?)"
[[ -n "$PY_V" ]] || fail "could not extract HELPER_VERSION from $PY_FILE (pattern changed?)"

if [[ "$SWIFT_V" != "$PY_V" ]]; then
    fail "helper version drift: HelperSwift kHelperVersion=$SWIFT_V but Python HELPER_VERSION=$PY_V.
      Bump BOTH in the same commit — a stale Swift value produces an unclearable
      'Update available' nag on every DEVID install (see the comment above
      kHelperVersion in Protocol.swift)."
fi

echo "OK: helper version lines in sync ($SWIFT_V)"
