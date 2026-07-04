-- migrate_v0.64_heartbeat_metrics_size_guard.sql
-- Codex-review hardening (2026-07-04): bound the p_metrics jsonb in helper_heartbeat.
--
-- helper_heartbeat is SECURITY DEFINER and reachable by anon (helpers call via the
-- anon key). A caller with a stolen device secret could submit an arbitrarily large
-- p_metrics object; even though only whitelisted keys are stored, Postgres still has
-- to parse it and the function walks the `capability` object via jsonb_each_text.
-- Cap the payload so an abusive caller can't drive parse/CPU cost — oversized => the
-- whole metrics block is IGNORED (preserve last-known), never an error.
--
-- Body-only change (same 7-arg signature), so CREATE OR REPLACE preserves the
-- existing EXECUTE grants; no DROP / re-grant needed. Additive + inert.
-- pg_get_functiondef confirmed the live body == repo v0.63 before this replace.

begin;

create or replace function public.helper_heartbeat(
  p_device_id uuid,
  p_helper_secret text,
  p_cpu_usage integer default 0,
  p_memory_usage integer default 0,
  p_active_session_count integer default 0,
  p_provider_plan_status jsonb default null,
  p_metrics jsonb default null
)
returns jsonb as $$
declare
  v_user_id uuid;
  v_plan jsonb;
  v_has_metrics boolean;
  v_metrics jsonb;
  v_caps jsonb;
  v_batt_state text;
begin
  select user_id into v_user_id
  from public.devices where id = p_device_id and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  v_plan := null;
  if p_provider_plan_status is not null and jsonb_typeof(p_provider_plan_status) = 'object' then
    select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into v_plan
    from (
      select key as k, value as v
      from jsonb_each_text(p_provider_plan_status)
      where value in ('on_plan', 'off_plan') and char_length(key) <= 32
      order by key
      limit 24
    ) s;
  end if;

  v_has_metrics := (p_metrics is not null and jsonb_typeof(p_metrics) = 'object');
  -- v0.64: bound the payload (see header). Oversized => ignore the metrics block.
  if v_has_metrics and pg_column_size(p_metrics) > 8192 then
    v_has_metrics := false;
  end if;
  v_metrics := '{}'::jsonb;
  v_caps := null;
  v_batt_state := null;

  if v_has_metrics then
    select coalesce(jsonb_object_agg(spec.key, g.num), '{}'::jsonb) into v_metrics
    from (values
      ('cpu_power_w',              0::numeric,   500::numeric),
      ('gpu_power_w',              0,            500),
      ('ane_power_w',              0,            500),
      ('system_power_w',           0,            500),
      ('cpu_temp_c',              -40,           150),
      ('gpu_temp_c',              -40,           150),
      ('battery_temp_c',          -40,           150),
      ('fan_rpm',                  0,            30000),
      ('fan_max_rpm',              0,            30000),
      ('thermal_state',            0,            3),
      ('battery_charge_pct',       0,            100),
      ('battery_cycle_count',      0,            20000),
      ('battery_health_pct',       0,            200),
      ('battery_design_capacity',  0,            100000),
      ('battery_current_capacity', 0,            100000),
      ('adapter_watts',            0,            1000)
    ) as spec(key, lo, hi)
    cross join lateral (
      select case when jsonb_typeof(p_metrics->spec.key) = 'number'
                  then (p_metrics->>spec.key)::numeric end as num
    ) g
    where g.num is not null and g.num between spec.lo and spec.hi;

    if jsonb_typeof(p_metrics->'battery_state') = 'string'
       and (p_metrics->>'battery_state') in ('charging','discharging','charged','none','unknown') then
      v_batt_state := p_metrics->>'battery_state';
    end if;

    if jsonb_typeof(p_metrics->'capability') = 'object' then
      select coalesce(jsonb_object_agg(k, (v = 'true')), '{}'::jsonb) into v_caps
      from (
        select key as k, value as v
        from jsonb_each_text(p_metrics->'capability')
        where value in ('true','false') and char_length(key) <= 32
        order by key
        limit 32
      ) s;
    end if;
  end if;

  update public.devices set
    status = 'Online', cpu_usage = p_cpu_usage,
    memory_usage = p_memory_usage, last_seen_at = now(),
    provider_plan_status = coalesce(v_plan, provider_plan_status),
    cpu_power_w              = coalesce((v_metrics->>'cpu_power_w')::real,               cpu_power_w),
    gpu_power_w              = coalesce((v_metrics->>'gpu_power_w')::real,               gpu_power_w),
    ane_power_w              = coalesce((v_metrics->>'ane_power_w')::real,               ane_power_w),
    system_power_w           = coalesce((v_metrics->>'system_power_w')::real,            system_power_w),
    cpu_temp_c               = coalesce((v_metrics->>'cpu_temp_c')::real,                cpu_temp_c),
    gpu_temp_c               = coalesce((v_metrics->>'gpu_temp_c')::real,                gpu_temp_c),
    battery_temp_c           = coalesce((v_metrics->>'battery_temp_c')::real,            battery_temp_c),
    fan_rpm                  = coalesce((v_metrics->>'fan_rpm')::numeric::int,           fan_rpm),
    fan_max_rpm              = coalesce((v_metrics->>'fan_max_rpm')::numeric::int,       fan_max_rpm),
    thermal_state            = coalesce((v_metrics->>'thermal_state')::numeric::smallint, thermal_state),
    battery_charge_pct       = coalesce((v_metrics->>'battery_charge_pct')::numeric::smallint, battery_charge_pct),
    battery_state            = coalesce(v_batt_state,                                    battery_state),
    battery_cycle_count      = coalesce((v_metrics->>'battery_cycle_count')::numeric::int, battery_cycle_count),
    battery_health_pct       = coalesce((v_metrics->>'battery_health_pct')::real,        battery_health_pct),
    battery_design_capacity  = coalesce((v_metrics->>'battery_design_capacity')::numeric::int, battery_design_capacity),
    battery_current_capacity = coalesce((v_metrics->>'battery_current_capacity')::numeric::int, battery_current_capacity),
    adapter_watts            = coalesce((v_metrics->>'adapter_watts')::real,             adapter_watts),
    sensors_capability       = coalesce(v_caps,                                          sensors_capability),
    sensors_updated_at       = case when v_has_metrics then now() else sensors_updated_at end
  where id = p_device_id;

  return jsonb_build_object('status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

commit;
