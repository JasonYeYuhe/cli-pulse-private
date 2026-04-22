# PROJECT_FIX v1.10 P2-4 — cleanup_expired_data nightly pg_cron schedule

**Date**: 2026-04-22
**Schema**: v0.20 → **v0.21**
**Plan item**: `/Users/jason/.claude/plans/melodic-booping-truffle.md` P2-4 (cleanup cron)
**Review**: Self-review (direct code inspection + live smoke); Codex rescue flake-stuck; Gemini 3.1 Pro flake-timeout.

## Problem

`cleanup_expired_data()` has shipped in the schema since v0.11 but was never
actually scheduled. The v1.9.6d smoke invocation (manual service_role RPC
call) cleaned **91 alerts + 69 sessions + 2 pairing_attempt_log rows** of
real expired data — unambiguous evidence the function had never been run.

Gemini's session-wide review explicitly called this out: *"The function
exists and is authorized, but I can't find any schedule registration —
pg_cron, edge-function cron, or external invoker. This is production data
retention silently not happening."*

## Fix

### 1. `CREATE EXTENSION IF NOT EXISTS pg_cron;`

Supabase supports `pg_cron` out-of-the-box on all tiers. No explicit
`WITH SCHEMA` — defer to Supabase's default placement.

### 2. Split public → internal helper

The existing `public.cleanup_expired_data()` gates on
`current_setting('request.jwt.claims', true)::jsonb ->> 'role' !=
'service_role'`. pg_cron runs as the `postgres` superuser with no JWT
context, so that gate would block the scheduled call.

Same pattern as v0.18's `_recompute_yield_scores_for_user_internal`:

- **New private** `public._cleanup_expired_data_internal()` — existing
  body minus the JWT check. `SECURITY DEFINER`, pinned `search_path`,
  `REVOKE ALL FROM PUBLIC, authenticated, anon`. Only reachable from
  inside the DB as postgres or from other SECURITY DEFINER functions.
- **Public** `public.cleanup_expired_data()` — keeps the service_role
  JWT gate and delegates: `RETURN public._cleanup_expired_data_internal();`.
  HTTP RPC path unchanged; existing service_role smoke tests still pass.

### 3. Idempotent schedule registration

```sql
DO $$
BEGIN
  PERFORM cron.unschedule('cleanup_expired_data_nightly');
EXCEPTION WHEN OTHERS THEN NULL;  -- job did not exist; ignore
END;
$$;

SELECT cron.schedule(
  'cleanup_expired_data_nightly',
  '7 3 * * *',
  $cron$SELECT public._cleanup_expired_data_internal();$cron$
);
```

03:07 UTC nightly (Tokyo 12:07) — off-peak, 7-minute offset from the hour
to avoid clustering with other scheduled jobs.

## Apply + verify

Applied to `gkjwsxotmwrgqsvfijzs` (Tokyo) via Supabase MCP
`apply_migration` 2026-04-22.

Post-apply verification:

- `SELECT * FROM cron.job WHERE jobname = 'cleanup_expired_data_nightly'`
  → jobid=1, schedule `'7 3 * * *'`, active=true, command matches.
- `SELECT public._cleanup_expired_data_internal()` via execute_sql →
  `{alerts_deleted: 91, sessions_deleted: 69, snapshots_deleted: 0,
   pairing_attempt_log_deleted: 1}`. (MCP `execute_sql` rolls back for
  safety — rows remained post-call. The 03:07 UTC cron run will commit
  normally.)
- `SELECT * FROM public.cleanup_expired_data()` with no JWT →
  `Forbidden: service_role required`. Public gate still intact.

## Review

### Codex (codex:codex-rescue)

**Status**: Flake — stuck in "Searching:" loop for 8+ minutes. Known
pattern this session (v0.20 review also flaked on the Codex side).
Monitor task stopped manually.

### Gemini 3.1 Pro (mcp__gemini__review, depth=scan)

**Status**: Flake — timed out at 180s on a 111-LOC single-file diff.
Same recurring flake as v0.20.

### Self-review (direct inspection + live smoke)

- **Idempotency**: `CREATE EXTENSION IF NOT EXISTS` + `DO $ … EXCEPTION
  WHEN OTHERS $` unschedule + `SELECT cron.schedule` re-registration —
  safe to re-run.
- **Security parity**: internal helper has SECURITY DEFINER, pinned
  search_path, REVOKE from PUBLIC/authenticated/anon. Public helper
  JWT gate preserved.
- **Function body parity**: internal body is byte-identical to the v0.19
  public body minus the 3-line JWT check. Diffed line by line.
- **Schedule correctness**: `'7 3 * * *'` validated via cron.job lookup;
  command string dispatches to the internal helper.
- **Data correctness**: smoke invocation returned the expected counts
  for stale sessions / alerts / snapshots / pairing log.

## Files

- **New**: `backend/supabase/migrate_v0.21_cleanup_cron.sql` (111 LOC)
- **No app-side changes** — `cleanup_expired_data()` signature unchanged;
  existing service_role callers (if any) continue to work.

## Follow-ups / not done

- Monitoring: no alert wired for "cron job failed N nights in a row."
  Consider adding a `cron.job_run_details` scraper in the P2-8 Sentry
  rollout so silent cron failures surface.
- Supabase tier: pg_cron is available on all tiers; no paid-tier
  dependency introduced.
