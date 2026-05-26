-- ============================================================
-- v0.50 — Accept `input_raw` and `resize` command kinds for the
-- in-app remote terminal (v1.25 Phase 4 slice 2).
-- Date: 2026-05-26
--
-- Goal:
-- The v1.25 iOS in-app terminal needs to forward raw xterm.js
-- keystrokes (including control bytes like 0x03 Ctrl-C / 0x04
-- Ctrl-D / arrow ESC sequences) and viewport-resize signals to
-- the Mac helper's PTY. The existing `prompt` command kind
-- CR-appends payloads (correct semantics for "send a prompt to
-- the spawned Claude") but corrupts raw byte streams. The
-- existing `interrupt` kind sends SIGINT but doesn't carry a
-- payload.
--
-- Two new kinds:
--   * `input_raw` — payload is **base64-encoded raw bytes** the
--     helper decodes and writes verbatim to the PTY master fd
--     (helper-side: `ManagedSessionManager.sendInputRaw(bytes:)`).
--     Base64 keeps the wire shape JSON-safe for the byte ranges
--     UTF-8 can't round-trip (control bytes, partial multi-byte
--     boundaries the keystroke timing may produce).
--   * `resize` — payload is `"<cols>x<rows>"` (e.g. `"80x24"`).
--     Helper parses and calls `ManagedSessionManager.resize`
--     which `ioctl(TIOCSWINSZ)`s the master fd, generating
--     SIGWINCH to the child so ratatui / ncurses reflow.
--
-- Architecture:
-- Only `remote_app_send_command`'s allowed-kinds whitelist
-- needs to change. The downstream pipeline
-- (`remote_helper_pull_commands` → helper queue) is
-- already kind-agnostic — it forwards `(kind, payload)` to
-- `RemoteAgentCloud.dispatch` which has its own `switch` on
-- kind. Helper-side changes ship in the same PR but are
-- inert until this migration is applied.
--
-- The `remote_session_commands.kind` check constraint (added
-- in v0.39, line 51 of `migrate_v0.39_remote_session_input.sql`)
-- already accepts `'start'` as a write-only synthetic kind;
-- extend it the same way for `'input_raw'` and `'resize'`.
--
-- Safety:
--   * Backward-compatible: existing `'prompt'`/`'stop'`/
--     `'interrupt'` flows unchanged.
--   * The helper-side dispatch for `'input_raw'` / `'resize'`
--     no-ops on a helper that hasn't been updated to v1.25
--     (the `switch` falls through to `default → "unknown
--     command kind"`, which marks the command failed but
--     keeps the queue draining). Pre-v1.25 helpers stay
--     functional.
--   * No new tables, no new columns, no RLS changes — the
--     queue already enforces "user can only enqueue commands
--     against sessions they own" via `remote_app_send_command`
--     itself.
--
-- Rollback:
-- `drop function remote_app_send_command(uuid, text, text);`
-- then re-create with the v0.41 body. The
-- `remote_session_commands.kind` check constraint can be
-- restored via:
--   alter table remote_session_commands drop constraint if exists ...;
--   alter table remote_session_commands add constraint kind_check
--     check (kind in ('prompt', 'stop', 'interrupt', 'start'));
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
    'input_raw',  -- v0.50: raw xterm.js bytes (base64 payload)
    'resize'      -- v0.50: viewport resize ("<cols>x<rows>" payload)
  ));

-- 2. Replace `remote_app_send_command` to accept the new kinds.
--    Body matches v0.41's logic for the existing kinds; the only
--    delta is the allowed-kinds list. Keep the pending-cancel
--    early-out for `'stop'` (v0.41 P0 behavior).
create or replace function public.remote_app_send_command(
  p_session_id uuid,
  p_kind text,
  p_payload text default ''
)
returns table (command_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_device_id uuid;
  v_status text;
  v_cmd_id uuid;
begin
  -- v0.50: accept input_raw and resize. Reject everything else
  -- so a buggy client can't sneak a typo'd kind into the queue.
  if p_kind not in ('prompt', 'stop', 'interrupt', 'input_raw', 'resize') then
    raise exception 'Invalid command kind: %', p_kind;
  end if;

  -- Caller must own the session. JWT-gated; no service-role
  -- bypass needed because the helper-side path goes through a
  -- different RPC (`remote_helper_pull_commands`).
  select user_id, device_id, status
    into v_user_id, v_device_id, v_status
    from public.remote_sessions
   where id = p_session_id
     and user_id = auth.uid();

  if not found then
    raise exception 'Session not found or unauthorized';
  end if;

  -- v0.41 P0: stopping a 'pending' session means the helper
  -- hasn't picked up the 'start' yet; the simplest cancel is
  -- to flip the session status to 'cancelled' so the helper's
  -- next pull skips the queued start. No `'stop'` queue row
  -- needed in that case — the helper would just race a stop
  -- against a session that never spawned.
  if p_kind = 'stop' and v_status = 'pending' then
    update public.remote_sessions
       set status = 'cancelled'
     where id = p_session_id;
    -- Return NULL command id; client treats it as a no-op
    -- success.
    return query select null::uuid as command_id;
    return;
  end if;

  -- Queue the command. Helper picks it up via
  -- `remote_helper_pull_commands` on its 1 s (or 200 ms post-
  -- v1.25 fast-tick) loop.
  insert into public.remote_session_commands (
    user_id, device_id, session_id, kind, payload, status, created_at
  ) values (
    v_user_id, v_device_id, p_session_id, p_kind,
    coalesce(p_payload, ''), 'queued', now()
  )
  returning id into v_cmd_id;

  return query select v_cmd_id as command_id;
end;
$$;

grant execute on function public.remote_app_send_command(uuid, text, text) to authenticated;

-- ============================================================
-- Verify:
--
--   -- happy path:
--   select public.remote_app_send_command(
--     '<owned-session-uuid>'::uuid, 'input_raw', 'AwQK'  -- base64("\x03\x04\n")
--   );
--   -- → returns a command_id; helper.remote_session_commands gets a row.
--
--   -- resize:
--   select public.remote_app_send_command(
--     '<owned-session-uuid>'::uuid, 'resize', '80x24'
--   );
--
--   -- rejection (mistyped kind):
--   select public.remote_app_send_command(
--     '<owned-session-uuid>'::uuid, 'inpoot_raw', ''
--   );
--   -- → ERROR: Invalid command kind: inpoot_raw
-- ============================================================
