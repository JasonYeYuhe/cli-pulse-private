-- ============================================================
-- v0.50 — Accept `input_raw` and `resize` command kinds for the
-- in-app remote terminal (v1.25 Phase 4 slice 2).
-- Date: 2026-05-26 (drafted) · APPLIED to prod 2026-05-28 (jizav.../gkjw...)
--
-- Goal:
-- The v1.25 iOS in-app terminal needs to forward raw xterm.js
-- keystrokes (including control bytes like 0x03 Ctrl-C / 0x04
-- Ctrl-D / arrow ESC sequences) and viewport-resize signals to
-- the Mac helper's PTY. The existing `prompt` command kind
-- CR-appends payloads (correct for "send a prompt to the spawned
-- Claude") but corrupts raw byte streams. The existing
-- `interrupt` kind sends SIGINT but doesn't carry a payload.
--
-- Two new kinds:
--   * `input_raw` — payload is **base64-encoded raw bytes** the
--     helper decodes and writes verbatim to the PTY master fd
--     (helper-side: `ManagedSessionManager.sendInputRaw(bytes:)`).
--   * `resize` — payload is `"<cols>x<rows>"` (e.g. `"80x24"`).
--     Helper parses and calls `ManagedSessionManager.resize`
--     which `ioctl(TIOCSWINSZ)`s the master fd, generating
--     SIGWINCH to the child so ratatui / ncurses reflow.
--
-- Architecture:
-- Only `remote_app_send_command`'s allowed-kinds whitelist
-- needs to change. The downstream pipeline
-- (`remote_helper_pull_commands` → helper queue) is already
-- kind-agnostic — it forwards `(kind, payload)` to
-- `RemoteAgentCloud.dispatch` which has its own switch on
-- kind. Helper-side changes ship in the same PR but are inert
-- until this migration is applied.
--
-- IMPORTANT — production-fidelity body:
-- The applied function body preserves every production semantic
-- accumulated since v0.39:
--   * `returns jsonb` (NOT `returns table`)
--   * `_remote_control_enabled_for_caller()` gate (v0.27 RC gate)
--   * `for update` row lock on `remote_sessions`
--   * On stop-pending: cancels existing pending commands +
--     transitions session to 'stopped' + writes a synthetic
--     failed 'stop' command row (v0.41 P0 stop-cancel behavior)
--   * `left(coalesce(p_payload, ''), 8192)` payload cap
--   * `set search_path to 'pg_catalog', 'public', 'extensions'`
--
-- The only delta vs v0.41's function body is the allowed-kinds
-- whitelist.
--
-- Safety:
--   * Backward-compatible: existing `'prompt'`/`'stop'`/
--     `'interrupt'` flows unchanged.
--   * Helper-side dispatch for `'input_raw'` / `'resize'`
--     no-ops on a helper that hasn't been updated to v1.25
--     (the switch falls through to default → "unknown command
--     kind", which marks the command failed but keeps the
--     queue draining). Pre-v1.25 helpers stay functional.
--   * No new tables, no new columns, no RLS changes.
--
-- Rollback:
--   alter table remote_session_commands
--     drop constraint remote_session_commands_kind_check;
--   alter table remote_session_commands
--     add constraint remote_session_commands_kind_check
--     check (kind in ('prompt', 'stop', 'interrupt', 'start'));
--   drop function remote_app_send_command(uuid, text, text);
--   -- restore the v0.41 function body.
-- ============================================================

-- 1. Loosen the table-level kind check to accept the two new
--    runtime kinds.
alter table public.remote_session_commands
  drop constraint if exists remote_session_commands_kind_check;

alter table public.remote_session_commands
  add constraint remote_session_commands_kind_check
  check (kind in (
    'prompt',
    'stop',
    'interrupt',
    'start',
    'input_raw',
    'resize'
  ));

-- 2. Re-create `remote_app_send_command` with the v0.41 body +
--    extended allowed-kinds list.  Must DROP first because the
--    function's return signature is jsonb (not table) and Postgres
--    rejects return-type changes via CREATE OR REPLACE.
drop function if exists public.remote_app_send_command(uuid, text, text);

create function public.remote_app_send_command(
  p_session_id uuid,
  p_kind text,
  p_payload text default ''
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'extensions'
as $$
declare
  v_user_id uuid := auth.uid();
  v_device_id uuid;
  v_status text;
  v_command_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    raise exception 'Remote Control is disabled';
  end if;
  if p_kind not in ('prompt', 'stop', 'interrupt', 'input_raw', 'resize') then
    raise exception 'Invalid command kind: %', p_kind;
  end if;

  select device_id, status
    into v_device_id, v_status
  from public.remote_sessions
  where id = p_session_id and user_id = v_user_id
  for update;

  if v_device_id is null then
    raise exception 'Session not found';
  end if;

  -- v0.41 P0: stopping a 'pending' session means the helper
  -- hasn't picked up the 'start' yet; cancel any queued
  -- commands + transition the session to 'stopped' + insert a
  -- synthetic failed 'stop' row so the audit trail records it.
  if p_kind = 'stop' and v_status = 'pending' then
    update public.remote_session_commands
       set status = 'failed',
           completed_at = now(),
           error_message = 'cancelled before helper pickup'
     where session_id = p_session_id
       and status = 'pending';

    update public.remote_sessions
       set status = 'stopped',
           last_event_at = now()
     where id = p_session_id;

    insert into public.remote_session_commands (
      user_id, device_id, session_id, kind, payload, status,
      completed_at, error_message
    ) values (
      v_user_id, v_device_id, p_session_id, 'stop',
      left(coalesce(p_payload, ''), 8192),
      'failed',
      now(),
      'cancelled before helper pickup'
    )
    returning id into v_command_id;

    return jsonb_build_object('command_id', v_command_id);
  end if;

  -- Queue the command. Helper picks it up via
  -- `remote_helper_pull_commands` on its 200 ms (v1.25) loop.
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
$$;

grant execute on function public.remote_app_send_command(uuid, text, text) to authenticated;

-- ============================================================
-- Verify (after apply):
--   select pg_get_constraintdef(oid) from pg_constraint
--    where conname = 'remote_session_commands_kind_check';
--   -- → must include 'input_raw' and 'resize'
--
--   select pg_get_function_result(oid) from pg_proc
--    where proname = 'remote_app_send_command'
--      and pronamespace = 'public'::regnamespace;
--   -- → 'jsonb'
-- ============================================================
