-- Migration v0.21: schedule cleanup_expired_data nightly via pg_cron
--
-- Background (see v1.9.6d archive + Gemini review):
--   cleanup_expired_data has been in production since v0.11 but was never
--   actually scheduled. v1.9.6d smoke call cleaned 91 alerts + 69 sessions +
--   2 pairing_attempt_log rows of real expired data — confirming it had not
--   been running.
--
-- Fix: install pg_cron and register a nightly job. Because the existing
--   public cleanup_expired_data gates on the service_role JWT claim (which
--   pg_cron does not set), we split out an internal helper without the JWT
--   check — same pattern as _recompute_yield_scores_for_user_internal.
--
--   1. Enable pg_cron extension (Supabase-supported).
--   2. New private `_cleanup_expired_data_internal()` = existing body
--      minus the JWT gate; EXECUTE revoked from PUBLIC/authenticated/anon.
--   3. Public `cleanup_expired_data()` continues to gate service_role and
--      delegates to the internal helper (so the HTTP RPC path is unchanged).
--   4. cron.schedule job 'cleanup_expired_data_nightly' runs 03:07 UTC
--      daily, invoking the internal helper as the postgres role.

-- Step 1: enable pg_cron. Supabase installs it in pg_catalog by default;
-- no explicit WITH SCHEMA to stay portable across Supabase tiers.
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Step 2: internal helper — no JWT gate, callable only inside the DB by
-- SECURITY DEFINER context (pg_cron runs as postgres superuser which
-- bypasses the REVOKE, so the schedule still works).
CREATE OR REPLACE FUNCTION public._cleanup_expired_data_internal()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
DECLARE
  v_user RECORD;
  v_total_sessions integer := 0;
  v_total_alerts integer := 0;
  v_total_snapshots integer := 0;
  v_pairing_log_deleted integer := 0;
  v_deleted integer;
BEGIN
  FOR v_user IN
    SELECT us.user_id, us.data_retention_days
    FROM public.user_settings us
    WHERE us.data_retention_days > 0
  LOOP
    BEGIN
      DELETE FROM public.sessions
      WHERE user_id = v_user.user_id
        AND status = 'Ended'
        AND last_active_at < now() - (v_user.data_retention_days || ' days')::interval;
      GET DIAGNOSTICS v_deleted = ROW_COUNT;
      v_total_sessions := v_total_sessions + v_deleted;

      DELETE FROM public.alerts
      WHERE user_id = v_user.user_id
        AND created_at < now() - (v_user.data_retention_days || ' days')::interval;
      GET DIAGNOSTICS v_deleted = ROW_COUNT;
      v_total_alerts := v_total_alerts + v_deleted;

      DELETE FROM public.device_snapshots
      WHERE user_id = v_user.user_id
        AND captured_at < now() - (v_user.data_retention_days || ' days')::interval;
      GET DIAGNOSTICS v_deleted = ROW_COUNT;
      v_total_snapshots := v_total_snapshots + v_deleted;

    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '_cleanup_expired_data_internal: failed for user %, skipping: %', v_user.user_id, SQLERRM;
    END;
  END LOOP;

  DELETE FROM public.pairing_attempt_log WHERE attempted_at < now() - interval '1 hour';
  GET DIAGNOSTICS v_pairing_log_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'sessions_deleted', v_total_sessions,
    'alerts_deleted', v_total_alerts,
    'snapshots_deleted', v_total_snapshots,
    'pairing_attempt_log_deleted', v_pairing_log_deleted
  );
END;
$$;

REVOKE ALL ON FUNCTION public._cleanup_expired_data_internal()
  FROM PUBLIC, authenticated, anon;

-- Step 3: public entrypoint keeps the service_role gate.
CREATE OR REPLACE FUNCTION public.cleanup_expired_data()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
BEGIN
  IF current_setting('request.jwt.claims', true)::jsonb ->> 'role' != 'service_role' THEN
    RAISE EXCEPTION 'Forbidden: service_role required';
  END IF;
  RETURN public._cleanup_expired_data_internal();
END;
$$;

-- Step 4: nightly schedule at 03:07 UTC. Unschedule first to make the
-- migration idempotent (no-op if the job doesn't yet exist).
DO $$
BEGIN
  PERFORM cron.unschedule('cleanup_expired_data_nightly');
EXCEPTION WHEN OTHERS THEN
  -- job did not exist; ignore
  NULL;
END;
$$;

SELECT cron.schedule(
  'cleanup_expired_data_nightly',
  '7 3 * * *',
  $cron$SELECT public._cleanup_expired_data_internal();$cron$
);
