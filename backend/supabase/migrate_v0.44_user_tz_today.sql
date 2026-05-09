-- ============================================================
-- migrate_v0.44 — Timezone-aware dashboard_summary / provider_summary
--
-- (Filename was originally migrate_v0.42; renamed to v0.44 because
-- v0.43 was already applied to production by the cli-pulse-desktop
-- team on 2026-05-04 — see `v0_43_provider_quotas_bigint_and_updated_at`.
-- Rebasing this migration on top of v0.43 means it must:
--   * Keep the `updated_at` column projection that v0.43 added.
--   * Restore the correct rolling-window math (6 days / 29 days for
--     7- and 30-day inclusive windows). v0.43 inadvertently shipped
--     an off-by-one regression by writing `'7 days'` / `'30 days'` —
--     the CI guard `ci_check_date_windows.py` only scans this repo's
--     `backend/supabase/*.sql` and didn't see v0.43 because that
--     migration was authored in cli-pulse-desktop's tree.)
--
-- Bug (observed 2026-05-08, reported by user at 02:03 CN):
--   iPhone "Usage Today" = 0 / "<$0.01"
--   macOS  "Usage Today" = 12.7M tokens / $135.5
--   Same authenticated user, same wall-clock moment.
--
-- Root cause:
--   * macOS writes `daily_usage_metrics.metric_date` in the device's
--     LOCAL timezone (Calendar.current → "2026-05-08" in CN UTC+8).
--   * `dashboard_summary` and `provider_summary` compute `v_today` via
--     `current_date`, which Postgres evaluates in the SERVER timezone
--     (UTC for Tokyo Supabase). At 02:03 CN that's "2026-05-07" UTC.
--   * The query `metric_date = current_date` therefore matches yesterday
--     (CN), not today (CN). The 30-day window (`current_date - 29 days`)
--     is also UTC-anchored and off by one CN day.
--   * iOS/Android consume server-derived numbers; macOS reads local
--     JSONL files directly. → Visible iPhone vs Mac mismatch.
--
-- Fix:
--   Both RPCs accept a new optional `p_user_today date` parameter that
--   the client computes in its OWN local timezone. Server uses
--   `coalesce(p_user_today, current_date)` everywhere `v_today` is
--   needed. Old callers that pass nothing keep the previous behavior
--   via the default (forward-compatible during client rollout).
--
--   Codex P2 follow-up (PR #41 review): clamp `metric_date <= v_today`
--   in provider_summary so a multi-timezone user (Mac in CN UTC+8 +
--   iPhone queried from US Pacific) cannot have the iPhone's 7- and
--   30-day totals include CN-tomorrow rows the Mac just wrote.
--
-- Migration shape (per Codex review of v0.37 + memory
-- `feedback_gemini_review_patterns.md` rule #1):
--   * jsonb-returning functions survive CREATE OR REPLACE only if the
--     SIGNATURE is unchanged. Adding a parameter creates a NEW overload,
--     not a replacement.
--   * Therefore: explicit DROP of the 0-arg shape FIRST, then CREATE the
--     1-arg shape with a DEFAULT. PostgREST routes parameter-less calls
--     to the new function via the default.
--
-- Review history:
--   * Self-review against `feedback_gemini_review_patterns.md` — passed
--     #1 (DROP first) and #4 (no silent fallback worth surfacing in UI:
--     server is single source of truth).
--   * Codex P1+P2 (PR #41 review, 2026-05-08): caught Lifetime tie-break
--     in SubscriptionManager + missing upper-bound on provider_summary.
--     Both fixes applied.
--   * Gemini 3.1 Pro — approved migration as ship-ready (idempotency,
--     PostgREST routing, upper-bound clamp all correct).
-- ============================================================

set lock_timeout = '30s';

-- ────────────────────────────────────────────────────────────
-- 1. dashboard_summary — accept p_user_today.
-- ────────────────────────────────────────────────────────────
drop function if exists public.dashboard_summary();

create or replace function public.dashboard_summary(
  p_user_today date default null
)
returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  -- Use the client-supplied local date when present; otherwise fall back
  -- to server `current_date` (UTC) so legacy clients keep the prior
  -- behavior until they update.
  v_today date := coalesce(p_user_today, current_date);
  v_today_usage bigint;
  v_today_cost numeric;
  v_today_rows integer;
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select
    coalesce(sum(coalesce(input_tokens,0) + coalesce(cached_tokens,0) + coalesce(output_tokens,0)), 0),
    coalesce(sum(cost), 0),
    count(*)
  into v_today_usage, v_today_cost, v_today_rows
  from public.daily_usage_metrics
  where user_id = v_user_id
    and metric_date = v_today;

  select jsonb_build_object(
    'today_usage', v_today_usage,
    'today_cost', v_today_cost,
    'active_sessions', (
      select count(*) from public.sessions
      where user_id = v_user_id and status = 'Running'
    ),
    'online_devices', (
      select count(*) from public.devices
      where user_id = v_user_id and status = 'Online'
    ),
    'unresolved_alerts', (
      select count(*) from public.alerts
      where user_id = v_user_id and is_resolved = false
    ),
    'today_sessions', v_today_rows
  ) into v_result;

  return v_result;
end;
$$;

-- Lock down: revoke the implicit PUBLIC grant Postgres applies to new
-- functions, then explicit grant to authenticated only. Without these
-- two REVOKEs anon can call the RPC and only get bounced by the in-body
-- `auth.uid() is null` check — defense-in-depth says lock at the role
-- boundary too.
revoke execute on function public.dashboard_summary(date) from public;
revoke execute on function public.dashboard_summary(date) from anon;
grant execute on function public.dashboard_summary(date) to authenticated;

-- ────────────────────────────────────────────────────────────
-- 2. provider_summary — accept p_user_today (today / 7-day / 30-day
--    windows all key off the same client-supplied local date).
-- ────────────────────────────────────────────────────────────
drop function if exists public.provider_summary();

create or replace function public.provider_summary(
  p_user_today date default null
)
returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := coalesce(p_user_today, current_date);
  -- Rolling-7-day window = today + previous 6 days inclusive (= 7 days).
  v_week_start date := v_today - interval '6 days';
  -- Rolling-30-day window = today + previous 29 days inclusive.
  v_month_start date := v_today - interval '29 days';
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  return (
    with usage_agg as (
      select
        provider,
        -- Codex P2 (PR #41 review, 2026-05-08): clamp the upper bound to
        -- v_today so a multi-timezone user (Mac in CN UTC+8 + iPhone
        -- queried from US Pacific, say) cannot have the iPhone's 7-day
        -- and 30-day totals include CN-tomorrow rows the Mac already
        -- wrote. Pre-v0.42 the boundary was the server's `current_date`,
        -- which always trailed any local-TZ writer; with `p_user_today`
        -- the upper edge is now client-controlled, so the explicit
        -- `metric_date <= v_today` clamp restores the implicit guarantee.
        -- The `today_usage` and `today_cost` cases already use equality,
        -- so they do not need the clamp.
        sum(case when metric_date = v_today
              then coalesce(input_tokens,0) + coalesce(cached_tokens,0) + coalesce(output_tokens,0)
              else 0 end) as today_usage,
        sum(case when metric_date >= v_week_start and metric_date <= v_today
              then coalesce(input_tokens,0) + coalesce(cached_tokens,0) + coalesce(output_tokens,0)
              else 0 end) as total_usage,
        sum(case when metric_date = v_today then cost else 0 end) as today_cost,
        sum(case when metric_date >= v_week_start and metric_date <= v_today
              then cost else 0 end) as week_cost,
        sum(case when metric_date <= v_today then cost else 0 end) as month_cost
      from public.daily_usage_metrics
      where user_id = v_user_id
        and metric_date >= v_month_start
        and metric_date <= v_today
      group by provider
    ),
    quota_agg as (
      -- v0.43 (2026-05-04): added updated_at projection so cli-pulse-desktop
      -- can render a "stale" badge when cached server data is older than
      -- ~6 minutes. Preserved here in v0.44.
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
$$;

revoke execute on function public.provider_summary(date) from public;
revoke execute on function public.provider_summary(date) from anon;
grant execute on function public.provider_summary(date) to authenticated;

reset lock_timeout;

-- ============================================================
-- Client rollout plan:
--   1. Apply this migration. Existing iOS/macOS/Watch/Android clients
--      keep working unchanged (they pass no parameter → defaults to
--      current_date → identical pre-fix behavior).
--   2. Ship client changes that compute and pass the local-TZ today
--      via `p_user_today`. After clients update, today/week/30-day
--      windows align with the user's wall clock.
-- ============================================================
