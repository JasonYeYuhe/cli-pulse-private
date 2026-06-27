# PROJECT FIX — Drop orphaned anon-reachable `_debug_heartbeat_trace` (P0)

**Date:** 2026-06-27
**Train:** Backend trust hardening + supply-chain & decoder defense-in-depth — **PR1 (P0)**
**Branch:** `security/drop-debug-heartbeat-trace`
**Plan:** `DEV_PLAN_2026-06-27_nextphase_trust_hardening.md` §2 PR1

---

## Summary

Dropped the prod-only, never-committed debugging function
`public._debug_heartbeat_trace(p_device_id uuid, p_helper_secret text)`, an
**unauthenticated credential-material disclosure**.

## Root cause / severity (VERIFIED LIVE — prod `gkjwsxotmwrgqsvfijzs`, read-only)

| Property | Value (live, 2026-06-27) |
|---|---|
| `prosecdef` (SECURITY DEFINER) | `true` |
| `proacl` | `anon=X`, `authenticated=X`, `service_role=X` → EXECUTE granted to `anon` |
| Reachable | `POST /rest/v1/rpc/_debug_heartbeat_trace` **unauthenticated** |
| In tracked SQL? | **No** — prod-only ad-hoc debug helper, never in `backend/supabase/` |
| Repo callers | **Zero** (grep-clean across `*.sql`/`*.swift`/`*.py`/`*.ts`/`*.kt`) |

Live function body (from `pg_get_functiondef`):

```sql
v_hash := encode(digest(p_helper_secret, 'sha256'), 'hex');
select user_id, helper_secret into v_user_id, v_stored
from public.devices where id = p_device_id;
return jsonb_build_object(
  'device_found', v_user_id is not null,
  'v_user_id', v_user_id,
  'computed_hash', v_hash,
  'stored_hash', v_stored,            -- ← stored server-side credential material
  'hash_matches', v_hash = v_stored,
  'input_secret_length', length(p_helper_secret),
  'input_secret_prefix', left(p_helper_secret, 20)
);
```

It returns the device owner's `user_id` and the **stored** `helper_secret`
(`stored_hash`) for **any** `device_id`, **unconditionally** — the supplied
`p_helper_secret` is only echoed/hashed, never used as a gate. An unauthenticated
caller who enumerates/guesses a `device_id` (uuid) learns that device's owner
`user_id` and the stored helper-secret hash. Real anon disclosure.

Distinct from `helper_heartbeat(uuid, uuid)` — the vestigial overload that
`migrate_v0.57` already dropped. This object was never tracked, so the DROP is
also the first time it is acknowledged in version control.

## What changed

- **NEW** `backend/supabase/migrate_v0.58_drop_debug_heartbeat_trace.sql`
  — `drop function if exists public._debug_heartbeat_trace(uuid, text);`
  (idempotent, zero-risk: orphaned debug helper, `if exists` guard).

No client/code change — there are no callers.

## Verification checklist

- [x] Confirmed live: `SECURITY DEFINER` + `anon=X` EXECUTE + unconditional
      `stored_hash` return (read-only `pg_proc` / `pg_get_functiondef`).
- [x] Confirmed zero repo callers (grep `*.sql *.swift *.py *.ts *.kt`).
- [x] Confirmed distinct from `helper_heartbeat(uuid,uuid)` (v0.57).
- [x] Migration is drop-only → inert to all `supabase-ci.yml` static checks
      (search_path / rpc-contract / date-windows / alert-types / user-id-cascade
      scan `CREATE FUNCTION` bodies & contracts; same shape as v0.57 which passed).
- [ ] **Owner go-ahead** to apply to prod (flag-first schema change).
- [ ] Applied to prod; `pg_get_functiondef` returns no such function.
- [ ] `get_advisors(security)` no longer reports
      `anon_security_definer_function` for this object (re-baseline).
- [ ] CI green on PR.

## Notes / follow-ups

- Flag-first convention: the DROP is zero-risk (orphaned, no callers), but it is
  a prod schema change → owner one-word go-ahead recorded before prod apply.
- After apply, re-run `get_advisors(security)` to re-baseline the advisor set.
