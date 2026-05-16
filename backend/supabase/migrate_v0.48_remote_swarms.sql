-- ============================================================
-- v0.48 — Swarm View backend: remote_swarms + heartbeat/list RPCs (S2)
-- Date: 2026-05-17 (v1.22.0 P0 "Mission Control for the agent swarm")
--
-- Goal:
-- Land the edge-aggregated swarm heartbeat the helper (S1b) already
-- emits, and the authenticated read the Mac/iOS Swarm grid (S3/S4)
-- will consume — with the ghost-swarm TTL and privacy posture the
-- Gemini 2-round review locked in (PLAN_v1.22 §7/§8).
--
-- Architecture:
-- 1. `remote_swarms` — ONE latest-wins row per (user_id, device_id),
--    modelled on `provider_quotas` (jsonb blob + updated_at, UPSERT,
--    never a backlog). `swarms` holds the helper's per-swarm rollup
--    array (R1-A4 edge aggregation — the backend never scans the raw
--    event stream).
-- 2. `remote_helper_swarm_heartbeat(p_device_id, p_helper_secret,
--    p_swarms jsonb)` — gated by `_remote_authenticate_helper_gated`
--    (same posture as `remote_helper_post_event`); UPSERTs the blob.
--    Defensive caps mirror the `left(payload,4096)` philosophy.
-- 3. `remote_app_list_swarms()` — JWT-authenticated read
--    (`auth.uid()` + `_remote_control_enabled_for_caller()`), returns
--    each swarm annotated with a `stale` flag instead of dropping it
--    (R2-2: past-TTL renders as "last-seen Xm ago", not vanished).
--
-- Privacy (RK7):
-- The helper only ever uploads opaque `swarm_key` (account-scoped
-- HMAC) + `handle` (`swarm-<6hex>`) — NO repo path or branch name.
-- This migration stores and returns exactly that opaque shape; there
-- is nothing here to redact because nothing identifying arrives.
--
-- TTL / RK8:
-- Helper beats every ~30s (S1b). "Live" window = 90s (3× the beat —
-- the anti-flap margin the plan pinned). Rows 90s–10min old are
-- returned with stale=true so the UI can show them greyed; a nightly
-- cron purges rows older than 1 day.
--
-- Return types are `jsonb` (NOT `RETURNS TABLE`) so CREATE OR REPLACE
-- needs no DROP and preserves grants (feedback_gemini_review_patterns
-- #1).
--
-- Idempotency:
-- `create table if not exists`, `create index if not exists`,
-- `drop policy if exists` + recreate, `CREATE OR REPLACE FUNCTION`,
-- `cron.unschedule` then `cron.schedule` — safe to re-run.
-- ============================================================

-- ── 1. table ────────────────────────────────────────────────

create table if not exists public.remote_swarms (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  device_id   uuid not null references public.devices(id) on delete cascade,
  swarms      jsonb not null default '[]'::jsonb,
  updated_at  timestamptz not null default now(),
  primary key (user_id, device_id)
);

alter table public.remote_swarms enable row level security;

-- Per-user read; no INSERT/UPDATE policy — writes go via the
-- SECURITY DEFINER helper RPC only (same posture as remote_sessions).
drop policy if exists "Users can read own swarms" on public.remote_swarms;
create policy "Users can read own swarms"
  on public.remote_swarms for select using ((select auth.uid()) = user_id);

drop policy if exists "Users can delete own swarms" on public.remote_swarms;
create policy "Users can delete own swarms"
  on public.remote_swarms for delete using ((select auth.uid()) = user_id);

-- Read path filters by (user_id, updated_at) for the TTL window.
create index if not exists idx_remote_swarms_user
  on public.remote_swarms(user_id, updated_at desc);

-- ── 2. helper write RPC (anon-key callable, device-secret gated) ──

create or replace function public.remote_helper_swarm_heartbeat(
  p_device_id uuid,
  p_helper_secret text,
  p_swarms jsonb
) returns jsonb as $$
declare
  v_user_id uuid;
  v_swarms  jsonb;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  -- Defensive: must be a jsonb array; cap element count (helper caps
  -- at 64 — SwarmStore._MAX_SWARMS). Anything else collapses to [].
  if p_swarms is null or jsonb_typeof(p_swarms) <> 'array' then
    v_swarms := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(elem), '[]'::jsonb)
      into v_swarms
      from (
        select elem
        from jsonb_array_elements(p_swarms) with ordinality as t(elem, ord)
        order by ord
        limit 64
      ) capped;
  end if;

  -- Hard size cap so a malformed/oversized blob can't bloat the row
  -- (mirrors the left(payload,4096) philosophy; 64 swarms of small
  -- opaque summaries fit comfortably under 32 KB).
  if length(v_swarms::text) > 32768 then
    raise exception 'swarm payload too large';
  end if;

  insert into public.remote_swarms (user_id, device_id, swarms, updated_at)
  values (v_user_id, p_device_id, v_swarms, now())
  on conflict (user_id, device_id)
  do update set swarms = excluded.swarms, updated_at = now();

  return jsonb_build_object('status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ── 3. app read RPC (authenticated JWT only) ─────────────────

create or replace function public.remote_app_list_swarms()
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    return '[]'::jsonb;
  end if;

  -- One object per device that has heart-beaten in the last 10 min.
  -- `stale` = past the 90s live-TTL (RK8 / R2-2): the UI greys it and
  -- shows "last seen", rather than the swarm silently disappearing.
  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'device_id',  rs.device_id,
          'updated_at', rs.updated_at,
          'age_s',      round(extract(epoch from (now() - rs.updated_at))::numeric, 1),
          'stale',      (rs.updated_at <= now() - interval '90 seconds'),
          'swarms',     rs.swarms
        )
        order by rs.updated_at desc
      )
      from public.remote_swarms rs
      where rs.user_id = v_user_id
        and rs.updated_at > now() - interval '10 minutes'
    ),
    '[]'::jsonb
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

revoke all on function public.remote_app_list_swarms() from public, anon;
grant execute on function public.remote_app_list_swarms() to authenticated;

-- `remote_helper_swarm_heartbeat` intentionally keeps Postgres's
-- default PUBLIC EXECUTE so the helper can call it via the anon key,
-- exactly like the other remote_helper_* RPCs (see v0.40 note: the
-- v0.26 anon/authenticated/service_role grants carry forward).

-- ── 4. nightly TTL cleanup (internal + cron) ─────────────────

create or replace function public._cleanup_remote_swarms_internal()
returns void as $$
begin
  delete from public.remote_swarms
  where updated_at < now() - interval '1 day';
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

revoke all on function public._cleanup_remote_swarms_internal()
  from PUBLIC, authenticated, anon;

-- Idempotent (un)schedule — v0.28/v0.47 shape. Next free nightly slot
-- after v0.28's 03:47 UTC, continuing the ~20-min stagger → 04:07.
do $$
begin
  perform cron.unschedule('remote_swarms_cleanup_nightly');
exception when others then
  null;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'remote_swarms_cleanup_nightly',
      '7 4 * * *',
      $cron$select public._cleanup_remote_swarms_internal();$cron$
    );
  else
    raise notice 'pg_cron extension missing — skipping remote_swarms_cleanup_nightly schedule.';
  end if;
end $$;
