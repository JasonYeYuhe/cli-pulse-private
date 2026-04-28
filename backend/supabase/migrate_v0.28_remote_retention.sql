-- ============================================================
-- v0.28 — Remote Agent Sessions retention cleanup
-- Date: 2026-04-28
-- Background:
--   v0.26 added remote_sessions, remote_session_events, remote_session_commands,
--   remote_permission_requests, remote_permission_decisions. None of these
--   have a retention policy yet — pending requests that the user never
--   decides on, expired requests, decided requests, completed commands, and
--   the per-session event tail all accumulate indefinitely.
--
--   This migration adds three things:
--
--   1. A `_cleanup_remote_retention_internal()` helper that, with a
--      configurable cutoff in days, deletes:
--       * remote_session_events older than (max event retention)
--       * remote_session_commands older than (command retention) once they
--         are no longer pending (status in delivered/failed/expired)
--       * remote_permission_requests older than (request retention) once
--         they are no longer pending
--       * still-pending remote_permission_requests past expires_at + grace
--         (so a paused user doesn't leave them hanging forever)
--       * remote_sessions older than (session retention) with no activity
--      remote_permission_decisions cascade-delete via the FK on
--      remote_permission_requests.id, and remote_session_events /
--      remote_session_commands cascade via remote_sessions.id; we still
--      sweep them explicitly for sessions that aren't being deleted (the
--      common case is a long-running session that's accruing event tail).
--
--   2. A public `cleanup_remote_retention_data()` wrapper gated by
--      service_role, mirroring the v0.21 / v0.22 split.
--
--   3. A pg_cron entry running at 03:47 UTC — 20 minutes after the v0.22
--      retention job (03:27) so the three nightly jobs don't compete for
--      DELETE locks.
--
-- Defaults are aggressive on purpose:
--   * events:   7 days (terminal-output tail is high churn, low value)
--   * commands: 30 days (debugging / audit window)
--   * requests: 30 days (audit window for decided requests)
--   * sessions: 60 days idle (likely no longer running anywhere)
--   * pending request grace: 1 hour past expires_at
--
-- All idempotent. Safe to re-run.
-- ============================================================

CREATE OR REPLACE FUNCTION public._cleanup_remote_retention_internal(
  p_event_days integer DEFAULT 7,
  p_command_days integer DEFAULT 30,
  p_request_days integer DEFAULT 30,
  p_session_idle_days integer DEFAULT 60,
  p_pending_grace_minutes integer DEFAULT 60
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
DECLARE
  v_event_cutoff timestamptz := now() - (p_event_days || ' days')::interval;
  v_command_cutoff timestamptz := now() - (p_command_days || ' days')::interval;
  v_request_cutoff timestamptz := now() - (p_request_days || ' days')::interval;
  v_session_cutoff timestamptz := now() - (p_session_idle_days || ' days')::interval;
  v_pending_cutoff timestamptz := now() - (p_pending_grace_minutes || ' minutes')::interval;
  v_events_deleted integer := 0;
  v_commands_deleted integer := 0;
  v_requests_deleted integer := 0;
  v_pending_expired integer := 0;
  v_sessions_deleted integer := 0;
BEGIN
  IF p_event_days < 1 OR p_command_days < 1 OR p_request_days < 1
     OR p_session_idle_days < 1 OR p_pending_grace_minutes < 1 THEN
    RAISE EXCEPTION '_cleanup_remote_retention_internal: every retention argument must be >= 1';
  END IF;

  -- 1. Trim per-session terminal-output tail. Cascade FK from
  --    remote_sessions would handle this on session delete; we sweep
  --    independently here so long-running sessions don't accumulate
  --    weeks of stdout.
  DELETE FROM public.remote_session_events
  WHERE created_at < v_event_cutoff;
  GET DIAGNOSTICS v_events_deleted = ROW_COUNT;

  -- 2. Old completed commands. Pending commands are NOT touched here —
  --    they're the helper's queue. status != 'pending' covers
  --    delivered / failed / expired.
  DELETE FROM public.remote_session_commands
  WHERE created_at < v_command_cutoff
    AND status <> 'pending';
  GET DIAGNOSTICS v_commands_deleted = ROW_COUNT;

  -- 3a. Mark pending-but-expired permission requests as 'expired' so
  --     they don't sit in remote_app_list_pending_approvals forever if
  --     the helper crashed or the user closed the app mid-flow.
  UPDATE public.remote_permission_requests
  SET status = 'expired'
  WHERE status = 'pending'
    AND expires_at < v_pending_cutoff;
  GET DIAGNOSTICS v_pending_expired = ROW_COUNT;

  -- 3b. Old decided / expired permission requests. Pending is left alone —
  --     3a already moved expired-pending out of pending. remote_permission_decisions
  --     cascade via the FK on request_id.
  DELETE FROM public.remote_permission_requests
  WHERE created_at < v_request_cutoff
    AND status <> 'pending';
  GET DIAGNOSTICS v_requests_deleted = ROW_COUNT;

  -- 4. Idle remote_sessions — neither a recent event nor recent activity
  --    inside the keep-alive window. Cascade FK on remote_session_events
  --    and remote_session_commands handles their leftovers.
  DELETE FROM public.remote_sessions
  WHERE coalesce(last_event_at, created_at) < v_session_cutoff
    AND status <> 'running';
  GET DIAGNOSTICS v_sessions_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'event_days', p_event_days,
    'command_days', p_command_days,
    'request_days', p_request_days,
    'session_idle_days', p_session_idle_days,
    'pending_grace_minutes', p_pending_grace_minutes,
    'events_deleted', v_events_deleted,
    'commands_deleted', v_commands_deleted,
    'requests_deleted', v_requests_deleted,
    'pending_expired', v_pending_expired,
    'sessions_deleted', v_sessions_deleted
  );
END;
$$;

REVOKE ALL ON FUNCTION public._cleanup_remote_retention_internal(integer, integer, integer, integer, integer)
  FROM PUBLIC, authenticated, anon;


-- Public entrypoint, service_role gated. Mirrors the v0.21 / v0.22 split.
CREATE OR REPLACE FUNCTION public.cleanup_remote_retention_data(
  p_event_days integer DEFAULT 7,
  p_command_days integer DEFAULT 30,
  p_request_days integer DEFAULT 30,
  p_session_idle_days integer DEFAULT 60,
  p_pending_grace_minutes integer DEFAULT 60
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
BEGIN
  -- coalesce: NULL-gate fix from v0.22. current_setting() returns NULL
  -- when called outside PostgREST (direct DB connection). NULL !=
  -- 'service_role' is NULL, PL/pgSQL's IF treats NULL as FALSE → gate
  -- silently bypassed. Coalesce to empty string so comparison is
  -- three-valued-safe.
  IF coalesce(
       current_setting('request.jwt.claims', true)::jsonb ->> 'role',
       ''
     ) != 'service_role' THEN
    RAISE EXCEPTION 'Forbidden: service_role required';
  END IF;
  RETURN public._cleanup_remote_retention_internal(
    p_event_days, p_command_days, p_request_days,
    p_session_idle_days, p_pending_grace_minutes
  );
END;
$$;


-- Schedule 03:47 UTC nightly — 20 minutes after retention_cleanup_nightly
-- (03:27 UTC). Idempotent: unschedule first.
DO $$
BEGIN
  PERFORM cron.unschedule('remote_retention_cleanup_nightly');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'remote_retention_cleanup_nightly',
      '47 3 * * *',
      $cron$SELECT public._cleanup_remote_retention_internal();$cron$
    );
  ELSE
    RAISE NOTICE 'pg_cron extension missing — skipping remote_retention_cleanup_nightly schedule. Install via dashboard.';
  END IF;
END $$;
