#!/usr/bin/env python3
"""
CI guard for P0-2: rolling-N-day SQL windows must be inclusive of today.

Background
----------
Swift `DateRange` (CLIPulseCore) defines:

    rolling week  = today + previous 6 calendar days   = 7 days
    rolling month = today + previous 29 calendar days  = 30 days

A naive SQL translation that uses

    metric_date >= current_date - interval '7 days'

actually spans 8 calendar days (today through today-7), which silently
inflates rolling-week aggregates by ~14%. The same off-by-one applies to
30-day windows and to `get_daily_usage(N)` where `current_date - N` with
`>=` returns N+1 rows.

This check is intentionally narrow: it scans `backend/supabase/*.sql` for
patterns that look like rolling-window declarations or filters and fails
on any that span N+1 days instead of N.

What it catches
---------------
1. `interval '7 days'` paired with a `>=` comparison anywhere in the same
   file (rolling week should be `'6 days'`).
2. `interval '30 days'` paired with `>=` (rolling month should be `'29 days'`).
3. `current_date - days` (parameterized N) paired with `>=` where `days` is
   not first decremented (`days - 1` or guarded by `greatest(...)`).

What it ignores
---------------
- `interval '7 days'` not paired with `>=` (e.g. retention deletes that use
  `<` against historical data).
- Comments and CHANGELOG-style strings inside `--` lines.

Exit codes
----------
0  All rolling-window patterns are inclusive-N (matches Swift contract).
1  At least one off-by-one. Each failure prints `path:line  reason`.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SQL_FILES = sorted(ROOT.glob("*.sql"))

# v1.21 F10: files that intentionally preserve historical / superseded SQL
# even though the static analysis would correctly flag the bug. v0.43 is a
# verbatim backfill of what the cli-pulse-desktop team applied to prod on
# 2026-05-04 — it shipped an off-by-one rolling window, which v0.44 fixed
# the same week. Rewriting v0.43 to "look correct" would break F9 live-
# migration replay parity with prod.
EXEMPT_FILES: set[str] = {
    "migrate_v0.43_provider_quotas_bigint_and_updated_at.sql",
}


def strip_comments(text: str) -> str:
    """Drop `-- ...` line comments so we don't false-positive on prose."""
    out = []
    for line in text.splitlines():
        idx = line.find("--")
        out.append(line[:idx] if idx >= 0 else line)
    return "\n".join(out)


# ---- pattern 1: `current_date - interval 'N days'` paired with >= in file ----
#
# The narrow `current_date -` prefix (vs. `now() +`) deliberately excludes
# column-default TTLs like `default (now() + interval '7 days')`, which are
# forward-expiry markers, not backward-rolling-window filters.

SEVEN_DAY = re.compile(
    r"current_date\s*-\s*interval\s*'7\s+days?'", re.IGNORECASE
)
THIRTY_DAY = re.compile(
    r"current_date\s*-\s*interval\s*'30\s+days?'", re.IGNORECASE
)
HAS_GTE = re.compile(r">=")

# ---- pattern 2: parameterized `current_date - days` without (days - 1) ----
# Looks for `current_date - <ident>` where <ident> is a bare name (not arithmetic).
PARAM_SINCE = re.compile(
    r"current_date\s*-\s*([a-zA-Z_][a-zA-Z0-9_]*)\b(?!\s*[-+*/0-9])",
    re.IGNORECASE,
)


def find_lines(text: str, pattern: re.Pattern[str]) -> list[tuple[int, str]]:
    hits = []
    for i, line in enumerate(text.splitlines(), start=1):
        if pattern.search(line):
            hits.append((i, line.strip()))
    return hits


def check_file(path: pathlib.Path) -> list[str]:
    raw = path.read_text(encoding="utf-8")
    body = strip_comments(raw)

    failures: list[str] = []

    has_gte = bool(HAS_GTE.search(body))

    seven = find_lines(body, SEVEN_DAY)
    if seven and has_gte:
        for line_no, snippet in seven:
            failures.append(
                f"{path.relative_to(ROOT.parent.parent)}:{line_no}  "
                f"`interval '7 days'` with `>=` in same file -> spans 8 days. "
                f"Use `interval '6 days'` for a 7-day inclusive window. "
                f"[{snippet}]"
            )

    thirty = find_lines(body, THIRTY_DAY)
    if thirty and has_gte:
        for line_no, snippet in thirty:
            failures.append(
                f"{path.relative_to(ROOT.parent.parent)}:{line_no}  "
                f"`interval '30 days'` with `>=` in same file -> spans 31 days. "
                f"Use `interval '29 days'` for a 30-day inclusive window. "
                f"[{snippet}]"
            )

    # Parameterized-window check: only flag when the bare-ident form is paired
    # with `>=` AND the file does not derive an inclusive `days - 1` first.
    for line_no, snippet in find_lines(body, PARAM_SINCE):
        m = PARAM_SINCE.search(snippet)
        if not m:
            continue
        ident = m.group(1).lower()
        # Whitelist tokens that aren't N-day parameters.
        if ident in {"interval", "now", "current_date"}:
            continue
        if not has_gte:
            continue
        # If the file already pre-clamps via `<ident> - 1` or similar, skip.
        if re.search(rf"{re.escape(ident)}\s*-\s*1\b", body):
            continue
        # Skip if the surrounding declaration is `v_<ident> int := greatest(...)`
        # plus a separate `current_date - (<v_ident> - 1)` (already handled above).
        failures.append(
            f"{path.relative_to(ROOT.parent.parent)}:{line_no}  "
            f"`current_date - {ident}` with `>=` and no `{ident} - 1` adjustment "
            f"-> returns N+1 rows. Use `current_date - ({ident} - 1)` and clamp "
            f"`{ident} >= 1`. [{snippet}]"
        )

    return failures


def main() -> int:
    all_failures: list[str] = []
    for path in SQL_FILES:
        if path.name in EXEMPT_FILES:
            continue
        all_failures.extend(check_file(path))

    if all_failures:
        print("Date-window contract violations:")
        for line in all_failures:
            print(f"  - {line}")
        return 1

    print(f"OK: scanned {len(SQL_FILES)} SQL file(s); rolling windows match Swift contract.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
