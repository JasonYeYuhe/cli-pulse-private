-- Migration v0.17: Harden search_path on all SECURITY DEFINER functions
--
-- NOTE: superseded on 2026-04-21 by migrate_v0.17.1_search_path_hotfix.sql.
-- The pin used here (public, pg_catalog) broke three helpers that call
-- pgcrypto unqualified. If replaying from scratch, apply v0.17 then v0.17.1
-- in order, or apply only v0.17.1 (it ALTERs the same 20 functions with the
-- corrected pin: pg_catalog, public, extensions). Kept for audit history.
--
-- Background:
--   Supabase advisor flags every SECURITY DEFINER function whose search_path
--   is not pinned (lint 0011_function_search_path_mutable). A caller that can
--   SET search_path before invocation could shadow built-in names with their
--   own objects and escalate privilege inside the definer's context.
--
-- Decision:
--   Pin search_path to `public, pg_catalog` on each function. We use
--   ALTER FUNCTION (not CREATE OR REPLACE) to keep the change minimal and
--   reversible — function bodies are untouched.
--
--   All auth.* and extensions.* references in our codebase are already
--   schema-qualified, so they resolve regardless of search_path.
--
-- Coverage: 20 functions. rls_auto_enable() is already pinned and is skipped.
--   helper_heartbeat has two overloads — both must be altered by exact
--   signature.
--
-- Non-goals (handled elsewhere or out of scope):
--   - SECURITY DEFINER views (provider_usage_week, provider_usage_today)
--   - Permissive RLS policy on public.subscriptions
--   - HIBP leaked-password protection (auth settings, not SQL)

ALTER FUNCTION public.cleanup_expired_data()
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.cleanup_old_data(p_retention_days integer)
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.dashboard_summary()
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.delete_user_account()
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.generate_pairing_code()
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.get_daily_usage(days integer)
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.get_track_git_activity(p_device_id uuid, p_helper_secret text)
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.get_user_tier()
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.handle_new_profile()
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.handle_new_subscription()
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.handle_new_user()
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.helper_heartbeat(
  p_device_id uuid,
  p_helper_secret text,
  p_cpu_usage integer,
  p_memory_usage integer,
  p_active_session_count integer
) SET search_path = public, pg_catalog;

ALTER FUNCTION public.helper_heartbeat(
  p_device_id uuid,
  p_user_id uuid,
  p_cpu_usage integer,
  p_memory_usage integer,
  p_active_session_count integer
) SET search_path = public, pg_catalog;

ALTER FUNCTION public.helper_sync(
  p_device_id uuid,
  p_helper_secret text,
  p_sessions jsonb,
  p_alerts jsonb,
  p_provider_remaining jsonb,
  p_provider_tiers jsonb
) SET search_path = public, pg_catalog;

ALTER FUNCTION public.ingest_commits(p_commits jsonb)
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.my_teams()
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.provider_summary()
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.recompute_yield_scores_for_user(p_user_id uuid)
  SET search_path = public, pg_catalog;

ALTER FUNCTION public.register_helper(
  p_pairing_code text,
  p_device_name text,
  p_device_type text,
  p_system text,
  p_helper_version text
) SET search_path = public, pg_catalog;

ALTER FUNCTION public.upsert_daily_usage(metrics jsonb)
  SET search_path = public, pg_catalog;
