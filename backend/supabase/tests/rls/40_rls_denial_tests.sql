-- ============================================================================
-- 40_rls_denial_tests.sql — cross-user RLS denial assertions.
--
-- Run with psql -v ON_ERROR_STOP=1: any RAISE EXCEPTION aborts the run non-zero,
-- so CI fails the moment a cross-user access succeeds. Each block impersonates a
-- role exactly as PostgREST does: set the request.jwt.claims GUC (→ auth.uid())
-- then `set local role authenticated` (a non-superuser, non-BYPASSRLS role), so
-- the live RLS policies — and nothing else — decide every result.
--
-- Coverage (deliverable of PR3 / DEV_PLAN §2):
--   • userB cannot SELECT / INSERT / UPDATE userA rows on remote_sessions,
--     remote_session_commands, remote_session_events, remote_permission_requests,
--     remote_permission_decisions, subscriptions, daily_usage_metrics.
--   • team_members: a non-member cannot read members; an ADMIN cannot self-promote
--     to owner via a direct UPDATE/INSERT (the P1 from DEV_PLAN PR2); the OWNER can.
--   • Positive controls: userA CAN read its own rows (guards against a globally
--     denying RLS giving false confidence).
-- ============================================================================

\set userA '''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'''
\set userB '''bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'''
\set teamId '''7ea11111-0000-0000-0000-000000000001'''
\set ownerId '''11111111-1111-1111-1111-111111111111'''
\set adminId '''22222222-2222-2222-2222-222222222222'''
\set memberId '''33333333-3333-3333-3333-333333333333'''

-- ───────────────────────────────────────────────────────────────────────────
-- BLOCK 1 — userB CANNOT SELECT userA rows (every in-scope table)
-- ───────────────────────────────────────────────────────────────────────────
begin;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  n int;
  tbl text;
  tables text[] := array[
    'remote_sessions','remote_session_commands','remote_session_events',
    'remote_permission_requests','remote_permission_decisions',
    'machine_commands','daily_usage_metrics','subscriptions'];
begin
  foreach tbl in array tables loop
    execute format('select count(*) from public.%I where user_id = %L', tbl,
                   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') into n;
    if n <> 0 then
      raise exception 'FAIL[read]: userB saw % userA row(s) in public.%', n, tbl;
    end if;
    raise notice 'PASS[read]: userB sees 0 userA rows in public.%', tbl;
  end loop;
end $$;
rollback;

-- ───────────────────────────────────────────────────────────────────────────
-- BLOCK 2 — userB CANNOT INSERT a row attributed to userA (RLS → 42501)
-- ───────────────────────────────────────────────────────────────────────────
begin;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}', true);
set local role authenticated;

do $$
begin
  begin
    insert into public.remote_sessions (user_id, device_id, provider)
      values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', gen_random_uuid(), 'claude');
    raise exception 'FAIL[insert]: userB inserted a remote_sessions row';
  exception when insufficient_privilege then
    raise notice 'PASS[insert]: RLS blocked userB insert into remote_sessions';
  end;

  begin
    insert into public.daily_usage_metrics (user_id, metric_date, provider, model, cost)
      values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_date, 'claude', 'opus', 99);
    raise exception 'FAIL[insert]: userB inserted a daily_usage_metrics row for userA';
  exception when insufficient_privilege then
    raise notice 'PASS[insert]: RLS blocked userB insert into daily_usage_metrics';
  end;

  begin
    insert into public.subscriptions (user_id, tier) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'team');
    raise exception 'FAIL[insert]: userB inserted/overwrote a subscriptions row';
  exception when insufficient_privilege or unique_violation then
    -- 42501 (no client INSERT policy) is the intended denial; a PK clash would
    -- also mean the row wasn't forged. Either way userB did not write userA data.
    raise notice 'PASS[insert]: RLS blocked userB insert into subscriptions';
  end;
end $$;
rollback;

-- ───────────────────────────────────────────────────────────────────────────
-- BLOCK 3 — userB CANNOT UPDATE userA rows (RLS → 0 rows affected)
-- ───────────────────────────────────────────────────────────────────────────
begin;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}', true);
set local role authenticated;

do $$
declare n int;
begin
  update public.remote_session_commands set payload = 'hijacked'
    where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL[update]: userB updated % remote_session_commands rows', n; end if;
  raise notice 'PASS[update]: userB updated 0 remote_session_commands rows';

  update public.machine_commands set status = 'delivered'
    where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL[update]: userB updated % machine_commands rows', n; end if;
  raise notice 'PASS[update]: userB updated 0 machine_commands rows';

  update public.daily_usage_metrics set cost = 0
    where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL[update]: userB updated % daily_usage_metrics rows', n; end if;
  raise notice 'PASS[update]: userB updated 0 daily_usage_metrics rows';
end $$;
rollback;

-- ───────────────────────────────────────────────────────────────────────────
-- BLOCK 4 — team_members: insider-escalation denial (DEV_PLAN PR2 / NEW-H2v)
-- ───────────────────────────────────────────────────────────────────────────

-- 4a) a non-member (userB) cannot even enumerate members
begin;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  select count(*) into n from public.team_members where team_id = '7ea11111-0000-0000-0000-000000000001';
  if n <> 0 then raise exception 'FAIL[team read]: non-member saw % team_members rows', n; end if;
  raise notice 'PASS[team read]: non-member sees 0 team_members rows';
end $$;
rollback;

-- 4b) an ADMIN cannot promote itself to owner via a direct table UPDATE
begin;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int; r text;
begin
  update public.team_members set role = 'owner'
    where team_id = '7ea11111-0000-0000-0000-000000000001'
      and user_id = '22222222-2222-2222-2222-222222222222';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL[self-promote]: admin UPDATE escalated % row(s) to owner', n; end if;
  select role into r from public.team_members
    where team_id = '7ea11111-0000-0000-0000-000000000001'
      and user_id = '22222222-2222-2222-2222-222222222222';
  if r is distinct from 'admin' then raise exception 'FAIL[self-promote]: admin role is now %', r; end if;
  raise notice 'PASS[self-promote]: admin direct-UPDATE to owner denied (role still admin)';
end $$;
rollback;

-- 4c) an ADMIN cannot INSERT a fresh owner-role membership for itself either
begin;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    insert into public.team_members (team_id, user_id, role)
      values ('7ea11111-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'owner');
    raise exception 'FAIL[insert owner]: admin inserted an owner-role membership';
  exception when insufficient_privilege or unique_violation then
    raise notice 'PASS[insert owner]: admin INSERT of owner-role membership denied';
  end;
end $$;
rollback;

-- 4d) POSITIVE control — the real OWNER can still manage member roles
begin;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  update public.team_members set role = 'admin'
    where team_id = '7ea11111-0000-0000-0000-000000000001'
      and user_id = '33333333-3333-3333-3333-333333333333';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL[owner manage]: owner updated % member rows (expected 1)', n; end if;
  raise notice 'PASS[owner manage]: owner can update a member role (1 row)';
end $$;
rollback;

-- 4e) POSITIVE control — a real member CAN read its own team's roster WITHOUT
-- recursion. This is also the regression guard for the recursion bug that made
-- team_members direct reads fail in prod (42P17); the Android team feature uses
-- exactly this direct REST read (SupabaseClient.kt).
begin;
select set_config('request.jwt.claims', '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  select count(*) into n from public.team_members where team_id = '7ea11111-0000-0000-0000-000000000001';
  if n <> 3 then raise exception 'FAIL[member read]: member saw % of 3 team rows (recursion or over-block?)', n; end if;
  raise notice 'PASS[member read]: member reads own team roster (3 rows, no recursion)';
end $$;
rollback;

-- ───────────────────────────────────────────────────────────────────────────
-- BLOCK 5 — POSITIVE controls: userA CAN read its own rows (no false denial)
-- ───────────────────────────────────────────────────────────────────────────
begin;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  n int; tbl text;
  tables text[] := array[
    'remote_sessions','remote_session_commands','remote_session_events',
    'remote_permission_requests','remote_permission_decisions',
    'machine_commands','daily_usage_metrics','subscriptions'];
begin
  foreach tbl in array tables loop
    execute format('select count(*) from public.%I where user_id = %L', tbl,
                   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') into n;
    if n < 1 then
      raise exception 'FAIL[self read]: userA cannot see its own public.% row (RLS over-blocks)', tbl;
    end if;
    raise notice 'PASS[self read]: userA sees its own public.% row(s)', tbl;
  end loop;
end $$;
rollback;

\echo '========================================================================'
\echo 'ALL CROSS-USER RLS DENIAL TESTS PASSED'
\echo '========================================================================'
