-- ============================================================
-- v0.53 — P1 security surface reduction: revoke anon EXECUTE from
-- authenticated-only SECURITY DEFINER RPCs.
-- Date: 2026-05-29 · APPLIED to prod (gkjwsxotmwrgqsvfijzs) 2026-05-29
--
-- 2026-05-29 deep audit found ~23 SECURITY DEFINER functions reachable
-- by the `anon` role. Many are LEGITIMATELY anon (the Mac helper
-- authenticates with the anon key + a per-device helper_secret HMAC —
-- e.g. register_helper, helper_sync, helper_heartbeat, ingest_commits,
-- remote_helper_*). Those are LEFT UNTOUCHED.
--
-- This migration locks down only the functions that enforce auth.uid()
-- internally (app-only; an anon caller already fails inside them, so
-- revoking anon is behavior-preserving — it just rejects earlier at the
-- PostgREST layer instead of raising "Not authenticated").
--
-- Classification was done by inspecting each function body for
-- `auth.uid()` (app-auth marker) vs `helper_secret` (helper-auth marker).
-- `upsert_daily_usage` was DELIBERATELY EXCLUDED — it has auth.uid() but
-- also takes a device_id and may have a helper-callable path; left for
-- manual review before locking.
--
-- All affected functions already have `authenticated` explicitly granted,
-- so revoking PUBLIC+anon keeps logged-in users working. pg_cron runs as
-- `postgres` and is unaffected.
-- ============================================================

DO $$
DECLARE r record;
BEGIN
  -- Group A: authenticated-app RPCs → keep authenticated, drop PUBLIC + anon
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN (
        'delete_user_account','evaluate_budget_alerts','generate_pairing_code',
        'get_daily_usage','get_user_tier','my_teams','recompute_yield_scores_for_user',
        'remote_app_decide_permission','remote_app_list_pending_approvals','remote_app_send_command')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.sig);
    EXECUTE format('GRANT  EXECUTE ON FUNCTION %s TO authenticated', r.sig);
  END LOOP;

  -- Group B: service_role-only cleanup wrappers → drop PUBLIC + anon + authenticated
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('cleanup_expired_data','cleanup_retention_data')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
  END LOOP;
END $$;

-- Verify (Group A → authenticated,postgres,service_role; Group B → postgres,service_role;
--         helper fns like register_helper/helper_sync MUST still include anon):
--   SELECT routine_name, string_agg(grantee,',' ORDER BY grantee)
--   FROM information_schema.role_routine_grants
--   WHERE routine_schema='public' AND privilege_type='EXECUTE'
--   GROUP BY routine_name;
