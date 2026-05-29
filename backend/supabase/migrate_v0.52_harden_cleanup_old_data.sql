-- ============================================================
-- v0.52 — P0 security: harden cleanup_old_data
-- Date: 2026-05-29 · APPLIED to prod (gkjwsxotmwrgqsvfijzs) 2026-05-29
--
-- Discovered in the 2026-05-29 deep audit: `cleanup_old_data` (legacy,
-- introduced in migrate_v0.4) is SECURITY DEFINER, DELETEs from
-- public.sessions + public.usage_snapshots, and had EXECUTE granted to
-- PUBLIC / anon / authenticated with NO auth guard. Any unauthenticated
-- caller could mass-delete all users' Ended sessions + usage snapshots:
--   POST /rest/v1/rpc/cleanup_old_data  {"p_retention_days": 1}
--
-- It is a SUPERSEDED orphan: current retention runs via pg_cron calling
-- _cleanup_expired_data_internal() / _cleanup_retention_data_internal();
-- nothing in the repo or prod references cleanup_old_data. We HARDEN
-- rather than DROP only because ci_check_rpc_contract.py lists it as an
-- expected RPC (dropping would fail that gate).
--
-- Fix: add the same service_role JWT guard cleanup_expired_data uses,
-- and revoke EXECUTE from PUBLIC/anon/authenticated.
--
-- Rollback: not recommended (the pre-fix state is the vulnerability).
-- ============================================================

CREATE OR REPLACE FUNCTION public.cleanup_old_data(p_retention_days integer DEFAULT 90)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  v_sessions_deleted integer;
  v_snapshots_deleted integer;
  v_cutoff timestamptz;
BEGIN
  -- v0.52: gate to service_role only (mirrors cleanup_expired_data).
  IF coalesce(
       current_setting('request.jwt.claims', true)::jsonb ->> 'role',
       ''
     ) != 'service_role' THEN
    RAISE EXCEPTION 'Forbidden: service_role required';
  END IF;

  v_cutoff := now() - (p_retention_days || ' days')::interval;

  DELETE FROM public.sessions
  WHERE status = 'Ended'
    AND last_active_at < v_cutoff;
  GET DIAGNOSTICS v_sessions_deleted = ROW_COUNT;

  DELETE FROM public.usage_snapshots
  WHERE recorded_at < v_cutoff;
  GET DIAGNOSTICS v_snapshots_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'sessions_deleted', v_sessions_deleted,
    'snapshots_deleted', v_snapshots_deleted,
    'cutoff', v_cutoff
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.cleanup_old_data(integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cleanup_old_data(integer) TO service_role;

-- Verify:
--   SELECT grantee, privilege_type FROM information_schema.role_routine_grants
--    WHERE routine_name='cleanup_old_data' AND routine_schema='public';
--   -- expect only: postgres, service_role
