-- ============================================================
-- pgTAP — migrate_v0.68 Keep Awake lid-closed option (prevent_lid_sleep)
-- ============================================================
-- OWNER-RUN (not CI). Run AFTER applying migrate_v0.68 against a BRANCH
-- database as a privileged role. One transaction, rolls back.
--
--   create extension if not exists pgtap;
--   \i backend/supabase/tests/migrate_v0.68_keep_awake_lid.test.sql
--
-- WHAT THIS PROVES: prevent_lid_sleep passes through ONLY as an explicit
-- boolean true on enable; absent / non-boolean / on-disable → key omitted.
-- (Assertions look rows up BY the returned command_id — created_at is
-- transaction_timestamp(), constant inside one txn.)
-- ============================================================

begin;
select plan(4);

insert into auth.users (id) values ('a6800000-6800-4680-8680-680000000001');
insert into public.devices (id, user_id, name, helper_secret) values
  ('d6800000-6800-4680-8680-680000000001', 'a6800000-6800-4680-8680-680000000001',
   'v068-dev', encode(extensions.digest('v068-secret', 'sha256'), 'hex'));
update public.user_settings set remote_control_enabled = true
  where user_id = 'a6800000-6800-4680-8680-680000000001';
select set_config('request.jwt.claims',
  '{"sub":"a6800000-6800-4680-8680-680000000001","role":"authenticated"}', true);

-- 1. enable + lid true → key included
select is(
  (select payload from public.machine_commands where id =
    ((public.remote_app_send_machine_command(
      'd6800000-6800-4680-8680-680000000001','set_keep_awake',
      '{"on":true,"prevent_lid_sleep":true}'::jsonb))->>'command_id')::uuid),
  '{"on": true, "prevent_lid_sleep": true}'::jsonb,
  'lid: explicit true on enable passes through');

-- 2. enable, lid absent → key omitted
select is(
  (select payload from public.machine_commands where id =
    ((public.remote_app_send_machine_command(
      'd6800000-6800-4680-8680-680000000001','set_keep_awake','{"on":true}'::jsonb))->>'command_id')::uuid),
  '{"on": true}'::jsonb, 'lid: absent stays absent');

-- 3. enable, lid non-boolean → ignored (key omitted, command still valid)
select is(
  (select payload from public.machine_commands where id =
    ((public.remote_app_send_machine_command(
      'd6800000-6800-4680-8680-680000000001','set_keep_awake',
      '{"on":true,"prevent_lid_sleep":"yes"}'::jsonb))->>'command_id')::uuid),
  '{"on": true}'::jsonb, 'lid: non-boolean ignored');

-- 4. disable + lid true → dropped along with ttl
select is(
  (select payload from public.machine_commands where id =
    ((public.remote_app_send_machine_command(
      'd6800000-6800-4680-8680-680000000001','set_keep_awake',
      '{"on":false,"prevent_lid_sleep":true,"ttl_seconds":600}'::jsonb))->>'command_id')::uuid),
  '{"on": false}'::jsonb, 'lid: dropped on disable');

select * from finish();
rollback;
