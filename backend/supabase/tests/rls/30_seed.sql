-- ============================================================================
-- 30_seed.sql — deterministic fixtures (runs as the bootstrap superuser, which
-- bypasses RLS, exactly like the service_role key would server-side).
--
-- Users (inserting into auth.users fires on_auth_user_created → profiles →
-- user_settings + subscriptions, mirroring real signup):
--   userA  = aaaaaaaa…  — owns one row in every in-scope table
--   userB  = bbbbbbbb…  — the attacker; owns nothing of userA's
--   owner  = 11111111…  — team owner
--   admin  = 22222222…  — team ADMIN (the team_members self-promotion attacker)
--   member = 33333333…  — plain team member
-- ============================================================================

insert into auth.users (id, email) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'usera@test.local'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'userb@test.local'),
  ('11111111-1111-1111-1111-111111111111', 'owner@test.local'),
  ('22222222-2222-2222-2222-222222222222', 'admin@test.local'),
  ('33333333-3333-3333-3333-333333333333', 'member@test.local');

-- ── userA-owned rows in each in-scope table ─────────────────────────────────
insert into public.remote_sessions (id, user_id, device_id, provider)
  values ('a0000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', gen_random_uuid(), 'claude');

insert into public.remote_session_commands (id, user_id, device_id, kind, payload)
  values ('a0000000-0000-0000-0000-0000000000a2', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', gen_random_uuid(), 'input_raw', 'secret-keystrokes');

insert into public.remote_session_events (session_id, user_id, device_id, seq, kind, payload)
  values ('a0000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', gen_random_uuid(), 1, 'stdout', 'private terminal output');

insert into public.remote_permission_requests (id, user_id, device_id, provider, summary)
  values ('a0000000-0000-0000-0000-0000000000a3', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', gen_random_uuid(), 'claude', 'rm -rf approval');

insert into public.remote_permission_decisions (id, request_id, user_id, decision)
  values ('a0000000-0000-0000-0000-0000000000a4', 'a0000000-0000-0000-0000-0000000000a3', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'approve');

insert into public.daily_usage_metrics (user_id, metric_date, provider, model, cost)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', current_date, 'claude', 'opus', 12.34);

-- subscriptions for userA already exists (auto-created on profile). Make it
-- non-default so a leaked read would be obviously wrong.
update public.subscriptions set tier = 'team', apple_transaction_id = 'A-PRIVATE-TXN'
  where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

-- ── Team with an owner, an admin, and a member ──────────────────────────────
insert into public.teams (id, name, owner_id)
  values ('7ea11111-0000-0000-0000-000000000001', 'Acme', '11111111-1111-1111-1111-111111111111');

insert into public.team_members (team_id, user_id, role) values
  ('7ea11111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'owner'),
  ('7ea11111-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'admin'),
  ('7ea11111-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'member');
