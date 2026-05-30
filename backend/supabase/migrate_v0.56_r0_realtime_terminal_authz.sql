-- ============================================================
-- v0.56 — R0: realtime terminal per-subscriber authorization (v1.27 Workstream B1).
-- Design: ~/.claude/plans/r0-realtime-auth-spec.md v2 (post Gemini 3.1 Pro + Codex review).
--
-- ADDITIVE + gated OFF. Nothing exercises these until a v1.27 client opts in via
-- user_settings.realtime_private_enabled (default false). RLS on realtime.messages
-- governs PRIVATE channels ONLY → the live PUBLIC path (shipped v1.24–1.26, and the
-- v1.26 build-67 build in ASC review) is UNAFFECTED.
--
-- Pairs with: edge fn `mint-realtime-token` (B1b), helper broadcast path (B2),
-- iOS/Android private-subscribe (B3 / Workstream C).
--
-- ⚠️ NOT YET APPLIED TO PROD — drafted for review of the two re-emitted live RPCs
-- (remote_app_request_session_start / remote_app_list_sessions) before apply.
-- Their bodies below are the EXACT prod definitions (pg_get_functiondef,
-- 2026-05-30) with a SINGLE additive change each (the realtime_private field).
-- ============================================================

-- (1) Per-session mode flag (set atomically at session-create) + the user gate ---
alter table public.remote_sessions
  add column if not exists realtime_private boolean not null default false;
alter table public.user_settings
  add column if not exists realtime_private_enabled boolean not null default false;

-- (2) realtime.messages RLS — PRIVATE-channel authorization. -------------------
-- NOTE: never cast realtime.topic() (user-controlled → 22P02 DoS). Compare a
-- CONSTRUCTED string instead: 'term:' || rs.id::text = realtime.topic().
-- READ: a subscriber receives term:<uuid> broadcasts only for a session it owns.
drop policy if exists "read own remote session terminal" on realtime.messages;
create policy "read own remote session terminal"
  on realtime.messages for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and exists (
      select 1 from public.remote_sessions rs
      where rs.user_id = (select auth.uid())
        and 'term:' || rs.id::text = realtime.topic()
    )
  );
-- WRITE: only the owner may broadcast. The helper's edge-fn-minted token carries
-- sub = <owner user_id>, so auth.uid() = owner → passes only for owned topics.
-- (No client write policy beyond this → cross-user injection is structurally closed.)
drop policy if exists "broadcast own remote session terminal" on realtime.messages;
create policy "broadcast own remote session terminal"
  on realtime.messages for insert to authenticated
  with check (
    realtime.messages.extension = 'broadcast'
    and exists (
      select 1 from public.remote_sessions rs
      where rs.user_id = (select auth.uid())
        and 'term:' || rs.id::text = realtime.topic()
    )
  );

-- (3) Helper broadcast authorization (called by the mint-realtime-token edge fn).
-- Gate done RIGHT (Codex CRITICAL): ASSIGN the gated-auth result, CHECK non-null,
-- SCOPE ownership by the returned user. (`_remote_authenticate_helper_gated`
-- returns NULL on bad secret — it does NOT raise — so `perform` would bypass it.)
create or replace function public.remote_helper_authorize_broadcast(
  p_device_id uuid,
  p_helper_secret text,
  p_session_id uuid
) returns uuid
  language plpgsql
  security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user uuid;
  v_owner uuid;
begin
  v_user := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  select rs.user_id into v_owner
  from public.remote_sessions rs
  where rs.id = p_session_id
    and rs.device_id = p_device_id
    and rs.user_id = v_user;
  if v_owner is null then
    raise exception 'session not owned by device' using errcode = '42501';
  end if;
  return v_owner;
end;
$$;
revoke all on function public.remote_helper_authorize_broadcast(uuid, text, uuid) from public;
grant execute on function public.remote_helper_authorize_broadcast(uuid, text, uuid) to anon;

-- (4) Re-emit remote_app_request_session_start — set realtime_private atomically.
-- Body = prod (pg_get_functiondef 2026-05-30); ONLY change: realtime_private in
-- the remote_sessions insert, sourced from the caller's user_settings gate.
create or replace function public.remote_app_request_session_start(
  p_device_id uuid,
  p_provider text,
  p_cwd_basename text default ''::text,
  p_cwd_hmac text default null::text,
  p_client_label text default null::text
) returns jsonb
  language plpgsql
  security definer
  set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_device_owner uuid;
  v_session_id uuid;
  v_command_id uuid;
  v_provider text;
  v_payload text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    raise exception 'Remote Control is disabled';
  end if;

  v_provider := coalesce(p_provider, '');
  if v_provider not in ('claude', 'codex', 'gemini') then
    raise exception 'Invalid provider for managed session: %', p_provider;
  end if;

  select user_id into v_device_owner
  from public.devices
  where id = p_device_id;

  if v_device_owner is distinct from v_user_id then
    raise exception 'Device not found';
  end if;

  v_session_id := gen_random_uuid();

  insert into public.remote_sessions (
    id, user_id, device_id, provider, cwd_basename, cwd_hmac, client_label,
    status, last_event_at, realtime_private
  ) values (
    v_session_id, v_user_id, p_device_id, v_provider,
    coalesce(left(p_cwd_basename, 255), ''),
    p_cwd_hmac,
    nullif(left(coalesce(p_client_label, ''), 128), ''),
    'pending', now(),
    coalesce((select realtime_private_enabled from public.user_settings where user_id = v_user_id), false)
  );

  v_payload := jsonb_build_object(
    'provider',     v_provider,
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
$function$;

-- (5) Re-emit remote_app_list_sessions — return realtime_private so clients pick
-- the matching join mode. Body = prod (pg_get_functiondef 2026-05-30); ONLY
-- change: the 'realtime_private' key in the per-row jsonb_build_object.
create or replace function public.remote_app_list_sessions()
  returns jsonb
  language plpgsql
  security definer
  set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
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
          'id',               s.id,
          'device_id',        s.device_id,
          'device_name',      d.name,
          'provider',         s.provider,
          'cwd_basename',     s.cwd_basename,
          'cwd_hmac',         s.cwd_hmac,
          'status',           s.status,
          'client_label',     s.client_label,
          'created_at',       s.created_at,
          'last_event_at',    s.last_event_at,
          'realtime_private', s.realtime_private
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
$function$;

-- Verify after apply:
--   select column_name from information_schema.columns
--    where table_schema='public' and table_name='remote_sessions' and column_name='realtime_private';
--   select policyname from pg_policies where schemaname='realtime' and tablename='messages';
--   -- expect the two "... remote session terminal" policies
--   -- smoke the two re-emitted RPCs from an AUTHENTICATED client (not service_role),
--   -- since both gate on auth.uid().
