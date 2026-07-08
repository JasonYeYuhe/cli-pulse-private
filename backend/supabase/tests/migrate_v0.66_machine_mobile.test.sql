-- ============================================================
-- pgTAP — migrate_v0.66 mobile-machine snapshot uplink + remote command queue
-- ============================================================
-- OWNER-RUN (not CI): pgTAP is NOT installed in prod and there is no SQL test
-- runner in CI. Run this AFTER applying migrate_v0.66 against a BRANCH database
-- as a privileged role. The whole script runs in ONE transaction and ROLLS BACK,
-- so it leaves no fixtures behind.
--
--   create extension if not exists pgtap;   -- if not already present
--   \i backend/supabase/tests/migrate_v0.66_machine_mobile.test.sql
--
-- WHAT THIS PROVES (mirrors the live self-rolling-back smoke run at ship time):
--   TRACK A (heartbeat uplink):
--     * the v0.66 system block (uptime/load/pressure/swap/disk) + lpm_on +
--       fan_boost_active/target + machine_controls write to the new columns.
--     * out-of-range / wrong-type readings are DROPPED (preserve last-known),
--       never clamped and never allowed to break the heartbeat.
--     * machine_controls keeps only booleans; memory_pressure honors its enum.
--     * grant hygiene: anon + authenticated can SELECT the new columns.
--   TRACK B (machine_commands queue + RPC trio):
--     * remote_app_send_machine_command allowlists kind, validates rpm range,
--       clamps ttl_seconds to [60,3600], rate-limits to 6/min, device-owner-scoped.
--     * remote_helper_pull_machine_commands delivers pending & EXPIRES stale.
--     * remote_helper_complete_machine_command is one-way (delivered→done/failed
--       only) — a replay does not overwrite a terminal row.
--     * grant hygiene: send is authenticated-only (anon REVOKED); pull/complete
--       are anon+authenticated (helper contract).
--     * RLS: a cross-user cannot SELECT another user's machine_commands rows.
-- ============================================================

begin;
select plan(30);

-- ---- fixtures (fixed uuids; rolled back) --------------------
-- Inserting auth.users fires handle_new_user → profiles + user_settings.
insert into auth.users (id) values
  ('a6600000-6600-4660-8660-660000000001'),   -- owner of the device
  ('b6600000-6600-4660-8660-660000000002');   -- attacker (owns nothing)

insert into public.devices (id, user_id, name, helper_secret) values
  ('d6600000-6600-4660-8660-660000000001', 'a6600000-6600-4660-8660-660000000001',
   'v066-dev', encode(extensions.digest('v066-secret', 'sha256'), 'hex'));

update public.user_settings set remote_control_enabled = true
  where user_id = 'a6600000-6600-4660-8660-660000000001';

-- ============================================================
-- TRACK A — heartbeat writes the new snapshot columns
-- ============================================================
select public.helper_heartbeat(
  'd6600000-6600-4660-8660-660000000001', 'v066-secret', 21, 34, 1, null,
  jsonb_build_object(
    'uptime_seconds', 123456, 'load_avg_1m', 2.5, 'load_avg_5m', 1.8, 'load_avg_15m', 1.2,
    'memory_pressure', 'warn',
    'swap_used_bytes', 1073741824, 'swap_total_bytes', 4294967296,
    'disk_free_bytes', 250000000000, 'disk_total_bytes', 500000000000,
    'lpm_on', true, 'fan_boost_active', true, 'fan_boost_target_rpm', 4200,
    'machine_controls', jsonb_build_object('remote_fan', true, 'remote_lpm', true, 'bogus', 'x')
  )
);

select is(uptime_seconds, 123456::bigint, 'uptime_seconds written')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(load_avg_5m::text, '1.8', 'load_avg_5m written')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(memory_pressure, 'warn', 'memory_pressure enum accepted')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(swap_total_bytes, 4294967296::bigint, 'swap_total_bytes written')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(disk_total_bytes, 500000000000::bigint, 'disk_total_bytes written')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(lpm_on, true, 'lpm_on written')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(fan_boost_active, true, 'fan_boost_active written')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(fan_boost_target_rpm, 4200, 'fan_boost_target_rpm written')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(machine_controls, '{"remote_fan": true, "remote_lpm": true}'::jsonb,
  'machine_controls keeps only booleans (bogus:"x" stripped)')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';

-- ---- out-of-range / wrong-type => DROP (preserve last-known) ----
select public.helper_heartbeat(
  'd6600000-6600-4660-8660-660000000001', 'v066-secret', 21, 34, 1, null,
  jsonb_build_object(
    'uptime_seconds', -5,               -- out of range
    'memory_pressure', 'meltdown',      -- not in enum
    'lpm_on', 'yes',                    -- not a JSON boolean
    'fan_boost_target_rpm', 999999      -- out of range
  )
);
select is(uptime_seconds, 123456::bigint, 'out-of-range uptime DROPPED (preserved)')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(memory_pressure, 'warn', 'invalid memory_pressure DROPPED (preserved)')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(lpm_on, true, 'non-boolean lpm_on DROPPED (preserved)')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';
select is(fan_boost_target_rpm, 4200, 'out-of-range fan_boost_target_rpm DROPPED (preserved)')
  from public.devices where id = 'd6600000-6600-4660-8660-660000000001';

-- ---- grant hygiene: new columns SELECTable by mobile roles ----
select is(has_column_privilege('authenticated', 'public.devices', 'machine_controls', 'select'),
  true, 'grant: authenticated can SELECT machine_controls');
select is(has_column_privilege('anon', 'public.devices', 'lpm_on', 'select'),
  true, 'grant: anon can SELECT lpm_on');

-- ============================================================
-- TRACK B — machine_commands + RPC trio
-- ============================================================
-- Impersonate the device owner (auth.uid()) for the app-facing RPC.
select set_config('request.jwt.claims',
  '{"sub":"a6600000-6600-4660-8660-660000000001","role":"authenticated"}', true);

-- kind allowlist
select throws_ok(
  $$ select public.remote_app_send_machine_command('d6600000-6600-4660-8660-660000000001','frobnicate','{}'::jsonb) $$,
  'P0001', 'Invalid command kind: frobnicate', 'send: rejects a non-allowlisted kind');

-- rpm range
select throws_ok(
  $$ select public.remote_app_send_machine_command('d6600000-6600-4660-8660-660000000001','set_fan_target','{"rpm":99999}'::jsonb) $$,
  'P0001', 'rpm out of range (0..30000)', 'send: rejects rpm > 30000');

-- ttl clamp + rpm accepted
select public.remote_app_send_machine_command(
  'd6600000-6600-4660-8660-660000000001', 'set_fan_target',
  jsonb_build_object('rpm', 4200, 'ttl_seconds', 5));
select is((payload->>'ttl_seconds')::int, 60, 'send: ttl_seconds clamped up to 60')
  from public.machine_commands
  where device_id = 'd6600000-6600-4660-8660-660000000001' and kind = 'set_fan_target';
select is((payload->>'rpm')::int, 4200, 'send: rpm preserved in payload')
  from public.machine_commands
  where device_id = 'd6600000-6600-4660-8660-660000000001' and kind = 'set_fan_target';

-- pull as helper delivers the pending command
select is(
  jsonb_array_length(
    public.remote_helper_pull_machine_commands('d6600000-6600-4660-8660-660000000001','v066-secret',10)),
  1, 'pull: returns the one pending command');
select is(status, 'delivered', 'pull: pending → delivered')
  from public.machine_commands
  where device_id = 'd6600000-6600-4660-8660-660000000001' and kind = 'set_fan_target';

-- complete → done
select public.remote_helper_complete_machine_command(
  'd6600000-6600-4660-8660-660000000001','v066-secret',
  (select id from public.machine_commands where device_id='d6600000-6600-4660-8660-660000000001' and kind='set_fan_target'),
  'done', '{"applied":true}'::jsonb);
select is(status, 'done', 'complete: delivered → done')
  from public.machine_commands
  where device_id = 'd6600000-6600-4660-8660-660000000001' and kind = 'set_fan_target';

-- replay: completing a terminal row is a no-op (one-way)
select public.remote_helper_complete_machine_command(
  'd6600000-6600-4660-8660-660000000001','v066-secret',
  (select id from public.machine_commands where device_id='d6600000-6600-4660-8660-660000000001' and kind='set_fan_target'),
  'failed', '{"x":1}'::jsonb);
select is(status, 'done', 'complete: replay does NOT overwrite a terminal row')
  from public.machine_commands
  where device_id = 'd6600000-6600-4660-8660-660000000001' and kind = 'set_fan_target';

-- expiry: a stale pending command is expired at pull time, never delivered
insert into public.machine_commands (user_id, device_id, kind, payload, status, created_at, expires_at)
  values ('a6600000-6600-4660-8660-660000000001','d6600000-6600-4660-8660-660000000001',
          'revert_fan_auto','{}'::jsonb,'pending', now()-interval '5 min', now()-interval '4 min');
select is(
  jsonb_array_length(
    public.remote_helper_pull_machine_commands('d6600000-6600-4660-8660-660000000001','v066-secret',10)),
  0, 'pull: does NOT deliver a stale (expired-deadline) command');
select is(status, 'expired', 'pull: stale pending → expired')
  from public.machine_commands
  where device_id = 'd6600000-6600-4660-8660-660000000001' and kind = 'revert_fan_auto';

-- grant hygiene on the RPC trio
select is(has_function_privilege('authenticated',
  'public.remote_app_send_machine_command(uuid,text,jsonb)', 'execute'),
  true, 'grant: authenticated can EXECUTE send');
select is(has_function_privilege('anon',
  'public.remote_app_send_machine_command(uuid,text,jsonb)', 'execute'),
  false, 'grant: anon CANNOT EXECUTE send (app-only)');
select is(has_function_privilege('anon',
  'public.remote_helper_pull_machine_commands(uuid,text,integer)', 'execute'),
  true, 'grant: anon can EXECUTE pull (helper contract)');
select is(has_function_privilege('anon',
  'public.remote_helper_complete_machine_command(uuid,text,uuid,text,jsonb)', 'execute'),
  true, 'grant: anon can EXECUTE complete (helper contract)');

-- RLS: a cross-user cannot read the owner's machine_commands rows
select set_config('request.jwt.claims',
  '{"sub":"b6600000-6600-4660-8660-660000000002","role":"authenticated"}', true);
set local role authenticated;
select is(
  (select count(*)::int from public.machine_commands
     where device_id = 'd6600000-6600-4660-8660-660000000001'),
  0, 'RLS: attacker sees 0 of the owner''s machine_commands rows');
reset role;

select * from finish();
rollback;
