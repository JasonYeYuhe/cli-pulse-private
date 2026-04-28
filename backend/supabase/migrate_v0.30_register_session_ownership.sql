-- ============================================================
-- v0.30 — remote_helper_register_session ownership hardening
-- Date: 2026-04-28
--
-- Codex review iter4 P2: the v0.26 / v0.27 implementations of
-- `remote_helper_register_session` used `insert ... on conflict (id) do
-- update` without checking that the existing row's `user_id` and `device_id`
-- match the calling helper. Two practical risks:
--
--   1. Cross-tenant overwrite. If a UUID collision ever occurred — or if a
--      malicious helper guesses an ID from another user's session — the ON
--      CONFLICT branch would silently UPDATE that foreign row's status,
--      cwd_basename, and last_event_at, even though the FK on user_id
--      blocks an INSERT into another user's namespace. The UPDATE path
--      bypasses that check entirely.
--   2. Cross-device overwrite within the same user. A malformed helper
--      pairing on Device B that re-uses an ID from Device A would silently
--      mark Device A's session as "running" with Device B's metadata. We
--      should refuse instead of corrupting state.
--
-- Fix: try the INSERT with `on conflict do nothing returning id`. If the
-- INSERT didn't take (the row already exists), explicitly verify ownership
-- before allowing the UPDATE. Mismatch raises the same opaque error the
-- gate uses elsewhere ("Device not found or unauthorized") so a probing
-- caller can't distinguish "row belongs to someone else" from "your secret
-- is wrong" — the same fail-uniform principle as v0.27.
--
-- This v0.30 supersedes the v0.26 + v0.27 definitions of
-- `remote_helper_register_session`. CREATE OR REPLACE is replay-safe.
-- v0.26 / v0.27 are NOT edited so the audit trail stays append-only; the
-- final replayed function is whatever this file installs.
--
-- Idempotent: safe to re-run.
-- ============================================================

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
  v_inserted_id uuid;
  v_existing_user uuid;
  v_existing_device uuid;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;
  if p_provider not in ('claude', 'codex', 'shell') then
    raise exception 'Invalid provider: %', p_provider;
  end if;

  -- Try the insert first. If the id is fresh, this is the only path that
  -- runs — fast, single statement.
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

  -- Conflict path: the row already exists. Verify ownership before letting
  -- the helper update it. A mismatch on EITHER user_id or device_id is
  -- treated as unauthorized — the v0.27 gate already authenticated
  -- (device_id, helper_secret) → user_id, but the *session* may belong to
  -- another device pairing for the same user, which is also disallowed.
  select user_id, device_id
    into v_existing_user, v_existing_device
  from public.remote_sessions
  where id = p_session_id
  for update;

  if v_existing_user is null then
    -- Genuinely race-y: row vanished between the failed insert and the
    -- select. Refuse rather than retry-insert (which could loop). Caller
    -- can simply call again with a fresh request.
    raise exception 'Device not found or unauthorized';
  end if;

  if v_existing_user is distinct from v_user_id
     or v_existing_device is distinct from p_device_id then
    raise exception 'Device not found or unauthorized';
  end if;

  -- Ownership confirmed. Refresh the mutable fields. cwd_basename and
  -- cwd_hmac are preserved when the caller omits them (older helpers, or
  -- sessions where the helper never resolved a basename).
  update public.remote_sessions
  set status        = 'running',
      last_event_at = now(),
      cwd_basename  = coalesce(nullif(left(p_cwd_basename, 255), ''), cwd_basename),
      cwd_hmac      = coalesce(p_cwd_hmac, cwd_hmac)
  where id = p_session_id;

  return jsonb_build_object('session_id', p_session_id, 'status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;
