-- ============================================================
-- migrate_v0.37 — Multi-device daily_usage_metrics
--   (cli-pulse-desktop v0.3.1)
--
-- Adds device_id to daily_usage_metrics so multiple devices on the
-- same account can coexist without race-clobbering each other's
-- per-day totals. Strategy:
--
--   (a) Add device_id with a nil-UUID sentinel default to backfill
--       existing rows; swap PK to (user_id, device_id, metric_date,
--       provider, model).
--
--   (b) Replace upsert_daily_usage with a 2-arg version (the old
--       1-arg shape is explicitly DROPed, then the new shape is
--       created with a default for p_device_id so legacy callers
--       still resolve via PostgREST).
--
--   (c) ADD a SIBLING RPC `helper_sync_daily_usage(...)` rather
--       than extending the existing helper_sync. This avoids the
--       blast-radius of touching helper_sync's sophisticated
--       sessions/alerts/provider-quota body. Tauri will call both
--       RPCs each 2-min cycle.
--
--   (d) Replace get_daily_usage with SUM-aggregating version so
--       iOS/Android dashboard JSON shapes stay unchanged. Add
--       get_daily_usage_by_device for future per-device UI.
--
-- Spec: cli-pulse-desktop/PROJECT_DEV_PLAN_2026-05-03_v0.3.1_multi_device_daily_usage.md
--
-- Review history:
--   - Gemini 3.1 Pro (product/UX): caught broken rollback strategy
--     when 2+ devices have already written; rollback is run-once
--     tooling with a SUM-collapse step (see spec §4.1).
--   - Codex GPT-5.4 (SQL/security): caught 3 FIX-FIRSTs:
--       1. CREATE OR REPLACE FUNCTION with extra args creates a NEW
--          overload, not a replacement. Fixed: explicit drops.
--       2. devices.id could be inserted as the nil UUID. Fixed:
--          check constraint added.
--       3. get_daily_usage_by_device JOIN on id alone could leak
--          foreign device names. Fixed: ownership validation in
--          upsert_daily_usage AND user_id-constrained JOIN.
-- ============================================================

set lock_timeout = '30s';

-- ────────────────────────────────────────────────────────────
-- 1. Add device_id with the nil-UUID sentinel as default.
--    Postgres 11+: a constant-default add-column is metadata-only.
-- ────────────────────────────────────────────────────────────
alter table public.daily_usage_metrics
  add column device_id uuid not null
  default '00000000-0000-0000-0000-000000000000'::uuid;

-- ────────────────────────────────────────────────────────────
-- 2. Swap the primary key from per-user to per-(user, device).
-- ────────────────────────────────────────────────────────────
alter table public.daily_usage_metrics
  drop constraint daily_usage_metrics_pkey;

alter table public.daily_usage_metrics
  add primary key (user_id, device_id, metric_date, provider, model);

-- ────────────────────────────────────────────────────────────
-- 3. Replace indexes — old user_date-only; new pair adds
--    user_device_date for the per-device read path.
-- ────────────────────────────────────────────────────────────
drop index if exists idx_daily_usage_metrics_user_date;

create index idx_daily_usage_metrics_user_date
  on public.daily_usage_metrics(user_id, metric_date desc);

create index idx_daily_usage_metrics_user_device_date
  on public.daily_usage_metrics(user_id, device_id, metric_date desc);

-- ────────────────────────────────────────────────────────────
-- 4. Reserve the nil UUID — defensive guard so no real device row
--    can ever take the sentinel value (Codex review).
-- ────────────────────────────────────────────────────────────
alter table public.devices
  add constraint devices_id_not_nil_uuid
  check (id <> '00000000-0000-0000-0000-000000000000'::uuid);

reset lock_timeout;

-- ────────────────────────────────────────────────────────────
-- 5. Replace upsert_daily_usage. Drop old 1-arg, create new
--    2-arg. PostgREST routes old-shape calls to the new function
--    via the default for p_device_id.
-- ────────────────────────────────────────────────────────────
drop function if exists public.upsert_daily_usage(metrics jsonb);

create or replace function public.upsert_daily_usage(
  metrics jsonb,
  p_device_id uuid default null
) returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_device_id uuid;
  v_count int := 0;
  v_item jsonb;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  -- Validate device ownership when an explicit device_id is supplied.
  -- Without this check (Codex review), a malicious caller could pass
  -- another user's device UUID; rows would still land under their own
  -- user_id (RLS-safe), but the future device-management UI could
  -- leak foreign device names via get_daily_usage_by_device's join.
  if p_device_id is not null then
    if not exists (
      select 1 from public.devices
        where id = p_device_id and user_id = v_user_id
    ) then
      raise exception 'Device not owned by caller'
        using errcode = '42501';
    end if;
    v_device_id := p_device_id;
  else
    v_device_id := '00000000-0000-0000-0000-000000000000'::uuid;
  end if;

  for v_item in select * from jsonb_array_elements(metrics)
  loop
    insert into public.daily_usage_metrics (
      user_id, device_id, metric_date, provider, model,
      input_tokens, cached_tokens, output_tokens, cost, updated_at
    ) values (
      v_user_id,
      v_device_id,
      (v_item->>'metric_date')::date,
      v_item->>'provider',
      v_item->>'model',
      coalesce((v_item->>'input_tokens')::bigint, 0),
      coalesce((v_item->>'cached_tokens')::bigint, 0),
      coalesce((v_item->>'output_tokens')::bigint, 0),
      coalesce((v_item->>'cost')::numeric, 0),
      now()
    )
    on conflict (user_id, device_id, metric_date, provider, model)
    do update set
      input_tokens = excluded.input_tokens,
      cached_tokens = excluded.cached_tokens,
      output_tokens = excluded.output_tokens,
      cost = excluded.cost,
      updated_at = now();
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('upserted', v_count);
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 6. NEW: helper_sync_daily_usage — sibling to helper_sync for
--    the helper-credentialed daily-usage push path.
--
--    We deliberately do NOT extend helper_sync because the live
--    function body (sessions / alerts / provider quotas) is
--    sophisticated and replacing it carries too much regression
--    risk. The 2-RPC-per-cycle cost (helper_sync + helper_sync_daily_usage)
--    is negligible at the 2-min cadence.
--
--    p_device_id is auth'd via helper_secret; cannot be spoofed.
-- ────────────────────────────────────────────────────────────
create or replace function public.helper_sync_daily_usage(
  p_device_id uuid,
  p_helper_secret text,
  p_metrics jsonb default '[]'::jsonb
) returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid;
  v_metric jsonb;
  v_metric_count integer := 0;
  v_metric_error_count integer := 0;
begin
  -- Auth via device secret (compare SHA-256 hash). Same pattern as
  -- helper_heartbeat / helper_sync.
  select user_id into v_user_id
  from public.devices
  where id = p_device_id
    and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  if jsonb_array_length(p_metrics) > 200 then
    raise exception 'Too many daily usage metrics (max 200)';
  end if;

  -- Per-row sub-transaction: a bad row (malformed date, null model,
  -- etc.) doesn't unwind the whole sync — counts are returned in the
  -- response.
  for v_metric in select * from jsonb_array_elements(p_metrics) loop
    begin
      insert into public.daily_usage_metrics (
        user_id, device_id, metric_date, provider, model,
        input_tokens, cached_tokens, output_tokens, cost, updated_at
      ) values (
        v_user_id,
        p_device_id,
        (v_metric->>'metric_date')::date,
        v_metric->>'provider',
        v_metric->>'model',
        coalesce((v_metric->>'input_tokens')::bigint, 0),
        coalesce((v_metric->>'cached_tokens')::bigint, 0),
        coalesce((v_metric->>'output_tokens')::bigint, 0),
        coalesce((v_metric->>'cost')::numeric, 0),
        now()
      )
      on conflict (user_id, device_id, metric_date, provider, model)
      do update set
        input_tokens = excluded.input_tokens,
        cached_tokens = excluded.cached_tokens,
        output_tokens = excluded.output_tokens,
        cost = excluded.cost,
        updated_at = now();
      v_metric_count := v_metric_count + 1;
    exception when others then
      v_metric_error_count := v_metric_error_count + 1;
    end;
  end loop;

  return jsonb_build_object(
    'metrics_synced', v_metric_count,
    'metrics_errored', v_metric_error_count
  );
end;
$$;

grant execute on function public.helper_sync_daily_usage(uuid, text, jsonb)
  to anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 7. Update get_daily_usage to SUM across device_id so the public
--    JSON shape stays unchanged. iOS/Android dashboards keep
--    consuming one row per (date, provider, model).
-- ────────────────────────────────────────────────────────────
create or replace function public.get_daily_usage(days int default 30)
returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_days int := greatest(coalesce(days, 30), 1);
  v_since date := current_date - (v_days - 1);
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  return coalesce(
    (select jsonb_agg(row_to_json(t)) from (
      select metric_date, provider, model,
             coalesce(sum(input_tokens), 0)::bigint   as input_tokens,
             coalesce(sum(cached_tokens), 0)::bigint  as cached_tokens,
             coalesce(sum(output_tokens), 0)::bigint  as output_tokens,
             coalesce(sum(cost), 0)::numeric          as cost
      from public.daily_usage_metrics
      where user_id = v_user_id and metric_date >= v_since
      group by metric_date, provider, model
      order by metric_date desc, provider, model
    ) t),
    '[]'::jsonb
  );
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 8. New: get_daily_usage_by_device for the future per-device
--    breakdown UI. JOIN constrained on user_id so a malicious
--    upserter cannot leak foreign device names.
-- ────────────────────────────────────────────────────────────
create or replace function public.get_daily_usage_by_device(days int default 30)
returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_days int := greatest(coalesce(days, 30), 1);
  v_since date := current_date - (v_days - 1);
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  return coalesce(
    (select jsonb_agg(row_to_json(t)) from (
      select
        d.metric_date,
        d.device_id,
        coalesce(dev.name, '(legacy)') as device_name,
        d.provider, d.model,
        d.input_tokens, d.cached_tokens, d.output_tokens, d.cost
      from public.daily_usage_metrics d
      left join public.devices dev
        on dev.id = d.device_id
       and dev.user_id = d.user_id
      where d.user_id = v_user_id and d.metric_date >= v_since
      order by d.metric_date desc, dev.name nulls last, d.provider, d.model
    ) t),
    '[]'::jsonb
  );
end;
$$;

grant execute on function public.get_daily_usage_by_device(int)
  to authenticated;
revoke execute on function public.get_daily_usage_by_device(int)
  from anon;
