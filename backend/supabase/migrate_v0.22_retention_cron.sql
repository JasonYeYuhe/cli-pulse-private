-- Migration v0.22: GDPR 18-month data retention (P3-5)
--
-- Background:
--   `commits`, `sessions`, `daily_usage_metrics`, and `yield_score_daily`
--   have no retention policy — rows accumulate indefinitely. GDPR data-
--   minimization best practice (and the v1.10 plan's P3-5 item) is to
--   retain historical rows for no longer than is needed for the product's
--   analytical window. 18 months covers year-over-year cost comparisons
--   with one month of buffer.
--
--   Separate from v0.21's `cleanup_expired_data_nightly` (which enforces
--   per-user `user_settings.data_retention_days` on sessions/alerts/
--   snapshots/pairing log) — this one is a global, account-independent
--   hard limit on the long-tail analytical tables.
--
-- Fix: install a separate pg_cron job `retention_cleanup_nightly` that
--   runs 20 minutes after the v0.21 job (03:27 UTC), executing a new
--   `_cleanup_retention_data_internal()` helper.
--
-- Delete order + rationale (table FK structure audited 2026-04-22):
--   1. `commits` by `committed_at` < cutoff. FK on
--      `session_commit_links.commit_id` is ON DELETE CASCADE — deleting a
--      commit prunes its link rows automatically.
--   2. `session_commit_links` for expired sessions. There is NO FK cascade
--      from `sessions` → `session_commit_links.session_id`, so this must
--      be done explicitly before the session delete (otherwise orphan
--      links leak).
--   3. `sessions` by `last_active_at` < cutoff. `last_active_at` is the
--      canonical activity anchor (also what yield-score ingest derives
--      affected days from).
--   4. `daily_usage_metrics` by `metric_date` < cutoff::date.
--   5. `yield_score_daily` by `day` < cutoff::date. (The user_id FK to
--      profiles cascades on profile delete, which is unrelated — this is
--      a per-day retention cut.)
--
-- Steady-state scope: after the first backfill run (if there's already
-- >18-month data, which there likely isn't yet since the project is ~1 yr
-- old), nightly runs only remove ~1 day of newly-expired rows per table,
-- so no batching or lock-shedding is needed.
--
-- The cron job calls the internal helper directly; the public
-- `cleanup_retention_data()` wrapper preserves the service_role JWT gate
-- for manual operator invocations via HTTP RPC (same pattern as v0.21).

-- Step 1: internal helper (no JWT gate, REVOKE'd from PUBLIC/authenticated/
-- anon, callable from pg_cron's postgres superuser or from the public
-- wrapper below).
CREATE OR REPLACE FUNCTION public._cleanup_retention_data_internal(
  p_retention_months integer DEFAULT 18
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
DECLARE
  v_cutoff_ts timestamptz := now() - (p_retention_months || ' months')::interval;
  v_cutoff_date date := (v_cutoff_ts)::date;
  v_commits_deleted integer := 0;
  v_links_deleted integer := 0;
  v_sessions_deleted integer := 0;
  v_usage_deleted integer := 0;
  v_yield_deleted integer := 0;
BEGIN
  IF p_retention_months < 1 THEN
    RAISE EXCEPTION '_cleanup_retention_data_internal: retention_months must be >= 1, got %', p_retention_months;
  END IF;

  -- 1. Old commits. ON DELETE CASCADE on session_commit_links.commit_id
  --    prunes the corresponding link rows in the same statement.
  DELETE FROM public.commits
  WHERE committed_at < v_cutoff_ts;
  GET DIAGNOSTICS v_commits_deleted = ROW_COUNT;

  -- 2. Orphan links for expired sessions (no FK cascade from sessions).
  DELETE FROM public.session_commit_links
  WHERE session_id IN (
    SELECT id FROM public.sessions
    WHERE last_active_at < v_cutoff_ts
  );
  GET DIAGNOSTICS v_links_deleted = ROW_COUNT;

  -- 3. Expired sessions themselves.
  DELETE FROM public.sessions
  WHERE last_active_at < v_cutoff_ts;
  GET DIAGNOSTICS v_sessions_deleted = ROW_COUNT;

  -- 4. Old daily_usage_metrics rows.
  DELETE FROM public.daily_usage_metrics
  WHERE metric_date < v_cutoff_date;
  GET DIAGNOSTICS v_usage_deleted = ROW_COUNT;

  -- 5. Old yield_score_daily rows.
  DELETE FROM public.yield_score_daily
  WHERE day < v_cutoff_date;
  GET DIAGNOSTICS v_yield_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'retention_months', p_retention_months,
    'cutoff', v_cutoff_ts,
    'commits_deleted', v_commits_deleted,
    'session_commit_links_deleted', v_links_deleted,
    'sessions_deleted', v_sessions_deleted,
    'daily_usage_metrics_deleted', v_usage_deleted,
    'yield_score_daily_deleted', v_yield_deleted
  );
END;
$$;

REVOKE ALL ON FUNCTION public._cleanup_retention_data_internal(integer)
  FROM PUBLIC, authenticated, anon;

-- Step 2: public entrypoint for operator-triggered runs (service_role gate).
-- Mirrors the v0.21 split.
CREATE OR REPLACE FUNCTION public.cleanup_retention_data(
  p_retention_months integer DEFAULT 18
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
BEGIN
  -- coalesce: current_setting() returns NULL when called outside PostgREST
  -- (e.g. direct DB connection, no JWT claim). `NULL != 'service_role'`
  -- evaluates to NULL, which PL/pgSQL's IF treats as FALSE, silently
  -- bypassing the gate. coalesce to empty string so the comparison is
  -- always three-valued-safe. Gemini 3.1 Pro review 2026-04-22.
  IF coalesce(
       current_setting('request.jwt.claims', true)::jsonb ->> 'role',
       ''
     ) != 'service_role' THEN
    RAISE EXCEPTION 'Forbidden: service_role required';
  END IF;
  RETURN public._cleanup_retention_data_internal(p_retention_months);
END;
$$;

-- Step 2.1: harden the v0.21 `cleanup_expired_data` public wrapper with
-- the same coalesce fix. Same NULL-gate bug: if invoked via a direct DB
-- connection, `current_setting('request.jwt.claims', true)` is NULL, so
-- `NULL != 'service_role'` is NULL, PL/pgSQL's IF treats NULL as FALSE,
-- and the gate is silently bypassed. Fix in-place here to keep the
-- sibling functions consistent (Gemini review 2026-04-22).
CREATE OR REPLACE FUNCTION public.cleanup_expired_data()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
BEGIN
  IF coalesce(
       current_setting('request.jwt.claims', true)::jsonb ->> 'role',
       ''
     ) != 'service_role' THEN
    RAISE EXCEPTION 'Forbidden: service_role required';
  END IF;
  RETURN public._cleanup_expired_data_internal();
END;
$$;

-- Step 3: schedule 03:27 UTC nightly — 20 minutes after
-- cleanup_expired_data_nightly (03:07 UTC) so the two jobs don't compete
-- for DELETE locks. Idempotent: unschedule first.
DO $$
BEGIN
  PERFORM cron.unschedule('retention_cleanup_nightly');
EXCEPTION WHEN OTHERS THEN
  -- job did not exist; ignore
  NULL;
END;
$$;

SELECT cron.schedule(
  'retention_cleanup_nightly',
  '27 3 * * *',
  $cron$SELECT public._cleanup_retention_data_internal(18);$cron$
);
