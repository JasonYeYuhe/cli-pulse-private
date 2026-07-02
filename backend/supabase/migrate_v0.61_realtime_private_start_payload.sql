-- ============================================================
-- v0.61 — R0: carry realtime_private in the helper-facing session-start
--         payload + revoke the drifted authorize-broadcast grant.
-- Date: 2026-07-02
--
-- Operationalizes DEV_PLAN_2026-07-02_r0_private_cutover.md §S5 (Codex P0-1
-- + Gemini #2). ADDITIVE + safe to apply around any client release: it does
-- NOT change any RPC signature, only the JSON *body* of the 'start' command a
-- helper already reads, and tightens one grant that had drifted wider than
-- migrate_v0.56 intended.
--
-- WHY (Codex P0-1, verified live 2026-07-02 via pg_get_functiondef):
--   remote_app_request_session_start decides realtime_private ATOMICALLY at
--   session-create (migrate_v0.56 §6) and stores it on the remote_sessions
--   row, but the 'start' *command* payload the helper pulls
--   (remote_helper_pull_commands → the stored payload text) carries only
--   provider / cwd_basename / cwd_hmac / client_label. So NEITHER helper had
--   an authoritative privacy source before first stdout. Both the Python
--   producer's LOCAL gate ("only mint a broadcast token for private sessions")
--   and the Swift helper's fail-closed mute ("unknown privacy ⇒ do not
--   broadcast") need this flag in-band. realtime_private is IMMUTABLE after
--   create (session mode is atomic at create — migrate_v0.56 §1), so baking it
--   into the create-time payload is equivalent to re-reading the row, and
--   remote_helper_pull_commands then carries it forward verbatim with zero
--   change to that hot-path RPC.
--
-- DRIFT RULE ([[feedback_supabase_function_body_drift]]): the re-emitted body
-- below was dumped LIVE from prod (gkjwsxotmwrgqsvfijzs) via pg_get_functiondef
-- on 2026-07-02 and matched the migrate_v0.56 re-emit byte-for-byte (no drift
-- from v0.57–v0.60). The ONLY changes are the two [R0-v0.61] lines: the
-- realtime-private decision is hoisted into a single variable so the inserted
-- COLUMN and the emitted PAYLOAD can never disagree, and a 'realtime_private'
-- key is added to the start payload.
--
-- Signature is UNCHANGED, so CREATE OR REPLACE preserves grants (no re-grant
-- needed) and PostgREST's schema cache needs no reload (the change is internal
-- to the body). This whole script runs as ONE transaction.
-- ============================================================

-- ------------------------------------------------------------
-- (1) Re-emit remote_app_request_session_start — add realtime_private to the
--     start-command payload. Hoist the atomic mode decision into v_realtime_private
--     so the inserted column and the emitted payload share one source.
-- ------------------------------------------------------------
create or replace function public.remote_app_request_session_start(
  p_device_id uuid,
  p_provider text,
  p_cwd_basename text DEFAULT ''::text,
  p_cwd_hmac text DEFAULT NULL::text,
  p_client_label text DEFAULT NULL::text
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
  v_realtime_private boolean;                                            -- [R0-v0.61] single source for column + payload
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

  -- [R0-v0.61] Decide the session mode ONCE, atomically, from the caller's
  -- opt-in. Used for both the stored column and the helper-facing payload.
  v_realtime_private := coalesce(
    (select realtime_private_enabled from public.user_settings where user_id = v_user_id),
    false);

  insert into public.remote_sessions (
    id, user_id, device_id, provider, cwd_basename, cwd_hmac, client_label,
    status, last_event_at,
    realtime_private                                                     -- [R0] added column (v0.56)
  ) values (
    v_session_id, v_user_id, p_device_id, v_provider,
    coalesce(left(p_cwd_basename, 255), ''),
    p_cwd_hmac,
    nullif(left(coalesce(p_client_label, ''), 128), ''),
    'pending', now(),
    v_realtime_private                                                   -- [R0-v0.61] hoisted (was inline coalesce)
  );

  v_payload := jsonb_build_object(
    'provider',         v_provider,
    'cwd_basename',     coalesce(left(p_cwd_basename, 255), ''),
    'cwd_hmac',         p_cwd_hmac,
    'client_label',     nullif(left(coalesce(p_client_label, ''), 128), ''),
    'realtime_private', v_realtime_private                               -- [R0-v0.61] authoritative privacy source for the helper
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

-- ------------------------------------------------------------
-- (2) Revoke the drifted EXECUTE grant. migrate_v0.56 §5 intended
--     `to anon, service_role` only, but prod drifted to also grant
--     `authenticated` (confirmed live 2026-07-02 via role_routine_grants).
--     The edge fn mints via the SERVICE ROLE (functions/mint-realtime-token/
--     index.ts) and the fn is internally gated by helper_secret, so an
--     end-user (authenticated) role never needs — and must not have — EXECUTE.
--     Idempotent: revoking an absent grant is a no-op.
-- ------------------------------------------------------------
revoke execute on function public.remote_helper_authorize_broadcast(uuid, text, uuid) from authenticated;

-- ------------------------------------------------------------
-- Post-apply verification (run manually after APPLY):
--   -- start payload now carries realtime_private (create a session as a
--   -- private-enabled user, then inspect the pending 'start' command):
--   --   select payload::jsonb -> 'realtime_private' from public.remote_session_commands
--   --     where kind='start' order by created_at desc limit 1;   -- expect true/false, not null
--   -- authorize RPC granted to anon + service_role only (NOT authenticated):
--   select grantee, privilege_type from information_schema.role_routine_grants
--     where routine_schema='public' and routine_name='remote_helper_authorize_broadcast'
--     order by grantee;                                           -- anon, postgres, service_role (no authenticated)
-- ============================================================
