-- Migration v0.17.1: HOTFIX for v0.17 search_path hardening
--
-- Incident:
--   v0.17 pinned all 20 SECURITY DEFINER functions to
--   `search_path = public, pg_catalog`. That broke three helper-facing RPCs
--   which call pgcrypto functions unqualified:
--     - register_helper  (gen_random_bytes, digest)
--     - helper_sync      (digest)
--     - get_track_git_activity (digest)
--   On Supabase, pgcrypto is installed in the `extensions` schema, not
--   `pg_catalog`. With v0.17's pin those calls resolved as
--   "function ... does not exist" at runtime. Advisor was still green
--   because the pin was formally non-mutable — the lint catches the
--   absence of a pin, not whether the pin is functionally correct.
--
-- Fix:
--   Re-pin to `pg_catalog, public, extensions`:
--     - pg_catalog first so built-ins cannot be shadowed by objects created
--       in `public` (hardening advice from Codex review)
--     - public for our tables
--     - extensions tail for pgcrypto and friends
--
-- Scope: same 20 functions as v0.17. rls_auto_enable() intentionally left
--   with its original `pg_catalog` pin.
--
-- Verified post-apply (2026-04-21):
--   - advisor: 0 function_search_path_mutable warnings
--   - register_helper('BADCOD', ...) returns {error:invalid_code} (reached
--     pg_advisory_xact_lock + insert path without pgcrypto undefined-function
--     errors)
--   - helper_sync(random_uuid, 'fake-secret', ...) reaches "Device not found
--     or unauthorized" AFTER digest() resolves (previously failed at digest)
--   - get_track_git_activity(random_uuid, 'fake') same successful digest path

ALTER FUNCTION public.cleanup_expired_data()
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.cleanup_old_data(p_retention_days integer)
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.dashboard_summary()
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.delete_user_account()
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.generate_pairing_code()
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.get_daily_usage(days integer)
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.get_track_git_activity(p_device_id uuid, p_helper_secret text)
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.get_user_tier()
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.handle_new_profile()
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.handle_new_subscription()
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.handle_new_user()
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.helper_heartbeat(
  p_device_id uuid,
  p_helper_secret text,
  p_cpu_usage integer,
  p_memory_usage integer,
  p_active_session_count integer
) SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.helper_heartbeat(
  p_device_id uuid,
  p_user_id uuid,
  p_cpu_usage integer,
  p_memory_usage integer,
  p_active_session_count integer
) SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.helper_sync(
  p_device_id uuid,
  p_helper_secret text,
  p_sessions jsonb,
  p_alerts jsonb,
  p_provider_remaining jsonb,
  p_provider_tiers jsonb
) SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.ingest_commits(p_commits jsonb)
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.my_teams()
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.provider_summary()
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.recompute_yield_scores_for_user(p_user_id uuid)
  SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.register_helper(
  p_pairing_code text,
  p_device_name text,
  p_device_type text,
  p_system text,
  p_helper_version text
) SET search_path = pg_catalog, public, extensions;

ALTER FUNCTION public.upsert_daily_usage(metrics jsonb)
  SET search_path = pg_catalog, public, extensions;
