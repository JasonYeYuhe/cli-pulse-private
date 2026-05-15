-- ============================================================
-- v0.43 — provider_quotas bigint + provider_summary projects updated_at
-- Date applied to prod: 2026-05-04 (version 20260504143348)
-- Backfilled to source: 2026-05-15 (v1.21 long-tail F10)
--
-- HISTORY:
-- The cli-pulse-desktop team applied this migration directly to the
-- Tokyo prod project (gkjwsxotmwrgqsvfijzs) via their own deploy
-- pipeline. The .sql source was never committed to this repo, leaving
-- a numbering gap (v0.41 → v0.43 — v0.42 was never used, planning-only
-- placeholder that was renumbered before ship). This file backfills
-- the real SQL pulled from `supabase_migrations.schema_migrations`
-- (`name = 'v0_43_provider_quotas_bigint_and_updated_at'`) so that
-- CI live-migration replay (F9) matches prod schema and future
-- contributors don't see a missing file.
--
-- The original SQL was applied without `set search_path` hardening
-- on the ALTER TABLE (DDL doesn't need it) and with hardened search
-- path on the RPC; both behaviours preserved verbatim here.
--
-- Two changes batched:
--
-- 1. provider_quotas.{quota,remaining}: integer (i32) -> bigint.
--    Avoids overflow at $21,474 OpenRouter balance. Rust side has been
--    i64 since v0.4.0; only the column cast on INSERT in helper_sync
--    truncated. Documented in src-tauri/src/quota/openrouter.rs:15-20.
--
-- 2. provider_summary RPC: project updated_at so the desktop frontend
--    can render a "stale" badge when cached server data is older than
--    ~6 minutes. updated_at column already exists on provider_quotas
--    (DEFAULT now()) — only the read-path projection was missing.
--
-- Note: the RPC returns jsonb (NOT RETURNS TABLE). Gemini 3.1 Pro's
-- P0 concern in the dev plan was about the wrong assumption that the
-- signature was RETURNS TABLE — reality is jsonb, so CREATE OR REPLACE
-- works without DROP FUNCTION first.
--
-- IMPORTANT: provider_summary() was further revised in v0.44 to take
-- a `p_user_today date default null` parameter for device-local "today"
-- semantics. That superseding revision lives in migrate_v0.44_user_tz_today.sql.
-- If replaying migrations in CI from scratch, v0.44 will redefine this
-- function. Both states are intentional.
-- ============================================================

ALTER TABLE public.provider_quotas
  ALTER COLUMN quota TYPE bigint USING quota::bigint,
  ALTER COLUMN remaining TYPE bigint USING remaining::bigint;

CREATE OR REPLACE FUNCTION public.provider_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_today date := current_date;
  v_week_start date := current_date - interval '7 days';
  v_month_start date := current_date - interval '30 days';
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  return (
    with usage_agg as (
      select
        provider,
        sum(case when metric_date = v_today
              then coalesce(input_tokens,0) + coalesce(cached_tokens,0) + coalesce(output_tokens,0)
              else 0 end) as today_usage,
        sum(case when metric_date >= v_week_start
              then coalesce(input_tokens,0) + coalesce(cached_tokens,0) + coalesce(output_tokens,0)
              else 0 end) as total_usage,
        sum(case when metric_date = v_today then cost else 0 end) as today_cost,
        sum(case when metric_date >= v_week_start then cost else 0 end) as week_cost,
        sum(cost) as month_cost
      from public.daily_usage_metrics
      where user_id = v_user_id
        and metric_date >= v_month_start
      group by provider
    ),
    quota_agg as (
      select provider, remaining, quota, plan_type, reset_time, tiers, updated_at
      from public.provider_quotas
      where user_id = v_user_id
    )
    select coalesce(jsonb_agg(row_data order by sort_key desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'provider', coalesce(u.provider, q.provider),
        'today_usage', coalesce(u.today_usage, 0),
        'total_usage', coalesce(u.total_usage, 0),
        'estimated_cost', coalesce(u.week_cost, 0),
        'estimated_cost_today', coalesce(u.today_cost, 0),
        'estimated_cost_30_day', coalesce(u.month_cost, 0),
        'remaining', q.remaining,
        'quota', q.quota,
        'plan_type', q.plan_type,
        'reset_time', q.reset_time,
        'tiers', coalesce(q.tiers, '[]'::jsonb),
        'updated_at', q.updated_at
      ) as row_data,
      coalesce(u.total_usage, 0) as sort_key
      from usage_agg u
      full outer join quota_agg q on q.provider = u.provider
    ) sub
  );
end;
$function$;
