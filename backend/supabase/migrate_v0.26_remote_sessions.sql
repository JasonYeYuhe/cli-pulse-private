-- ============================================================
-- v0.26 — Remote Agent Sessions / Remote Approvals (Phase 1 MVP)
-- Date: 2026-04-28
-- Adds: remote_sessions, remote_session_events, remote_session_commands,
--       remote_permission_requests, remote_permission_decisions
-- Plus 6 helper-side RPCs (device_id + helper_secret auth, SECURITY DEFINER)
-- and 3 app-side RPCs (auth.uid() / RLS).
--
-- Phase 1 scope: Claude approval-only happy path. Tables for managed PTY
-- sessions are present so the helper can register/post events/poll commands
-- but the helper-side PTY runner is not implemented yet (separate task).
-- Codex hooks: schema is shared but no decisions support `alwaysSession`
-- yet because Codex updatedPermissions is not exposed.
--
-- Idempotent: safe to re-run. RLS by user_id; helpers cannot bypass RLS via
-- direct SELECT, only through SECURITY DEFINER RPCs that validate
-- (device_id, helper_secret) the same way helper_sync does.
-- ============================================================

-- ── remote_sessions ───────────────────────────────────────────
-- Represents one Claude / Codex / shell session running under the helper.
-- Privacy posture:
--   - cwd_basename: only the trailing path component, never the full path
--   - cwd_hmac: HMAC of full path so the app can group same-project sessions
--   - NO transcript, NO API keys, NO cookies, NO full session log
create table if not exists public.remote_sessions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  device_id       uuid not null references public.devices(id) on delete cascade,
  provider        text not null check (provider in ('claude', 'codex', 'shell')),
  cwd_basename    text not null default '',
  cwd_hmac        text,
  status          text not null default 'pending'
                    check (status in ('pending', 'running', 'stopped', 'errored')),
  client_label    text,                            -- short human label, optional
  created_at      timestamptz not null default now(),
  last_event_at   timestamptz
);

alter table public.remote_sessions enable row level security;

drop policy if exists "Users can read own remote sessions" on public.remote_sessions;
create policy "Users can read own remote sessions"
  on public.remote_sessions for select using (auth.uid() = user_id);

-- App users do NOT directly insert/update — helper RPCs do that. We still
-- allow DELETE so a user can prune sessions from the UI.
drop policy if exists "Users can delete own remote sessions" on public.remote_sessions;
create policy "Users can delete own remote sessions"
  on public.remote_sessions for delete using (auth.uid() = user_id);

create index if not exists idx_remote_sessions_user_id
  on public.remote_sessions(user_id, last_event_at desc nulls last);
create index if not exists idx_remote_sessions_device_id
  on public.remote_sessions(device_id);

-- ── remote_session_events ─────────────────────────────────────
-- Append-only terminal-output tail, capped per row. Helper writes; app reads.
-- Each row is at most 4 KB to bound DoS surface.
create table if not exists public.remote_session_events (
  id          bigserial primary key,
  session_id  uuid not null references public.remote_sessions(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  device_id   uuid not null references public.devices(id) on delete cascade,
  seq         integer not null,
  kind        text not null check (kind in ('stdout', 'stderr', 'status', 'info')),
  payload     text not null check (length(payload) <= 4096),
  created_at  timestamptz not null default now()
);

alter table public.remote_session_events enable row level security;

drop policy if exists "Users can read own session events" on public.remote_session_events;
create policy "Users can read own session events"
  on public.remote_session_events for select using (auth.uid() = user_id);

create index if not exists idx_remote_session_events_session
  on public.remote_session_events(session_id, seq);
create index if not exists idx_remote_session_events_user
  on public.remote_session_events(user_id, created_at desc);

-- ── remote_session_commands ───────────────────────────────────
-- App enqueues; helper polls + completes. status transitions:
--   pending → delivered → (no terminal state — completion is a status row)
-- expired is set by a future cleanup job (not in MVP).
create table if not exists public.remote_session_commands (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles(id) on delete cascade,
  device_id      uuid not null references public.devices(id) on delete cascade,
  session_id     uuid references public.remote_sessions(id) on delete cascade,
  kind           text not null check (kind in ('prompt', 'stop', 'interrupt')),
  payload        text not null default '' check (length(payload) <= 8192),
  status         text not null default 'pending'
                   check (status in ('pending', 'delivered', 'failed', 'expired')),
  error_message  text,
  created_at     timestamptz not null default now(),
  picked_up_at   timestamptz,
  completed_at   timestamptz
);

alter table public.remote_session_commands enable row level security;

drop policy if exists "Users can read own commands" on public.remote_session_commands;
create policy "Users can read own commands"
  on public.remote_session_commands for select using (auth.uid() = user_id);

-- App writes via RPC, not direct insert (so we can validate session ownership)
create index if not exists idx_remote_commands_pending
  on public.remote_session_commands(device_id, created_at)
  where status = 'pending';
create index if not exists idx_remote_commands_session
  on public.remote_session_commands(session_id, created_at desc);

-- ── remote_permission_requests ────────────────────────────────
-- Helper-issued permission request (Claude PermissionRequest or Codex hook).
-- Payload is a REDACTED, MINIMISED jsonb subset of the provider hook input —
-- never the full transcript.
create table if not exists public.remote_permission_requests (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  device_id       uuid not null references public.devices(id) on delete cascade,
  session_id      uuid references public.remote_sessions(id) on delete cascade,
  provider        text not null check (provider in ('claude', 'codex')),
  tool_name       text not null default '',
  summary         text not null default '' check (length(summary) <= 512),
  payload         jsonb not null default '{}'::jsonb,
  risk            text not null default 'medium' check (risk in ('low', 'medium', 'high')),
  status          text not null default 'pending'
                    check (status in ('pending', 'approved', 'denied', 'expired', 'fallback')),
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null default (now() + interval '5 minutes'),
  decided_at      timestamptz
);

alter table public.remote_permission_requests enable row level security;

drop policy if exists "Users can read own permission requests" on public.remote_permission_requests;
create policy "Users can read own permission requests"
  on public.remote_permission_requests for select using (auth.uid() = user_id);

create index if not exists idx_remote_perm_requests_pending
  on public.remote_permission_requests(user_id, created_at desc)
  where status = 'pending';
create index if not exists idx_remote_perm_requests_device
  on public.remote_permission_requests(device_id, status);

-- ── remote_permission_decisions ───────────────────────────────
-- App-issued decision. One decision per request; app RPC enforces this.
create table if not exists public.remote_permission_decisions (
  id                   uuid primary key default gen_random_uuid(),
  request_id           uuid not null unique
                          references public.remote_permission_requests(id) on delete cascade,
  user_id              uuid not null references public.profiles(id) on delete cascade,
  decision             text not null check (decision in ('approve', 'deny')),
  scope                text not null default 'once'
                         check (scope in ('once', 'alwaysSession')),
  decided_by_device_id uuid,                      -- iOS device that decided (optional)
  created_at           timestamptz not null default now()
);

alter table public.remote_permission_decisions enable row level security;

drop policy if exists "Users can read own decisions" on public.remote_permission_decisions;
create policy "Users can read own decisions"
  on public.remote_permission_decisions for select using (auth.uid() = user_id);

-- ============================================================
-- Helper-side RPCs (device_id + helper_secret auth, SECURITY DEFINER)
-- ============================================================

-- Internal helper: validate (device_id, helper_secret) → user_id
-- Returns null if unauthorized; callers should raise.
create or replace function public._remote_authenticate_helper(
  p_device_id uuid,
  p_helper_secret text
) returns uuid as $$
declare
  v_user_id uuid;
begin
  select user_id into v_user_id
  from public.devices
  where id = p_device_id
    and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');
  return v_user_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Helper registers / upserts a remote session.
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
  v_user_id := public._remote_authenticate_helper(p_device_id, p_helper_secret);
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

-- Helper appends one terminal-output / status event.
-- payload is server-side truncated to 4096 chars to enforce the row CHECK.
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
  v_user_id := public._remote_authenticate_helper(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;
  if p_kind not in ('stdout', 'stderr', 'status', 'info') then
    raise exception 'Invalid event kind: %', p_kind;
  end if;

  -- Verify session belongs to this device+user (cheap RLS-equivalent)
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

-- Helper polls pending commands for this device.
-- Atomically marks them as 'delivered' so a re-poll won't double-deliver.
create or replace function public.remote_helper_pull_commands(
  p_device_id uuid,
  p_helper_secret text,
  p_max integer default 10
) returns jsonb as $$
declare
  v_user_id uuid;
  v_max integer;
begin
  v_user_id := public._remote_authenticate_helper(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  v_max := least(greatest(coalesce(p_max, 10), 1), 50);

  -- Serialise concurrent helper instances on the same device. Same pattern as
  -- helper_sync v0.25 — a few µs cost, prevents two helpers from grabbing
  -- overlapping command rows.
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

-- Helper reports completion / failure of a previously-pulled command.
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
  v_user_id := public._remote_authenticate_helper(p_device_id, p_helper_secret);
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

-- Helper creates a permission request (called from the Claude/Codex hook).
-- Payload should already be REDACTED + minimised by the caller.
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
  v_user_id := public._remote_authenticate_helper(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;
  if p_provider not in ('claude', 'codex') then
    raise exception 'Invalid provider for permission request: %', p_provider;
  end if;
  if p_risk not in ('low', 'medium', 'high') then
    raise exception 'Invalid risk: %', p_risk;
  end if;
  if p_session_id is not null and not exists (
    select 1 from public.remote_sessions
    where id = p_session_id and user_id = v_user_id and device_id = p_device_id
  ) then
    raise exception 'Session not found for device';
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

-- Helper polls for a decision on a previously-created request.
-- Returns: { status: pending|approved|denied|expired, decision: ?, scope: ? }
-- Auto-marks the request 'expired' if past expires_at.
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
  v_user_id := public._remote_authenticate_helper(p_device_id, p_helper_secret);
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

-- ============================================================
-- App-side RPCs (auth.uid() / RLS-aware)
-- ============================================================

-- App enqueues a command for a session it owns.
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

-- App approves or denies a permission request.
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
  v_expires_at timestamptz;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if p_decision not in ('approve', 'deny') then
    raise exception 'Invalid decision: %', p_decision;
  end if;
  if p_scope not in ('once', 'alwaysSession') then
    raise exception 'Invalid scope: %', p_scope;
  end if;

  select provider, status, expires_at into v_provider, v_status, v_expires_at
  from public.remote_permission_requests
  where id = p_request_id and user_id = v_user_id;

  if v_provider is null then
    raise exception 'Permission request not found';
  end if;
  if v_status <> 'pending' then
    raise exception 'Request already decided (%): cannot re-decide', v_status;
  end if;
  if v_expires_at <= now() then
    update public.remote_permission_requests
    set status = 'expired'
    where id = p_request_id and user_id = v_user_id and status = 'pending';
    raise exception 'Request expired';
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

-- App lists pending approvals across all the user's devices.
-- Returns a jsonb array so the client can decode in one shot.
create or replace function public.remote_app_list_pending_approvals()
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', id,
          'session_id', session_id,
          'device_id', device_id,
          'provider', provider,
          'tool_name', tool_name,
          'summary', summary,
          'risk', risk,
          'status', status,
          'created_at', created_at,
          'expires_at', expires_at
        )
        order by created_at desc
      )
      from public.remote_permission_requests
      where user_id = v_user_id and status = 'pending' and expires_at > now()
    ),
    '[]'::jsonb
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;
