-- migrate_v0.67_keep_awake.sql — v1.42 "Keep Awake" (Amphetamine-style).
--
-- Adds the 'set_keep_awake' machine command: the phone asks a paired Mac to
-- hold (or release) an IOKit PreventUserIdleSystemSleep power assertion — the
-- display may sleep, the system won't idle-sleep. Executor-side it's a plain
-- in-process IOPM assertion (no root daemon), so the ONLY backend change is
-- the command whitelist + payload normalization:
--   payload {"on": true|false, "ttl_seconds": 60..86400 (optional; absent =
--   indefinite, Amphetamine's default)}. "off" ignores ttl.
--
-- Capability + live state ("keep_awake"/"keep_awake_active") ride the existing
-- devices.machine_controls jsonb — helper_heartbeat already folds EVERY key of
-- p_metrics->machine_controls to boolean per key (v0.66), so NO devices-schema
-- change and NO heartbeat re-emit.
--
-- The RPC body below is the LIVE PROD definition (pg_get_functiondef pulled
-- 2026-07-09 — zero drift vs migrate_v0.66) plus: the whitelist entry, the
-- set_keep_awake payload branch, and ONE deliberate hardening (v1.42 review):
-- `jsonb_typeof(p_payload->'missing_key')` is NULL, and `NULL <> 'x'` is NULL,
-- so the "requires ..." guards never fired for an ABSENT key (benign — the
-- executor fails such commands as "clamped" — but the validation was dead).
-- All three payload guards now coalesce the typeof to '' so a missing key
-- raises like a wrong-typed one. Real clients always send the keys.

begin;

-- ── 1. machine_commands.kind CHECK: allow 'set_keep_awake' ────────────────────
alter table public.machine_commands
  drop constraint if exists machine_commands_kind_check;
alter table public.machine_commands
  add constraint machine_commands_kind_check
  check (kind in ('set_fan_target', 'revert_fan_auto', 'set_low_power_mode', 'set_keep_awake'));

-- ── 2. remote_app_send_machine_command: whitelist + payload branch ────────────
create or replace function public.remote_app_send_machine_command(
  p_device_id uuid, p_kind text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_owns boolean;
  v_recent int;
  v_command_id uuid;
  v_payload jsonb := '{}'::jsonb;
  v_rpm_num numeric;
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
  if p_kind not in ('set_fan_target', 'revert_fan_auto', 'set_low_power_mode', 'set_keep_awake') then
    raise exception 'Invalid command kind: %', p_kind;
  end if;

  select true into v_owns
  from public.devices
  where id = p_device_id and user_id = v_user_id;
  if v_owns is null then
    raise exception 'Device not found';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text, 2));

  select count(*) into v_recent
  from public.machine_commands
  where user_id = v_user_id and created_at > now() - interval '60 seconds';
  if v_recent >= 6 then
    raise exception 'Rate limit exceeded (max 6 machine commands per minute)';
  end if;

  if p_kind = 'set_fan_target' then
    if coalesce(jsonb_typeof(p_payload->'rpm'), '') <> 'number' then
      raise exception 'set_fan_target requires numeric rpm';
    end if;
    v_rpm_num := floor((p_payload->>'rpm')::numeric);
    if v_rpm_num < 0 or v_rpm_num > 30000 then
      raise exception 'rpm out of range (0..30000)';
    end if;
    v_rpm := v_rpm_num::int;
    v_ttl_num := 900;
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
    if coalesce(jsonb_typeof(p_payload->'on'), '') <> 'boolean' then
      raise exception 'set_low_power_mode requires boolean on';
    end if;
    v_on := (p_payload->>'on')::boolean;
    v_payload := jsonb_build_object('on', v_on);
  elsif p_kind = 'set_keep_awake' then
    -- v1.42: {"on": bool, "ttl_seconds": optional 60..86400}. Absent ttl on
    -- enable = indefinite hold (bounded by the local Mac UI / app lifetime);
    -- ttl is dropped on disable. Range-check the NUMERIC before ::int
    -- (int-overflow-before-range — v0.66 review catch).
    if coalesce(jsonb_typeof(p_payload->'on'), '') <> 'boolean' then
      raise exception 'set_keep_awake requires boolean on';
    end if;
    v_on := (p_payload->>'on')::boolean;
    if v_on and jsonb_typeof(p_payload->'ttl_seconds') = 'number' then
      v_ttl_num := floor((p_payload->>'ttl_seconds')::numeric);
      if v_ttl_num < 60 then
        v_ttl_num := 60;
      elsif v_ttl_num > 86400 then
        v_ttl_num := 86400;
      end if;
      v_ttl := v_ttl_num::int;
      v_payload := jsonb_build_object('on', true, 'ttl_seconds', v_ttl);
    else
      v_payload := jsonb_build_object('on', v_on);
    end if;
  else
    v_payload := '{}'::jsonb;
  end if;

  insert into public.machine_commands (user_id, device_id, kind, payload, status)
  values (v_user_id, p_device_id, p_kind, v_payload, 'pending')
  returning id into v_command_id;

  return jsonb_build_object('command_id', v_command_id);
end;
$function$;

-- Grants are unchanged (authenticated-only execute, inherited from v0.66 —
-- CREATE OR REPLACE preserves existing ACLs).

commit;
