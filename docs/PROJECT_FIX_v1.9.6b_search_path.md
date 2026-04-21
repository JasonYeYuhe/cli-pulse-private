# PROJECT_FIX v1.9.6b — P0-3: SECURITY DEFINER search_path hardening

**Date**: 2026-04-21
**Scope**: Supabase backend only (Swift/Android/iOS untouched)
**Incident class**: advisor WARN → self-inflicted production runtime break → hotfix
**Reviewers**: Codex rescue (2 passes), Gemini 3.1 Pro (1 partial pass)

---

## Why

Supabase advisor reported `function_search_path_mutable` (lint 0011) on all 20
of our `SECURITY DEFINER` public functions plus `rls_auto_enable` (pre-pinned).
A caller that can `SET search_path` before invocation could shadow built-in
names with objects in `public` and escalate inside the definer's context.

The P0-3 task in `/Users/jason/.claude/plans/melodic-booping-truffle.md`:

> P0-3 `SECURITY DEFINER` functions 缺 `SET search_path` — 独立 hotfix

---

## What changed (final state)

1. **New migrations**
   - `backend/supabase/migrate_v0.17_search_path_hardening.sql` — original pin
     `public, pg_catalog` on 20 functions. **Superseded same day** — see
     incident below. Kept for audit history with a header pointer.
   - `backend/supabase/migrate_v0.17.1_search_path_hotfix.sql` — corrected pin
     `pg_catalog, public, extensions` on the same 20 functions.

2. **Canonical SQL embedded pin**
   All `CREATE OR REPLACE FUNCTION ... SECURITY DEFINER` sources now carry
   `SET search_path = pg_catalog, public, extensions` inside the function
   attribute block, so any future redeploy from these files re-pins the
   function rather than silently dropping the hardening:

   - `backend/supabase/helper_rpc.sql` (3 functions: register_helper,
     helper_heartbeat, helper_sync)
   - `backend/supabase/app_rpc.sql` (13 functions: dashboard_summary,
     provider_summary, get_user_tier, delete_user_account,
     cleanup_expired_data, evaluate_budget_alerts, create_team, team_details,
     invite_member, accept_invite, remove_member, update_member_role,
     team_usage_summary)
   - `backend/supabase/migrate_v0.14_yield_score.sql` (2 functions:
     recompute_yield_scores_for_user, ingest_commits)
   - `backend/supabase/migrate_v0.15_track_git_activity.sql` (1:
     get_track_git_activity)
   - `backend/supabase/migrate_v0.16_register_helper_hardening.sql` (1:
     register_helper — replaces helper_rpc.sql definition on v0.16 apply)

3. **Live Supabase DB state (project gkjwsxotmwrgqsvfijzs, Tokyo)**
   All 20 live `SECURITY DEFINER` public functions now report
   `search_path=pg_catalog, public, extensions` via `pg_proc.proconfig`.
   `rls_auto_enable` remains on its original `pg_catalog`-only pin.
   Advisor returns 0 `function_search_path_mutable` lints.

---

## Incident: v0.17 → v0.17.1 same-day hotfix

**What broke**: v0.17 used `SET search_path = public, pg_catalog`. That pin is
what Supabase's own lint 0011 remediation example suggests.

On Supabase, pgcrypto lives in the `extensions` schema, not `pg_catalog`. Three
functions call `gen_random_bytes` / `digest` unqualified:

- `register_helper` — uses both for helper-secret generation and hashing
- `helper_sync` — uses `digest()` to verify `p_helper_secret`
- `get_track_git_activity` — same digest verification pattern

With the v0.17 pin applied those calls resolved as
`ERROR 42883: function gen_random_bytes(integer) does not exist`. Helpers
syncing every 30s would all have failed starting at v0.17 apply time.

**How it was caught**: Codex rescue review (first pass) flagged unqualified
pgcrypto references as a potential break vector. I verified empirically by
creating a throwaway function with the v0.17 pin and calling `gen_random_bytes`
— got `42883` as predicted.

**Detection gap that matters**: the Supabase advisor kept reporting green
after v0.17 because lint 0011 checks *presence of a pin*, not whether the pin
resolves every symbol the function calls. A working advisor scan is not
sufficient acceptance criteria for this class of change.

**Fix**: migration v0.17.1 re-pins all 20 functions to
`pg_catalog, public, extensions`:
- `pg_catalog` first — built-ins cannot be shadowed by `public`-created
  objects (Codex recommendation carried into hotfix)
- `public` — our app tables
- `extensions` — pgcrypto and friends, so unqualified calls still resolve

**Smoke verification post-hotfix**:

| Test vector | Expected | Observed |
|---|---|---|
| `register_helper('BADCOD', ...)` via PostgREST anon | 200 `{error:invalid_code}` (reaches `pg_advisory_xact_lock` + insert path) | ✅ |
| `helper_sync(random_uuid, 'fake', [],[],{},{})` | fails AFTER digest() resolves, at `line 16 RAISE "Device not found"` | ✅ |
| `get_track_git_activity(random_uuid, 'fake')` | same — digest resolves, business-layer rejects | ✅ |
| Supabase advisor `function_search_path_mutable` count | 0 | 0 |
| Throwaway function with new pin calling `gen_random_bytes` | executes | returns hex |

---

## Scope decisions (explicit non-goals)

The Supabase advisor also flags these issues on our project. **They are
deliberately out of scope for v1.9.6b** and will be handled separately:

- `security_definer_view` on `provider_usage_week` / `provider_usage_today`
  (ERROR) — these are views, not functions; require `CREATE VIEW ... WITH
  (security_invoker = true)` treatment. Pre-existing issue.
- `rls_policy_always_true` on `public.subscriptions` (WARN) — permissive
  service-role policy. Pre-existing and used by webhook ingest.
- `auth_leaked_password_protection` (WARN) — enable HIBP check in auth
  settings (dashboard action, not SQL).
- `rls_enabled_no_policy` on `public.pairing_attempt_log` (INFO) — new table
  from v0.16, intentionally only accessed via the SECURITY DEFINER
  `register_helper`. No policy = no non-definer access, which is the desired
  behavior. Could be made explicit with a `CREATE POLICY ... USING (false)`
  to quiet the lint; defer.

Also **not done in this fix**:

- Did not schema-qualify `digest(...)` / `gen_random_bytes(...)` inside the
  three callers (keep blast radius minimal). If we later want to remove
  `extensions` from search_path entirely, this follow-up is prerequisite.
- Did not retro-pin `schema.sql`, `migrate_v0.2.sql`, `migrate_v0.4.sql`,
  `migrate_v0.9.sql`, `migrate_v0.10.sql`, `migrate_v0.11.sql`. These contain
  older `SECURITY DEFINER` definitions of functions whose current live
  versions are governed by the newer migrations and v0.17.1. Re-running an
  old file would un-pin until the next `v0.17.1` replay. Tracked as follow-up.

---

## Follow-ups (not blocking v1.9.6b ship)

1. **P0.5 Supabase CI**: advisor check as a PR gate would have caught the
   v0.17 → v0.17.1 fragility earlier. Already scheduled as P0.5-2.
2. **pgTAP coverage for `search_path` pin**: assert that each live
   `SECURITY DEFINER` function has a non-empty `pg_proc.proconfig` matching
   our policy.
3. **Schema-qualify pgcrypto calls** across helper_rpc.sql and migrations so
   `extensions` can drop out of search_path.
4. **Retro-patch older migrations / schema.sql** so a full re-replay from
   an empty DB produces the hardened state without requiring v0.17.1.

---

## Files changed

```
backend/supabase/migrate_v0.17_search_path_hardening.sql     (new, superseded)
backend/supabase/migrate_v0.17.1_search_path_hotfix.sql      (new, live)
backend/supabase/helper_rpc.sql                              (3 occurrences re-pinned)
backend/supabase/app_rpc.sql                                 (13 occurrences re-pinned)
backend/supabase/migrate_v0.14_yield_score.sql               (2 occurrences re-pinned)
backend/supabase/migrate_v0.15_track_git_activity.sql        (1 re-pinned)
backend/supabase/migrate_v0.16_register_helper_hardening.sql (1 re-pinned)
docs/PROJECT_FIX_v1.9.6b_search_path.md                      (this doc)
```

No client-side (Swift / Python / Android) changes.

---

## Verification residue check

```
$ rg -n "search_path = public, pg_catalog" backend/supabase/
(migrate_v0.17 comment only — no live CREATE/ALTER references)

$ rg -n "search_path = pg_catalog, public, extensions" backend/supabase/ | wc -l
40   # 3 + 13 + 2 + 1 + 1 + 20 in hotfix = 40
```

Live DB (from `pg_proc.proconfig`): 20/20 functions pin
`pg_catalog, public, extensions`; `rls_auto_enable` keeps its pre-existing
`pg_catalog` pin. Advisor `function_search_path_mutable` count: 0.

---

## Review audit trail

- **Codex rescue, pass 1 (pre-hotfix)** — flagged unqualified pgcrypto as a
  likely break vector; recommended `pg_catalog`-first ordering. Both
  findings actioned in v0.17.1.
- **Gemini 3.1 Pro, focused (pre-hotfix)** — partial response, timed out;
  consumed chunk 1/4. Did not surface the pgcrypto risk before the timeout.
  Not rerun post-hotfix given Codex v2 already cycled and the empirical
  smoke tests pass.
- **Codex rescue, pass 2 (post-hotfix)** — task ran, intermediate findings
  captured (canonical files correctly updated, pgcrypto schema not declared
  in repo, older migrations remain un-pinned). Terminated before a final
  verdict message flushed, but all intermediate findings align with the
  non-blocking follow-ups listed above.
