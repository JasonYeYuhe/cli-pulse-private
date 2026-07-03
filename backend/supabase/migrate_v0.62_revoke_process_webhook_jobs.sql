-- ============================================================
-- v0.62 — Revoke anon/authenticated EXECUTE on process_webhook_jobs
-- Date: 2026-07-03
--
-- 2026-07-03 global deep review: public.process_webhook_jobs() (migrate_v0.25)
-- is SECURITY DEFINER, reads service-role secrets from vault, has NO internal
-- caller gate, and carries Supabase default-privilege EXECUTE for PUBLIC/anon/
-- authenticated (never granted by a migration — CREATE-time residue). Any
-- anonymous PostgREST caller can force webhook-job dispatch; combined with the
-- function's lack of FOR UPDATE SKIP LOCKED, a caller racing the pg_cron run
-- can double-send user webhooks.
--
-- The v0.53 Group-B sweep locked the analogous cleanup_* cron wrappers and the
-- v0.32/v0.47 siblings (process_app_push_jobs / process_widget_refresh_jobs)
-- were revoked at creation — this one was simply missed. pg_cron runs as the
-- function owner (postgres), which is unaffected by these revokes.
--
-- Idempotent; safe to re-run.
-- ============================================================

revoke execute on function public.process_webhook_jobs() from PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Post-apply verification:
--   select grantee, privilege_type from information_schema.role_routine_grants
--     where routine_schema='public' and routine_name='process_webhook_jobs'
--     order by grantee;   -- expect: postgres (owner) only
-- ============================================================
