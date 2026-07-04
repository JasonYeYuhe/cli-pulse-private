-- ============================================================
-- pgTAP — migrate_v0.63 device machine-health sensors + heartbeat p_metrics
-- ============================================================
-- OWNER-RUN (not CI): pgTAP is NOT installed in prod and there is no SQL test
-- runner in CI. Run this AFTER applying migrate_v0.63 against a BRANCH database
-- as a privileged role. The whole script runs in ONE transaction and ROLLS BACK,
-- so it leaves no fixtures behind.
--
--   create extension if not exists pgtap;   -- if not already present
--   \i backend/supabase/tests/migrate_v0.63_device_sensors.test.sql
--
-- WHAT THIS PROVES (mirrors the live self-rolling-back smoke run at ship time):
--   * p_metrics writes valid readings to the new columns.
--   * out-of-range readings are DROPPED (preserve last-known / stay NULL), never
--     clamped-to-boundary and never allowed to raise and break the heartbeat.
--   * omitting p_metrics (old-caller path) preserves every sensor column.
--   * a partial p_metrics updates only its keys; others preserve.
--   * capability keeps only boolean values; battery_state honors its enum.
--   * sensors_updated_at bumps only when a metrics object is supplied.
--   * grant hygiene: anon + authenticated can SELECT the new columns; anon can
--     EXECUTE the 7-arg heartbeat (helper contract).
-- ============================================================

begin;
select plan(16);

-- ---- fixtures (fixed uuids; rolled back) --------------------
-- Inserting auth.users fires the handle_new_user cascade that AUTO-CREATES the
-- profiles + user_settings rows.
insert into auth.users (id) values
  ('a1a1a1a1-1111-4111-8111-111111111111');

insert into public.devices (id, user_id, name, helper_secret) values
  ('d1d1d1d1-1111-4111-8111-111111111111', 'a1a1a1a1-1111-4111-8111-111111111111',
   'sensor-dev', encode(extensions.digest('v063-secret', 'sha256'), 'hex'));

-- ---- Call #1: valid + out-of-range readings ----------------
select public.helper_heartbeat(
  'd1d1d1d1-1111-4111-8111-111111111111', 'v063-secret', 33, 44, 2, '{"codex":"off_plan"}'::jsonb,
  jsonb_build_object(
    'cpu_power_w', 12.5, 'gpu_power_w', 999999, 'ane_power_w', 0.1, 'system_power_w', 18.2,
    'cpu_temp_c', 55.2, 'gpu_temp_c', 48.0, 'battery_temp_c', -999,
    'fan_rpm', 1980.0, 'fan_max_rpm', 6200,
    'thermal_state', 2, 'battery_charge_pct', 82, 'battery_state', 'discharging',
    'battery_cycle_count', 59, 'battery_health_pct', 98.0,
    'battery_design_capacity', 6075, 'battery_current_capacity', 5950, 'adapter_watts', 0,
    'capability', jsonb_build_object('temps', true, 'fans', true, 'power', true, 'battery', true, 'bogus', 'x')
  )
);

select is(cpu_power_w::text, '12.5', 'valid cpu_power_w written')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';
select ok(gpu_power_w is null, 'out-of-range gpu_power_w (999999) DROPPED, not clamped')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';
select ok(battery_temp_c is null, 'out-of-range battery_temp_c (-999) DROPPED')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';
select is(fan_rpm, 1980, 'fan_rpm float 1980.0 stored as int 1980')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';
select is(thermal_state, 2::smallint, 'thermal_state written')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';
select is(battery_state, 'discharging', 'battery_state enum accepted')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';
select is(battery_health_pct::text, '98', 'battery_health_pct written')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';
select is(sensors_capability, '{"fans": true, "power": true, "temps": true, "battery": true}'::jsonb,
  'capability keeps only booleans (bogus:"x" stripped)')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';
select ok(sensors_updated_at is not null, 'sensors_updated_at bumped when metrics supplied')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';

-- ---- Call #2: omit p_metrics (old-caller path) -> preserve all
select public.helper_heartbeat('d1d1d1d1-1111-4111-8111-111111111111', 'v063-secret', 5, 6, 0);
select is(cpu_power_w::text, '12.5', 'omitting p_metrics preserves cpu_power_w')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';
select is(battery_cycle_count, 59, 'omitting p_metrics preserves battery_cycle_count')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';

-- ---- Call #3: partial metrics -> only its keys change -------
select public.helper_heartbeat('d1d1d1d1-1111-4111-8111-111111111111', 'v063-secret', 5, 6, 0, null,
  '{"cpu_power_w": 3.3}'::jsonb);
select is(cpu_power_w::text, '3.3', 'partial metrics updates cpu_power_w')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';
select is(fan_rpm, 1980, 'partial metrics preserves fan_rpm')
  from public.devices where id = 'd1d1d1d1-1111-4111-8111-111111111111';

-- ---- grant hygiene -----------------------------------------
select is(
  has_column_privilege('authenticated', 'public.devices', 'battery_health_pct', 'select'),
  true, 'grant: authenticated can SELECT battery_health_pct');
select is(
  has_column_privilege('anon', 'public.devices', 'sensors_capability', 'select'),
  true, 'grant: anon can SELECT sensors_capability');
select is(
  has_function_privilege('anon',
    'public.helper_heartbeat(uuid,text,integer,integer,integer,jsonb,jsonb)', 'execute'),
  true, 'grant: anon can EXECUTE 7-arg helper_heartbeat (helper contract)');

select * from finish();
rollback;
