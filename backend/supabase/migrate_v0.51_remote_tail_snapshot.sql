-- ============================================================
-- v0.51 — Accept `tail_snapshot` command kind for iOS terminal
-- foreground-recovery (v1.26 Phase B2).
-- Date: 2026-05-27
--
-- Goal:
-- The v1.25 iOS in-app terminal has a foreground-recovery gap:
-- when the app backgrounds and resubscribes to Realtime, chunks
-- emitted during the disconnect are lost. v1.26 B2 fills the gap
-- with a `tail_snapshot` RPC — iOS requests the last N bytes of
-- the session's PTY ring buffer; helper publishes the snapshot
-- via the same Realtime broadcast channel as `stdout` chunks
-- (new event kind `tail_snapshot_result`).
--
-- Architecture:
--   * **Request path is durable** — iOS calls
--     `remote_app_send_command(session_id, 'tail_snapshot', '')`.
--     We extend the existing command queue's allowed-kinds list.
--     `payload` carries `maxBytes` as a decimal string (defaults
--     to 8192 helper-side when empty / unparseable). Helper picks
--     the command up via `remote_helper_pull_commands`.
--   * **Response path is ephemeral (Codex MEDIUM B2)** — the
--     existing `remote_session_events` table caps payloads at
--     4 KB (migrate_v0.26 line 67 / migrate_v0.27 line 143), and
--     a 64 KB snapshot would need chunking + reassembly. Instead,
--     the helper publishes the snapshot via the same `term:<sid>`
--     Realtime broadcast channel the live `stdout` chunks use;
--     event kind `tail_snapshot_result`. If iOS misses the
--     broadcast (rare timing race), a subsequent background→
--     foreground cycle re-requests. Snapshot is best-effort.
--
-- iOS-side state machine:
--   * `Coordinator.resume()` → set `pendingSnapshotBuffer = []`,
--     subscribe to terminal channel, send `tail_snapshot`
--     command, start 2 s timer.
--   * Live chunks while buffering → append to buffer (don't
--     `term.write` yet).
--   * `tail_snapshot_result` arrives → write snapshot, drain
--     buffer in order, set `pendingSnapshotBuffer = nil`.
--   * 2 s timeout → drain buffer, set `nil` (snapshot never
--     arrived; user sees the live chunks unprefixed).
--   * Cold-start skip — fresh subscribe with no prior session
--     state goes straight to direct-write mode (nothing to
--     recover).
--
-- Safety:
--   * Backward-compatible: existing `'prompt'/'stop'/'interrupt'/
--     'input_raw'/'resize'` flows unchanged.
--   * Helper-side dispatch for `'tail_snapshot'` on a helper
--     that hasn't been updated to v1.26 falls through to the
--     default → "unknown command kind" arm; pre-v1.26 helpers
--     stay functional (snapshot RPC silently fails, iOS times
--     out at 2 s and proceeds without recovery).
--   * No new tables, no new columns, no RLS changes — the
--     queue already enforces "user can only enqueue commands
--     against sessions they own" via `remote_app_send_command`
--     itself.
--   * `tail_snapshot_result` is **NOT** added to the
--     `remote_session_events.kind` check constraint — broadcast
--     events don't touch Postgres.
--
-- Rollback:
-- `drop function remote_app_send_command(uuid, text, text);`
-- then re-create with the v0.50 body. The
-- `remote_session_commands.kind` check constraint can be
-- restored via:
--   alter table remote_session_commands drop constraint if exists ...;
--   alter table remote_session_commands add constraint kind_check
--     check (kind in ('prompt', 'stop', 'interrupt', 'start',
--                     'input_raw', 'resize'));
-- ============================================================

-- 1. Loosen the table-level kind check to accept the new
--    runtime kind.
alter table public.remote_session_commands
  drop constraint if exists remote_session_commands_kind_check;

alter table public.remote_session_commands
  add constraint remote_session_commands_kind_check
  check (kind in (
    'prompt',
    'stop',
    'interrupt',
    'start',
    'input_raw',     -- v0.50: raw xterm.js bytes (base64 payload)
    'resize',        -- v0.50: viewport resize ("<cols>x<rows>" payload)
    'tail_snapshot'  -- v0.51: foreground-recovery snapshot request (maxBytes decimal payload)
  ));

-- 2. Replace `remote_app_send_command` to accept the new kind.
--    Body matches v0.50's logic for the existing kinds; the only
--    delta is the allowed-kinds list.
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
  -- v0.51: accept tail_snapshot. Reject everything else so a
  -- buggy client can't sneak a typo'd kind into the queue.
  if p_kind not in (
    'prompt', 'stop', 'interrupt',
    'input_raw', 'resize',
    'tail_snapshot'
  ) then
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
  -- next pull skips the queued start.
  if p_kind = 'stop' and v_status = 'pending' then
    update public.remote_sessions
       set status = 'cancelled'
     where id = p_session_id;
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
--     '<owned-session-uuid>'::uuid, 'tail_snapshot', '8192'
--   );
--   -- → returns a command_id; helper.remote_session_commands gets a row.
--   --   Helper picks it up, queries ManagedSessionManager.getTailSnapshot,
--   --   POSTs the redacted snapshot to /realtime/v1/api/broadcast as
--   --   event 'tail_snapshot_result' on channel 'term:<sid>'.
--
--   -- rejection (mistyped kind):
--   select public.remote_app_send_command(
--     '<owned-session-uuid>'::uuid, 'tail_snapshat', ''
--   );
--   -- → ERROR: Invalid command kind: tail_snapshat
-- ============================================================
