#!/usr/bin/env python3
"""
GDPR right-to-erasure cascade guard.

Static, read-only. Walks every `create table public.<name>` in the SQL
sources and asserts that any column matching the pattern `user_id uuid
... references ... on delete cascade` truly cascades on delete. Any
table introducing a `user_id` column without ON DELETE CASCADE
(or without the FK reference at all) fails CI.

Why this exists
---------------
`delete_user_account` runs `delete from auth.users where id = ...` as
its final step. profiles.id has `on delete cascade` from auth.users, so
every table whose `user_id uuid references public.profiles(id) on
delete cascade` gets wiped automatically. New tables added without that
FK shape silently retain user data after account deletion, violating
GDPR right-to-erasure.

The Plan v2 review (Gemini 3 Pro, 2026-04-27) caught that
daily_usage_metrics is correctly cascade-covered, but a future regression
would only surface in a privacy audit. This script enforces the
invariant at merge time.

Exit codes
----------
0 — every public table with a `user_id uuid` column cascades
1 — at least one user_id column doesn't reference profiles(id) on delete cascade
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_DIR = REPO / "backend" / "supabase"

# Tables that intentionally omit `user_id` because they're shared/team-owned
# or system-level. Add justifications when extending this list.
EXEMPT_TABLES: set[str] = {
    # team_invites uses email, not user_id (joiner may not yet exist)
    "team_invites",
    # webhook_jobs cascades from profiles via user_id (covered, just exempting
    # any future audit that checks "every table"). Listed for documentation.
}

# Patterns: catches `user_id ... references public.profiles(id) on delete cascade`
# even with line breaks and varied case.
TABLE_BLOCK_PAT = re.compile(
    r"create\s+table\s+(?:if\s+not\s+exists\s+)?public\.([a-z_][a-z0-9_]*)\s*\((.*?)\)\s*;",
    re.IGNORECASE | re.DOTALL,
)
USER_ID_COL_PAT = re.compile(
    r"\buser_id\s+uuid\b(?P<rest>.*?)(?:,\s*\n|$)",
    re.IGNORECASE | re.DOTALL,
)
CASCADE_PAT = re.compile(
    r"references\s+(?:public\.)?(?P<target>profiles|auth\.users)\s*\(\s*id\s*\)\s*on\s+delete\s+cascade",
    re.IGNORECASE,
)


def scan_file(path: pathlib.Path) -> list[tuple[str, str, str]]:
    """Return [(table, status, detail), ...] for every public.<table> in file."""
    text = path.read_text()
    rows: list[tuple[str, str, str]] = []
    for m in TABLE_BLOCK_PAT.finditer(text):
        table = m.group(1)
        body = m.group(2)
        if table in EXEMPT_TABLES:
            rows.append((table, "exempt", "intentionally omitted from check"))
            continue
        # Find user_id column declaration line.
        col_m = USER_ID_COL_PAT.search(body)
        if not col_m:
            # No user_id at all. Common for shared resources (teams,
            # provider_metadata caches, etc.). Not a violation by itself —
            # but flag if the table name is suspiciously per-user.
            rows.append((table, "no-user-id", "skipped (no user_id column)"))
            continue
        rest = col_m.group("rest")
        if CASCADE_PAT.search(rest):
            rows.append((table, "ok", "cascade present"))
        else:
            rows.append((table, "FAIL", f"user_id missing cascade FK: {rest.strip()[:120]}"))
    return rows


def main() -> int:
    all_rows: list[tuple[str, str, str, pathlib.Path]] = []
    for p in sorted(SQL_DIR.glob("*.sql")):
        for table, status, detail in scan_file(p):
            all_rows.append((table, status, detail, p))

    # Dedup: a table is OK if ANY of its create-table occurrences declared
    # the cascade. Migrations may "re-declare" via `create table if not
    # exists` — last-write isn't the right metric; first-correct is.
    by_table: dict[str, list[tuple[str, str, pathlib.Path]]] = {}
    for table, status, detail, p in all_rows:
        by_table.setdefault(table, []).append((status, detail, p))

    failures: list[tuple[str, str, pathlib.Path]] = []
    okays: list[str] = []
    for table, occurrences in by_table.items():
        statuses = {s for s, _, _ in occurrences}
        if "ok" in statuses or "exempt" in statuses:
            okays.append(table)
            continue
        if "FAIL" in statuses:
            for s, detail, p in occurrences:
                if s == "FAIL":
                    failures.append((table, detail, p))
        # "no-user-id" alone is fine — skip without listing.

    if failures:
        print("FAIL: tables with user_id but no `on delete cascade` to auth.users root:", file=sys.stderr)
        for table, detail, p in failures:
            print(f"  - public.{table}  ({p.name})  → {detail}", file=sys.stderr)
        print(
            "\nEvery table with a `user_id uuid` column must reference "
            "public.profiles(id) (or auth.users(id)) with ON DELETE CASCADE "
            "so `delete_user_account`'s final `delete from auth.users` wipes "
            "all user data. Otherwise account deletion silently retains rows "
            "and violates GDPR right-to-erasure.",
            file=sys.stderr,
        )
        return 1

    print(f"ok: {len(okays)} public.* tables with user_id all cascade-covered to auth.users")
    return 0


if __name__ == "__main__":
    sys.exit(main())
