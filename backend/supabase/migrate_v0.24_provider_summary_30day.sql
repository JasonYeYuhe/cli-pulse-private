-- ============================================================
-- v0.24 — provider_summary: expose real 30-day cost
--
-- Context: iPhone/Watch/Android dashboards render a "30 Day Est."
-- Cost Summary. The client was extrapolating via week_cost * 4.3,
-- which under-reports by ~50% on users whose recent 7 days are
-- below their 30-day average (a normal pattern). This migration
-- returns actual 30-day sums from `daily_usage_metrics` so clients
-- can stop extrapolating. Additive only — the existing
-- `estimated_cost` (= week_cost) and `estimated_cost_today` fields
-- are unchanged, so older clients keep working.
-- ============================================================

create or replace function public.provider_summary()
returns jsonb as $$
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
      select provider, remaining, quota, plan_type, reset_time, tiers
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
        'tiers', coalesce(q.tiers, '[]'::jsonb)
      ) as row_data,
      coalesce(u.total_usage, 0) as sort_key
      from usage_agg u
      full outer join quota_agg q on q.provider = u.provider
    ) sub
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;
