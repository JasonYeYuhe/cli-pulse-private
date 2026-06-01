#!/usr/bin/env python3
"""
v1.27 E4 — fail CI if the Android xterm.js terminal bundle drifts from the iOS
source of truth.

The bundle is vendored in two places so each platform ships it as a local
asset (no network dependency):

  iOS  (source of truth): CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources/Terminal/
  Android (copy):         android/app/src/main/assets/terminal/

Only `index.html` legitimately differs — the Android copy carries the R1
AndroidBridge shim (`webkit.messageHandlers` -> `AndroidBridge.postMessage`) plus
the `TERMINAL_CONFIG` scrollback injection that iOS does via a WKUserScript.
Every other file (xterm.js, addon-*.js, xterm.css, LICENSE.xterm) MUST be
byte-identical so both platforms render the exact same xterm.js. This guard
enforces that, and additionally asserts the Android index.html still carries the
shim (so a careless re-copy from iOS can't silently strip it).

Run from CI (cheap, no Android SDK needed). Exit 0 = parity holds; 1 = drift.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IOS = REPO / "CLI Pulse Bar" / "CLIPulseCore" / "Sources" / "CLIPulseCore" / "Resources" / "Terminal"
ANDROID = REPO / "android" / "app" / "src" / "main" / "assets" / "terminal"

# index.html diverges by design (the Android shim); everything else must match.
EXCLUDE = {"index.html"}
# Markers that must survive in the Android index.html so the shim isn't lost.
ANDROID_INDEX_MARKERS = ("AndroidBridge", "TERMINAL_CONFIG")


def main() -> int:
    if not IOS.is_dir():
        print(f"FATAL: iOS bundle dir missing: {IOS}", file=sys.stderr)
        return 2
    if not ANDROID.is_dir():
        print(f"FATAL: Android bundle dir missing: {ANDROID}", file=sys.stderr)
        return 2

    problems: list[str] = []

    ios_shared = sorted(p.name for p in IOS.iterdir() if p.is_file() and p.name not in EXCLUDE)
    for name in ios_shared:
        a = ANDROID / name
        if not a.is_file():
            problems.append(f"MISSING in Android: {name}")
        elif (IOS / name).read_bytes() != a.read_bytes():
            problems.append(f"DRIFT: {name} differs between iOS and Android")

    ios_names = {p.name for p in IOS.iterdir() if p.is_file()}
    for p in sorted(ANDROID.iterdir()):
        if p.is_file() and p.name not in EXCLUDE and p.name not in ios_names:
            problems.append(f"EXTRA in Android (no iOS counterpart): {p.name}")

    android_index = ANDROID / "index.html"
    if not android_index.is_file():
        problems.append("MISSING Android index.html")
    else:
        txt = android_index.read_text(encoding="utf-8")
        for marker in ANDROID_INDEX_MARKERS:
            if marker not in txt:
                problems.append(
                    f"Android index.html lost required shim marker '{marker}' "
                    "(was it re-copied from iOS without the Android shim?)"
                )

    if problems:
        print("FAIL — Android terminal bundle drifted from the iOS source of truth:\n", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print(
            "\nFix: re-copy the changed shared file(s) from\n"
            f"  {IOS}\nto\n  {ANDROID}\n"
            "preserving index.html's Android shim (AndroidBridge + TERMINAL_CONFIG).",
            file=sys.stderr,
        )
        return 1

    print(
        f"OK — {len(ios_shared)} shared terminal bundle file(s) byte-identical "
        "iOS<->Android (index.html excluded by design; Android shim present)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
