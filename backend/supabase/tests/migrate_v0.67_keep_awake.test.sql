-- ============================================================
-- pgTAP — migrate_v0.67 Keep Awake (set_keep_awake machine command)
-- ============================================================
-- OWNER-RUN (not CI): pgTAP is NOT installed in prod. Run AFTER applying
-- migrate_v0.67 against a BRANCH database as a privileged role. One
-- transaction, rolls back — no fixtures left behind.
--
--   create extension if not exists pgtap;
--   \i backend/supabase/tests/migrate_v0.67_keep_awake.test.sql
--
-- WHAT THIS PROVES:
--   * 'set_keep_awake' passes the kind allowlist (RPC) + table CHECK.
--   * payload requires boolean "on"; enable normalizes to {on,ttl_seconds?}
--     with ttl clamped to [60,86400]; absent ttl on enable = {on:true} only
--     (indefinite); disable DROPS a supplied ttl.
--   * pre-existing kinds still work (whitelist extension, not replacement).
--   * the heartbeat's machine_controls fold carries keep_awake +
--     keep_awake_active booleans (capability + live state ride the jsonb —
--     no devices-schema change in this migration).
-- ============================================================

begin;
select plan(9);

-- ---- fixtures (fixed uuids; rolled back) --------------------
insert into auth.users (id) values
  ('a6700000-6700-4670-8670-670000000001');

insert into public.devices (id, user_id, name, helper_secret) values
  ('d6700000-6700-4670-8670-670000000001', 'a6700000-6700-4670-8670-670000000001',
   'v067-dev', encode(extensions.digest('v067-secret', 'sha256'), 'hex'));

update public.user_settings set remote_control_enabled = true
  where user_id = 'a6700000-6700-4670-8670-670000000001';

-- Impersonate the device owner (auth.uid()) for the app-facing RPC.
select set_config('request.jwt.claims',
  '{"sub":"a6700000-6700-4670-8670-670000000001","role":"authenticated"}', true);

-- 1. requires boolean "on"
select throws_ok(
  $$ select public.remote_app_send_machine_command('d6700000-6700-4670-8670-670000000001','set_keep_awake','{}'::jsonb) $$,
  'P0001', 'set_keep_awake requires boolean on', 'keep_awake: rejects a payload without boolean on');

-- 2. enable, no ttl → {on:true} only (indefinite)
select public.remote_app_send_machine_command(
  'd6700000-6700-4670-8670-670000000001', 'set_keep_awake', '{"on":true}'::jsonb);
select is(
  (select payload from public.machine_commands
    where kind = 'set_keep_awake' order by created_at desc limit 1),
  '{"on": true}'::jsonb, 'keep_awake: enable without ttl normalizes to {on:true} (indefinite)');

-- 3. enable, low ttl → clamped up to 60
select public.remote_app_send_machine_command(
  'd6700000-6700-4670-8670-670000000001', 'set_keep_awake', '{"on":true,"ttl_seconds":5}'::jsonb);
select is(
  (select payload->>'ttl_seconds' from public.machine_commands
    where kind = 'set_keep_awake' order by created_at desc limit 1),
  '60', 'keep_awake: ttl below floor clamps to 60');

-- 4. enable, huge ttl → clamped down to 86400 (also proves numeric-before-int:
--    9e12 would overflow ::int if cast before the range check)
select public.remote_app_send_machine_command(
  'd6700000-6700-4670-8670-670000000001', 'set_keep_awake', '{"on":true,"ttl_seconds":9000000000000}'::jsonb);
select is(
  (select payload->>'ttl_seconds' from public.machine_commands
    where kind = 'set_keep_awake' order by created_at desc limit 1),
  '86400', 'keep_awake: ttl above cap clamps to 86400 (numeric-range before ::int)');

-- 5. disable drops a supplied ttl
select public.remote_app_send_machine_command(
  'd6700000-6700-4670-8670-670000000001', 'set_keep_awake', '{"on":false,"ttl_seconds":600}'::jsonb);
select is(
  (select payload from public.machine_commands
    where kind = 'set_keep_awake' order by created_at desc limit 1),
  '{"on": false}'::jsonb, 'keep_awake: disable drops ttl (normalizes to {on:false})');

-- 6. table CHECK admits the new kind (5 rows inserted above would have thrown otherwise);
--    prove an unknown kind is still rejected end-to-end.
select throws_ok(
  $$ select public.remote_app_send_machine_command('d6700000-6700-4670-8670-670000000001','stay_awake','{}'::jsonb) $$,
  'P0001', 'Invalid command kind: stay_awake', 'keep_awake: unknown kinds still rejected');

-- 7. pre-existing kind still works (whitelist extended, not replaced) —
--    NOTE this is the 6th accepted command in the 60s window; the rate limit
--    allows exactly 6, so it must succeed…
select lives_ok(
  $$ select public.remote_app_send_machine_command('d6700000-6700-4670-8670-670000000001','set_low_power_mode','{"on":true}'::jsonb) $$,
  'keep_awake: pre-existing set_low_power_mode still accepted');

-- 8. …and the 7th trips the (unchanged) rate limit.
select throws_ok(
  $$ select public.remote_app_send_machine_command('d6700000-6700-4670-8670-670000000001','set_keep_awake','{"on":true}'::jsonb) $$,
  'P0001', 'Rate limit exceeded (max 6 machine commands per minute)',
  'keep_awake: rate limit unchanged (6/min)');

-- 9. heartbeat folds keep_awake + keep_awake_active into machine_controls
select public.helper_heartbeat(
  'd6700000-6700-4670-8670-670000000001', 'v067-secret', 5, 10, 0, null,
  jsonb_build_object(
    'machine_controls', jsonb_build_object(
      'remote_fan', true, 'remote_lpm', true,
      'keep_awake', true, 'keep_awake_active', true)));
select is(
  (select machine_controls from public.devices
    where id = 'd6700000-6700-4670-8670-670000000001'),
  '{"remote_fan": true, "remote_lpm": true, "keep_awake": true, "keep_awake_active": true}'::jsonb,
  'keep_awake: heartbeat machine_controls fold carries capability + live state');

select * from finish();
rollback;
