-- ============================================================
-- CLI Pulse — Helper RPC Functions
-- Called by the helper daemon via device-scoped helper tokens.
--
-- register_helper: security definer. Authentication is via the
--   pairing code: the function looks up pairing_codes.user_id and
--   creates a device row under that user_id. Does NOT require or
--   check auth.uid() — callers use the anon key. (For an
--   auth.uid()-based desktop sign-in path, see register_desktop_helper,
--   planned for v0.3.0.)
-- helper_heartbeat / helper_sync: security definer — helpers call
--   via anon key, so RLS would block them.  Internal auth is done
--   by validating (device_id, helper_secret) inside the function.
-- ============================================================

-- Register a helper device via pairing code
-- Called once during pairing. Response shape:
--   success: { device_id, user_id, helper_secret }
--   failure: { error: <code>, message: <human-readable> }
--   error codes: rate_limited | invalid_code | too_many_failed_attempts | expired
-- Brute-force protection (see migrate_v0.16):
--   Layer 1 — per-code failed_attempts counter (caps guesses at a real code)
--   Layer 2 — per-IP 10/min window via pairing_attempt_log (caps random
--             code cycling where the code doesn't exist in pairing_codes)
-- IMPORTANT: Expected failures RETURN jsonb — they do NOT raise. RAISE would
-- roll back the pairing_attempt_log insert and failed_attempts bump made
-- earlier in the function, defeating the counters.
create or replace function public.register_helper(
  p_pairing_code text,
  p_device_name text,
  p_device_type text default 'macOS',
  p_system text default '',
  p_helper_version text default '0.1.0'
)
returns jsonb as $$
declare
  v_user_id uuid;
  v_device_id uuid;
  v_expires_at timestamptz;
  v_helper_secret text;
  v_failed_attempts integer;
  v_ip text;
  v_ip_attempt_count integer;
begin
  begin
    v_ip := nullif(current_setting('request.headers', true), '')::jsonb->>'cf-connecting-ip';
  exception when others then
    v_ip := null;
  end;

  if v_ip is not null then
    perform pg_advisory_xact_lock(hashtext(v_ip)::bigint);
  end if;

  delete from public.pairing_attempt_log where attempted_at < now() - interval '1 hour';

  insert into public.pairing_attempt_log (ip_addr) values (v_ip);

  if v_ip is not null then
    select count(*) into v_ip_attempt_count
    from public.pairing_attempt_log
    where ip_addr = v_ip
      and attempted_at > now() - interval '1 minute';

    if v_ip_attempt_count > 10 then
      return jsonb_build_object(
        'error', 'rate_limited',
        'message', 'Too many pairing attempts — please wait a minute and try again'
      );
    end if;
  end if;

  select user_id, expires_at, failed_attempts
  into v_user_id, v_expires_at, v_failed_attempts
  from public.pairing_codes where code = p_pairing_code;

  if v_user_id is null then
    update public.pairing_codes set failed_attempts = failed_attempts + 1
    where code = p_pairing_code;
    return jsonb_build_object('error', 'invalid_code', 'message', 'Invalid pairing code');
  end if;

  if v_failed_attempts >= 5 then
    return jsonb_build_object(
      'error', 'too_many_failed_attempts',
      'message', 'Too many failed attempts — please generate a new pairing code'
    );
  end if;

  if v_expires_at < now() then
    update public.pairing_codes set failed_attempts = failed_attempts + 1
    where code = p_pairing_code;
    delete from public.pairing_codes where code = p_pairing_code;
    return jsonb_build_object('error', 'expired', 'message', 'Pairing code has expired');
  end if;

  v_helper_secret := 'helper_' || encode(gen_random_bytes(32), 'hex');

  insert into public.devices (user_id, name, type, system, helper_version, status, helper_secret)
  values (v_user_id, left(p_device_name, 255), left(p_device_type, 50), left(p_system, 255), left(p_helper_version, 20), 'Online', encode(digest(v_helper_secret, 'sha256'), 'hex'))
  returning id into v_device_id;

  update public.profiles set paired = true where id = v_user_id;
  delete from public.pairing_codes where code = p_pairing_code;

  return jsonb_build_object('device_id', v_device_id, 'user_id', v_user_id, 'helper_secret', v_helper_secret);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Helper heartbeat — requires device secret
-- v0.60: optional p_provider_plan_status carries the per-provider managed-session
-- plan map ({"codex":"off_plan",...}); defaults NULL so pre-v0.60 callers that omit
-- it never clobber the stored value (coalesce preserves last-known). Payload is
-- normalized server-side (only on_plan/off_plan string values, short keys, bounded).
-- v0.63: optional p_metrics carries the machine-health sensor blob (temps, fans,
-- power, battery health, thermal_state, capability map). Same discipline — one
-- jsonb blob, default NULL, normalize + bound server-side, per-field coalesce so
-- an omitted / out-of-range reading preserves last-known instead of clobbering.
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
  -- Authenticate via device secret (compare SHA-256 hash)
  select user_id into v_user_id
  from public.devices where id = p_device_id and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  -- Normalize the optional plan map: NULL / non-object => leave stored value
  -- untouched; valid object => keep only on_plan/off_plan entries (bounded).
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

  -- v0.63: normalize the optional sensor metrics blob. NULL / non-object (old
  -- callers) => touch NOTHING (every sensor column coalesces to its existing value).
  v_has_metrics := (p_metrics is not null and jsonb_typeof(p_metrics) = 'object');
  -- v0.64: bound the payload. This is SECURITY DEFINER and anon-reachable, so a
  -- caller with a stolen device secret must not be able to make it parse/walk an
  -- arbitrarily large jsonb. Oversized => ignore the whole metrics block (preserve
  -- last-known), never error. Legit payloads are ~500 B; 8 KiB is generous.
  if v_has_metrics and pg_column_size(p_metrics) > 8192 then
    v_has_metrics := false;
  end if;
  v_metrics := '{}'::jsonb;
  v_caps := null;
  v_batt_state := null;

  if v_has_metrics then
    -- Keep only known numeric keys whose JSON value is a NUMBER within a sane
    -- physical range. The CASE guards the ::numeric cast so a non-number value
    -- can never raise and break the heartbeat.
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
grant execute on function public.helper_heartbeat(uuid, text, integer, integer, integer, jsonb, jsonb) to anon, authenticated;

-- Helper sync — upsert sessions, alerts, provider quotas
-- Requires device secret for authentication
create or replace function public.helper_sync(
  p_device_id uuid,
  p_helper_secret text,
  p_sessions jsonb default '[]'::jsonb,
  p_alerts jsonb default '[]'::jsonb,
  p_provider_remaining jsonb default '{}'::jsonb,
  p_provider_tiers jsonb default '{}'::jsonb
)
returns jsonb as $$
declare
  v_user_id uuid;
  v_session jsonb;
  v_alert jsonb;
  v_provider text;
  v_remaining integer;
  v_session_count integer := 0;
  v_alert_count integer := 0;
  v_synced_ids text[] := '{}';
begin
  -- Authenticate via device secret (compare SHA-256 hash)
  select user_id into v_user_id
  from public.devices where id = p_device_id and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  -- v0.25: serialize concurrent syncs from the same device so two helper
  -- instances (e.g. a relaunch overlapping the old process) can't race and
  -- mark each other's sessions Ended.
  perform pg_advisory_xact_lock(hashtextextended(p_device_id::text, 0));

  -- Guard against oversized payloads (DoS prevention)
  if jsonb_array_length(p_sessions) > 500 then
    raise exception 'Too many sessions (max 500)';
  end if;
  if jsonb_array_length(p_alerts) > 500 then
    raise exception 'Too many alerts (max 500)';
  end if;

  update public.devices set status = 'Online', last_seen_at = now()
  where id = p_device_id;

  for v_session in select * from jsonb_array_elements(p_sessions) loop
    v_synced_ids := v_synced_ids || left(v_session->>'id', 128);
    insert into public.sessions (id, user_id, device_id, name, provider, project, status, total_usage, estimated_cost, requests, error_count, collection_confidence, project_hash, started_at, last_active_at, synced_at)
    values (
      left(v_session->>'id', 128), v_user_id, p_device_id,
      coalesce(v_session->>'name', ''), v_session->>'provider',
      coalesce(v_session->>'project', ''), coalesce(v_session->>'status', 'Running'),
      coalesce((v_session->>'total_usage')::integer, 0),
      least(greatest(coalesce((v_session->>'exact_cost')::numeric, 0), 0), 9999),
      coalesce((v_session->>'requests')::integer, 0),
      coalesce((v_session->>'error_count')::integer, 0),
      coalesce(v_session->>'collection_confidence', 'medium'),
      nullif(v_session->>'project_hash', ''),
      least(coalesce((v_session->>'started_at')::timestamptz, now()), now() + interval '10 minutes'),
      least(coalesce((v_session->>'last_active_at')::timestamptz, now()), now() + interval '10 minutes'), now()
    )
    on conflict (id, user_id) do update set
      name = excluded.name, status = excluded.status,
      total_usage = excluded.total_usage, estimated_cost = excluded.estimated_cost,
      requests = excluded.requests, error_count = excluded.error_count,
      collection_confidence = excluded.collection_confidence,
      project_hash = coalesce(excluded.project_hash, public.sessions.project_hash),
      last_active_at = excluded.last_active_at, synced_at = now();
    v_session_count := v_session_count + 1;
  end loop;

  -- Mark sessions from this device not in current sync as Ended
  if coalesce(array_length(v_synced_ids, 1), 0) > 0 then
    -- Normal case: end sessions not reported in this sync
    update public.sessions set status = 'Ended'
    where device_id = p_device_id and user_id = v_user_id
      and status = 'Running' and id != all(v_synced_ids)
      and last_active_at < now() - interval '10 minutes';
  else
    -- Empty sync (helper restart/crash): end stale sessions older than 10 minutes
    -- to prevent ghost sessions, while giving a grace period for transient issues
    update public.sessions set status = 'Ended'
    where device_id = p_device_id and user_id = v_user_id
      and status = 'Running' and last_active_at < now() - interval '10 minutes';
  end if;

  for v_alert in select * from jsonb_array_elements(p_alerts) loop
    insert into public.alerts (id, user_id, type, severity, title, message, related_project_id, related_project_name, related_session_id, related_session_name, related_provider, related_device_name, source_kind, source_id, grouping_key, suppression_key, created_at)
    values (
      left(v_alert->>'id', 128), v_user_id, v_alert->>'type',
      coalesce(v_alert->>'severity', 'Info'), v_alert->>'title',
      coalesce(v_alert->>'message', ''),
      v_alert->>'related_project_id', v_alert->>'related_project_name',
      v_alert->>'related_session_id', v_alert->>'related_session_name',
      v_alert->>'related_provider', v_alert->>'related_device_name',
      v_alert->>'source_kind', v_alert->>'source_id',
      v_alert->>'grouping_key', v_alert->>'suppression_key',
      coalesce((v_alert->>'created_at')::timestamptz, now())
    )
    on conflict (id, user_id) do update set
      severity = excluded.severity, title = excluded.title, message = excluded.message,
      source_kind = excluded.source_kind, source_id = excluded.source_id,
      grouping_key = excluded.grouping_key, suppression_key = excluded.suppression_key;
    v_alert_count := v_alert_count + 1;
  end loop;

  -- Upsert provider quotas with tier data (new) or just remaining (legacy)
  for v_provider in select * from jsonb_object_keys(p_provider_tiers) loop
    declare
      v_tier_data jsonb := p_provider_tiers -> v_provider;
    begin
      insert into public.provider_quotas (user_id, provider, remaining, quota, plan_type, reset_time, tiers, updated_at)
      values (
        v_user_id, v_provider,
        coalesce((v_tier_data->>'remaining')::integer, 0),
        (v_tier_data->>'quota')::integer,
        v_tier_data->>'plan_type',
        (v_tier_data->>'reset_time')::timestamptz,
        coalesce(v_tier_data->'tiers', '[]'::jsonb),
        now()
      )
      on conflict (user_id, provider) do update set
        remaining = excluded.remaining, quota = excluded.quota,
        plan_type = excluded.plan_type, reset_time = excluded.reset_time,
        tiers = excluded.tiers, updated_at = now();
    end;
  end loop;

  -- Legacy fallback: update remaining for providers not already handled by p_provider_tiers
  for v_provider, v_remaining in select * from jsonb_each_text(p_provider_remaining) loop
    if NOT p_provider_tiers ? v_provider then
      insert into public.provider_quotas (user_id, provider, remaining, updated_at)
      values (v_user_id, v_provider, v_remaining::integer, now())
      on conflict (user_id, provider) do update set
        remaining = excluded.remaining, updated_at = now();
    end if;
  end loop;

  return jsonb_build_object('sessions_synced', v_session_count, 'alerts_synced', v_alert_count);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;
