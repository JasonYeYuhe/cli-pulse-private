# PROJECT_FIX v1.10.7 — P3-5: GDPR 18-month retention + coalesce JWT-gate hardening

**Date:** 2026-04-22
**Commit:** (pending)
**Schema:** v0.21 → v0.22 (applied live)
**Scope:** Add a global 18-month data-retention policy for the long-tail
analytical tables (commits, sessions, session_commit_links,
daily_usage_metrics, yield_score_daily) via a new pg_cron job. As a
Gemini-caught drive-by, also harden the `cleanup_expired_data` +
`cleanup_retention_data` public wrappers against a NULL-gate silent-bypass
on direct-DB invocations.

## Shipped

### New migration
`backend/supabase/migrate_v0.22_retention_cron.sql` — applied live as
`v0_22_retention_cron`.

**`public._cleanup_retention_data_internal(p_retention_months int = 18)`**
— SECURITY DEFINER, pinned `search_path = pg_catalog, public, extensions`,
REVOKE'd from PUBLIC/authenticated/anon. Deletes in this order (FK-safe,
audited against pg_constraint on 2026-04-22):

1. `commits` WHERE `committed_at` < cutoff. FK
   `session_commit_links.commit_id` is ON DELETE CASCADE — link rows
   prune automatically.
2. `session_commit_links` WHERE `session_id` ∈ expired sessions. **There
   is NO FK cascade** from `sessions.id` → `session_commit_links.session_id`,
   so this explicit cleanup must happen before the session delete
   (otherwise orphan link rows leak).
3. `sessions` WHERE `last_active_at` < cutoff (same anchor yield-score
   ingest uses).
4. `daily_usage_metrics` WHERE `metric_date` < cutoff::date.
5. `yield_score_daily` WHERE `day` < cutoff::date.

Returns a `jsonb` summary with per-table delete counts + cutoff timestamp
+ retention-months echoed back.

**`public.cleanup_retention_data(int = 18)`** — public wrapper with
service_role JWT gate; delegates to the internal helper. Same pattern as
v0.21's `cleanup_expired_data` split.

**`cron.schedule('retention_cleanup_nightly', '27 3 * * *', ...)`** —
runs 03:27 UTC nightly, 20 minutes after v0.21's
`cleanup_expired_data_nightly` (03:07 UTC) so the two DELETE passes
don't compete for locks. Idempotent via `cron.unschedule` + `EXCEPTION
WHEN OTHERS THEN NULL`.

### Hardening (Gemini-caught drive-by)
First-pass Gemini flagged: `current_setting('request.jwt.claims', true)`
returns NULL for direct DB connections (outside PostgREST). `NULL !=
'service_role'` evaluates to NULL, and PL/pgSQL's `IF` treats NULL as
FALSE — silently bypassing the gate. Any Postgres user with direct DB
access could invoke the internal helper through the public wrapper. Fix:
wrap the role extraction in `coalesce(..., '')` in **both** wrappers
(the new `cleanup_retention_data` and the existing v0.21
`cleanup_expired_data`, which had the identical bug). Applied live via
a second `apply_migration` step (`v0_22b_coalesce_jwt_gates`).

**Note:** pg_cron bypasses the wrapper entirely (it invokes
`_cleanup_*_internal()` directly, as postgres superuser), so the cron
paths were never affected. The wrapper gate exists for HTTP RPC
operator invocations; this fix is defense-in-depth, not a crit.

### PRIVACY.md
Updated "Data retention" section + bumped last-updated date to April 22,
2026:
- Explicit 18-month rolling history callout for Supabase-stored metrics
- Named the 5 affected tables
- Clarified user-override behavior (if `user_settings.data_retention_days`
  is shorter, v0.21's per-user cron wins for sessions/alerts/snapshots;
  the global 18-month job applies to the analytical long tail)

### Smoke test (live)
- `public._cleanup_retention_data_internal(360)` returned all-zero
  counters with cutoff at 1996-04-22 — function works, nothing to delete
  for a 30-year retention window (expected; project is ~1 year old).
- `SELECT jobid, jobname, schedule, active FROM cron.job` lists 2 active
  jobs: `cleanup_expired_data_nightly` (03:07) + `retention_cleanup_nightly`
  (03:27). ✓
- Post-patch `pg_proc.prosrc LIKE '%coalesce%'` check confirms both
  public wrappers carry the fix.

## Review verdict
- **Codex codex-rescue:** not invoked this slice (session-long flake
  pattern; Gemini was available and reliable).
- **Gemini 3.1 Pro scan (first pass):** flagged the NULL-gate issue at
  line ~118. Fixed in both `cleanup_retention_data` AND v0.21's
  `cleanup_expired_data`.
- **Gemini 3.1 Pro scan (second pass):** **SHIP** — "No bugs, security
  vulnerabilities, or performance issues found. Excellent work including
  the detailed inline comments documenting the rationale and FK
  dependencies."

## Baselines
- `execute_sql` smoke: retention helper returned well-formed jsonb ✓
- cron.job: 2 active jobs at 03:07 + 03:27 UTC ✓
- `search_path` advisor: unchanged (new functions include pinned
  `search_path`) ✓
- No app-side code touched; no Xcode/Swift baseline runs needed.

## Why this matters
- GDPR data-minimization: we've been storing commits/sessions
  indefinitely. 18 months covers YoY cost comparison + 1 mo buffer;
  beyond that, no product value in retaining the detail.
- Sibling to v0.21: v0.21 prunes per-user (user-controlled
  `data_retention_days`) operational data. v0.22 is a global,
  account-independent hard limit on the analytical long tail that
  individual users can't override. Both jobs coexist.
- Defense-in-depth on the wrapper gate closes a theoretical bypass that
  pre-dated this session (present since v0.11 for cleanup_expired_data).

## Follow-ups / not done here
- **P2-8** Sentry observability baseline (blocked on user-supplied DSN).
- **P3-4** Watch quota alert UI verification (light smoke, then decide).
- **P3-3** Accessibility pass (macOS 4 labels → full HIG compliance).
- **P3-2** L10n + Japanese/Spanish scaffold.
- After 30 days, sanity-check `cron.job_run_details` to verify the new
  job has been running reliably.
