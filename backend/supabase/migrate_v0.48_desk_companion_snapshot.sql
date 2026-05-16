-- ============================================================
-- v0.48 — Desk Companion device snapshot RPC
-- Date: 2026-05-16 (desktop-robot-prototype)
--
-- Goal:
-- A new hardware product — a small desktop companion device (ambient
-- display first, expressive/animated later) — sits on a developer's
-- desk and physically reacts to their AI coding-agent activity. It is a
-- READ-ONLY consumer of the existing CLI Pulse backend.
--
-- This migration adds ONE function, public.desk_snapshot, that a
-- constrained ESP32/Pi-class device polls once per cycle over HTTPS to
-- get everything it needs to render in a single round trip.
--
-- Auth model:
-- The device pairs through the EXISTING register_helper() pairing-code
-- flow, passing p_device_type = 'DeskCompanion'. It stores the returned
-- (device_id, helper_secret) the same way the Mac helper does. This RPC
-- authenticates with the same SHA-256 secret-hash comparison as
-- helper_heartbeat/helper_sync, AND additionally requires
-- devices.type = 'DeskCompanion'. It is strictly READ-ONLY apart from a
-- presence touch (status/last_seen_at), so a leaked desk secret cannot
-- be replayed to write sessions/alerts or drive remote control (remote
-- control is independently gated by user_settings.remote_control_enabled
-- and is never enabled for a passive display).
--
-- Revocation reuses the existing path: the user deletes the device from
-- the app's device list (unregister_desktop_helper / account cascade),
-- and the next poll's auth subquery returns NULL → exception → the
-- firmware drops to its re-pair screen.
--
-- Aggregation reuses the exact math already in app_rpc.sql:
--   - today cost/usage  ← dashboard_summary's daily_usage_metrics block
--   - quota             ← provider_summary's provider_quotas projection
-- so there is a single source of truth and no drift.
--
-- Note on "finished": a just-completed session is intentionally NOT a
-- server-emitted status. The sessions table has no reliable ended-at
-- timestamp (helper_sync flips status to 'Ended' in a bulk update
-- without touching last_active_at), and adding one is out of this
-- migration's minimal scope. The firmware synthesizes the "finished"
-- celebration locally by diffing the active count between two
-- consecutive snapshots (see plan §4.3).
--
-- Idempotent: create or replace; safe to re-run. No schema/table
-- change, no new edge function, no change to register_helper or any
-- existing RPC. Rollback: rollback_v0.48.sql (drop function).
-- ============================================================

create or replace function public.desk_snapshot(
  p_device_id uuid,
  p_helper_secret text,
  p_user_today date default null
) returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid;
  v_today date := coalesce(p_user_today, current_date);
  v_today_usage bigint;
  v_today_cost numeric;
  v_running integer;
  v_pending integer;
  v_unresolved integer;
  v_top_severity text;
  v_min_pct integer;
  v_quota_low boolean;
  v_reset_at timestamptz;
  v_sessions jsonb;
  v_status text;
  v_poll_after integer;
begin
  -- Authenticate: device secret hash match AND device must be a desk
  -- companion. Mirrors helper_heartbeat's check; the extra type guard
  -- keeps a leaked desk secret from being replayed against a different
  -- device class.
  select user_id into v_user_id
  from public.devices
  where id = p_device_id
    and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex')
    and type = 'DeskCompanion';

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  -- Presence touch so the desk device shows up in the existing device
  -- list / Online status UI (free reuse, no new UI).
  update public.devices
    set status = 'Online', last_seen_at = now()
    where id = p_device_id;

  -- today usage/cost — copied verbatim from dashboard_summary so the
  -- desk device and the apps always agree on "today".
  select
    coalesce(sum(coalesce(input_tokens,0) + coalesce(cached_tokens,0) + coalesce(output_tokens,0)), 0),
    coalesce(sum(cost), 0)
  into v_today_usage, v_today_cost
  from public.daily_usage_metrics
  where user_id = v_user_id
    and metric_date = v_today;

  select count(*) into v_running
  from public.sessions
  where user_id = v_user_id and status = 'Running';

  select count(*) into v_pending
  from public.remote_permission_requests
  where user_id = v_user_id and status = 'pending' and expires_at > now();

  select count(*) into v_unresolved
  from public.alerts
  where user_id = v_user_id and is_resolved = false;

  -- Highest unresolved-alert severity, ranked Critical > Warning > Info.
  select severity into v_top_severity
  from public.alerts
  where user_id = v_user_id and is_resolved = false
  order by case lower(severity)
             when 'critical' then 3
             when 'warning'  then 2
             when 'info'     then 1
             else 0
           end desc
  limit 1;

  -- Worst-provider quota: lowest remaining/quota ratio across providers
  -- that report a positive quota. Reuses provider_summary's quota source.
  select
    round(min(remaining::numeric / quota) * 100)::integer,
    min(reset_time)
  into v_min_pct, v_reset_at
  from public.provider_quotas
  where user_id = v_user_id
    and quota is not null and quota > 0
    and remaining is not null;

  v_quota_low := v_min_pct is not null and v_min_pct < 10;

  -- Up to 20 running sessions, smallest projection the device needs.
  -- Per-session "needs approval" attribution is intentionally deferred:
  -- helper_sync `sessions` and `remote_permission_requests.session_id`
  -- (which references remote_sessions) share no key, so approval is
  -- surfaced at the user level via pending_approvals + the status enum.
  select coalesce(
           jsonb_agg(jsonb_build_object('p', provider, 's', 'running')
                     order by last_active_at desc),
           '[]'::jsonb)
  into v_sessions
  from (
    select provider, last_active_at
    from public.sessions
    where user_id = v_user_id and status = 'Running'
    order by last_active_at desc
    limit 20
  ) s;

  -- Single precomputed headline status so the firmware does zero
  -- business logic. 'finished' is synthesized client-side (see header).
  v_status := case
    when v_pending > 0                   then 'needs_approval'
    when v_top_severity ilike 'critical' then 'alert_critical'
    when v_quota_low                     then 'quota_low'
    when v_running > 0                   then 'running'
    when v_top_severity ilike 'warning'  then 'alert_warning'
    else 'idle'
  end;

  -- Adaptive cadence: fast lane while something is active so an approval
  -- surfaces within ~5s; relaxed when idle. Firmware clamps to [5,120].
  v_poll_after := case when v_running > 0 or v_pending > 0 then 5 else 30 end;

  return jsonb_build_object(
    'v', 1,
    'ts', now(),
    'poll_after_s', v_poll_after,
    'status', v_status,
    'sessions', jsonb_build_object(
      'active', v_running,
      'running', v_running,
      'needs_approval', v_pending,
      'list', v_sessions
    ),
    'pending_approvals', v_pending,
    'today', jsonb_build_object('cost', v_today_cost, 'usage', v_today_usage),
    'quota', jsonb_build_object(
      'low', v_quota_low,
      'min_remaining_pct', v_min_pct,
      'reset_at', v_reset_at
    ),
    'alerts', jsonb_build_object(
      'unresolved', v_unresolved,
      'top_severity', v_top_severity
    ),
    'device', jsonb_build_object(
      'online_devices', (
        select count(*) from public.devices
        where user_id = v_user_id and status = 'Online'
      )
    )
  );
end;
$$;

-- Reachable with the anon key (device sends p_device_id + p_helper_secret
-- in the body, exactly like helper_heartbeat / device_status). Internal
-- auth is the secret-hash + type check above.
grant execute on function public.desk_snapshot(uuid, text, date) to anon, authenticated;
