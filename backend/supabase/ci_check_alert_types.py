#!/usr/bin/env python3
"""
Webhook type-filter alias drift guard.

Static, read-only. Walks every place where an alert.type literal is
emitted (AlertGenerator.swift, DemoDataProvider.swift, DataRefreshManager.swift,
app_rpc.sql) AND scans the canonical `enum AlertType` cases in Models.swift.
Asserts each value is reachable through the `TYPE_ALIASES` map in the
`send-webhook` edge function — OR is explicitly listed in
WEBHOOK_INELIGIBLE here with a written reason.

Why this exists
---------------
The webhook edge function filters alerts by user-selected slugs
(`cost_spike|quota_exceeded|session_long|device_offline`), which the UI
stores. Real `alert.type` strings are human-readable ("Cost Spike",
"Helper Offline", ...). For ~6 months the edge function did exact-string
`includes` of the slug list against the human type, silently dropping
every alert when any user enabled a type filter (Plan v2 Change 1).
The fix is a slug→type alias map. This script catches future
regressions: any new alert.type that isn't covered by some alias-map
value (or explicitly marked non-webhook-eligible) fails CI.

Iter2 follow-up (Codex + Gemini both flagged):
  - Old version filtered emitted types through a hard-coded allow-list,
    which meant a new alert type was SILENTLY ignored unless someone
    edited the script. Now we fail on unknown types unless they're
    explicitly opted out via WEBHOOK_INELIGIBLE.
  - Old version skipped Models.swift's AlertType enum. Now scanned.

Exit codes
----------
0 — every emitted alert.type appears in TYPE_ALIASES (or WEBHOOK_INELIGIBLE)
1 — unknown emitted alert.type detected, fix TYPE_ALIASES (or opt out)
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]

# Types that exist but are deliberately NOT routed through webhooks.
# Each entry must include a one-line reason. Adding to this set is
# explicit opt-out, not silent ignore.
WEBHOOK_INELIGIBLE: dict[str, str] = {
    "Test": "test-webhook flow only; edge skips it explicitly",
    # AlertType enum cases that don't have a real emitter today.
    # Listed so the cascade `Models.swift → emitted types` doesn't
    # block CI on declarations the rest of the codebase doesn't actually
    # produce. Re-evaluate when an emitter is added.
    "Quota Low": "AlertType case declared but no emitter found in 2026-04-27 audit",
    "Sync Failed": "AlertType case declared but no emitter found in 2026-04-27 audit",
    "Auth Expired": "AlertType case declared but no emitter found in 2026-04-27 audit",
    "Session Failed": "AlertType case declared but no emitter found in 2026-04-27 audit",
    "Error Rate Spike": "AlertType case declared but no emitter found in 2026-04-27 audit",
    "Quota Critical": "AlertType case declared but no emitter found in 2026-04-27 audit",
}


def collect_emitted_types() -> set[str]:
    """Grep the repo for emitted alert.type strings AND AlertType enum cases."""
    found: set[str] = set()

    # Swift dict-literal: "type": "..."
    swift_dict_pat = re.compile(r'"type"\s*:\s*"([^"]+)"')
    for rel in [
        "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertGenerator.swift",
    ]:
        path = REPO / rel
        if not path.exists():
            continue
        for m in swift_dict_pat.finditer(path.read_text()):
            found.add(m.group(1))

    # Swift call-site: AlertRecord(... type: "...", ...)
    swift_call_pat = re.compile(r'\btype:\s*"([^"]+)"')
    for rel in [
        "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DemoDataProvider.swift",
        "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift",
    ]:
        path = REPO / rel
        if not path.exists():
            continue
        for m in swift_call_pat.finditer(path.read_text()):
            v = m.group(1)
            # Drop obvious non-AlertType strings (Slack block kit etc.).
            # AlertType strings are Title Case with optional spaces; the
            # heuristic is "starts with uppercase, contains either space
            # or is a single capitalised word".
            if v and v[0].isupper():
                found.add(v)

    # Swift enum: case <ident> = "<value>"  inside `enum AlertType`.
    # Match the enum block first, then case lines within it. This avoids
    # picking up the 30+ ProviderKind cases that share the file.
    models_path = REPO / "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Models.swift"
    if models_path.exists():
        text = models_path.read_text()
        # Extract the AlertType enum body. Greedy match up to the next
        # `^}` at column 0 — Swift enums conventionally close at column 0.
        m = re.search(
            r"public\s+enum\s+AlertType\s*:[^{]*\{(?P<body>.*?)\n\}",
            text, re.DOTALL,
        )
        if m:
            for cm in re.finditer(r'case\s+\w+\s*=\s*"([^"]+)"', m.group("body")):
                found.add(cm.group(1))

    # SQL inserts into public.alerts. Match the literal type column inside
    # `insert into public.alerts ... values ( <id>, <user>, '<TYPE>', ... )`.
    sql_alert_pat = re.compile(
        r"insert\s+into\s+public\.alerts[^;]*?values[^;]*?\(\s*[^,]*,\s*[^,]*,\s*'([^']+)'",
        re.IGNORECASE | re.DOTALL,
    )
    for rel in ["backend/supabase/app_rpc.sql"]:
        path = REPO / rel
        if not path.exists():
            continue
        for m in sql_alert_pat.finditer(path.read_text()):
            found.add(m.group(1))

    # Filter out clearly-not-AlertType strings (lowercase, contains _,
    # too short, or matches Slack block kit primitives).
    bad_lower = {"header", "section", "context", "mrkdwn", "plain_text", "fields"}
    return {t for t in found if t not in bad_lower and "_" not in t}


def collect_alias_values() -> set[str]:
    """Parse TYPE_ALIASES from send-webhook/index.ts and return all values."""
    path = REPO / "backend/supabase/functions/send-webhook/index.ts"
    text = path.read_text()
    block = re.search(r"TYPE_ALIASES[^=]*=\s*\{(.+?)\};", text, re.S)
    if not block:
        print(f"FAIL: TYPE_ALIASES map not found in {path}", file=sys.stderr)
        sys.exit(1)
    return set(re.findall(r'"([^"]+)"', block.group(1)))


def main() -> int:
    emitted = collect_emitted_types()
    aliased = collect_alias_values()

    required = emitted - set(WEBHOOK_INELIGIBLE.keys())
    missing = required - aliased

    if missing:
        print(
            "FAIL: alert.type strings emitted by the codebase are not reachable "
            "through TYPE_ALIASES in backend/supabase/functions/send-webhook/index.ts:",
            file=sys.stderr,
        )
        for t in sorted(missing):
            print(f"  - {t!r}", file=sys.stderr)
        print(
            "\nFix one of:\n"
            "  - Add the value to a slug array in TYPE_ALIASES (covers webhook delivery).\n"
            "  - Add it to WEBHOOK_INELIGIBLE in this script with a written reason\n"
            "    (signals: this alert exists but should not fan out via webhook).",
            file=sys.stderr,
        )
        return 1

    # Soft signal: aliased values that don't appear in the codebase. May
    # indicate dead aliases or types that have been renamed.
    stale = aliased - emitted
    for t in sorted(stale):
        print(f"  INFO: TYPE_ALIASES contains {t!r} but no emitter was found")

    print(
        f"ok: {len(required)} emitted alert.type strings all covered by "
        f"TYPE_ALIASES; {len(WEBHOOK_INELIGIBLE)} explicitly opted out"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
