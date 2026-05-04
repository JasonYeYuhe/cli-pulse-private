-- ============================================================
-- v0.41 — remote_app_send_command pending-session cancel path
-- Date: 2026-05-04
--
-- Background:
-- v0.39 introduced `remote_app_request_session_start` which inserts a
-- `remote_sessions` row with status='pending' and enqueues a 'start'
-- command for the helper. If no helper picks the command up (helper
-- not running, or installed helper is pre-PR-#10 and doesn't know the
-- 'start' kind), the session stays pending forever and the regular
-- stop path is also useless (helper never reads its stop command
-- either).
--
-- Manual UI testing surfaced the trap: a user can create pending
-- sessions, click Stop multiple times, type a prompt and hit Send —
-- nothing works, and the rows accumulate in the active-sessions list
-- because list_sessions filters status in ('pending','running').
--
-- Fix:
-- Extend `remote_app_send_command` so that `p_kind='stop'` against a
-- session whose current status='pending' acts as an APP-SIDE CANCEL,
-- not a queued helper command. Concretely the function:
--   * locks the session row (for update) to serialize against helper
--     `register_session` racing in,
--   * marks every pending command for that session 'failed' with
--     error_message='cancelled before helper pickup',
--   * sets the session to status='stopped' + last_event_at=now(),
--   * records the new stop command row with status='failed' (NOT
--     'pending') and matching error_message — preserving the
--     "every send_command call writes one command row" invariant
--     and the {command_id} return shape — but explicitly indicating
--     it never reached a helper.
--
-- All other paths are byte-identical:
--   * stop on running session → still enqueues 'pending' for the
--     helper to consume on next tick;
--   * prompt / interrupt → unchanged;
--   * stop on already-stopped/errored → unchanged (enqueues a
--     pending command that the helper will see and dispose of); not
--     introducing a regression.
--
-- Race note:
-- The "for update" lock ensures the session-status read and the
-- subsequent UPDATE happen atomically with respect to the helper's
-- `remote_helper_register_session` (which UPSERTs ownership-checked).
-- If the helper has ALREADY transitioned the session to 'running'
-- when the cancel arrives, v_status reads 'running' and we fall
-- through to the normal stop-by-enqueue path — i.e. the cancel
-- gracefully degrades to a regular stop, no orphaned PTY.
--
-- Privacy/security:
-- Auth uid + Remote Control gate identical to today. SECURITY
-- DEFINER, search_path locked, signature unchanged. CREATE OR
-- REPLACE preserves grants (anon/authenticated/service_role
-- EXECUTE — same as v0.31 hardening).
--
-- Idempotent: safe to re-run.
-- ============================================================

create or replace function public.remote_app_send_command(
  p_session_id uuid,
  p_kind text,
  p_payload text default ''
) returns jsonb as $$
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
  if p_kind not in ('prompt', 'stop', 'interrupt') then
    raise exception 'Invalid command kind: %', p_kind;
  end if;

  -- Lock the session row to serialize cancel vs. helper register_session.
  select device_id, status
    into v_device_id, v_status
  from public.remote_sessions
  where id = p_session_id and user_id = v_user_id
  for update;

  if v_device_id is null then
    raise exception 'Session not found';
  end if;

  -- App-side cancel for queued (pending) sessions on stop.
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

  -- Normal path: enqueue a pending command for the helper to consume.
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


-- ── Manual verification (run after applying):
--   -- normal-path stop on a running session still enqueues pending:
--   set local role authenticated;
--   set local "request.jwt.claim.sub" to '<user>';
--   select public.remote_app_send_command('<running-session>'::uuid, 'stop', '');
--   select status from public.remote_session_commands order by created_at desc limit 1;
--   --   → 'pending'
--
--   -- pending-session stop is now an inline cancel:
--   select public.remote_app_send_command('<pending-session>'::uuid, 'stop', '');
--   select status, error_message from public.remote_session_commands order by created_at desc limit 1;
--   --   → status='failed', error_message='cancelled before helper pickup'
--   select status from public.remote_sessions where id = '<pending-session>';
--   --   → 'stopped'
