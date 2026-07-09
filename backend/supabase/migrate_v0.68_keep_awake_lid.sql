-- migrate_v0.68_keep_awake_lid.sql — v1.42.1 Keep Awake "lid-closed" option.
--
-- Adds an OPTIONAL boolean `prevent_lid_sleep` to the set_keep_awake payload:
-- the Mac executor then holds an ADDITIONAL kIOPMAssertionTypePreventSystemSleep
-- assertion (Amphetamine's "Closed-Display Mode") — on AC POWER the Mac stays
-- awake with the lid closed; on battery macOS force-sleeps regardless (root-only
-- override; `man caffeinate` documents -s as AC-only).
--
-- Normalization: included as `true` ONLY when enabling AND explicitly boolean
-- true; absent/false/off/non-boolean → key omitted. Everything else (whitelist,
-- auth, ownership, rate limit, 60..86400 ttl clamp) is byte-identical to the
-- v0.67 definition applied 2026-07-09.
--
-- Table CHECK unchanged (same kind). devices schema unchanged (the lid state
-- rides machine_controls.keep_awake_lid_active — heartbeat folds it already).

begin;

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
    -- v0.68: optional lid-closed hold — included ONLY as an explicit boolean
    -- true on enable; anything else (absent, false, non-boolean, disable)
    -- omits the key so the executor's `cmd.lid ?? false` stays honest.
    if v_on and coalesce(jsonb_typeof(p_payload->'prevent_lid_sleep'), '') = 'boolean'
       and (p_payload->>'prevent_lid_sleep')::boolean then
      v_payload := v_payload || jsonb_build_object('prevent_lid_sleep', true);
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

commit;
