-- ============================================================
-- migrate_v0.45 — Multi-CLI managed sessions (Codex + Gemini provider)
--
-- v1.15 product change: the iOS / macOS app's "Start managed session"
-- flow should be able to spawn Codex CLI and Gemini CLI on the paired
-- Mac, not just Claude Code. Helper-side spawner registry already
-- shipped (PR <v1.15-multi-cli>). This migration unblocks the SQL
-- surface so backend rejects don't preempt the helper.
--
-- Audit (2026-05-08):
--   * No RLS policy on `public.*` tables hardcodes provider lists.
--   * `remote_sessions_provider_check` constraint allows
--     ('claude','codex','shell'). Add 'gemini'.
--   * `remote_permission_requests_provider_check` constraint allows
--     ('claude','codex'). Add 'gemini' for forward-compat even though
--     v1.15 ships no remote-approve surface for non-Claude providers.
--   * `remote_app_request_session_start` body has TWO Claude
--     hardcodings:
--       (a) `if p_provider is null or p_provider <> 'claude' raise`
--       (b) INSERT uses literal 'claude' instead of `p_provider`
--     Both must be replaced or the RPC will keep returning the
--     "Invalid provider for managed session" error AND silently
--     overwrite codex/gemini requests with claude rows.
--   * `remote_helper_register_session` whitelist: ('claude','codex','shell').
--     Add 'gemini'.
--   * `remote_helper_create_permission_request` whitelist:
--     ('claude','codex'). Add 'gemini'.
--
-- All four `RETURNS jsonb` RPCs survive `CREATE OR REPLACE` without
-- DROP because the signature stays identical (per memory's
-- `feedback_gemini_review_patterns.md` rule #1: the DROP-first
-- requirement is for `RETURNS TABLE` only, or when adding
-- parameters).
--
-- Lock window: each `ALTER TABLE … ADD CONSTRAINT` takes a brief
-- ACCESS EXCLUSIVE lock. `remote_sessions` is small (single-digit MB),
-- the operation is sub-millisecond. Acceptable per Gemini's P2 review
-- finding.
--
-- Reviews:
--   * Gemini 3.1 Pro (against the v1.15 product plan): SHIP. Two
--     concerns flagged (RLS audit P1, lock-window P2). Both addressed
--     above.
-- ============================================================

set lock_timeout = '30s';

-- ────────────────────────────────────────────────────────────
-- 1. Extend check constraints to include 'gemini'.
-- ────────────────────────────────────────────────────────────
alter table public.remote_sessions
  drop constraint remote_sessions_provider_check;
alter table public.remote_sessions
  add constraint remote_sessions_provider_check
  check (provider = any (array['claude', 'codex', 'gemini', 'shell']));

alter table public.remote_permission_requests
  drop constraint remote_permission_requests_provider_check;
alter table public.remote_permission_requests
  add constraint remote_permission_requests_provider_check
  check (provider = any (array['claude', 'codex', 'gemini']));

-- ────────────────────────────────────────────────────────────
-- 2. Rewrite remote_app_request_session_start to honor p_provider.
--    The legacy body had two Claude hardcodings (precondition check
--    + INSERT value). Replace both. Preserve the rest verbatim from
--    migrate_v0.39_remote_session_input.sql.
-- ────────────────────────────────────────────────────────────
create or replace function public.remote_app_request_session_start(
  p_device_id uuid,
  p_provider text,
  p_cwd_basename text default '',
  p_cwd_hmac text default null,
  p_client_label text default null
)
returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
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

  -- v0.45: accept any provider whose helper-side spawner exists.
  -- The whitelist matches the table check constraint above;
  -- 'shell' is excluded here because we don't yet ship a shell
  -- spawner in the helper, so the app should never request it.
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

  -- Use the validated v_provider (NOT a literal 'claude') so the
  -- session row + helper command actually carry the requested CLI.
  insert into public.remote_sessions (
    id, user_id, device_id, provider, cwd_basename, cwd_hmac, client_label,
    status, last_event_at
  ) values (
    v_session_id, v_user_id, p_device_id, v_provider,
    coalesce(left(p_cwd_basename, 255), ''),
    p_cwd_hmac,
    nullif(left(coalesce(p_client_label, ''), 128), ''),
    'pending', now()
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
$$;

-- Permissions stay as configured by migrate_v0.39 (REVOKE PUBLIC,
-- GRANT authenticated). The CREATE OR REPLACE above preserves them
-- because the signature is unchanged.

-- ────────────────────────────────────────────────────────────
-- 3. Extend `remote_helper_register_session` whitelist.
--    Same body otherwise.
-- ────────────────────────────────────────────────────────────
create or replace function public.remote_helper_register_session(
  p_device_id uuid,
  p_helper_secret text,
  p_session_id uuid,
  p_provider text,
  p_cwd_basename text,
  p_cwd_hmac text,
  p_client_label text
)
returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid;
  v_inserted_id uuid;
  v_existing_user uuid;
  v_existing_device uuid;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;
  -- v0.45: add 'gemini' to whitelist.
  if p_provider not in ('claude', 'codex', 'gemini', 'shell') then
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
  on conflict (id) do nothing
  returning id into v_inserted_id;

  if v_inserted_id is not null then
    return jsonb_build_object('session_id', p_session_id, 'status', 'ok');
  end if;

  select user_id, device_id
    into v_existing_user, v_existing_device
  from public.remote_sessions
  where id = p_session_id
  for update;

  if v_existing_user is null then
    raise exception 'Device not found or unauthorized';
  end if;

  if v_existing_user is distinct from v_user_id
     or v_existing_device is distinct from p_device_id then
    raise exception 'Device not found or unauthorized';
  end if;

  update public.remote_sessions
  set status        = 'running',
      last_event_at = now(),
      cwd_basename  = coalesce(nullif(left(p_cwd_basename, 255), ''), cwd_basename),
      cwd_hmac      = coalesce(p_cwd_hmac, cwd_hmac)
  where id = p_session_id;

  return jsonb_build_object('session_id', p_session_id, 'status', 'ok');
end;
$$;

-- ────────────────────────────────────────────────────────────
-- 4. Extend `remote_helper_create_permission_request` whitelist.
--    Even though v1.15 ships no remote-approve surface for
--    Codex/Gemini, the helper might still call this RPC for a
--    Codex session (e.g. shipping a future build over the wire);
--    rejecting it here would crash the call. Adding 'gemini' is
--    forward-compat for the same reason.
-- ────────────────────────────────────────────────────────────
create or replace function public.remote_helper_create_permission_request(
  p_device_id uuid,
  p_helper_secret text,
  p_request_id uuid,
  p_session_id uuid,
  p_provider text,
  p_tool_name text,
  p_summary text,
  p_payload jsonb,
  p_risk text,
  p_ttl_seconds integer
)
returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid;
  v_ttl integer;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;
  -- v0.45: extend whitelist with 'gemini' for forward-compat.
  if p_provider not in ('claude', 'codex', 'gemini') then
    raise exception 'Invalid provider for permission request: %', p_provider;
  end if;
  if p_risk not in ('low', 'medium', 'high') then
    raise exception 'Invalid risk: %', p_risk;
  end if;

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
$$;

reset lock_timeout;

-- ============================================================
-- Client rollout plan:
--   1. Apply this migration. Existing v1.13/v1.14 clients keep
--      working unchanged — they only ever pass 'claude' as
--      p_provider, which remains accepted.
--   2. Ship v1.15 client. iOS / macOS picker can now pass 'codex'
--      and 'gemini'. SQL accepts; helper spawner registry resolves.
-- ============================================================
