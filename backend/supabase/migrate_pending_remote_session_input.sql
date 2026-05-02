-- ============================================================
-- PENDING (placeholder slot) — Remote Session Input (iter 1)
-- Date: 2026-05-03
-- Status: NOT YET APPLIED to live Supabase. NOT YET assigned a v0.3X slot.
--
-- Why placeholder?
--   The cli-pulse-desktop track (Tauri 2 — Windows + Linux) is shipping its
--   own schema backlog targeting v0.4.4. To prevent two concurrent tracks
--   from claiming the same migration number, this file deliberately uses a
--   non-numeric name. Jason will green-light a v0.3X slot AND apply this to
--   live Supabase via the Mgmt API once both tracks have aligned.
--
-- Adds (all idempotent):
--   1. Widen `remote_session_commands.kind` CHECK to include the new
--      lifecycle command 'start'. End users can NOT enqueue a 'start' via
--      `remote_app_send_command` (that RPC stays restricted to runtime
--      kinds — prompt | stop | interrupt). 'start' is the wire format for
--      the new app→helper start RPC defined below.
--   2. `remote_app_request_session_start(p_device_id, p_provider,
--                                       p_cwd_basename, p_cwd_hmac,
--                                       p_client_label)` — RLS-safe app
--      RPC that (a) creates a remote_sessions row with status='pending'
--      and (b) enqueues a 'start' command for the helper to pick up.
--      Only `claude` is accepted in iter 1; codex/shell are deferred.
--      Gated on `_remote_control_enabled_for_caller()` (v0.27).
--   3. `remote_app_list_sessions()` — read-only RPC that returns the
--      caller's remote sessions joined with `devices.name` so the UI can
--      label which Mac each session is running on. Gated to return `[]`
--      when Remote Control is disabled.
--
-- Privacy / security posture (unchanged from Phase 1):
--   * Default OFF. The RPCs above all bail when
--     `user_settings.remote_control_enabled = false`.
--   * cwd_basename ≤ 255 chars, cwd_hmac arbitrary string. NO full path,
--     NO transcript, NO API keys.
--   * Command payload ≤ 8192 chars (existing CHECK).
--
-- Idempotent: safe to re-run.
-- ============================================================

-- ── 1. Widen remote_session_commands.kind CHECK ────────────────
-- Anonymous CHECK from v0.26 is auto-named `remote_session_commands_kind_check`
-- by PostgreSQL. Drop + re-add to widen.
do $$
begin
  begin
    alter table public.remote_session_commands
      drop constraint if exists remote_session_commands_kind_check;
  exception when undefined_object then
    null;  -- Constraint name didn't match; will be re-added below.
  end;
end $$;

alter table public.remote_session_commands
  add constraint remote_session_commands_kind_check
  check (kind in ('prompt', 'stop', 'interrupt', 'start'));


-- ── 2. App-side: request a managed-session start ───────────────
-- Atomic (a) insert remote_sessions(status='pending') (b) enqueue
-- remote_session_commands(kind='start', payload=<json with provider+cwd>).
-- Returns { session_id, command_id } so the UI can correlate the row it
-- just created with the helper command queue entry.
create or replace function public.remote_app_request_session_start(
  p_device_id uuid,
  p_provider text,
  p_cwd_basename text default '',
  p_cwd_hmac text default null,
  p_client_label text default null
) returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_device_owner uuid;
  v_session_id uuid;
  v_command_id uuid;
  v_payload text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    raise exception 'Remote Control is disabled';
  end if;

  -- iter 1: only claude is supported. Server-side rejection keeps a
  -- malformed app from quietly creating a row no helper can spawn.
  -- codex / shell are intentional Phase 2 work.
  if p_provider is null or p_provider <> 'claude' then
    raise exception 'Invalid provider for managed session: %', p_provider;
  end if;

  -- Verify the device belongs to the caller before creating any rows.
  -- Without this a caller could enqueue start commands targeted at
  -- another user's device. RLS on devices is select-only by user_id, but
  -- this RPC is SECURITY DEFINER so we check explicitly.
  select user_id into v_device_owner
  from public.devices
  where id = p_device_id;

  if v_device_owner is distinct from v_user_id then
    raise exception 'Device not found';
  end if;

  v_session_id := gen_random_uuid();

  -- Create the session row up-front so the app can list/select it
  -- immediately. status='pending' means "queued, helper hasn't spawned
  -- yet". The helper will UPDATE → 'running' via remote_helper_register_session
  -- once the PTY is alive (v0.30 ownership-checked UPSERT).
  insert into public.remote_sessions (
    id, user_id, device_id, provider, cwd_basename, cwd_hmac, client_label,
    status, last_event_at
  ) values (
    v_session_id, v_user_id, p_device_id, 'claude',
    coalesce(left(p_cwd_basename, 255), ''),
    p_cwd_hmac,
    nullif(left(coalesce(p_client_label, ''), 128), ''),
    'pending', now()
  );

  -- Encode the lifecycle metadata as a JSON object inside the payload
  -- TEXT column. Keeping it in the existing payload column (vs. a new
  -- jsonb column) means the queue stays platform-neutral and snake_case
  -- across all 4 client platforms — desktop track agreement.
  v_payload := jsonb_build_object(
    'provider',     'claude',
    'cwd_basename', coalesce(left(p_cwd_basename, 255), ''),
    'cwd_hmac',     p_cwd_hmac,
    'client_label', nullif(left(coalesce(p_client_label, ''), 128), '')
  )::text;

  insert into public.remote_session_commands (
    user_id, device_id, session_id, kind, payload, status
  ) values (
    v_user_id, p_device_id, v_session_id, 'start',
    left(v_payload, 8192),
    'pending'
  )
  returning id into v_command_id;

  return jsonb_build_object(
    'session_id', v_session_id,
    'command_id', v_command_id
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


-- ── 3. App-side: list the caller's remote sessions ─────────────
-- Joined with devices.name so the UI can label "running on <Mac>". Gated
-- to return [] when Remote Control is disabled — listing zero rows when
-- the feature is off matches the natural UX.
create or replace function public.remote_app_list_sessions()
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    return '[]'::jsonb;
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id',            s.id,
          'device_id',     s.device_id,
          'device_name',   d.name,
          'provider',      s.provider,
          'cwd_basename',  s.cwd_basename,
          'cwd_hmac',      s.cwd_hmac,
          'status',        s.status,
          'client_label',  s.client_label,
          'created_at',    s.created_at,
          'last_event_at', s.last_event_at
        )
        order by coalesce(s.last_event_at, s.created_at) desc
      )
      from public.remote_sessions s
      left join public.devices d on d.id = s.device_id
      where s.user_id = v_user_id
        and s.status in ('pending', 'running')
    ),
    '[]'::jsonb
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


-- ── 4. Permissions ─────────────────────────────────────────────
-- App users authenticate via JWT (`authenticated` role). Anon callers
-- must NOT be able to enumerate sessions or queue start commands; the
-- `auth.uid() is null` guard above already raises but a REVOKE on anon
-- is the standard belt-and-braces for the v0.31 hardening posture.
revoke all on function public.remote_app_request_session_start(uuid, text, text, text, text) from public, anon;
grant execute on function public.remote_app_request_session_start(uuid, text, text, text, text) to authenticated;

revoke all on function public.remote_app_list_sessions() from public, anon;
grant execute on function public.remote_app_list_sessions() to authenticated;


-- ── Manual verification (run after applying):
--   select pg_get_functiondef('public.remote_app_request_session_start'::regproc);
--   select pg_get_functiondef('public.remote_app_list_sessions'::regproc);
--   select conname, pg_get_constraintdef(oid)
--     from pg_constraint
--    where conrelid = 'public.remote_session_commands'::regclass
--      and conname like '%kind_check';
