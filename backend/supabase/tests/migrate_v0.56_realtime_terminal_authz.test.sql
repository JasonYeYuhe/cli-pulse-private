-- ============================================================
-- pgTAP — R0 migrate_v0.56 realtime terminal authz
-- ============================================================
-- OWNER-RUN (not CI): pgTAP is NOT installed in prod and there is no SQL
-- test runner in CI (the live-migration-replay job is deferred — see
-- supabase-ci.yml F9). Run this AFTER applying migrate_v0.56 against a
-- BRANCH database, as a privileged role (the Supabase SQL editor's
-- `postgres`, or `supabase db` connection) — creating a realtime.messages
-- partition + switching into the `authenticated`/`anon` roles both require
-- it. The whole script runs in ONE transaction and ROLLS BACK, so it leaves
-- no fixtures, no partition, and no test rows behind.
--
--   create extension if not exists pgtap;   -- if not already present
--   \i backend/supabase/tests/migrate_v0.56_realtime_terminal_authz.test.sql
--
-- WHAT THIS PROVES (the SQL layer):
--   * remote_helper_authorize_broadcast is the gate-done-right: rejects bad
--     secret / wrong device / non-owned session / NON-PRIVATE session, and
--     returns the owner for a valid owned PRIVATE session.
--   * read RLS on realtime.messages: an owner sees its own `pterm:` topic;
--     a non-owner and `anon` see nothing; a PUBLIC (non-private) session's
--     topic is invisible; a MALFORMED topic NEVER errors (the 22P02 no-cast
--     guard).
--   * write RLS on realtime.messages: an owner CAN insert a broadcast to its
--     own private topic; a non-owner CANNOT; a public session's topic CANNOT
--     (proves the insert policy actually evaluates — Gemini MEDIUM, SQL half).
--
-- WHAT THIS DOES NOT PROVE (the HTTP half — owner runbook integration step):
--   that the live `POST /realtime/v1/api/broadcast` endpoint runs this insert
--   policy end-to-end with a minted ES256 token. That needs the issuer
--   registered + the edge fn deployed → it is the runbook's integration
--   verify (a non-owner token must get ZERO delivery; an owner token must
--   deliver). pgTAP proves the policy; the integration step proves the path.
-- ============================================================

begin;
select plan(14);

-- ---- fixtures (fixed uuids; rolled back) --------------------
-- owner + attacker users. NOTE: inserting auth.users fires the
-- on_auth_user_created → handle_new_user → profiles → handle_new_profile
-- cascade, which AUTO-CREATES a public.user_settings row (user_id PK) AND the
-- public.profiles row that devices/remote_sessions FK to. So we must NOT
-- insert user_settings (PK collision = 23505 aborts the whole tx); we UPDATE
-- the auto-created rows instead.
insert into auth.users (id) values
  ('11111111-1111-4111-8111-111111111111'),  -- owner
  ('22222222-2222-4222-8222-222222222222');  -- attacker

-- Remote Control must be ON for the owner (the helper-gate checks it).
-- ON CONFLICT keeps the test robust whether or not the auto-create trigger ran.
insert into public.user_settings (user_id, remote_control_enabled, realtime_private_enabled) values
  ('11111111-1111-4111-8111-111111111111', true, true)
on conflict (user_id) do update
  set remote_control_enabled = excluded.remote_control_enabled,
      realtime_private_enabled = excluded.realtime_private_enabled;
insert into public.user_settings (user_id, remote_control_enabled) values
  ('22222222-2222-4222-8222-222222222222', true)
on conflict (user_id) do update
  set remote_control_enabled = excluded.remote_control_enabled;

-- devices: helper_secret stored as sha256 hex of the cleartext secret.
insert into public.devices (id, user_id, name, helper_secret) values
  ('33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111',
   'owner-dev', encode(extensions.digest('r0-test-helper-secret', 'sha256'), 'hex')),
  ('44444444-4444-4444-8444-444444444444', '22222222-2222-4222-8222-222222222222',
   'attacker-dev', encode(extensions.digest('attacker-secret', 'sha256'), 'hex'));

-- sessions: owner-private, owner-public, attacker-private.
insert into public.remote_sessions (id, user_id, device_id, provider, status, realtime_private) values
  ('55555555-5555-4555-8555-555555555555', '11111111-1111-4111-8111-111111111111',
   '33333333-3333-4333-8333-333333333333', 'claude', 'running', true),   -- owner private
  ('66666666-6666-4666-8666-666666666666', '11111111-1111-4111-8111-111111111111',
   '33333333-3333-4333-8333-333333333333', 'claude', 'running', false),  -- owner PUBLIC
  ('77777777-7777-4777-8777-777777777777', '22222222-2222-4222-8222-222222222222',
   '44444444-4444-4444-8444-444444444444', 'claude', 'running', true);   -- attacker private

-- A partition covering the test inserted_at (realtime.messages is RANGE
-- partitioned on inserted_at with no default partition). Dropped on rollback.
create table realtime.messages_r0test
  partition of realtime.messages
  for values from ('2099-01-01') to ('2099-01-02');

-- Seed ONE broadcast row on the owner's private topic (as the current
-- privileged role → RLS bypassed) so the read tests have something to see.
insert into realtime.messages (topic, extension, payload, event, private, inserted_at)
values ('pterm:55555555-5555-4555-8555-555555555555', 'broadcast',
        '{"session_id":"55555555-5555-4555-8555-555555555555","data_b64":""}'::jsonb,
        'stdout', true, timestamp '2099-01-01 00:00:00');

-- ---- helpers: run a query under a given role + realtime context ----
-- Kept in pg_temp so the pgTAP harness itself stays as the privileged role
-- (switching the session role around pgTAP's temp plan table breaks it).
create function pg_temp.r0_read_count(p_role text, p_sub text, p_topic text)
returns int language plpgsql as $$
declare n int;
begin
  if p_sub is null then
    perform set_config('request.jwt.claims', '', true);
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', p_sub, 'role', p_role)::text, true);
  end if;
  perform set_config('realtime.topic', p_topic, true);
  execute format('set local role %I', p_role);
  select count(*) into n from realtime.messages where extension = 'broadcast';
  reset role;
  return n;
end $$;

create function pg_temp.r0_try_insert(p_sub text, p_topic text)
returns boolean language plpgsql as $$
declare ok boolean := true;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('realtime.topic', p_topic, true);
  begin
    set local role authenticated;
    insert into realtime.messages (topic, extension, payload, event, private, inserted_at)
    values (p_topic, 'broadcast',
            '{"session_id":"x","data_b64":""}'::jsonb, 'stdout', true,
            timestamp '2099-01-01 12:00:00');
  exception when others then
    ok := false;   -- RLS denial (42501) or any error → "denied"
  end;
  reset role;
  return ok;
end $$;

-- ============================================================
-- (A) remote_helper_authorize_broadcast — the gate-done-right
-- ============================================================
select is(
  public.remote_helper_authorize_broadcast(
    '33333333-3333-4333-8333-333333333333', 'r0-test-helper-secret',
    '55555555-5555-4555-8555-555555555555'),
  '11111111-1111-4111-8111-111111111111'::uuid,
  'authorize: valid owner+device+private session → returns owner');

select throws_ok(
  $$ select public.remote_helper_authorize_broadcast(
       '33333333-3333-4333-8333-333333333333', 'WRONG-secret',
       '55555555-5555-4555-8555-555555555555') $$,
  '42501', 'unauthorized',
  'authorize: bad helper_secret → 42501');

select throws_ok(
  $$ select public.remote_helper_authorize_broadcast(
       '44444444-4444-4444-8444-444444444444', 'r0-test-helper-secret',
       '55555555-5555-4555-8555-555555555555') $$,
  '42501',
  'authorize: wrong device for the secret → 42501');

select throws_ok(
  $$ select public.remote_helper_authorize_broadcast(
       '33333333-3333-4333-8333-333333333333', 'r0-test-helper-secret',
       '77777777-7777-4777-8777-777777777777') $$,
  '42501', 'session not authorized for private broadcast',
  'authorize: session not owned by the device''s user → 42501');

select throws_ok(
  $$ select public.remote_helper_authorize_broadcast(
       '33333333-3333-4333-8333-333333333333', 'r0-test-helper-secret',
       '66666666-6666-4666-8666-666666666666') $$,
  '42501', 'session not authorized for private broadcast',
  'authorize: NON-private (public) session → 42501');

-- ============================================================
-- (B) read RLS on realtime.messages (pterm: prefix, owner-only, no-cast)
-- ============================================================
select is(
  pg_temp.r0_read_count('authenticated', '11111111-1111-4111-8111-111111111111',
    'pterm:55555555-5555-4555-8555-555555555555'),
  1, 'read: owner sees its own private pterm: topic');

select is(
  pg_temp.r0_read_count('authenticated', '22222222-2222-4222-8222-222222222222',
    'pterm:55555555-5555-4555-8555-555555555555'),
  0, 'read: NON-owner sees nothing on the owner''s topic');

select is(
  pg_temp.r0_read_count('authenticated', '11111111-1111-4111-8111-111111111111',
    'pterm:66666666-6666-4666-8666-666666666666'),
  0, 'read: owner''s PUBLIC (non-private) session topic is invisible');

select is(
  pg_temp.r0_read_count('anon', null,
    'pterm:55555555-5555-4555-8555-555555555555'),
  0, 'read: anon sees nothing');

select lives_ok(
  $$ select pg_temp.r0_read_count('authenticated',
       '11111111-1111-4111-8111-111111111111', 'pterm:not-a-valid-uuid-garbage') $$,
  'read: MALFORMED topic never errors (22P02 no-cast guard)');

select is(
  pg_temp.r0_read_count('authenticated', '11111111-1111-4111-8111-111111111111',
    'pterm:not-a-valid-uuid-garbage'),
  0, 'read: malformed topic yields 0 rows (no match, no error)');

-- ============================================================
-- (C) write RLS on realtime.messages (proves the INSERT policy evaluates)
-- ============================================================
select ok(
  pg_temp.r0_try_insert('11111111-1111-4111-8111-111111111111',
    'pterm:55555555-5555-4555-8555-555555555555'),
  'write: owner CAN broadcast to its own private topic');

select ok(
  not pg_temp.r0_try_insert('22222222-2222-4222-8222-222222222222',
    'pterm:55555555-5555-4555-8555-555555555555'),
  'write: NON-owner CANNOT broadcast to the owner''s topic (injection closed)');

select ok(
  not pg_temp.r0_try_insert('11111111-1111-4111-8111-111111111111',
    'pterm:66666666-6666-4666-8666-666666666666'),
  'write: owner CANNOT broadcast to a PUBLIC (non-private) session topic');

select * from finish();
rollback;
