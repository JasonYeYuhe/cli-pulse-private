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
--   * payload REQUIRES boolean "on" — including the MISSING-key case (the
--     coalesce'd typeof guard; jsonb_typeof of an absent key is NULL, which
--     the pre-v0.67 guards silently let through).
--   * enable normalizes to {on,ttl_seconds?} with ttl clamped to [60,86400];
--     absent ttl on enable = {on:true} only (indefinite); disable DROPS ttl.
--   * pre-existing kinds still work (whitelist extension, not replacement).
--   * rate limit unchanged (6/min; the 7th attempt throws).
--   * the heartbeat's machine_controls fold carries keep_awake +
--     keep_awake_active booleans (capability + state ride the jsonb).
--
-- NOTE all payload assertions look rows up BY the command_id the RPC returns
-- (created_at is transaction_timestamp() — CONSTANT inside this txn, so
-- "order by created_at desc limit 1" would be non-deterministic here).
-- ============================================================

begin;
select plan(10);

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

-- 1. missing "on" key raises (the coalesce'd guard — a plain
--    jsonb_typeof(...)<>'boolean' is NULL for an absent key and never fires)
select throws_ok(
  $$ select public.remote_app_send_machine_command('d6700000-6700-4670-8670-670000000001','set_keep_awake','{}'::jsonb) $$,
  'P0001', 'set_keep_awake requires boolean on', 'keep_awake: rejects a payload without boolean on');

-- 2. enable, no ttl → {on:true} only (indefinite)                [insert #1]
select is(
  (select payload from public.machine_commands where id =
    ((public.remote_app_send_machine_command(
      'd6700000-6700-4670-8670-670000000001','set_keep_awake','{"on":true}'::jsonb))->>'command_id')::uuid),
  '{"on": true}'::jsonb, 'keep_awake: enable without ttl normalizes to {on:true} (indefinite)');

-- 3. enable, low ttl → clamped up to 60                          [insert #2]
select is(
  (select payload->>'ttl_seconds' from public.machine_commands where id =
    ((public.remote_app_send_machine_command(
      'd6700000-6700-4670-8670-670000000001','set_keep_awake','{"on":true,"ttl_seconds":5}'::jsonb))->>'command_id')::uuid),
  '60', 'keep_awake: ttl below floor clamps to 60');

-- 4. enable, huge ttl → clamped down to 86400 (numeric-range BEFORE ::int —
--    9e12 would overflow int4 if cast first)                     [insert #3]
select is(
  (select payload->>'ttl_seconds' from public.machine_commands where id =
    ((public.remote_app_send_machine_command(
      'd6700000-6700-4670-8670-670000000001','set_keep_awake','{"on":true,"ttl_seconds":9000000000000}'::jsonb))->>'command_id')::uuid),
  '86400', 'keep_awake: ttl above cap clamps to 86400');

-- 5. disable drops a supplied ttl                                 [insert #4]
select is(
  (select payload from public.machine_commands where id =
    ((public.remote_app_send_machine_command(
      'd6700000-6700-4670-8670-670000000001','set_keep_awake','{"on":false,"ttl_seconds":600}'::jsonb))->>'command_id')::uuid),
  '{"on": false}'::jsonb, 'keep_awake: disable drops ttl (normalizes to {on:false})');

-- 6. unknown kinds still rejected end-to-end (whitelist extended, not opened)
select throws_ok(
  $$ select public.remote_app_send_machine_command('d6700000-6700-4670-8670-670000000001','stay_awake','{}'::jsonb) $$,
  'P0001', 'Invalid command kind: stay_awake', 'keep_awake: unknown kinds still rejected');

-- 7. pre-existing kind still works                                [insert #5]
select lives_ok(
  $$ select public.remote_app_send_machine_command('d6700000-6700-4670-8670-670000000001','set_low_power_mode','{"on":true}'::jsonb) $$,
  'keep_awake: pre-existing set_low_power_mode still accepted');

-- 8. 6th accepted command is still under the limit                [insert #6]
select lives_ok(
  $$ select public.remote_app_send_machine_command('d6700000-6700-4670-8670-670000000001','set_keep_awake','{"on":true}'::jsonb) $$,
  'keep_awake: 6th command in the window still accepted');

-- 9. …and the 7th trips the (unchanged) rate limit.
select throws_ok(
  $$ select public.remote_app_send_machine_command('d6700000-6700-4670-8670-670000000001','set_keep_awake','{"on":true}'::jsonb) $$,
  'P0001', 'Rate limit exceeded (max 6 machine commands per minute)',
  'keep_awake: rate limit unchanged (6/min)');

-- 10. heartbeat folds keep_awake + keep_awake_active into machine_controls
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
