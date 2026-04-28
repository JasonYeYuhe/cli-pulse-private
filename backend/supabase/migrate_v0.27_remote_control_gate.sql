-- ============================================================
-- v0.27 — Remote Control gate (privacy-first opt-in)
-- Date: 2026-04-28
-- Adds: user_settings.remote_control_enabled (boolean, default false)
-- Plus a server-side gate baked into every v0.26 helper RPC and the two
-- write-side app RPCs. RLS-only protection isn't enough on its own:
-- helpers authenticate by device_id + helper_secret (not auth.uid), so a
-- user toggling Remote Control off in the UI must also block the helper
-- end of the channel — otherwise an old or rogue helper could keep
-- creating permission requests in the background.
--
-- Posture:
--   * Default OFF for every existing user. Migration sets default false on
--     the column so freshly-created profiles are opted out, and we do NOT
--     touch existing rows (they fall through to the column default on
--     upsert because v0.25 already had a defaulted column too).
--   * remote_control_enabled = false → all helper-side remote_* RPCs raise
--     the *same* "Device not found or unauthorized" error as a failed auth
--     check, so a helper can't distinguish "wrong secret" from "user has
--     disabled the feature". remote_hook.py treats the raise as a network
--     blip and falls back to local CLI prompt.
--   * App-side decide / send_command also check the gate. Read-side
--     `remote_app_list_pending_approvals` is left RLS-only because it
--     can't escalate any state — listing zero rows when the gate is off
--     is the natural shape.
--
-- Idempotent: safe to re-run.
-- ============================================================

alter table public.user_settings
  add column if not exists remote_control_enabled boolean not null default false;

-- ── Internal: combined auth + gate check ──────────────────────
-- Returns user_id only when:
--   1. (device_id, helper_secret) authenticate, AND
--   2. user_settings.remote_control_enabled is true.
-- Returns null in either failure case so callers raise a single uniform
-- "unauthorized" error and don't leak feature-flag state to the helper.
create or replace function public._remote_authenticate_helper_gated(
  p_device_id uuid,
  p_helper_secret text
) returns uuid as $$
declare
  v_user_id uuid;
  v_enabled boolean;
begin
  select user_id into v_user_id
  from public.devices
  where id = p_device_id
    and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');

  if v_user_id is null then
    return null;
  end if;

  -- COALESCE so a user with no user_settings row (shouldn't happen — the
  -- handle_new_profile trigger creates one — but be defensive) defaults
  -- to OFF, not ON.
  select coalesce(remote_control_enabled, false) into v_enabled
  from public.user_settings
  where user_id = v_user_id;

  if not coalesce(v_enabled, false) then
    return null;
  end if;

  return v_user_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ── Re-emit every v0.26 helper RPC with the gate ──────────────
-- The bodies match v0.26 except the helper `_remote_authenticate_helper`
-- call is swapped for the gated variant. Kept in this single migration so
-- a reviewer can diff in one place.

create or replace function public.remote_helper_register_session(
  p_device_id uuid,
  p_helper_secret text,
  p_session_id uuid,
  p_provider text,
  p_cwd_basename text default '',
  p_cwd_hmac text default null,
  p_client_label text default null
) returns jsonb as $$
declare
  v_user_id uuid;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;
  if p_provider not in ('claude', 'codex', 'shell') then
    raise exception 'Invalid provider: %', p_provider;
  end if;

  insert into public.remote_sessions (
    id, user_id, device_id, provider, cwd_basename, cwd_hmac, client_label,
    status, last_event_at
  ) values (
    p_session_id, v_user_id, p_device_id, p_provider,
    coalesce(left(p_cwd_basename, 255), ''),
    p_cwd_hmac,
    nullif(left(coalesce(p_client_label, ''), 128), ''),
    'running', now()
  )
  on conflict (id) do update set
    status = 'running',
    last_event_at = now(),
    cwd_basename = coalesce(nullif(excluded.cwd_basename, ''), public.remote_sessions.cwd_basename),
    cwd_hmac = coalesce(excluded.cwd_hmac, public.remote_sessions.cwd_hmac);

  return jsonb_build_object('session_id', p_session_id, 'status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


create or replace function public.remote_helper_post_event(
  p_device_id uuid,
  p_helper_secret text,
  p_session_id uuid,
  p_seq integer,
  p_kind text,
  p_payload text
) returns jsonb as $$
declare
  v_user_id uuid;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;
  if p_kind not in ('stdout', 'stderr', 'status', 'info') then
    raise exception 'Invalid event kind: %', p_kind;
  end if;

  if not exists (
    select 1 from public.remote_sessions
    where id = p_session_id and user_id = v_user_id and device_id = p_device_id
  ) then
    raise exception 'Session not found for device';
  end if;

  insert into public.remote_session_events (
    session_id, user_id, device_id, seq, kind, payload
  ) values (
    p_session_id, v_user_id, p_device_id, p_seq, p_kind,
    left(coalesce(p_payload, ''), 4096)
  );

  update public.remote_sessions
  set last_event_at = now(),
      status = case when p_kind = 'status' and p_payload = 'stopped'
                    then 'stopped'
                    when p_kind = 'status' and p_payload = 'errored'
                    then 'errored'
                    else status end
  where id = p_session_id;

  return jsonb_build_object('status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


create or replace function public.remote_helper_pull_commands(
  p_device_id uuid,
  p_helper_secret text,
  p_max integer default 10
) returns jsonb as $$
declare
  v_user_id uuid;
  v_max integer;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  v_max := least(greatest(coalesce(p_max, 10), 1), 50);

  perform pg_advisory_xact_lock(hashtextextended(p_device_id::text, 0));

  return coalesce(
    (
      with picked as (
        update public.remote_session_commands
        set status = 'delivered', picked_up_at = now()
        where id in (
          select id from public.remote_session_commands
          where device_id = p_device_id and user_id = v_user_id and status = 'pending'
          order by created_at asc
          limit v_max
          for update skip locked
        )
        returning id, session_id, kind, payload, created_at
      )
      select jsonb_agg(
        jsonb_build_object(
          'id', id,
          'session_id', session_id,
          'kind', kind,
          'payload', payload,
          'created_at', created_at
        )
      ) from picked
    ),
    '[]'::jsonb
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


create or replace function public.remote_helper_complete_command(
  p_device_id uuid,
  p_helper_secret text,
  p_command_id uuid,
  p_status text,
  p_error text default null
) returns jsonb as $$
declare
  v_user_id uuid;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;
  if p_status not in ('delivered', 'failed') then
    raise exception 'Invalid completion status: %', p_status;
  end if;

  update public.remote_session_commands
  set status = p_status,
      completed_at = now(),
      error_message = nullif(left(coalesce(p_error, ''), 1024), '')
  where id = p_command_id and device_id = p_device_id and user_id = v_user_id;

  return jsonb_build_object('status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


create or replace function public.remote_helper_create_permission_request(
  p_device_id uuid,
  p_helper_secret text,
  p_request_id uuid,
  p_session_id uuid,
  p_provider text,
  p_tool_name text,
  p_summary text,
  p_payload jsonb,
  p_risk text default 'medium',
  p_ttl_seconds integer default 300
) returns jsonb as $$
declare
  v_user_id uuid;
  v_ttl integer;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;
  if p_provider not in ('claude', 'codex') then
    raise exception 'Invalid provider for permission request: %', p_provider;
  end if;
  if p_risk not in ('low', 'medium', 'high') then
    raise exception 'Invalid risk: %', p_risk;
  end if;

  -- v0.26-iter2 carryover: if a session_id is supplied, it must belong to
  -- the same (user_id, device_id). Otherwise NULL so the row still inserts
  -- but isn't tied to a stale/foreign session.
  if p_session_id is not null and not exists (
    select 1 from public.remote_sessions
    where id = p_session_id and user_id = v_user_id and device_id = p_device_id
  ) then
    p_session_id := null;
  end if;

  v_ttl := least(greatest(coalesce(p_ttl_seconds, 300), 30), 1800);

  insert into public.remote_permission_requests (
    id, user_id, device_id, session_id, provider, tool_name,
    summary, payload, risk, status, expires_at
  ) values (
    p_request_id, v_user_id, p_device_id, p_session_id, p_provider,
    left(coalesce(p_tool_name, ''), 128),
    left(coalesce(p_summary, ''), 512),
    coalesce(p_payload, '{}'::jsonb),
    p_risk, 'pending',
    now() + (v_ttl::text || ' seconds')::interval
  )
  on conflict (id) do nothing;

  return jsonb_build_object('request_id', p_request_id, 'status', 'pending');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


create or replace function public.remote_helper_poll_permission_decision(
  p_device_id uuid,
  p_helper_secret text,
  p_request_id uuid
) returns jsonb as $$
declare
  v_user_id uuid;
  v_status text;
  v_expires timestamptz;
  v_decision text;
  v_scope text;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  select status, expires_at into v_status, v_expires
  from public.remote_permission_requests
  where id = p_request_id and device_id = p_device_id and user_id = v_user_id;

  if v_status is null then
    return jsonb_build_object('status', 'not_found');
  end if;

  if v_status = 'pending' and v_expires < now() then
    update public.remote_permission_requests
    set status = 'expired'
    where id = p_request_id;
    return jsonb_build_object('status', 'expired');
  end if;

  if v_status in ('approved', 'denied') then
    select decision, scope into v_decision, v_scope
    from public.remote_permission_decisions
    where request_id = p_request_id;
    return jsonb_build_object(
      'status', v_status,
      'decision', v_decision,
      'scope', coalesce(v_scope, 'once')
    );
  end if;

  return jsonb_build_object('status', v_status);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


-- ── App-side write RPCs: gate + helper to look up the flag ────

-- Internal: returns the auth.uid()'s remote_control_enabled flag, or false
-- if the user_settings row is missing.
create or replace function public._remote_control_enabled_for_caller()
returns boolean as $$
declare
  v_user_id uuid := auth.uid();
  v_enabled boolean;
begin
  if v_user_id is null then
    return false;
  end if;
  select coalesce(remote_control_enabled, false) into v_enabled
  from public.user_settings
  where user_id = v_user_id;
  return coalesce(v_enabled, false);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


-- Re-emit v0.26 send_command + decide_permission with the gate.

create or replace function public.remote_app_send_command(
  p_session_id uuid,
  p_kind text,
  p_payload text default ''
) returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_device_id uuid;
  v_command_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    raise exception 'Remote Control is disabled';
  end if;
  if p_kind not in ('prompt', 'stop', 'interrupt') then
    raise exception 'Invalid command kind: %', p_kind;
  end if;

  select device_id into v_device_id
  from public.remote_sessions
  where id = p_session_id and user_id = v_user_id;

  if v_device_id is null then
    raise exception 'Session not found';
  end if;

  insert into public.remote_session_commands (
    user_id, device_id, session_id, kind, payload, status
  ) values (
    v_user_id, v_device_id, p_session_id, p_kind,
    left(coalesce(p_payload, ''), 8192),
    'pending'
  )
  returning id into v_command_id;

  return jsonb_build_object('command_id', v_command_id);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


create or replace function public.remote_app_decide_permission(
  p_request_id uuid,
  p_decision text,
  p_scope text default 'once',
  p_decided_by_device_id uuid default null
) returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_provider text;
  v_status text;
  v_expires timestamptz;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    raise exception 'Remote Control is disabled';
  end if;
  if p_decision not in ('approve', 'deny') then
    raise exception 'Invalid decision: %', p_decision;
  end if;
  if p_scope not in ('once', 'alwaysSession') then
    raise exception 'Invalid scope: %', p_scope;
  end if;

  select provider, status, expires_at into v_provider, v_status, v_expires
  from public.remote_permission_requests
  where id = p_request_id and user_id = v_user_id;

  if v_provider is null then
    raise exception 'Permission request not found';
  end if;

  -- v0.26-iter2: don't allow approving/denying a request that has already
  -- aged out. Mark expired, then refuse the decision.
  if v_status = 'pending' and v_expires < now() then
    update public.remote_permission_requests
    set status = 'expired'
    where id = p_request_id;
    raise exception 'Request expired';
  end if;

  if v_status <> 'pending' then
    raise exception 'Request already decided (%): cannot re-decide', v_status;
  end if;

  -- Codex MVP: alwaysSession not supported (Codex updatedPermissions is not a
  -- usable capability yet). Force 'once' so a stale UI cannot accidentally
  -- promise a scope the helper can't honor.
  if v_provider = 'codex' and p_scope = 'alwaysSession' then
    p_scope := 'once';
  end if;

  insert into public.remote_permission_decisions (
    request_id, user_id, decision, scope, decided_by_device_id
  ) values (
    p_request_id, v_user_id, p_decision, p_scope, p_decided_by_device_id
  );

  update public.remote_permission_requests
  set status = case when p_decision = 'approve' then 'approved' else 'denied' end,
      decided_at = now()
  where id = p_request_id;

  return jsonb_build_object(
    'request_id', p_request_id,
    'decision', p_decision,
    'scope', p_scope
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


-- Note: `remote_app_list_pending_approvals` keeps its v0.26 shape. RLS
-- already scopes to auth.uid() and listing zero pending rows when the
-- feature is disabled is the natural UX. No change needed here.
