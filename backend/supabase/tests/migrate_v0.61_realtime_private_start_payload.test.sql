-- ============================================================
-- pgTAP — R0 migrate_v0.61 realtime_private in start payload + grant hygiene
-- ============================================================
-- OWNER-RUN (not CI): pgTAP is NOT installed in prod and there is no SQL test
-- runner in CI (the live-migration-replay job is deferred — see supabase-ci.yml
-- F9). Run this AFTER applying migrate_v0.61 against a BRANCH database, as a
-- privileged role (the Supabase SQL editor's `postgres`, or a `supabase db`
-- connection). The whole script runs in ONE transaction and ROLLS BACK, so it
-- leaves no fixtures behind.
--
--   create extension if not exists pgtap;   -- if not already present
--   \i backend/supabase/tests/migrate_v0.61_realtime_private_start_payload.test.sql
--
-- WHAT THIS PROVES:
--   * remote_app_request_session_start now bakes realtime_private into the
--     'start' COMMAND payload (the helper's authoritative privacy source), and
--     it always matches the remote_sessions ROW's realtime_private (single
--     source — the hoisted v_realtime_private var).
--   * a private-enabled user's session → payload realtime_private = true;
--     a non-enabled user's session → false.
--   * the migrate_v0.61 grant hygiene held: EXECUTE on
--     remote_helper_authorize_broadcast is REVOKED from `authenticated` while
--     `anon` + `service_role` retain it (surgical — the edge fn mints via the
--     service role; end-users must not reach the gate).
-- ============================================================

begin;
select plan(7);

-- ---- fixtures (fixed uuids; rolled back) --------------------
-- Inserting auth.users fires the handle_new_user cascade that AUTO-CREATES the
-- public.user_settings + profiles rows, so we UPDATE (never INSERT) settings.
insert into auth.users (id) values
  ('11111111-1111-4111-8111-111111111111'),  -- private-enabled owner
  ('22222222-2222-4222-8222-222222222222');  -- public (not private-enabled)

-- Remote Control ON for both (remote_app_request_session_start gates on it).
insert into public.user_settings (user_id, remote_control_enabled, realtime_private_enabled) values
  ('11111111-1111-4111-8111-111111111111', true, true)
on conflict (user_id) do update
  set remote_control_enabled = excluded.remote_control_enabled,
      realtime_private_enabled = excluded.realtime_private_enabled;
insert into public.user_settings (user_id, remote_control_enabled, realtime_private_enabled) values
  ('22222222-2222-4222-8222-222222222222', true, false)
on conflict (user_id) do update
  set remote_control_enabled = excluded.remote_control_enabled,
      realtime_private_enabled = excluded.realtime_private_enabled;

insert into public.devices (id, user_id, name, helper_secret) values
  ('33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111',
   'owner-dev', encode(extensions.digest('r0-test-helper-secret', 'sha256'), 'hex')),
  ('44444444-4444-4444-8444-444444444444', '22222222-2222-4222-8222-222222222222',
   'public-dev', encode(extensions.digest('public-secret', 'sha256'), 'hex'));

-- ---- helper: request a managed session as p_sub, return the created start
-- command's payload realtime_private AND the session ROW's realtime_private so
-- the test can assert they agree (single-source invariant).
create function pg_temp.mk(p_sub text, p_device uuid)
returns jsonb language plpgsql as $$
declare
  r jsonb;
  v_cmd uuid;
  v_sess uuid;
  v_payload jsonb;
  v_row boolean;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  r := public.remote_app_request_session_start(p_device, 'claude');
  v_sess := (r->>'session_id')::uuid;
  v_cmd  := (r->>'command_id')::uuid;
  select payload::jsonb into v_payload from public.remote_session_commands where id = v_cmd;
  select realtime_private into v_row from public.remote_sessions where id = v_sess;
  perform set_config('request.jwt.claims', '', true);
  return jsonb_build_object('payload_rp', v_payload->'realtime_private', 'row_rp', to_jsonb(v_row));
end $$;

create temp table t_owner  on commit drop as select pg_temp.mk('11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333') as r;
create temp table t_public on commit drop as select pg_temp.mk('22222222-2222-4222-8222-222222222222', '44444444-4444-4444-8444-444444444444') as r;

-- ============================================================
-- (A) start payload carries realtime_private, consistent with the row
-- ============================================================
select is((select r->'payload_rp' from t_owner), 'true'::jsonb,
  'start payload: private-enabled user → realtime_private = true');
select is((select r->'row_rp' from t_owner), 'true'::jsonb,
  'session row: private-enabled user → realtime_private = true (payload matches row)');
select is((select r->'payload_rp' from t_public), 'false'::jsonb,
  'start payload: non-enabled user → realtime_private = false');
select is((select r->'row_rp' from t_public), 'false'::jsonb,
  'session row: non-enabled user → realtime_private = false (payload matches row)');

-- ============================================================
-- (B) grant hygiene — authorize RPC revoked from authenticated, kept for the
--     service-role mint path + anon-reachable helper contract.
-- ============================================================
select is(
  has_function_privilege('authenticated',
    'public.remote_helper_authorize_broadcast(uuid,text,uuid)', 'execute'),
  false, 'grant: authenticated has NO execute on authorize RPC (v0.61 revoke)');
select is(
  has_function_privilege('anon',
    'public.remote_helper_authorize_broadcast(uuid,text,uuid)', 'execute'),
  true, 'grant: anon retains execute (helper contract, gated by helper_secret)');
select is(
  has_function_privilege('service_role',
    'public.remote_helper_authorize_broadcast(uuid,text,uuid)', 'execute'),
  true, 'grant: service_role retains execute (edge-fn mint path)');

select * from finish();
rollback;
