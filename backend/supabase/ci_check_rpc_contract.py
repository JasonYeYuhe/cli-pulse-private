#!/usr/bin/env python3
"""
Backend ↔ client RPC contract smoke check.

Static, read-only. No network, no Supabase credentials, no production access.
Walks the in-repo SQL definitions plus every app/helper/Android RPC call site
and fails when they drift apart.

What it catches (hard failures, exit 1)
---------------------------------------
1. A client (Apple Swift / helper Python / Android Kotlin) calls an RPC name
   that is not defined by `CREATE [OR REPLACE] FUNCTION public.<name>` in any
   `backend/supabase/*.sql` file.
2. A client sends a parameter to an RPC that the SQL signature does not
   declare (typo, rename in SQL the client missed).
3. An edge function URL (`/functions/v1/<name>`) is referenced from the
   client but the corresponding directory under `backend/supabase/functions/`
   is missing.

Soft signals (info/warn only, never fail)
-----------------------------------------
- An SQL function defined in `backend/supabase/` that no Apple/helper/Android
  client currently calls. SQL may intentionally retain compatibility shims,
  future RPCs staged for an upcoming release, or helper-facing entry points
  used by external tooling — silent removal of a client referent is not, by
  itself, a contract bug. Helper-facing RPCs (`register_helper`,
  `helper_heartbeat`, `helper_sync`, `ingest_commits`, `get_track_git_activity`)
  are tagged in the note so a reviewer can double-check intent, but the check
  still passes.

What it deliberately does NOT check
-----------------------------------
- Live Supabase project (no token, no network).
- Return-shape / column-by-column contract — too fluid; would generate churn.
- REST table calls (`/rest/v1/<table>?...`) — schema-driven, not RPC-driven.
- Edge function bodies — only the directory presence.
- Clients omitting an SQL parameter that has a `default` — those are valid.

Exit codes
----------
0  All references match. (Info-level notes about app-facing-only orphans may
   still be printed; they don't fail the check.)
1  At least one mismatch above. Each failure prints a one-line reason with
   file:line context so the offending call site is easy to find.

Usage
-----
    python3 backend/supabase/ci_check_rpc_contract.py

No flags, no environment variables.
"""

from __future__ import annotations

import pathlib
import re
import sys
from dataclasses import dataclass, field

ROOT = pathlib.Path(__file__).resolve().parent
REPO = ROOT.parent.parent

# Helper-facing RPCs — tagged in info notes so a reviewer can spot if one is
# accidentally orphaned, but never fail the check (SQL may retain a helper
# RPC for compatibility / future / external tooling).
HELPER_RPCS = {
    "register_helper",
    "helper_heartbeat",
    "helper_sync",
    "ingest_commits",
    "get_track_git_activity",
}

# Internal/admin RPCs — never called from the client side. We skip the
# "no-client" report for these so it doesn't flood the output.
INTERNAL_RPCS = {
    "cleanup_expired_data",
    "cleanup_retention_data",
    "cleanup_old_data",
    "_cleanup_expired_data_internal",
    "_cleanup_retention_data_internal",
    "_recompute_yield_scores_for_user_internal",
    "_recompute_yield_scores_for_days_internal",
    "recompute_yield_scores_for_user",
    "handle_new_user",
    "handle_new_profile",
    "handle_new_subscription",
}

# Trigger / handler functions live in `schema.sql` and never need a client
# referent. The names above already cover the well-known ones; if a new
# trigger is added, append it to INTERNAL_RPCS.

# Regexes — kept intentionally simple. We string-grep, not full-parse.
SQL_FUNC_RE = re.compile(
    r"create\s+(?:or\s+replace\s+)?function\s+public\.([a-zA-Z0-9_]+)\s*\(([^;)]*?)\)\s*",
    re.IGNORECASE | re.DOTALL,
)
SQL_PARAM_RE = re.compile(
    r"^\s*([a-z_][a-z0-9_]*)\s+(?:[a-z][a-z0-9_]*\s*(?:\([^)]*\))?\s*)+(?:\bdefault\b)?",
    re.IGNORECASE | re.MULTILINE,
)


@dataclass
class SqlFunction:
    """A single CREATE FUNCTION definition."""
    name: str
    params: dict[str, bool] = field(default_factory=dict)  # param_name -> has_default
    file: str = ""
    line: int = 0


@dataclass
class CallSite:
    """One client RPC call."""
    rpc_name: str
    sent_params: set[str]
    file: str
    line: int

    def __str__(self) -> str:
        return f"{self.file}:{self.line}"


# ─────────────────────────────────────────────────────────────────────────────
# SQL side
# ─────────────────────────────────────────────────────────────────────────────


def parse_sql_param_block(raw: str) -> dict[str, bool]:
    """Given the body of `(...)` from CREATE FUNCTION, return
    `{param_name: has_default}`. Tolerant of multiline, defaults with quotes,
    and `default jsonb_build_object(...)` style expressions. Comma-split is
    parenthesis-aware so `default '{}'::jsonb` doesn't fool us.
    """
    out: dict[str, bool] = {}
    if not raw or not raw.strip():
        return out

    # Comma-split, but skip commas inside (), [], {} to keep complex defaults
    # (e.g. `'{}'::jsonb`, `jsonb_build_object('a', 1)`) intact.
    parts: list[str] = []
    buf: list[str] = []
    depth = 0
    for ch in raw:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        parts.append("".join(buf))

    for raw_part in parts:
        part = raw_part.strip()
        if not part:
            continue
        # First identifier is the parameter name.
        m = re.match(r"([a-z_][a-z0-9_]*)\s+", part, re.IGNORECASE)
        if not m:
            continue
        name = m.group(1).lower()
        has_default = bool(re.search(r"\bdefault\b", part, re.IGNORECASE))
        out[name] = has_default
    return out


_VERSION_RE = re.compile(r"migrate_v(\d+)\.(\d+)")


def _sql_replay_order(path: pathlib.Path) -> tuple[int, int, int, str]:
    """Return a sort key that mirrors Supabase replay order:
    1. Migrations replayed numerically (not alphabetically — `0.2` < `0.19`).
    2. Then `schema.sql`, `app_rpc.sql`, `helper_rpc.sql` last so they always
       win as the canonical post-migration shape.
    Tuple format: (priority, major, minor, name) — sorted ascending.
    """
    name = path.name
    m = _VERSION_RE.match(name)
    if m:
        return (0, int(m.group(1)), int(m.group(2)), name)
    if name in {"schema.sql", "app_rpc.sql", "helper_rpc.sql"}:
        # schema first, then app_rpc, then helper_rpc so helper signatures win
        # for shared names like helper_sync.
        order = {"schema.sql": 1, "app_rpc.sql": 2, "helper_rpc.sql": 3}[name]
        return (1, order, 0, name)
    # Unknown SQL files (e.g. rollback_*.sql) go last.
    return (2, 0, 0, name)


def collect_sql_definitions() -> dict[str, SqlFunction]:
    """Walk every backend/supabase/*.sql, returning the LATEST definition of
    each public function name. Files are processed in numeric migration order
    (so `migrate_v0.2.sql` is older than `migrate_v0.19_*.sql`), and
    `app_rpc.sql` / `helper_rpc.sql` / `schema.sql` are processed LAST so
    they win as the canonical authoritative signature.
    """
    funcs: dict[str, SqlFunction] = {}
    for sql_path in sorted(ROOT.glob("*.sql"), key=_sql_replay_order):
        text = sql_path.read_text(encoding="utf-8")
        # Pre-compute line offsets for line-number reporting.
        line_starts = [0]
        for idx, ch in enumerate(text):
            if ch == "\n":
                line_starts.append(idx + 1)

        for match in SQL_FUNC_RE.finditer(text):
            name = match.group(1).lower()
            param_block = match.group(2)
            params = parse_sql_param_block(param_block)
            # Find the line number where the CREATE keyword is.
            offset = match.start()
            line_no = max(i for i, start in enumerate(line_starts, start=1) if start <= offset)
            funcs[name] = SqlFunction(
                name=name,
                params=params,
                file=sql_path.name,
                line=line_no,
            )
    return funcs


# ─────────────────────────────────────────────────────────────────────────────
# Client side
# ─────────────────────────────────────────────────────────────────────────────


# Apple Swift rpc helper: `rpc("name")` or `rpc("name", params: <expr>)`.
# The 2nd argument is extracted via balanced-paren scan because it can be:
#   - `Params(p_x: ..., p_y: ...)`  ← struct init with argument labels
#   - `["p_x": ..., "p_y": ...]`    ← dictionary literal with quoted keys
#   - `EmptyBody()`                  ← no params
APPLE_RPC_HEAD_RE = re.compile(r'\brpc\(\s*"([a-z_][a-z0-9_]*)"')
APPLE_RPC_URL_RE = re.compile(r'/rest/v1/rpc/([a-z_][a-z0-9_]*)')
# Quoted-string dict keys: `"<lower_snake>":`. Real Swift header strings like
# "Content-Type" / "Authorization" contain a hyphen and won't match. Method
# strings ("POST", "GET") are not followed by a colon.
APPLE_DICT_KEY_RE = re.compile(r'"([a-z_][a-z0-9_]*)"\s*:')
# Swift Params struct argument labels: `Params(p_x: foo, p_y: bar)`.
APPLE_STRUCT_LABEL_RE = re.compile(r'([a-z_][a-z0-9_]*)\s*:', re.IGNORECASE)

# Helper Python: supabase_rpc("name", { "p_x": ..., "p_y": ... })
PY_RPC_RE = re.compile(r'supabase_rpc\(\s*"([a-z_][a-z0-9_]*)"\s*,\s*\{([^}]*)\}', re.DOTALL)
PY_KEY_RE = re.compile(r'"([a-z_][a-z0-9_]*)"\s*:')

# Android Kotlin: rpc / rpcArray / rpcPublic — call-name only. The 2nd
# argument is extracted via balanced-paren scan because it can contain
# arbitrary nested calls (`JSONObject().apply { put("k", v) }`).
KT_RPC_HEAD_RE = re.compile(
    r'\b(rpc|rpcArray|rpcPublic)\(\s*"([a-z_][a-z0-9_]*)"',
)
# Android params are built via JSONObject().apply { put("k", ...); ... } or
# JSONObject().put("k", ...). Both forms decode to the same put() literal.
KT_PUT_KEY_RE = re.compile(r'put\(\s*"([a-z_][a-z0-9_]*)"')
# Backward look-up for `val <name> = JSONObject() ... { ... }` when the rpc
# 2nd argument is a bare identifier.
KT_VAL_RE_TEMPLATE = r"val\s+{name}\s*=\s*JSONObject\(\s*\)"

# Apple-side `["key": value]` direct-URL post bodies are followed within ~10
# lines of the URL declaration. Same window used for Android.
SCAN_WINDOW = 12


def _line_no_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def _surrounding_lines(text: str, offset: int, window: int) -> str:
    """Return up to `window` lines starting at the line containing offset."""
    line_start = text.rfind("\n", 0, offset) + 1
    end = line_start
    for _ in range(window):
        nxt = text.find("\n", end)
        if nxt == -1:
            return text[line_start:]
        end = nxt + 1
    return text[line_start:end]


def collect_apple_call_sites() -> list[CallSite]:
    """APIClient.swift + HelperAPIClient.swift cover every Apple RPC reference
    today (verified by inspection during planning). If a future call site
    moves elsewhere, broaden the glob.

    Two call patterns are handled:

    (1) Helper form — `rpc("name", params: <expr>)`:
        - `Params(p_x: foo, p_y: bar)`  → argument labels become param names
        - `["p_x": foo, "p_y": bar]`    → dictionary literal keys become names
        - `EmptyBody()` / no 2nd arg     → no params
        2nd-arg expression is extracted with balanced-paren so neighbouring
        code never bleeds in.

    (2) Direct-URL form — `URL("…/rest/v1/rpc/<name>")` followed by a
        `URLRequest` body. Bodies appear as either an inline
        `withJSONObject: ["key": …]` or a separate `let body = ["key": …]`
        used a few lines later. Both forms have *quoted* string keys; type
        annotations like `[String: Any]` and HTTP header strings like
        "Content-Type" / "Authorization" don't match the lower-snake-with-
        colon shape so they're naturally excluded.
    """
    sites: list[CallSite] = []
    apple_dir = REPO / "CLI Pulse Bar" / "CLIPulseCore" / "Sources" / "CLIPulseCore"
    targets = [apple_dir / "APIClient.swift", apple_dir / "HelperAPIClient.swift"]
    for path in targets:
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        rel = str(path.relative_to(REPO))

        # ─── Pattern 1: rpc("name", ...) ────────────────────────────────────
        for head in APPLE_RPC_HEAD_RE.finditer(text):
            name = head.group(1).lower()
            paren_pos = text.find("(", head.start(), head.end())
            if paren_pos == -1:
                continue
            balanced = _balanced_extract(text, paren_pos)
            args = _split_top_level_comma(balanced)
            sent: set[str] = set()
            if len(args) >= 2:
                arg2 = args[1].strip()
                # `params: <expr>` — strip the label.
                if arg2.startswith("params:"):
                    arg2 = arg2[len("params:"):].strip()
                if arg2.startswith("["):
                    # Dictionary literal: ["p_x": foo, "p_y": bar]
                    for m in APPLE_DICT_KEY_RE.finditer(arg2):
                        sent.add(m.group(1).lower())
                elif arg2.startswith("Params(") or "Params(" in arg2[:10]:
                    # Struct init: Params(p_x: foo, p_y: bar) — labels only.
                    inner_open = arg2.find("(")
                    inner = _balanced_extract(arg2, inner_open) if inner_open != -1 else ""
                    for m in APPLE_STRUCT_LABEL_RE.finditer(inner):
                        sent.add(m.group(1).lower())
                # EmptyBody() and other expressions → no params.
            sites.append(CallSite(
                rpc_name=name,
                sent_params=sent,
                file=rel,
                line=_line_no_of(text, head.start()),
            ))

        # ─── Pattern 2: direct-URL /rest/v1/rpc/<name> ─────────────────────
        for match in APPLE_RPC_URL_RE.finditer(text):
            name = match.group(1).lower()
            window = _surrounding_lines(text, match.start(), SCAN_WINDOW)
            # Scan the full forward window for quoted snake-case keys. Real
            # body dict keys (`"days":`, `"metrics":`) match; HTTP header
            # strings ("Content-Type", "Authorization") and type annotations
            # (`[String: Any]`) don't.
            sent = {m.group(1).lower() for m in APPLE_DICT_KEY_RE.finditer(window)}
            sites.append(CallSite(
                rpc_name=name,
                sent_params=sent,
                file=rel,
                line=_line_no_of(text, match.start()),
            ))
    return sites


def collect_python_call_sites() -> list[CallSite]:
    sites: list[CallSite] = []
    helper_dir = REPO / "helper"
    if not helper_dir.exists():
        return sites
    for path in sorted(helper_dir.glob("*.py")):
        # Skip test files — they may use mock RPC names like "test_function".
        if path.name.startswith("test_"):
            continue
        text = path.read_text(encoding="utf-8")
        rel = str(path.relative_to(REPO))
        for match in PY_RPC_RE.finditer(text):
            name = match.group(1).lower()
            body = match.group(2)
            sent = {m.group(1).lower() for m in PY_KEY_RE.finditer(body)}
            sites.append(CallSite(
                rpc_name=name,
                sent_params=sent,
                file=rel,
                line=_line_no_of(text, match.start()),
            ))
    return sites


def _balanced_extract(text: str, open_pos: int, open_ch: str = "(", close_ch: str = ")") -> str:
    """Return the substring strictly between the parens at `open_pos` and the
    matching close. Returns "" if no matching close before EOF.
    """
    if open_pos >= len(text) or text[open_pos] != open_ch:
        return ""
    depth = 0
    for i in range(open_pos, len(text)):
        ch = text[i]
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return text[open_pos + 1:i]
    return ""


def _split_top_level_comma(s: str) -> list[str]:
    """Split `s` on top-level commas, ignoring commas nested in (), [], {}."""
    parts: list[str] = []
    buf: list[str] = []
    depth = 0
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        parts.append("".join(buf))
    return parts


def _kotlin_walkback_for_val(text: str, ident: str, before_pos: int) -> str:
    """When an rpc call's 2nd arg is a bare identifier (`params`), look back
    in the same enclosing function for `val <ident> = JSONObject() ... { ... }`
    and return the brace-balanced body. Bounded by the start of the file or
    the most recent top-level `fun ` keyword.
    """
    head = text[:before_pos]
    # Bound the walk-back to the current function so we don't pick up a
    # variable from a sibling function with the same name.
    fun_marker = head.rfind("\n    fun ")
    if fun_marker == -1:
        fun_marker = head.rfind("\n    suspend fun ")
    if fun_marker == -1:
        fun_marker = 0
    region = head[fun_marker:]
    val_re = re.compile(KT_VAL_RE_TEMPLATE.format(name=re.escape(ident)))
    val_match = None
    for m in val_re.finditer(region):
        val_match = m  # take last match (closest to the rpc call)
    if val_match is None:
        return ""
    # From val_match.end(), capture everything up to the end of the chain.
    # Both `JSONObject().apply { ... }` and `JSONObject().put(...).put(...)`
    # patterns can be captured by reading until the next top-level `}` or
    # blank line — but balanced-brace from the first `{` after the val is
    # cleaner.
    tail = region[val_match.end():]
    brace_pos = tail.find("{")
    if brace_pos != -1:
        # apply { ... } form
        body = _balanced_extract(tail, brace_pos, "{", "}")
        return body
    # No `{` → JSONObject().put(...).put(...) chain — read to end-of-line
    # block (newline followed by non-indented content or another statement).
    eol = tail.find("\n\n")
    return tail if eol == -1 else tail[:eol]


def collect_kotlin_call_sites() -> list[CallSite]:
    sites: list[CallSite] = []
    android_root = REPO / "android" / "app" / "src" / "main"
    if not android_root.exists():
        return sites
    for path in sorted(android_root.rglob("*.kt")):
        text = path.read_text(encoding="utf-8")
        rel = str(path.relative_to(REPO))
        for head in KT_RPC_HEAD_RE.finditer(text):
            name = head.group(2).lower()
            # Find the `(` of the rpc call — `head` matched `rpc("name"`, so
            # the opening paren is between the call name and the string. Walk
            # to it from head.start().
            paren_pos = text.find("(", head.start(), head.end())
            if paren_pos == -1:
                continue
            balanced = _balanced_extract(text, paren_pos)
            args = _split_top_level_comma(balanced)
            sent: set[str] = set()
            if len(args) >= 2:
                arg2 = args[1].strip()
                # Case A: arg2 is an inline JSONObject expression — parse its
                # puts directly. The balanced extract already isolated us to
                # this rpc call's own argument list, so no neighbour-bleed.
                if "JSONObject" in arg2 or "put(" in arg2:
                    for m in KT_PUT_KEY_RE.finditer(arg2):
                        sent.add(m.group(1).lower())
                # Case B: arg2 is a bare identifier (e.g. `params`). Walk back
                # to its declaration within the enclosing function.
                elif re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", arg2):
                    body = _kotlin_walkback_for_val(text, arg2, head.start())
                    for m in KT_PUT_KEY_RE.finditer(body):
                        sent.add(m.group(1).lower())
                # Other expressions (e.g. literal `JSONObject()`) → no params.
            sites.append(CallSite(
                rpc_name=name,
                sent_params=sent,
                file=rel,
                line=_line_no_of(text, head.start()),
            ))
    return sites


# ─────────────────────────────────────────────────────────────────────────────
# Edge functions
# ─────────────────────────────────────────────────────────────────────────────


EDGE_REF_RE = re.compile(r'/functions/v1/([a-z][a-z0-9_-]+)')


def collect_edge_refs() -> set[tuple[str, str, int]]:
    refs: set[tuple[str, str, int]] = set()
    scan_targets: list[pathlib.Path] = []
    apple_dir = REPO / "CLI Pulse Bar" / "CLIPulseCore" / "Sources" / "CLIPulseCore"
    if apple_dir.exists():
        scan_targets.extend(sorted(apple_dir.rglob("*.swift")))
    android_root = REPO / "android" / "app" / "src" / "main"
    if android_root.exists():
        scan_targets.extend(sorted(android_root.rglob("*.kt")))

    for path in scan_targets:
        text = path.read_text(encoding="utf-8")
        rel = str(path.relative_to(REPO))
        for match in EDGE_REF_RE.finditer(text):
            refs.add((match.group(1), rel, _line_no_of(text, match.start())))
    return refs


# ─────────────────────────────────────────────────────────────────────────────
# Driver
# ─────────────────────────────────────────────────────────────────────────────


def main() -> int:
    sql_funcs = collect_sql_definitions()
    apple = collect_apple_call_sites()
    python = collect_python_call_sites()
    android = collect_kotlin_call_sites()
    all_sites = apple + python + android
    edge_refs = collect_edge_refs()

    failures: list[str] = []
    notes: list[str] = []

    # Check 1 + 2: every call site references a defined RPC and only sends
    # declared parameters.
    referenced_rpcs: set[str] = set()
    for site in all_sites:
        referenced_rpcs.add(site.rpc_name)
        sql = sql_funcs.get(site.rpc_name)
        if sql is None:
            failures.append(
                f"MISSING IN SQL: {site} calls rpc '{site.rpc_name}' but no "
                f"`create function public.{site.rpc_name}` exists in backend/supabase/"
            )
            continue
        unknown = sorted(p for p in site.sent_params if p not in sql.params)
        if unknown:
            failures.append(
                f"UNKNOWN PARAM: {site} sends {unknown} to '{site.rpc_name}' — "
                f"SQL signature is ({sorted(sql.params)}) at "
                f"backend/supabase/{sql.file}:{sql.line}"
            )

    # Check 3: every referenced edge function has a matching directory.
    edge_dir = ROOT / "functions"
    for name, src_file, src_line in sorted(edge_refs):
        if not (edge_dir / name).is_dir():
            failures.append(
                f"MISSING EDGE: {src_file}:{src_line} references "
                f"'/functions/v1/{name}' but backend/supabase/functions/{name}/ does not exist"
            )

    # Soft signal: SQL functions defined in backend/supabase/ with no client
    # referent. Never a hard failure — SQL may retain compatibility shims,
    # future RPCs, or helper-facing entry points used by external tooling.
    # Helper-facing RPCs are tagged so a reviewer can double-check intent.
    for name in sorted(sql_funcs):
        if name in INTERNAL_RPCS or name in referenced_rpcs:
            continue
        sql = sql_funcs[name]
        tag = "INFO (helper-facing)" if name in HELPER_RPCS else "INFO"
        notes.append(
            f"{tag}: SQL defines public.{name} at backend/supabase/{sql.file}:{sql.line} "
            f"but no client (Apple/helper/Android) currently calls it (not a failure)"
        )

    # ─── Output ───────────────────────────────────────────────────────────
    print(
        f"Scanned: {len(sql_funcs)} SQL function definitions, "
        f"{len(all_sites)} client call sites "
        f"({len(apple)} Apple, {len(python)} helper Python, {len(android)} Android), "
        f"{len(edge_refs)} edge function references"
    )
    print()

    if notes:
        for note in notes:
            print(f"  {note}")
        print()

    if failures:
        print(f"FAIL — {len(failures)} contract issue(s):")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print("OK — every client RPC call references a defined SQL function with valid parameter names.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
