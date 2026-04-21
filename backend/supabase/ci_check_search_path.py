#!/usr/bin/env python3
"""
CI guard for P0-3: every SECURITY DEFINER public function defined in
backend/supabase/ must pin search_path in its attribute region.

Strategy: find each CREATE [OR REPLACE] FUNCTION public.<name>(...) block,
bounded by the first $$-balanced pair plus the trailing semicolon. Inspect
the whole block for both `SECURITY DEFINER` and a `SET search_path` pin.
Supports both PG attribute styles:

    (A) CREATE OR REPLACE FUNCTION f() RETURNS ... LANGUAGE plpgsql
        SECURITY DEFINER SET search_path = ... AS $$ ... $$;

    (B) CREATE OR REPLACE FUNCTION f() RETURNS ... AS $$ ... $$
        LANGUAGE plpgsql SECURITY DEFINER SET search_path = ...;

Exit 0 = all SECURITY DEFINER public definitions pinned.
Exit 1 = at least one unpinned — add `SET search_path = pg_catalog, public, extensions`.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent

# Legacy files: historical migrations superseded in live DB by later migrations.
# Warn but do not fail — tracked as follow-up in PROJECT_FIX_v1.9.6b_search_path.md.
LEGACY_FILES = {
    "migrate_v0.2.sql",
    "migrate_v0.4.sql",
    "migrate_v0.9.sql",
    "migrate_v0.10.sql",
    "migrate_v0.11.sql",
    "schema.sql",
}

# Files explicitly marked as superseded (v0.17 used a pin that broke pgcrypto).
SUPERSEDED_FILES = {
    "migrate_v0.17_search_path_hardening.sql",
}

FUNC_START_RE = re.compile(
    r"create\s+(?:or\s+replace\s+)?function\s+(public\.[a-zA-Z0-9_]+)\s*\(",
    re.IGNORECASE,
)
SECDEF_RE = re.compile(r"\bsecurity\s+definer\b", re.IGNORECASE)
SPATH_RE = re.compile(r"\bset\s+search_path\s*(?:=|to)\s*", re.IGNORECASE)
# Match $$ or $identifier$ as plpgsql dollar-quoting delimiter.
DOLLAR_TAG_RE = re.compile(r"\$[a-zA-Z_]*\$")


def extract_function_blocks(text: str) -> list[tuple[str, int, str]]:
    """Yield (func_name, start_line_1indexed, block_text) for every
    CREATE [OR REPLACE] FUNCTION public.<name>(...) ... ; definition."""
    blocks: list[tuple[str, int, str]] = []
    pos = 0
    while True:
        m = FUNC_START_RE.search(text, pos)
        if not m:
            break
        name = m.group(1)
        block_start = m.start()

        # Find the first dollar-quote tag after this CREATE FUNCTION.
        tag_m = DOLLAR_TAG_RE.search(text, m.end())
        if not tag_m:
            pos = m.end()
            continue
        tag = tag_m.group(0)

        # Find the matching close tag.
        close_pos = text.find(tag, tag_m.end())
        if close_pos == -1:
            pos = tag_m.end()
            continue

        # Find the `;` that terminates the CREATE FUNCTION statement after
        # the closing dollar quote.
        semi_pos = text.find(";", close_pos + len(tag))
        if semi_pos == -1:
            block_end = close_pos + len(tag)
        else:
            block_end = semi_pos + 1

        block = text[block_start:block_end]
        start_line = text[:block_start].count("\n") + 1
        blocks.append((name, start_line, block))
        pos = block_end
    return blocks


def check_file(path: pathlib.Path) -> tuple[list[str], list[str]]:
    """Return (errors, warnings) for a single SQL file."""
    errors: list[str] = []
    warnings: list[str] = []
    text = path.read_text()

    for name, line_num, block in extract_function_blocks(text):
        if not SECDEF_RE.search(block):
            continue  # invoker function — not our concern
        if SPATH_RE.search(block):
            continue  # pinned — good
        loc = f"{path.name}:{line_num}"
        msg = f"{loc}  function {name}  SECURITY DEFINER without SET search_path"
        if path.name in LEGACY_FILES or path.name in SUPERSEDED_FILES:
            warnings.append(msg + "  (legacy/superseded — ignored)")
        else:
            errors.append(msg)

    return errors, warnings


def main() -> int:
    all_errors: list[str] = []
    all_warnings: list[str] = []
    files = sorted(ROOT.glob("*.sql"))
    for f in files:
        if f.name.startswith("rollback_"):
            continue
        errs, warns = check_file(f)
        all_errors.extend(errs)
        all_warnings.extend(warns)

    print(f"Scanned {len(files)} SQL files in backend/supabase/")
    if all_warnings:
        print(f"\n{len(all_warnings)} warning(s):")
        for w in all_warnings:
            print(f"  WARN  {w}")
    if all_errors:
        print(f"\n{len(all_errors)} error(s):")
        for e in all_errors:
            print(f"  FAIL  {e}")
        print("\nP0-3 regression: add `SET search_path = pg_catalog, public, extensions`")
        print("to the function attribute block (or after SECURITY DEFINER and before ;).")
        return 1
    print("\nOK — every non-legacy SECURITY DEFINER public function is pinned.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
