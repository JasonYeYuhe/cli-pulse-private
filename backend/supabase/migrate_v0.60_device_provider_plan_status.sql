-- migrate_v0.60_device_provider_plan_status.sql
-- Adds per-provider managed-session PLAN status (on_plan / off_plan) to the
-- device row so mobile clients can warn — exactly as the macOS picker does —
-- that a managed Codex session on a given Mac would run BILLED on the OpenAI
-- API instead of the user's ChatGPT plan.
--
-- Rides the ALWAYS-ON device-heartbeat path (helper_heartbeat -> devices ->
-- authenticated select). Independent of remote_control_enabled (v0.27) AND the
-- R0 realtime cutover (v0.56). The value is a non-secret login-mode label.
--
-- Idempotent. DDL is transactional in Postgres, so the DROP+CREATE of
-- helper_heartbeat is atomic (no window where a live helper's heartbeat 404s).
--
-- Review: Codex GO-WITH-CHANGES 2026-07-01 —
--   * param defaults NULL (NOT '{}') so old callers omitting it don't clobber;
--     coalesce preserves last-known on omit / transient compute failure.
--   * normalize server-side: keep only string values in ('on_plan','off_plan')
--     with short keys, bounded count; never store arbitrary helper JSONB, and
--     never let a bad payload fail the NOT NULL column.
--   * devices uses COLUMN-LEVEL grants -> must explicitly grant SELECT on the
--     new column or authenticated (mobile) can't read it.

begin;

-- 1. Column (latest-wins device capability; RLS row policy already scopes to owner).
alter table public.devices
  add column if not exists provider_plan_status jsonb not null default '{}'::jsonb;

-- devices has per-column grants; the new column needs an explicit SELECT grant
-- (matches the existing anon+authenticated read pattern; writes go through the
-- SECURITY DEFINER helper_heartbeat, so no INSERT/UPDATE grant is needed here).
grant select (provider_plan_status) on public.devices to anon, authenticated;

-- 2. helper_heartbeat: add the optional plan-status map.
-- Drop the current secure 5-arg (a trailing defaulted param would otherwise
-- create a 2nd overload -> PostgREST "could not choose candidate" ambiguity).
-- Also defensively drop the pre-v0.57 insecure (uuid,uuid,...) overload.
drop function if exists public.helper_heartbeat(uuid, text, integer, integer, integer);
drop function if exists public.helper_heartbeat(uuid, uuid, integer, integer, integer);

create or replace function public.helper_heartbeat(
  p_device_id uuid,
  p_helper_secret text,
  p_cpu_usage integer default 0,
  p_memory_usage integer default 0,
  p_active_session_count integer default 0,
  p_provider_plan_status jsonb default null
)
returns jsonb as $$
declare
  v_user_id uuid;
  v_plan jsonb;
begin
  -- Authenticate via device secret (compare SHA-256 hash) — unchanged.
  select user_id into v_user_id
  from public.devices where id = p_device_id and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  -- v0.60: normalize the optional plan-status map. NULL (old callers) or a
  -- non-object payload => leave the stored value untouched (coalesce below). A
  -- valid object => keep ONLY well-formed entries (value in on_plan/off_plan,
  -- key <= 32 chars), bounded to 24 keys; an explicit {} clears the warning.
  v_plan := null;
  if p_provider_plan_status is not null and jsonb_typeof(p_provider_plan_status) = 'object' then
    select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into v_plan
    from (
      select key as k, value as v
      from jsonb_each_text(p_provider_plan_status)
      where value in ('on_plan', 'off_plan') and char_length(key) <= 32
      order by key
      limit 24
    ) s;
  end if;

  update public.devices set
    status = 'Online', cpu_usage = p_cpu_usage,
    memory_usage = p_memory_usage, last_seen_at = now(),
    provider_plan_status = coalesce(v_plan, provider_plan_status)
  where id = p_device_id;

  return jsonb_build_object('status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Helper calls via the anon key; app never calls this RPC. Re-grant after recreate.
grant execute on function public.helper_heartbeat(uuid, text, integer, integer, integer, jsonb) to anon, authenticated;

commit;
