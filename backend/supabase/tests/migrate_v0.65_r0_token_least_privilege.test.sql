-- ============================================================
-- pgTAP — R0 migrate_v0.65 least-privilege broadcast token (F1)
-- ============================================================
-- OWNER-RUN (not CI): pgTAP is NOT installed in prod and there is no SQL test
-- runner in CI. Run this AFTER applying migrate_v0.65 against a BRANCH database,
-- as a privileged role (the Supabase SQL editor's `postgres`) — creating a
-- realtime.messages partition + switching into the `r0_broadcast`/`anon` roles
-- both require it. The whole script runs in ONE transaction and ROLLS BACK, so
-- it leaves no fixtures, no partition, and no test rows behind.
--
--   create extension if not exists pgtap;   -- if not already present
--   \i backend/supabase/tests/migrate_v0.65_r0_token_least_privilege.test.sql
--
-- WHAT THIS PROVES (the SQL layer):
--   * r0_broadcast is least-privilege: it CANNOT read app tables
--     (devices/remote_sessions) and CANNOT execute the re-scoped uid-functions
--     (register_desktop_helper), but CAN insert into realtime.messages, and
--     `authenticator` can SET ROLE into it (so Realtime/PostgREST can assume it).
--   * The three uid-scoped SECURITY DEFINER functions are no longer reachable by
--     anon/PUBLIC but remain reachable by authenticated.
--   * WRITE RLS via the r0_broadcast_topic_allowed oracle: a token bound to
--     session A (session_id claim) may broadcast ONLY to pterm:A — cross-session
--     (same owner), topic/claim mismatch, missing claim, cross-user, and a
--     public (non-private) session are ALL denied; a malformed topic never errors.
--
-- WHAT THIS DOES NOT PROVE (the HTTP half — owner runbook integration step):
--   that the live POST /realtime/v1/api/broadcast endpoint (a) accepts a JWT
--   whose `role` is the CUSTOM r0_broadcast name and (b) evaluates this insert
--   policy end-to-end with a minted ES256 token. Supabase docs confirm Realtime
--   picks the Postgres role from the JWT `role` claim but only demonstrate the
--   built-in roles; the custom-role broadcast path MUST be integration-verified
--   before the cutover (mint an r0_broadcast token → broadcast to its pterm:
--   topic delivers; a cross-session token does NOT). Same gate v0.56 requires.
-- ============================================================

begin;
select plan(16);

-- Defensive: let this session SET ROLE into r0_broadcast regardless of the
-- harness login role (rolled back). A superuser could already; this covers
-- running the harness as a non-superuser member of authenticator.
grant r0_broadcast to current_user;

-- ---- fixtures (fixed uuids; rolled back) --------------------
insert into auth.users (id) values
  ('11111111-1111-4111-8111-111111111111'),  -- owner
  ('22222222-2222-4222-8222-222222222222');  -- attacker

insert into public.user_settings (user_id, remote_control_enabled, realtime_private_enabled) values
  ('11111111-1111-4111-8111-111111111111', true, true)
on conflict (user_id) do update
  set remote_control_enabled = excluded.remote_control_enabled,
      realtime_private_enabled = excluded.realtime_private_enabled;

insert into public.devices (id, user_id, name, helper_secret) values
  ('33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111',
   'owner-dev', encode(extensions.digest('r0-test-helper-secret', 'sha256'), 'hex'));

-- owner-private (A), owner-private (B, the cross-session target), owner-PUBLIC.
insert into public.remote_sessions (id, user_id, device_id, provider, status, realtime_private) values
  ('55555555-5555-4555-8555-555555555555', '11111111-1111-4111-8111-111111111111',
   '33333333-3333-4333-8333-333333333333', 'claude', 'running', true),   -- A: owner private
  ('66666666-6666-4666-8666-666666666666', '11111111-1111-4111-8111-111111111111',
   '33333333-3333-4333-8333-333333333333', 'claude', 'running', true),   -- B: owner private
  ('77777777-7777-4777-8777-777777777777', '11111111-1111-4111-8111-111111111111',
   '33333333-3333-4333-8333-333333333333', 'claude', 'running', false);  -- owner PUBLIC

-- A partition covering the test inserted_at (realtime.messages is RANGE
-- partitioned; no default partition). Dropped on rollback.
create table realtime.messages_r0_65test
  partition of realtime.messages
  for values from ('2099-06-01') to ('2099-06-02');

-- write-attempt helper under role r0_broadcast with a full claim set.
create function pg_temp.r0b_try_insert(p_sub text, p_session_id text, p_topic text)
returns boolean language plpgsql as $$
declare ok boolean := true;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'r0_broadcast', 'session_id', p_session_id)::text, true);
  perform set_config('realtime.topic', p_topic, true);
  begin
    set local role r0_broadcast;
    insert into realtime.messages (topic, extension, payload, event, private, inserted_at)
    values (p_topic, 'broadcast', '{"data_b64":""}'::jsonb, 'stdout', true,
            timestamp '2099-06-01 12:00:00');
  exception when others then
    ok := false;   -- RLS denial (42501), permission-denied, or any error → "denied"
  end;
  reset role;
  return ok;
end $$;

-- ============================================================
-- (A) r0_broadcast is least-privilege + assumable
-- ============================================================
select ok( exists(select 1 from pg_roles where rolname = 'r0_broadcast'),
  'role: r0_broadcast exists');
select ok( not has_table_privilege('r0_broadcast', 'public.devices', 'SELECT'),
  'role: r0_broadcast CANNOT read public.devices');
select ok( not has_table_privilege('r0_broadcast', 'public.remote_sessions', 'SELECT'),
  'role: r0_broadcast CANNOT read public.remote_sessions');
select ok( has_table_privilege('r0_broadcast', 'realtime.messages', 'INSERT'),
  'role: r0_broadcast CAN insert realtime.messages (broadcast)');
select ok( not has_table_privilege('r0_broadcast', 'realtime.messages', 'SELECT'),
  'role: r0_broadcast CANNOT select realtime.messages (no read-back)');
select ok( pg_has_role('authenticator', 'r0_broadcast', 'SET'),
  'role: authenticator can SET ROLE into r0_broadcast (Realtime/PostgREST can assume it)');

-- ============================================================
-- (B) uid-scoped SECURITY DEFINER functions re-scoped off anon/PUBLIC
-- ============================================================
select ok( not has_function_privilege('anon', 'public.register_desktop_helper(text,text,text,text)', 'EXECUTE'),
  'grant: anon CANNOT execute register_desktop_helper (no owner-impersonating helper_secret)');
select ok( not has_function_privilege('r0_broadcast', 'public.register_desktop_helper(text,text,text,text)', 'EXECUTE'),
  'grant: r0_broadcast CANNOT execute register_desktop_helper');
select ok( has_function_privilege('authenticated', 'public.register_desktop_helper(text,text,text,text)', 'EXECUTE'),
  'grant: authenticated CAN still execute register_desktop_helper (desktop app unaffected)');
select ok( not has_function_privilege('anon', 'public.upsert_daily_usage(jsonb,uuid)', 'EXECUTE'),
  'grant: anon CANNOT execute upsert_daily_usage');

-- ============================================================
-- (C) WRITE RLS via the r0_broadcast_topic_allowed oracle
-- ============================================================
select ok(
  pg_temp.r0b_try_insert('11111111-1111-4111-8111-111111111111',
    '55555555-5555-4555-8555-555555555555', 'pterm:55555555-5555-4555-8555-555555555555'),
  'write: token bound to session A CAN broadcast to pterm:A');

select ok(
  not pg_temp.r0b_try_insert('11111111-1111-4111-8111-111111111111',
    '55555555-5555-4555-8555-555555555555', 'pterm:66666666-6666-4666-8666-666666666666'),
  'write: token bound to A CANNOT broadcast to the owner''s OTHER session B (cross-session closed)');

select ok(
  not pg_temp.r0b_try_insert('11111111-1111-4111-8111-111111111111',
    '66666666-6666-4666-8666-666666666666', 'pterm:55555555-5555-4555-8555-555555555555'),
  'write: topic must equal pterm:<session_id claim> (claim/topic mismatch denied)');

select ok(
  not pg_temp.r0b_try_insert('11111111-1111-4111-8111-111111111111',
    null, 'pterm:55555555-5555-4555-8555-555555555555'),
  'write: missing session_id claim → denied (fail closed)');

select ok(
  not pg_temp.r0b_try_insert('22222222-2222-4222-8222-222222222222',
    '55555555-5555-4555-8555-555555555555', 'pterm:55555555-5555-4555-8555-555555555555'),
  'write: a DIFFERENT user''s sub CANNOT broadcast to the owner''s session (cross-user closed)');

select ok(
  not pg_temp.r0b_try_insert('11111111-1111-4111-8111-111111111111',
    '77777777-7777-4777-8777-777777777777', 'pterm:77777777-7777-4777-8777-777777777777'),
  'write: a PUBLIC (non-private) session CANNOT be broadcast on pterm:');

select * from finish();
rollback;
