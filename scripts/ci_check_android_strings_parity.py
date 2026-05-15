#!/usr/bin/env python3
"""
v1.21 E6 lint guard — fail CI if any non-default Android locale is missing
string keys that exist in values/strings.xml.

Why this script exists:
  Before v1.21, values-es / values-ko / values-zh-rTW had drifted to 137
  keys while values/ had 195 — meaning ~30% of UI strings were silently
  falling back to English in those languages. Android's own `lint` does
  not catch missing-locale gaps by default (you have to opt into the
  `MissingTranslation` issue, and it only warns).

  This script enforces strict parity: every <string name="..."> and
  <plurals name="..."> in the default values/strings.xml must also be
  declared in every other values-*/strings.xml. Run it from CI on the
  android-ci.yml `unit-tests` job (cheap, no Android SDK needed).

Exit codes:
  0 — every locale has parity with the default
  1 — at least one locale is missing keys (prints which + which keys)

Allowlist:
  If a key intentionally only exists in the default locale (e.g. an
  English-only debug label), prefix it with `_debug_` or add it to the
  IGNORED_KEYS set below. Keep that list short.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RES_DIR = REPO_ROOT / "android" / "app" / "src" / "main" / "res"
DEFAULT_LOCALE = "values"

# Keys that are deliberately default-only. Empty for now — fail-closed.
IGNORED_KEYS: set[str] = set()


def collect_keys(strings_xml: Path) -> set[str]:
    text = strings_xml.read_text(encoding="utf-8")
    string_keys = set(re.findall(r'<string\s+name="([^"]+)"', text))
    plural_keys = set(re.findall(r'<plurals\s+name="([^"]+)"', text))
    return string_keys | plural_keys


def main() -> int:
    default_xml = RES_DIR / DEFAULT_LOCALE / "strings.xml"
    if not default_xml.is_file():
        print(f"FATAL: default strings.xml missing at {default_xml}", file=sys.stderr)
        return 2

    expected = collect_keys(default_xml) - IGNORED_KEYS

    failures: dict[str, list[str]] = {}
    for locale_dir in sorted(RES_DIR.glob("values-*")):
        # Skip non-locale directories (values-night, values-w480dp, etc.)
        name = locale_dir.name
        suffix = name.removeprefix("values-")
        # ISO language codes are 2 letters (e.g. "es", "ko", "ja") or
        # language+region "zh-rCN"/"zh-rTW". Other suffixes are config
        # qualifiers (night/v23/w480dp) — skip them.
        if not (
            len(suffix) == 2
            or (len(suffix) > 2 and suffix[2] == "-" and suffix[3:].startswith("r"))
        ):
            continue
        strings_xml = locale_dir / "strings.xml"
        if not strings_xml.is_file():
            failures[name] = sorted(expected)
            continue
        present = collect_keys(strings_xml)
        missing = sorted(expected - present)
        if missing:
            failures[name] = missing

    if not failures:
        print(f"OK — every locale has parity with {DEFAULT_LOCALE}/strings.xml")
        return 0

    print("FAIL — locales are missing keys present in values/strings.xml:\n", file=sys.stderr)
    for locale, missing in failures.items():
        print(f"  {locale}: {len(missing)} missing", file=sys.stderr)
        for key in missing[:5]:
            print(f"    - {key}", file=sys.stderr)
        if len(missing) > 5:
            print(f"    ... ({len(missing) - 5} more)", file=sys.stderr)
    print(
        "\nFix by adding the missing <string>/<plurals> entries to the locale's\n"
        "strings.xml. Translations matter — don't paste the English text.\n",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
