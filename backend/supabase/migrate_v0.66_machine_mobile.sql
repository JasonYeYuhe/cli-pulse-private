-- migrate_v0.66_machine_mobile.sql
-- v1.41 "Mobile Machine" — let the phone (and watch, read-only) SEE the Mac's
-- machine state and remotely REQUEST fan-boost + Low Power Mode.
--
-- Two additive tracks, one owner review:
--   TRACK A (snapshot uplink) — extend the existing helper_heartbeat -> devices
--     pipeline with the v1.39 `system` block (uptime / load / memory pressure /
--     swap / disk), the Low Power Mode flag, the honest fan-boost state the Mac
--     executor reports back, and a `machine_controls` capability map so the
--     phone renders ONLY the controls the Mac will actually honor.
--   TRACK B (remote controls) — a NEW device-scoped `machine_commands` queue +
--     RPC trio. The phone enqueues a *request*; the Mac APP (not this backend,
--     not the Python helper) is the executor and owns the fan dead-man
--     heartbeat locally. Commands EXPIRE after 60s so a stale fan command can
--     never fire late.
--
-- Follows the v0.63 device-sensors precedent EXACTLY:
--   * ONE jsonb blob param on helper_heartbeat (not N scalar params) —
--     normalize + range-bound server-side; NEVER store an arbitrary payload.
--   * p_metrics default NULL so old callers omitting it don't clobber;
--     per-field coalesce preserves last-known on omit / transient read failure.
--   * a metric absent OR out of physical range is DROPPED (-> preserve), so one
--     bad read can't fabricate a boundary value or NULL a column.
--   * devices uses COLUMN-LEVEL grants -> every new readable column needs an
--     explicit SELECT grant or authenticated (mobile) can't read it.
--   * the 8KiB p_metrics cap (v0.64) stays.
--
-- Security invariants enforced here (plan §7): fan hold heartbeat NEVER leaves
-- the Mac (this queue only carries requests); every remote kind is allowlisted
-- and payload-validated SERVER-SIDE; 60s command expiry + one-way status
-- transitions (no replay); the process table is NEVER synced.
--
-- DDL is transactional in Postgres, so the CREATE OR REPLACE of helper_heartbeat
-- is atomic (no window where a live helper's heartbeat 404s). ADD COLUMN
-- (nullable / constant-default) is metadata-only on PG11+ — no table rewrite.

begin;

-- ════════════════════════════════════════════════════════════════════════════
-- TRACK A · 1. devices — new NULLABLE snapshot columns (latest-wins).
-- ════════════════════════════════════════════════════════════════════════════
alter table public.devices
  add column if not exists uptime_seconds       bigint,   -- seconds since boot
  add column if not exists load_avg_1m          real,     -- 1-minute load average
  add column if not exists load_avg_5m          real,     -- 5-minute load average
  add column if not exists load_avg_15m         real,     -- 15-minute load average
  add column if not exists memory_pressure      text
    check (memory_pressure is null
           or memory_pressure in ('nominal', 'warn', 'critical')),
  add column if not exists swap_used_bytes      bigint,   -- VM swap in use
  add column if not exists swap_total_bytes     bigint,   -- VM swap total
  add column if not exists disk_free_bytes      bigint,   -- boot volume free
  add column if not exists disk_total_bytes     bigint,   -- boot volume total
  add column if not exists lpm_on               boolean,  -- Low Power Mode active
  add column if not exists fan_boost_active     boolean,  -- Mac executor is holding a boost
  add column if not exists fan_boost_target_rpm integer,  -- current boost target RPM
  -- what REMOTE controls this Mac will honor right now, so the phone renders
  -- honestly: {"remote_fan":true,"remote_lpm":true}. Absent/false = hide the
  -- control (never gray it). Distinct from `sensors_capability` (read side).
  add column if not exists machine_controls     jsonb not null default '{}'::jsonb;

-- devices has per-column grants; each new readable column needs an explicit
-- SELECT grant for the mobile/desktop read path (matches v0.60 / v0.63).
grant select (
  uptime_seconds, load_avg_1m, load_avg_5m, load_avg_15m, memory_pressure,
  swap_used_bytes, swap_total_bytes, disk_free_bytes, disk_total_bytes,
  lpm_on, fan_boost_active, fan_boost_target_rpm, machine_controls
) on public.devices to anon, authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- TRACK A · 2. helper_heartbeat — extend the p_metrics validation + coalesce.
-- Body is COPIED VERBATIM from live prod (verified 2026-07-08 via
-- pg_get_functiondef) and only DELTA'd: +9 numeric spec rows, +memory_pressure
-- enum, +lpm_on / fan_boost_active booleans, +machine_controls capability map.
-- Signature is IDENTICAL to the live 7-arg overload, so CREATE OR REPLACE is
-- in-place (no drop, no overload ambiguity). 8KiB cap preserved.
-- ════════════════════════════════════════════════════════════════════════════
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
  v_metrics jsonb;              -- validated numeric metrics (key -> in-range number)
  v_caps jsonb;                 -- validated sensors_capability map (key -> boolean)
  v_batt_state text;           -- validated battery-state enum
  v_pressure text;             -- v0.66: validated memory_pressure enum
  v_lpm_on boolean;            -- v0.66: validated Low Power Mode flag
  v_fan_boost_active boolean;  -- v0.66: validated fan-boost flag (executor-reported)
  v_machine_controls jsonb;    -- v0.66: validated remote-control capability map
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

  -- v0.63/v0.64: normalize the optional sensor metrics blob.
  -- NULL / non-object (old callers) => touch NOTHING (all coalesce to existing).
  v_has_metrics := (p_metrics is not null and jsonb_typeof(p_metrics) = 'object');
  if v_has_metrics and pg_column_size(p_metrics) > 8192 then
    v_has_metrics := false;
  end if;
  v_metrics := '{}'::jsonb;
  v_caps := null;
  v_batt_state := null;
  v_pressure := null;
  v_lpm_on := null;
  v_fan_boost_active := null;
  v_machine_controls := null;

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
      ('adapter_watts',            0,            1000),
      -- v0.66 system block + fan-boost target:
      ('uptime_seconds',           0,            315360000),        -- 0 .. 10 years
      ('load_avg_1m',              0,            1024),
      ('load_avg_5m',              0,            1024),
      ('load_avg_15m',             0,            1024),
      ('swap_used_bytes',          0,            1125899906842624), -- 0 .. 1 PiB
      ('swap_total_bytes',         0,            1125899906842624),
      ('disk_free_bytes',          0,            1125899906842624),
      ('disk_total_bytes',         0,            1125899906842624),
      ('fan_boost_target_rpm',     0,            30000)
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

    -- v0.66 memory_pressure: strict enum whitelist.
    if jsonb_typeof(p_metrics->'memory_pressure') = 'string'
       and (p_metrics->>'memory_pressure') in ('nominal','warn','critical') then
      v_pressure := p_metrics->>'memory_pressure';
    end if;

    -- v0.66 booleans: only accept an actual JSON boolean.
    if jsonb_typeof(p_metrics->'lpm_on') = 'boolean' then
      v_lpm_on := (p_metrics->>'lpm_on')::boolean;
    end if;
    if jsonb_typeof(p_metrics->'fan_boost_active') = 'boolean' then
      v_fan_boost_active := (p_metrics->>'fan_boost_active')::boolean;
    end if;

    -- sensors_capability: keep only boolean values, short keys, bounded count.
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

    -- v0.66 machine_controls: remote-control capability map (booleans only).
    if jsonb_typeof(p_metrics->'machine_controls') = 'object' then
      select coalesce(jsonb_object_agg(k, (v = 'true')), '{}'::jsonb) into v_machine_controls
      from (
        select key as k, value as v
        from jsonb_each_text(p_metrics->'machine_controls')
        where value in ('true','false') and char_length(key) <= 32
        order by key
        limit 16
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
    -- v0.66 system block + LPM + fan-boost state + remote-control map:
    uptime_seconds           = coalesce((v_metrics->>'uptime_seconds')::numeric::bigint, uptime_seconds),
    load_avg_1m              = coalesce((v_metrics->>'load_avg_1m')::real,               load_avg_1m),
    load_avg_5m              = coalesce((v_metrics->>'load_avg_5m')::real,               load_avg_5m),
    load_avg_15m             = coalesce((v_metrics->>'load_avg_15m')::real,              load_avg_15m),
    memory_pressure          = coalesce(v_pressure,                                      memory_pressure),
    swap_used_bytes          = coalesce((v_metrics->>'swap_used_bytes')::numeric::bigint,  swap_used_bytes),
    swap_total_bytes         = coalesce((v_metrics->>'swap_total_bytes')::numeric::bigint, swap_total_bytes),
    disk_free_bytes          = coalesce((v_metrics->>'disk_free_bytes')::numeric::bigint,   disk_free_bytes),
    disk_total_bytes         = coalesce((v_metrics->>'disk_total_bytes')::numeric::bigint,  disk_total_bytes),
    lpm_on                   = coalesce(v_lpm_on,                                        lpm_on),
    fan_boost_active         = coalesce(v_fan_boost_active,                              fan_boost_active),
    fan_boost_target_rpm     = coalesce((v_metrics->>'fan_boost_target_rpm')::numeric::int, fan_boost_target_rpm),
    machine_controls         = coalesce(v_machine_controls,                             machine_controls),
    sensors_updated_at       = case when v_has_metrics then now() else sensors_updated_at end
  where id = p_device_id;

  return jsonb_build_object('status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Helper calls via the anon key; app never calls this RPC. Re-grant for safety
-- (CREATE OR REPLACE preserves grants, but be explicit/idempotent).
grant execute on function public.helper_heartbeat(uuid, text, integer, integer, integer, jsonb, jsonb) to anon, authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- TRACK B · 3. machine_commands — device-scoped remote-control request queue.
-- The phone enqueues a REQUEST via remote_app_send_machine_command; the helper
-- pulls it and hands it to the Mac app executor. Status is ONE-WAY:
--   pending -> delivered -> done | failed        (expired is a terminal sink)
-- A pending command that isn't picked up within 60s is EXPIRED at pull time so
-- a stale fan command can never fire late.
-- ════════════════════════════════════════════════════════════════════════════
create table if not exists public.machine_commands (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  device_id     uuid not null references public.devices(id) on delete cascade,
  kind          text not null
                  check (kind in ('set_fan_target', 'revert_fan_auto', 'set_low_power_mode')),
  -- server-BUILT, bounded payload (the send RPC normalizes it; clients cannot
  -- direct-insert — RLS has no INSERT policy). e.g. {"rpm":4200,"ttl_seconds":900}
  payload       jsonb not null default '{}'::jsonb,
  status        text not null default 'pending'
                  check (status in ('pending', 'delivered', 'done', 'failed', 'expired')),
  result        jsonb,  -- typed completion result e.g. {"error":"daemon_unavailable"}
  created_at    timestamptz not null default now(),
  -- pickup deadline: a fan command must NEVER fire late. Distinct from the boost
  -- HOLD duration (payload.ttl_seconds), which the Mac executor owns locally.
  expires_at    timestamptz not null default (now() + interval '60 seconds'),
  picked_up_at  timestamptz,
  completed_at  timestamptz
);

alter table public.machine_commands enable row level security;

-- App reads its own command rows to surface status/errors; all WRITES go through
-- the SECURITY DEFINER RPCs below (no INSERT/UPDATE/DELETE policy -> direct
-- client writes denied). Table-level grants come from Supabase default privileges
-- (mirrors remote_session_commands); RLS is the only thing that gates access.
drop policy if exists "Users can read own machine commands" on public.machine_commands;
create policy "Users can read own machine commands"
  on public.machine_commands for select using ((select auth.uid()) = user_id);

-- Helper polls pending-by-device; app polls a specific row by id.
create index if not exists idx_machine_commands_pending
  on public.machine_commands(device_id, created_at)
  where status = 'pending';

-- ── RPC 1 (app-facing): enqueue a remote machine-control REQUEST ─────────────
-- auth.uid() owner check + Remote-Control gate + server-side payload validation
-- + a per-user rate limit (fan commands are chunky, not chatty: <= 6 / minute).
create or replace function public.remote_app_send_machine_command(
  p_device_id uuid,
  p_kind text,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_owns boolean;
  v_recent int;
  v_command_id uuid;
  v_payload jsonb := '{}'::jsonb;
  v_rpm_num numeric;   -- validate as numeric BEFORE the ::int cast (no 22003)
  v_ttl_num numeric;
  v_rpm int;
  v_ttl int;
  v_on boolean;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    raise exception 'Remote Control is disabled';
  end if;
  if p_kind not in ('set_fan_target', 'revert_fan_auto', 'set_low_power_mode') then
    raise exception 'Invalid command kind: %', p_kind;
  end if;

  -- Ownership: the device must belong to the caller.
  select true into v_owns
  from public.devices
  where id = p_device_id and user_id = v_user_id;
  if v_owns is null then
    raise exception 'Device not found';
  end if;

  -- Serialize this caller's concurrent sends so the rate-limit count+insert is
  -- atomic (closes the TOCTOU where two parallel calls both read v_recent < 6).
  -- Distinct advisory key (2) from the session pull (0) / machine pull (1).
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 2));

  -- Rate limit: <= 6 machine commands per user per rolling minute.
  select count(*) into v_recent
  from public.machine_commands
  where user_id = v_user_id and created_at > now() - interval '60 seconds';
  if v_recent >= 6 then
    raise exception 'Rate limit exceeded (max 6 machine commands per minute)';
  end if;

  -- Server-side payload validation, per kind. NEVER trust the client's numbers.
  -- Range-check the NUMERIC first, then cast — a huge JSON number (> 2^31) must
  -- surface the friendly 'rpm out of range', not an opaque 22003 int-overflow.
  if p_kind = 'set_fan_target' then
    if jsonb_typeof(p_payload->'rpm') <> 'number' then
      raise exception 'set_fan_target requires numeric rpm';
    end if;
    v_rpm_num := floor((p_payload->>'rpm')::numeric);
    if v_rpm_num < 0 or v_rpm_num > 30000 then
      raise exception 'rpm out of range (0..30000)';
    end if;
    v_rpm := v_rpm_num::int;
    v_ttl_num := 900;  -- default boost hold 15 minutes
    if jsonb_typeof(p_payload->'ttl_seconds') = 'number' then
      v_ttl_num := floor((p_payload->>'ttl_seconds')::numeric);
    end if;
    if v_ttl_num < 60 then
      v_ttl_num := 60;
    elsif v_ttl_num > 3600 then
      v_ttl_num := 3600;
    end if;
    v_ttl := v_ttl_num::int;
    v_payload := jsonb_build_object('rpm', v_rpm, 'ttl_seconds', v_ttl);
  elsif p_kind = 'set_low_power_mode' then
    if jsonb_typeof(p_payload->'on') <> 'boolean' then
      raise exception 'set_low_power_mode requires boolean on';
    end if;
    v_on := (p_payload->>'on')::boolean;
    v_payload := jsonb_build_object('on', v_on);
  else
    -- revert_fan_auto: no payload.
    v_payload := '{}'::jsonb;
  end if;

  insert into public.machine_commands (user_id, device_id, kind, payload, status)
  values (v_user_id, p_device_id, p_kind, v_payload, 'pending')
  returning id into v_command_id;

  return jsonb_build_object('command_id', v_command_id);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ── RPC 2 (helper-facing): pull pending machine commands for a device ────────
-- Device-secret gated. Expires stale pending commands (past their 60s pickup
-- deadline) BEFORE delivering, so a late fan command is never handed out.
create or replace function public.remote_helper_pull_machine_commands(
  p_device_id uuid,
  p_helper_secret text,
  p_max integer default 10
)
returns jsonb as $$
declare
  v_user_id uuid;
  v_max integer;
  v_result jsonb;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  v_max := least(greatest(coalesce(p_max, 10), 1), 50);

  -- Distinct advisory-lock key from the session-command pull (0) so the two
  -- ~1 Hz pull loops never serialize against each other.
  perform pg_advisory_xact_lock(hashtextextended(p_device_id::text, 1));

  -- Expire stale pending commands (never fire a late fan command).
  update public.machine_commands
     set status = 'expired',
         completed_at = now(),
         result = coalesce(result, '{}'::jsonb) || jsonb_build_object('error', 'ttl_expired')
   where device_id = p_device_id
     and user_id = v_user_id
     and status = 'pending'
     and expires_at <= now();

  with picked as (
    update public.machine_commands
    set status = 'delivered', picked_up_at = now()
    where id in (
      select id from public.machine_commands
      where device_id = p_device_id
        and user_id = v_user_id
        and status = 'pending'
        and expires_at > now()
      order by created_at asc
      limit v_max
      for update skip locked
    )
    returning id, kind, payload, created_at
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',         id,
        'kind',       kind,
        'payload',    payload,
        'created_at', created_at
      )
      order by created_at asc
    ),
    '[]'::jsonb
  )
  into v_result
  from picked;

  return v_result;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ── RPC 3 (helper-facing): complete a delivered machine command ──────────────
-- Device-secret gated. One-way transition: only a 'delivered' row can move to
-- 'done'/'failed' (no replay). `p_result` is a small typed jsonb (bounded).
create or replace function public.remote_helper_complete_machine_command(
  p_device_id uuid,
  p_helper_secret text,
  p_command_id uuid,
  p_status text,
  p_result jsonb default null
)
returns jsonb as $$
declare
  v_user_id uuid;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;
  if p_status not in ('done', 'failed') then
    raise exception 'Invalid completion status: %', p_status;
  end if;

  update public.machine_commands
     set status = p_status,
         completed_at = now(),
         result = case
                    when p_result is not null
                         and jsonb_typeof(p_result) = 'object'
                         and pg_column_size(p_result) <= 1024
                    then p_result
                    else result
                  end
   where id = p_command_id
     and device_id = p_device_id
     and user_id = v_user_id
     and status = 'delivered';

  return jsonb_build_object('status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ── grants (v0.53 hygiene) ───────────────────────────────────────────────────
-- App RPC enforces auth.uid() internally -> authenticated only (drop PUBLIC/anon).
revoke execute on function public.remote_app_send_machine_command(uuid, text, jsonb) from public, anon;
grant  execute on function public.remote_app_send_machine_command(uuid, text, jsonb) to authenticated;

-- Helper RPCs authenticate with the anon key + per-device helper_secret HMAC ->
-- anon + authenticated (mirrors remote_helper_pull_commands / _complete_command).
grant execute on function public.remote_helper_pull_machine_commands(uuid, text, integer) to anon, authenticated;
grant execute on function public.remote_helper_complete_machine_command(uuid, text, uuid, text, jsonb) to anon, authenticated;

commit;
