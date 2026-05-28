-- ============================================================
-- v0.51 — Accept `tail_snapshot` command kind for iOS terminal
-- foreground-recovery (v1.26 Phase B2).
-- Date: 2026-05-27 (drafted) · APPLIED to prod 2026-05-28 (gkjw...)
--
-- Goal:
-- v1.25 ships iOS interactive terminal with a foreground-recovery
-- gap — chunks emitted while the app is backgrounded are lost when
-- the WS resubscribes. v1.26 B2 fills the gap: iOS asks the helper
-- for the last N bytes of the session's redacted PTY ring buffer;
-- helper publishes the snapshot via the same Realtime broadcast
-- channel as live stdout (event `tail_snapshot_result`). iOS
-- buffers live chunks during the warm subscribe, drains snapshot
-- first then buffered, then switches to direct-write.
--
-- Request path is durable (this migration): iOS calls
-- `remote_app_send_command(session_id, 'tail_snapshot', '<bytes>')`.
-- Payload carries maxBytes as a decimal string; helper defaults to
-- 8192 on empty/garbage and clamps to [0, 65536].
--
-- Response path is ephemeral (NOT in this migration):
-- `remote_session_events.kind` is NOT extended. The existing event
-- table caps payloads at 4 KB (v0.26 line 67 / v0.27 line 143);
-- a 64 KB snapshot would need chunking + reassembly. We publish
-- via the existing `term:<sid>` Realtime broadcast channel as
-- event `tail_snapshot_result`. Miss = iOS 2 s timeout = drain
-- buffer unprefixed (no regression vs v1.25 baseline).
--
-- IMPORTANT — production-fidelity body:
-- Preserves every production semantic from v0.50:
--   * `returns jsonb`
--   * `_remote_control_enabled_for_caller()` gate
--   * `for update` row lock
--   * Stop-pending side effects (v0.41 P0 behavior)
--   * 8192 payload cap, search_path 3-tuple
--
-- Delta vs v0.50 body: allowed-kinds list grows by `tail_snapshot`.
--
-- Safety:
--   * Backward-compatible: existing kinds unchanged.
--   * Helper-side dispatch for `'tail_snapshot'` on a pre-v1.26
--     helper falls through to default → "unknown command kind";
--     iOS 2 s timeout absorbs the miss.
--   * No new tables, no new columns, no RLS changes.
-- ============================================================

-- 1. Loosen the table-level kind check to accept tail_snapshot.
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
    'resize',
    'tail_snapshot'
  ));

-- 2. Re-create `remote_app_send_command` with extended whitelist.
--    Must DROP first (jsonb return type vs the table-typed body
--    Postgres rejects via CREATE OR REPLACE).
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
  if p_kind not in ('prompt', 'stop', 'interrupt', 'input_raw', 'resize', 'tail_snapshot') then
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
--   -- → must include 'tail_snapshot'
-- ============================================================
