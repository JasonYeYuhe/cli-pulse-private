-- ============================================================
-- v0.69 — remote_helper_register_session gains p_realtime_private
-- Date: 2026-07-16
--
-- Context: M4.4d — the phone drives tmux-WRAPPED EXTERNAL sessions.
--
-- A wrapped session is a `claude`/`codex` the USER launched in their own
-- terminal; the shell integration parked it inside a CLI-Pulse-owned tmux and
-- the helper ATTACHES to it (non-owning). When the user explicitly opts such a
-- session into the cloud plane, the helper must mint its `remote_sessions` row
-- — `remote_helper_register_session` is the only RPC that does that.
--
-- The gap: that RPC never writes `realtime_private`, so a row it mints keeps
-- the column default FALSE = "broadcast on the PUBLIC `term:<uuid>` topic".
-- Public topics always bypass RLS (see v0.56), i.e. anyone who learns the UUID
-- can read the stream. That default is wrong for a session CLI Pulse does not
-- own and the user did not launch through us — and it also produces a SILENT
-- BLACKHOLE today: the helper's fail-closed broadcast gate mutes an attached
-- session's public mirror, so the phone would join `term:` and receive nothing.
--
-- Fix: an optional `p_realtime_private` decided ATOMICALLY at row-create, the
-- same way `remote_app_request_session_start` does it (v0.61) — so the column
-- and the helper's in-memory privacy flag can never disagree. The helper passes
-- TRUE for wrapped sessions; the phone then joins the RLS-governed `pterm:`
-- topic and, absent a `pterm:` producer on the Swift helper, falls back to the
-- durable event tail (~3 s poll). Correct and private, just not live.
--
-- NULL = "leave as-is": an INSERT lands the existing FALSE default and the
-- conflict-UPDATE path leaves a stored value untouched. That keeps every
-- pre-M4.4d caller (Python `remote_agent.py`, Swift cloud-start) byte-identical
-- in behaviour without touching them.
--
-- Why DROP + CREATE rather than CREATE OR REPLACE: adding a defaulted argument
-- creates an OVERLOAD, not a replacement, and PostgREST resolves by argument
-- NAME — a 7-named-arg call would then match BOTH the old 7-arg and the new
-- 8-arg-with-default function and fail as ambiguous. Dropping first leaves
-- exactly one function; the default keeps 7-arg callers working unchanged.
--
-- Rollback: replay migrate_v0.45_multi_cli_managed_sessions.sql (its body is
-- this one minus the privacy arg) after dropping the 8-arg signature.
--
-- Idempotent: safe to re-run.
-- ============================================================

drop function if exists public.remote_helper_register_session(
  uuid, text, uuid, text, text, text, text
);

create or replace function public.remote_helper_register_session(
  p_device_id uuid,
  p_helper_secret text,
  p_session_id uuid,
  p_provider text,
  p_cwd_basename text default '',
  p_cwd_hmac text default null,
  p_client_label text default null,
  p_realtime_private boolean default null
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
  if p_provider not in ('claude', 'codex', 'gemini', 'shell') then
    raise exception 'Invalid provider: %', p_provider;
  end if;

  -- Try the insert first. If the id is fresh, this is the only path that
  -- runs — fast, single statement. `coalesce(p_realtime_private, false)`
  -- reproduces the column default when the caller doesn't care.
  insert into public.remote_sessions (
    id, user_id, device_id, provider, cwd_basename, cwd_hmac, client_label,
    status, last_event_at, realtime_private
  ) values (
    p_session_id, v_user_id, p_device_id, p_provider,
    coalesce(left(p_cwd_basename, 255), ''),
    p_cwd_hmac,
    nullif(left(coalesce(p_client_label, ''), 128), ''),
    'running', now(),
    coalesce(p_realtime_private, false)
  )
  on conflict (id) do nothing
  returning id into v_inserted_id;

  if v_inserted_id is not null then
    return jsonb_build_object('session_id', p_session_id, 'status', 'ok');
  end if;

  -- Conflict path: the row already exists. Verify ownership before letting
  -- the helper update it (v0.30). A mismatch on EITHER user_id or device_id
  -- is unauthorized — the gate authenticated (device_id, helper_secret) →
  -- user_id, but the *session* may belong to another device pairing for the
  -- same user, which is also disallowed.
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
  set status           = 'running',
      last_event_at    = now(),
      cwd_basename     = coalesce(nullif(left(p_cwd_basename, 255), ''), cwd_basename),
      cwd_hmac         = coalesce(p_cwd_hmac, cwd_hmac),
      -- NULL = leave as-is, so a re-register from a pre-M4.4d caller can
      -- never silently DOWNGRADE a private session to public.
      realtime_private = coalesce(p_realtime_private, realtime_private)
  where id = p_session_id;

  return jsonb_build_object('session_id', p_session_id, 'status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ACL: reproduce the 7-arg function's grants EXACTLY (verified against prod:
-- `{=X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,
-- service_role=X/postgres}`). A freshly created function already carries the
-- default PUBLIC EXECUTE that the `=X` entry represents, so these grants are
-- additive-only — deliberately NO `revoke ... from public` here, because
-- tightening the ACL is a security-semantics change that does not belong in a
-- migration whose purpose is adding an argument.
grant execute on function public.remote_helper_register_session(
  uuid, text, uuid, text, text, text, text, boolean
) to anon, authenticated, service_role;
