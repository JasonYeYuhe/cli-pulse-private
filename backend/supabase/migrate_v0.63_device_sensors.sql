-- migrate_v0.63_device_sensors.sql
-- Machine-health monitor, slice S1. Adds NULLABLE machine-health sensor columns
-- to `devices` and a single OPTIONAL `p_metrics jsonb` param on helper_heartbeat
-- that the (unsandboxed) helper populates from IOReport / AppleSMC / IOHID /
-- AppleSmartBattery / Power Sources / NSProcessInfo.thermalState. Phones then
-- render a read-only device-health summary from these columns.
--
-- Rides the ALWAYS-ON device-heartbeat path (helper_heartbeat -> devices ->
-- authenticated select). Additive + inert: pre-v0.63 callers omit p_metrics, so
-- every sensor column stays NULL and nothing they write changes. Safe to apply
-- live; ADD COLUMN (nullable / constant-default) is metadata-only on PG11+ — no
-- table rewrite.
--
-- Follows the v0.60 provider_plan_status precedent EXACTLY:
--   * ONE jsonb blob param (not ~17 scalar params) — normalize + bound
--     server-side; NEVER store an arbitrary helper payload.
--   * param default NULL (NOT '{}') so old callers omitting it don't clobber;
--     per-field coalesce preserves last-known on omit / transient read failure.
--   * a metric that is absent OR out of physical range is dropped (-> preserve),
--     so one bad sensor read can't fabricate a boundary value or NULL a column.
--   * devices uses COLUMN-LEVEL grants -> every new column needs an explicit
--     SELECT grant or authenticated (mobile) can't read it. Writes go through
--     the SECURITY DEFINER RPC, so no INSERT/UPDATE grant is added here.
--
-- Per-process tables stay LOCAL (helper -> UDS -> app); we deliberately do NOT
-- sync hundreds of process rows to Supabase (privacy + volume). Only the small,
-- fixed device-health summary lives here.
--
-- DDL is transactional in Postgres, so the DROP+CREATE of helper_heartbeat is
-- atomic (no window where a live helper's heartbeat 404s).

begin;

-- 1. NULLABLE sensor columns (NULL = "never reported by this device/helper").
--    reals for continuous readings, ints for counts, smallint for small enums.
alter table public.devices
  add column if not exists cpu_power_w real,                 -- CPU package power (W)
  add column if not exists gpu_power_w real,                 -- GPU power (W)
  add column if not exists ane_power_w real,                 -- Apple Neural Engine power (W)
  add column if not exists system_power_w real,              -- total SoC/system power (W)
  add column if not exists cpu_temp_c real,                  -- CPU die temp (°C, indicative)
  add column if not exists gpu_temp_c real,                  -- GPU die temp (°C, indicative)
  add column if not exists battery_temp_c real,              -- battery temp (°C)
  add column if not exists fan_rpm integer,                  -- current fan RPM (max across fans)
  add column if not exists fan_max_rpm integer,              -- hardware max fan RPM
  add column if not exists thermal_state smallint,           -- NSProcessInfo.thermalState 0..3
  add column if not exists battery_charge_pct smallint,      -- current charge 0..100
  add column if not exists battery_state text,               -- charging|discharging|charged|none|unknown
  add column if not exists battery_cycle_count integer,      -- AppleSmartBattery CycleCount
  add column if not exists battery_health_pct real,          -- rawMaxCapacity/designCapacity * 100
  add column if not exists battery_design_capacity integer,  -- design capacity (mAh)
  add column if not exists battery_current_capacity integer, -- current max capacity (mAh)
  add column if not exists adapter_watts real,               -- AC adapter wattage (0 on battery)
  -- what THIS device can actually report, so phones render honestly (a Mac mini
  -- has no battery; a fanless Air has no fans; a helper-less MAS-only Mac reports
  -- only thermal_state + charge). Boolean map, e.g. {"temps":true,"fans":false}.
  add column if not exists sensors_capability jsonb not null default '{}'::jsonb,
  -- when the sensor block was last sampled (may lag last_seen_at if a helper is
  -- too old to report sensors); phones gray out stale readings off this.
  add column if not exists sensors_updated_at timestamptz;

-- devices has per-column grants; new columns each need an explicit SELECT grant
-- for the mobile/desktop read path (matches provider_plan_status in v0.60).
grant select (
  cpu_power_w, gpu_power_w, ane_power_w, system_power_w,
  cpu_temp_c, gpu_temp_c, battery_temp_c,
  fan_rpm, fan_max_rpm, thermal_state,
  battery_charge_pct, battery_state, battery_cycle_count, battery_health_pct,
  battery_design_capacity, battery_current_capacity, adapter_watts,
  sensors_capability, sensors_updated_at
) on public.devices to anon, authenticated;

-- 2. helper_heartbeat: add the optional p_metrics blob.
-- Drop the current secure 6-arg overload (a trailing defaulted param would
-- otherwise create a 2nd overload -> PostgREST "could not choose candidate").
drop function if exists public.helper_heartbeat(uuid, text, integer, integer, integer, jsonb);

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
  v_metrics jsonb;      -- validated numeric metrics (key -> in-range number)
  v_caps jsonb;         -- validated capability map (key -> boolean)
  v_batt_state text;    -- validated battery-state enum
begin
  -- Authenticate via device secret (compare SHA-256 hash) — unchanged.
  select user_id into v_user_id
  from public.devices where id = p_device_id and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  -- v0.60: normalize the optional plan-status map (unchanged).
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

  -- v0.63: normalize the optional sensor metrics blob.
  -- NULL / non-object (old callers) => touch NOTHING (all coalesce to existing).
  v_has_metrics := (p_metrics is not null and jsonb_typeof(p_metrics) = 'object');
  v_metrics := '{}'::jsonb;
  v_caps := null;
  v_batt_state := null;

  if v_has_metrics then
    -- Keep only known numeric keys whose JSON value is a NUMBER within a sane
    -- physical range. The CASE guards the ::numeric cast so a non-number value
    -- can never raise (invalid_text_representation) and break the heartbeat.
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

    -- battery_state: strict enum whitelist.
    if jsonb_typeof(p_metrics->'battery_state') = 'string'
       and (p_metrics->>'battery_state') in ('charging','discharging','charged','none','unknown') then
      v_batt_state := p_metrics->>'battery_state';
    end if;

    -- capability: keep only boolean values, short keys, bounded count.
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
    -- per-field coalesce: an omitted / out-of-range metric preserves last-known.
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

-- Helper calls via the anon key; app never calls this RPC. Re-grant after recreate.
grant execute on function public.helper_heartbeat(uuid, text, integer, integer, integer, jsonb, jsonb) to anon, authenticated;

commit;
