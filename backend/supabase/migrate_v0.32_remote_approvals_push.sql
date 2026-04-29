-- ============================================================
-- v0.32 — Remote Approvals push notifications (iOS first)
-- Date: 2026-04-29
--
-- Closes the "user not currently watching the sheet" gap in Phase 1:
-- the Claude PermissionRequest hook waits ~10s, the Mac/iOS active
-- polling only kicks in while the approvals view is on screen, so a
-- pending request can time out into deny+message before the user
-- notices. This migration enqueues an APNs push at INSERT time.
--
-- Key design decisions (see PROJECT_DEV_PLAN_2026-04-29_remote_approvals_push.md):
--
--   * Same-account auto-match is already supported by Phase 1 via
--     auth.uid() — iOS does NOT need helper_secret. This migration
--     does not change that.
--
--   * `app_push_tokens` is a NEW table, separate from `devices.push_token`
--     (which has been a dead column since v0.10). devices is helper-
--     pairing-keyed; app_push_tokens is app-install-keyed (same user
--     can have multiple iPhones).
--
--   * `unique(token)` (NOT unique(user_id, platform, token)). APNs tokens
--     are device-globally unique; if a different user signs into the
--     same iPhone, the next register_app_push_token call must transfer
--     ownership atomically so the previous user's pending requests
--     don't push to someone else's phone.
--
--   * Immediate-first dispatch: the AFTER INSERT trigger calls
--     net.http_post directly so the push fires as soon as the helper
--     RPC commits. The pg_cron worker is for retry/backfill of failed
--     dispatches, NOT the primary delivery path.
--
--   * Server-side gate enforced THREE places: helper RPC (already there
--     since v0.27), trigger (here), edge function (defense in depth).
--     If user_settings.remote_control_enabled = false, no push.
--
--   * notified_at is only set by the edge function on confirmed APNs 2xx.
--     queued_at, attempts, last_error are recorded separately.
--
--   * Payload contains NO sensitive data (no provider, tool_name, cwd,
--     summary, command, user_id). Only request_id as a routing marker.
--
-- Idempotent: safe to re-run.
-- ============================================================

-- ── 1. app_push_tokens table ────────────────────────────────
-- Why `unique (token)` and NOT `unique (user_id, platform, token)` or
-- `unique (platform, bundle_id, token)`:
--
--   * APNs issues tokens at the (device, bundle_id, environment) tuple
--     level. Apple's contract guarantees: any two tokens that ever exist
--     for different (device, bundle_id) pairs are distinct. So `token`
--     alone is already a globally-unique identifier across platform and
--     bundle_id — adding those columns to the unique constraint can only
--     make it weaker (matches more conflicts), not stronger.
--
--   * The constraint must NOT include `user_id`. The whole point of the
--     unique-on-token invariant is to atomically transfer ownership when
--     user A logs out of an iPhone and user B logs in: APNs hands the
--     same token T to user B's app install, and ON CONFLICT(token) DO
--     UPDATE SET user_id = excluded.user_id flips the row to user B.
--     If unique included user_id, both rows would coexist and user A's
--     pending requests would keep pushing to user B's iPhone after the
--     handoff.
--
--   * The (defensive) consequence: if the same APNs token ever appears
--     under two user_ids, we treat the second register as authoritative
--     and overwrite. Better than splitting traffic.
create table if not exists public.app_push_tokens (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  platform      text not null check (platform in ('ios', 'macos')),
  bundle_id     text not null,
  token         text not null unique,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);

alter table public.app_push_tokens enable row level security;

drop policy if exists "Users can read own push tokens" on public.app_push_tokens;
create policy "Users can read own push tokens"
  on public.app_push_tokens for select
  using ((select auth.uid()) = user_id);

-- INSERT/UPDATE/DELETE are NOT exposed via RLS — only the SECURITY DEFINER
-- RPCs below can mutate the table. Keeps token-transfer logic centralised.

create index if not exists idx_app_push_tokens_user_id
  on public.app_push_tokens(user_id);


-- ── 2. App-side RPCs ────────────────────────────────────────

-- Register or transfer-ownership of a push token. SECURITY DEFINER + auth.uid()
-- gate. INSERT … ON CONFLICT(token) DO UPDATE SET user_id = auth.uid() means
-- when the same iPhone is signed in by a different user, the new user takes
-- over the row — the previous user's requests stop pushing to that device.
create or replace function public.register_app_push_token(
  p_platform  text,
  p_bundle_id text,
  p_token     text
) returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if p_platform not in ('ios', 'macos') then
    raise exception 'Invalid platform: %', p_platform;
  end if;
  if p_token is null or length(p_token) < 8 or length(p_token) > 256 then
    raise exception 'Invalid push token length';
  end if;
  if p_bundle_id is null or length(p_bundle_id) < 1 or length(p_bundle_id) > 128 then
    raise exception 'Invalid bundle id length';
  end if;

  insert into public.app_push_tokens (user_id, platform, bundle_id, token)
  values (v_user_id, p_platform, p_bundle_id, p_token)
  on conflict (token) do update
    set user_id      = excluded.user_id,
        platform     = excluded.platform,
        bundle_id    = excluded.bundle_id,
        last_seen_at = now();

  return jsonb_build_object('status', 'ok');
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

revoke all on function public.register_app_push_token(text, text, text)
  from PUBLIC, anon;
grant execute on function public.register_app_push_token(text, text, text)
  to authenticated;


-- Unregister (delete) a push token. Only allows deleting tokens owned by
-- the calling user. Called by the app on logout. Defensive: no-op if the
-- token doesn't exist or belongs to someone else (we don't want to leak
-- "this token is registered to another user").
create or replace function public.unregister_app_push_token(
  p_token text
) returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_deleted integer;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  delete from public.app_push_tokens
  where token = p_token and user_id = v_user_id;
  get diagnostics v_deleted = row_count;

  return jsonb_build_object('status', 'ok', 'deleted', v_deleted);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

revoke all on function public.unregister_app_push_token(text)
  from PUBLIC, anon;
grant execute on function public.unregister_app_push_token(text)
  to authenticated;


-- ── 3. remote_permission_requests notification columns ──────
-- queued_at  — first time we enqueued for delivery (set by trigger)
-- attempts   — number of dispatch attempts (incremented on each fire)
-- last_error — generic error string from edge function (no sensitive data)
-- notified_at — confirmed APNs 2xx; only set by the edge function
alter table public.remote_permission_requests
  add column if not exists notification_queued_at  timestamptz,
  add column if not exists notification_attempts   integer not null default 0,
  add column if not exists notification_last_error text,
  add column if not exists notified_at             timestamptz;


-- ── 4. app_push_jobs queue table (mirror webhook_jobs pattern) ─
create table if not exists public.app_push_jobs (
  id                bigserial primary key,
  user_id           uuid not null references public.profiles(id) on delete cascade,
  request_id        uuid not null references public.remote_permission_requests(id) on delete cascade,
  enqueued_at       timestamptz not null default now(),
  pg_net_request_id bigint,
  dispatched_at     timestamptz,
  processed_at      timestamptz,
  attempt_count     integer not null default 0,
  last_error        text
);

alter table public.app_push_jobs enable row level security;

-- Service role only (edge functions + cron). Authenticated users have no
-- need to read this directly; status is reflected on remote_permission_requests.
drop policy if exists "Service role only on app_push_jobs" on public.app_push_jobs;
create policy "Service role only on app_push_jobs"
  on public.app_push_jobs for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

-- One pending job per request_id at a time; rapid duplicates collapse.
create unique index if not exists idx_app_push_jobs_pending_dedup
  on public.app_push_jobs (request_id)
  where processed_at is null;

create index if not exists idx_app_push_jobs_pending_drain
  on public.app_push_jobs (enqueued_at)
  where processed_at is null;


-- ── 5. AFTER INSERT trigger: immediate-first dispatch ───────
-- Runs as SECURITY DEFINER + EXCEPTION-WHEN-OTHERS so a push failure
-- never breaks the helper's INSERT (which is already in a transaction
-- that committed remote_permission_requests).
--
-- Defence layers (matching the existing helper RPC + edge function):
--   1. user_settings.remote_control_enabled gate
--   2. existence of any push token for this user (skip if none)
--   3. pg_cron worker re-dispatches if pg_net call dropped
--
-- Vault secrets app_supabase_url + app_service_role_key are the SAME
-- ones v0.25 webhook fanout uses. No new vault key required for the
-- INVOKE side; APNs secrets are read inside the edge function.
create or replace function public.remote_request_after_insert_push()
returns trigger as $$
declare
  v_enabled    boolean;
  v_url        text;
  v_key        text;
  v_request_id bigint;
  v_has_tokens boolean;
begin
  -- Only act on freshly-pending rows. UPDATE-to-pending shouldn't happen
  -- per the state machine, but be defensive.
  if NEW.status is distinct from 'pending' then
    return NEW;
  end if;

  -- Layer 1: user-level Remote Control gate. Defense-in-depth — the helper
  -- RPC already gates, but we re-check in case the row was inserted via a
  -- future code path.
  select coalesce(remote_control_enabled, false) into v_enabled
  from public.user_settings
  where user_id = NEW.user_id;
  if not coalesce(v_enabled, false) then
    return NEW;
  end if;

  -- Layer 2: any push tokens? If not, don't enqueue (saves cron cycles
  -- and edge function dispatches for users who never signed in on iOS).
  select exists (
    select 1 from public.app_push_tokens where user_id = NEW.user_id
  ) into v_has_tokens;
  if not v_has_tokens then
    return NEW;
  end if;

  -- Vault secrets for invoking the edge function.
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'app_supabase_url';
  select decrypted_secret into v_key
  from vault.decrypted_secrets where name = 'app_service_role_key';
  if v_url is null or v_key is null or v_url = '' or v_key = '' then
    raise notice 'remote_request_after_insert_push: vault secrets not set; skipping';
    return NEW;
  end if;

  -- Mark queued + insert job row. Both are required state for the cron
  -- worker to know whether to back-fill.
  update public.remote_permission_requests
  set notification_queued_at = now()
  where id = NEW.id;

  insert into public.app_push_jobs (user_id, request_id)
  values (NEW.user_id, NEW.id)
  on conflict (request_id) where processed_at is null do nothing;

  -- Immediate dispatch. pg_net itself is async, so this returns quickly
  -- without blocking the parent helper RPC's commit. Failure here lands
  -- in the EXCEPTION block and the cron worker picks up.
  v_request_id := net.http_post(
    url := v_url || '/functions/v1/send-approval-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key,
      'X-Internal-Trigger', 'remote_request_after_insert_push'
    ),
    body := jsonb_build_object(
      'user_id', NEW.user_id,
      'request_id', NEW.id
    ),
    timeout_milliseconds := 5000
  );

  update public.app_push_jobs
  set pg_net_request_id = v_request_id,
      dispatched_at     = now(),
      attempt_count     = 1
  where request_id = NEW.id and processed_at is null;

  -- attempts on the request row tracks total dispatch tries.
  update public.remote_permission_requests
  set notification_attempts = 1
  where id = NEW.id;

  return NEW;

exception
  when others then
    -- DO NOT propagate. Helper RPC's commit must succeed; the cron worker
    -- will retry. Log generic info; never log NEW.payload or NEW.summary.
    raise warning 'remote_request_after_insert_push failed (request %): % (sqlstate %)',
      NEW.id, sqlerrm, sqlstate;
    return NEW;
end;
$$ language plpgsql security definer
   set search_path = pg_catalog, public, extensions, net;

drop trigger if exists remote_permission_requests_after_insert_push on public.remote_permission_requests;
create trigger remote_permission_requests_after_insert_push
  after insert on public.remote_permission_requests
  for each row execute function public.remote_request_after_insert_push();


-- ── 6. pg_cron retry/backfill worker ───────────────────────
-- Mirrors process_webhook_jobs. Two passes:
--   1. Reconcile dispatched jobs against net._http_response — mark
--      processed on 2xx, retry on >2xx, time out after 5min.
--   2. Dispatch never-dispatched jobs (rare — only when the trigger
--      threw an exception that the EXCEPTION block caught).
create or replace function public.process_app_push_jobs()
returns void as $$
declare
  v_job        record;
  v_url        text;
  v_key        text;
  v_request_id bigint;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'app_supabase_url';
  select decrypted_secret into v_key
  from vault.decrypted_secrets where name = 'app_service_role_key';
  if v_url is null or v_key is null or v_url = '' or v_key = '' then
    raise notice 'process_app_push_jobs: vault secrets not set; skipping';
    return;
  end if;

  -- Pass 1: reconcile dispatched jobs.
  for v_job in
    select id, request_id, pg_net_request_id, attempt_count
    from public.app_push_jobs
    where processed_at is null
      and pg_net_request_id is not null
      and dispatched_at < now() - interval '2 seconds'
    order by id
    limit 200
  loop
    declare
      v_status int;
      v_body   text;
    begin
      select status_code, content
      into v_status, v_body
      from net._http_response
      where id = v_job.pg_net_request_id;

      if v_status is null then
        update public.app_push_jobs
          set last_error = 'pg_net response not yet available',
              -- after 5min, allow re-dispatch
              pg_net_request_id = case
                when dispatched_at < now() - interval '5 minutes'
                then null else pg_net_request_id end
          where id = v_job.id;
      elsif v_status between 200 and 299 then
        update public.app_push_jobs
          set processed_at = now(),
              last_error = null
          where id = v_job.id;
      else
        update public.app_push_jobs
          set attempt_count    = attempt_count + 1,
              last_error       = 'edge HTTP ' || v_status::text,
              pg_net_request_id = null,
              dispatched_at    = null
          where id = v_job.id;
        update public.remote_permission_requests
          set notification_attempts   = notification_attempts + 1,
              notification_last_error = 'edge HTTP ' || v_status::text
          where id = v_job.request_id;
      end if;
    exception when others then
      raise warning 'process_app_push_jobs reconcile (job %): %', v_job.id, sqlerrm;
    end;
  end loop;

  -- Pass 2: dispatch never-dispatched (or failed-and-cleared) jobs.
  -- attempt_count < 3 caps retries.
  for v_job in
    select id, user_id, request_id
    from public.app_push_jobs
    where processed_at is null
      and pg_net_request_id is null
      and attempt_count < 3
      and enqueued_at < now() - interval '5 seconds'
    order by id
    limit 100
  loop
    begin
      v_request_id := net.http_post(
        url := v_url || '/functions/v1/send-approval-push',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_key,
          'X-Internal-Trigger', 'process_app_push_jobs'
        ),
        body := jsonb_build_object(
          'user_id', v_job.user_id,
          'request_id', v_job.request_id
        ),
        timeout_milliseconds := 5000
      );
      update public.app_push_jobs
        set pg_net_request_id = v_request_id,
            dispatched_at     = now(),
            attempt_count     = attempt_count + 1,
            last_error        = null
        where id = v_job.id;
      update public.remote_permission_requests
        set notification_attempts = notification_attempts + 1
        where id = v_job.request_id;
    exception when others then
      update public.app_push_jobs
        set attempt_count = attempt_count + 1,
            last_error    = 'http_post failed: ' || sqlerrm
        where id = v_job.id;
    end;
  end loop;
end;
$$ language plpgsql security definer
   set search_path = pg_catalog, extensions, public, net;

revoke all on function public.process_app_push_jobs()
  from PUBLIC, anon, authenticated;


-- ── 7. pg_cron schedule ─────────────────────────────────────
-- 30s interval. Idempotent: unschedule first.
do $$
begin
  perform cron.unschedule('app_push_jobs_drain');
exception when others then
  null;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'app_push_jobs_drain',
      '30 seconds',
      $cron$select public.process_app_push_jobs()$cron$
    );
  else
    raise notice 'pg_cron extension missing — skipping app_push_jobs_drain schedule.';
  end if;
end $$;


-- ── 8. Upgrade list_pending_approvals: include device_name ──
-- Multi-Mac users currently see UUIDs in device_id but no human label.
-- Join devices to surface the user-visible name. RLS-safe: devices.name
-- is already SELECT-able by the row owner, and we filter on user_id.
create or replace function public.remote_app_list_pending_approvals()
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

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', rpr.id,
          'session_id', rpr.session_id,
          'device_id', rpr.device_id,
          'device_name', d.name,
          'provider', rpr.provider,
          'tool_name', rpr.tool_name,
          'summary', rpr.summary,
          'risk', rpr.risk,
          'status', rpr.status,
          'created_at', rpr.created_at,
          'expires_at', rpr.expires_at
        )
        order by rpr.created_at desc
      )
      from public.remote_permission_requests rpr
      left join public.devices d
        on d.id = rpr.device_id and d.user_id = rpr.user_id
      where rpr.user_id = v_user_id
        and rpr.status = 'pending'
        and rpr.expires_at > now()
    ),
    '[]'::jsonb
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;
