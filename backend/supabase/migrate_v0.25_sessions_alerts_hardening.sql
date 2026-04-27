-- ============================================================
-- v0.25 — Sessions & Alerts hardening
-- Date: 2026-04-27
-- Bundles the SQL changes from PROJECT_DEV_PLAN_2026-04-27_sessions_alerts_hardening.md
-- (v2). Idempotent: safe to re-run.
--
-- Changes covered:
--   Change 3  — helper_sync writes project_hash
--   Change 5  — helper_sync per-device advisory lock
--   Change 10 — non-empty-sweep also gets the 10-minute grace floor
--   Change 6  — evaluate_budget_alerts: per-project block short-circuited;
--               cost-spike block keeps running with is_resolved gating
--   Change 2a — public.webhook_jobs queue + alerts_enqueue_webhook trigger
--               + process_webhook_jobs cron worker
--
-- See the dev plan for rationale on each. Reviewed by Gemini 3 Pro + Codex.
-- ============================================================

-- ── helper_sync ─────────────────────────────────────────────
-- Replaces the v0.24 definition. Diff vs prior:
--   1. perform pg_advisory_xact_lock so two concurrent calls for the
--      same device serialise (Codex's race-condition finding).
--   2. INSERT now writes project_hash (Change 3 — yield_score join was
--      broken since v0.14 because helper shipped the hash but RPC dropped
--      it). ON CONFLICT preserves any previously-stored project_hash when
--      the helper omits the key (older client compat).
--   3. Both branches of the "Ended" sweep now use the same 10-minute floor
--      (Change 10 — single helper partial scan was instantly ghost-ending
--      sessions that were just outside the snapshot window).
create or replace function public.helper_sync(
  p_device_id uuid,
  p_helper_secret text,
  p_sessions jsonb default '[]'::jsonb,
  p_alerts jsonb default '[]'::jsonb,
  p_provider_remaining jsonb default '{}'::jsonb,
  p_provider_tiers jsonb default '{}'::jsonb
)
returns jsonb as $$
declare
  v_user_id uuid;
  v_session jsonb;
  v_alert jsonb;
  v_provider text;
  v_remaining integer;
  v_session_count integer := 0;
  v_alert_count integer := 0;
  v_synced_ids text[] := '{}';
begin
  -- Authenticate via device secret (compare SHA-256 hash).
  select user_id into v_user_id
  from public.devices where id = p_device_id and helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');

  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  -- Serialise concurrent syncs from the same device. Without this lock,
  -- two helper instances (e.g. LoginItem + Xcode debug) racing the
  -- "end missing sessions" sweep would partially mark each other's
  -- sessions Ended. Lock releases at xact end. Cost: a few µs per call.
  perform pg_advisory_xact_lock(hashtextextended(p_device_id::text, 0));

  -- Guard against oversized payloads (DoS prevention).
  if jsonb_array_length(p_sessions) > 500 then
    raise exception 'Too many sessions (max 500)';
  end if;
  if jsonb_array_length(p_alerts) > 500 then
    raise exception 'Too many alerts (max 500)';
  end if;

  update public.devices set status = 'Online', last_seen_at = now()
  where id = p_device_id;

  for v_session in select * from jsonb_array_elements(p_sessions) loop
    v_synced_ids := v_synced_ids || left(v_session->>'id', 128);
    insert into public.sessions (
      id, user_id, device_id, name, provider, project, status,
      total_usage, estimated_cost, requests, error_count,
      collection_confidence, project_hash,
      started_at, last_active_at, synced_at
    )
    values (
      left(v_session->>'id', 128), v_user_id, p_device_id,
      coalesce(v_session->>'name', ''), v_session->>'provider',
      coalesce(v_session->>'project', ''), coalesce(v_session->>'status', 'Running'),
      coalesce((v_session->>'total_usage')::integer, 0),
      least(greatest(coalesce((v_session->>'exact_cost')::numeric, 0), 0), 9999),
      coalesce((v_session->>'requests')::integer, 0),
      coalesce((v_session->>'error_count')::integer, 0),
      coalesce(v_session->>'collection_confidence', 'medium'),
      nullif(v_session->>'project_hash', ''),
      least(coalesce((v_session->>'started_at')::timestamptz, now()), now() + interval '10 minutes'),
      least(coalesce((v_session->>'last_active_at')::timestamptz, now()), now() + interval '10 minutes'),
      now()
    )
    on conflict (id, user_id) do update set
      name = excluded.name, status = excluded.status,
      total_usage = excluded.total_usage, estimated_cost = excluded.estimated_cost,
      requests = excluded.requests, error_count = excluded.error_count,
      collection_confidence = excluded.collection_confidence,
      -- Preserve previously-stored project_hash when the helper omitted
      -- the key (older helpers, or sessions where guessProjectRoot found
      -- no marker). nullif above + COALESCE here = "set on first sight,
      -- never overwrite with NULL afterwards".
      project_hash = coalesce(excluded.project_hash, public.sessions.project_hash),
      last_active_at = excluded.last_active_at, synced_at = now();
    v_session_count := v_session_count + 1;
  end loop;

  -- Mark sessions from this device that weren't reported in this sync
  -- as Ended, BUT only if last_active_at is older than 10 minutes. The
  -- grace window covers transient scan misses (sandbox flake, libproc
  -- jitter, crashed scan) without immediately corrupting live state.
  -- Empty-sync branch already had this floor; iter2 makes the non-empty
  -- branch use it too (Change 10).
  if coalesce(array_length(v_synced_ids, 1), 0) > 0 then
    update public.sessions set status = 'Ended'
    where device_id = p_device_id and user_id = v_user_id
      and status = 'Running' and id != all(v_synced_ids)
      and last_active_at < now() - interval '10 minutes';
  else
    update public.sessions set status = 'Ended'
    where device_id = p_device_id and user_id = v_user_id
      and status = 'Running' and last_active_at < now() - interval '10 minutes';
  end if;

  for v_alert in select * from jsonb_array_elements(p_alerts) loop
    insert into public.alerts (id, user_id, type, severity, title, message, related_project_id, related_project_name, related_session_id, related_session_name, related_provider, related_device_name, source_kind, source_id, grouping_key, suppression_key, created_at)
    values (
      left(v_alert->>'id', 128), v_user_id, v_alert->>'type',
      coalesce(v_alert->>'severity', 'Info'), v_alert->>'title',
      coalesce(v_alert->>'message', ''),
      v_alert->>'related_project_id', v_alert->>'related_project_name',
      v_alert->>'related_session_id', v_alert->>'related_session_name',
      v_alert->>'related_provider', v_alert->>'related_device_name',
      v_alert->>'source_kind', v_alert->>'source_id',
      v_alert->>'grouping_key', v_alert->>'suppression_key',
      coalesce((v_alert->>'created_at')::timestamptz, now())
    )
    on conflict (id, user_id) do update set
      severity = excluded.severity, title = excluded.title, message = excluded.message,
      source_kind = excluded.source_kind, source_id = excluded.source_id,
      grouping_key = excluded.grouping_key, suppression_key = excluded.suppression_key;
    v_alert_count := v_alert_count + 1;
  end loop;

  -- Upsert provider quotas with tier data (new) or just remaining (legacy).
  for v_provider in select * from jsonb_object_keys(p_provider_tiers) loop
    declare
      v_tier_data jsonb := p_provider_tiers -> v_provider;
    begin
      insert into public.provider_quotas (user_id, provider, remaining, quota, plan_type, reset_time, tiers, updated_at)
      values (
        v_user_id, v_provider,
        coalesce((v_tier_data->>'remaining')::integer, 0),
        (v_tier_data->>'quota')::integer,
        v_tier_data->>'plan_type',
        (v_tier_data->>'reset_time')::timestamptz,
        coalesce(v_tier_data->'tiers', '[]'::jsonb),
        now()
      )
      on conflict (user_id, provider) do update set
        remaining = excluded.remaining, quota = excluded.quota,
        plan_type = excluded.plan_type, reset_time = excluded.reset_time,
        tiers = excluded.tiers, updated_at = now();
    end;
  end loop;

  for v_provider, v_remaining in select * from jsonb_each_text(p_provider_remaining) loop
    if NOT p_provider_tiers ? v_provider then
      insert into public.provider_quotas (user_id, provider, remaining, updated_at)
      values (v_user_id, v_provider, v_remaining::integer, now())
      on conflict (user_id, provider) do update set
        remaining = excluded.remaining, updated_at = now();
    end if;
  end loop;

  return jsonb_build_object('sessions_synced', v_session_count, 'alerts_synced', v_alert_count);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ── evaluate_budget_alerts ─────────────────────────────────
-- Change 6: per-project block disabled until daily_project_metrics exists.
--
-- Why: the prior block summed `sessions.estimated_cost` (a per-session
-- LIFETIME cumulative number written by helper_sync) with a
-- `last_active_at >= week_start` filter. A session active today that
-- started 3 weeks ago contributed its entire 3-week cost to "this week",
-- repeatedly firing budget alerts on stale data.
--
-- Cost-spike block keeps running because it uses today/yesterday
-- windows over `last_active_at` that don't suffer the cross-week leak.
-- We additionally gate the existence check on `is_resolved = false`
-- (was: any row with that suppression_key) so resolving a spike alert
-- doesn't silence next day's spike (was Plan v1 finding A9).
create or replace function public.evaluate_budget_alerts()
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  -- ITER2 FOLLOW-UP (Gemini caught two more bugs in the cost-spike block):
  --
  -- 1. Same lifetime-cost flaw as the per-project block. `sessions.estimated_cost`
  --    is a per-session CUMULATIVE number, refreshed by helper_sync. A session
  --    that crossed midnight has its entire lifetime cost shift OUT of the
  --    yesterday bucket (last_active_at < current_date) and INTO the today
  --    bucket (last_active_at >= current_date) just by being touched once
  --    today. Yesterday's number gets crushed, today's gets inflated, and
  --    `today > 2 * yesterday` fires nearly every time a long session exists.
  --
  -- 2. Resolution loop. The `is_resolved = false` guard plus a date-keyed
  --    suppression_key (`costspike:<uid>:<date>`) means: user clicks Resolve
  --    on today's spike → next 30s refresh finds no UNRESOLVED row for today
  --    → re-inserts a duplicate with a new uuid. The user can never silence
  --    today's spike, only suppress it for a tiny window.
  --
  -- Both bugs share the same root cause as the per-project block: we're
  -- aggregating a column with the wrong semantics. The right fix needs
  -- daily_project_metrics (or a daily_user_cost view from
  -- daily_usage_metrics, which already buckets correctly). Until then,
  -- this RPC returns 0 for both blocks. Cost-spike alerts will not fire;
  -- the existing dashboard cost summary still shows real data.

  return jsonb_build_object('alerts_created', 0);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ── webhook fan-out queue (Change 2a) ──────────────────────
-- pg_net is required for outbound HTTP from the cron worker. Idempotent.
create extension if not exists pg_net with schema extensions;

-- Queue table. The unique partial index acts as a 60-second dedup window
-- for the (user_id, grouping_key) pair while a row is still pending —
-- this catches the rollout-period overlap where old macOS clients still
-- POST to send-webhook directly while the new trigger also enqueues.
create table if not exists public.webhook_jobs (
  id              bigserial primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  alert_id        text not null,
  alert_payload   jsonb not null,
  enqueued_at     timestamptz not null default now(),
  -- iter2 follow-up (Codex): pg_net.http_post is itself async. We need a
  -- request_id handle so a later cron pass can join net._http_response
  -- and decide whether the request actually succeeded. Without this,
  -- "processed_at = now()" right after http_post() means "queued in
  -- pg_net" not "delivered to webhook target".
  pg_net_request_id bigint,
  dispatched_at   timestamptz,
  processed_at    timestamptz,
  attempt_count   int not null default 0,
  last_error      text
);

-- Idempotent additive columns (in case the table was created by an
-- earlier migration draft without them).
alter table public.webhook_jobs add column if not exists pg_net_request_id bigint;
alter table public.webhook_jobs add column if not exists dispatched_at timestamptz;

-- Pending-job dedup: at most one un-processed job per (user, grouping_key).
-- Rapid duplicates within the worker's 30s drain window collapse here.
create unique index if not exists idx_webhook_jobs_pending_dedup
  on public.webhook_jobs (user_id, (alert_payload->>'grouping_key'))
  where processed_at is null;

-- Drain order index for the cron worker.
create index if not exists idx_webhook_jobs_pending_enqueued
  on public.webhook_jobs (enqueued_at)
  where processed_at is null;

-- RLS: only service role reads the queue. Edge functions and pg_cron
-- both run with service role; users never query webhook_jobs directly.
alter table public.webhook_jobs enable row level security;
drop policy if exists "Service role only" on public.webhook_jobs;
create policy "Service role only"
  on public.webhook_jobs for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

-- Trigger function. Runs as security definer so it can write into
-- webhook_jobs regardless of caller. Postgres `AFTER INSERT FOR EACH ROW`
-- triggers do NOT fire for the UPDATE branch of an `INSERT ... ON CONFLICT
-- DO UPDATE`, so we don't need an xmax guard — Codex's review caught that
-- the v1-plan guard was dead code.
--
-- We deliberately exclude `Test` rows so the test-webhook flow (which
-- inserts a fake AlertRecord through the JWT path) can still validate a
-- user's URL without enqueueing a real fan-out.
--
-- search_path is the minimum needed: pg_catalog for built-ins, public
-- for the table itself. extensions and net are not referenced here.
create or replace function public.alerts_enqueue_webhook()
returns trigger as $$
begin
  if NEW.type is null or NEW.type = 'Test' then
    return NEW;
  end if;
  -- Iter2 follow-up (Codex + Gemini both flagged): Postgres rejects
  -- `on conflict on constraint <partial-unique-index-name>` because a
  -- partial unique index is NOT a constraint. The right form for a
  -- partial unique index is `on conflict (cols) where <predicate>`,
  -- which Postgres matches against the index. We can't reference the
  -- jsonb expression directly in `on conflict (...)` either — Postgres
  -- requires the EXPR set match the index expression text. Easiest
  -- correct form: explicit pre-INSERT existence check; the partial
  -- unique index still protects against truly concurrent races.
  if exists (
    select 1 from public.webhook_jobs
    where user_id = NEW.user_id
      and alert_payload->>'grouping_key' is not distinct from NEW.grouping_key
      and processed_at is null
  ) then
    return NEW;
  end if;

  insert into public.webhook_jobs (user_id, alert_id, alert_payload)
  values (
    NEW.user_id, NEW.id,
    jsonb_build_object(
      'id', NEW.id, 'type', NEW.type, 'severity', NEW.severity,
      'title', NEW.title, 'message', NEW.message,
      'related_provider', NEW.related_provider,
      'related_project_name', NEW.related_project_name,
      'grouping_key', NEW.grouping_key,
      'suppression_key', NEW.suppression_key,
      'created_at', NEW.created_at
    )
  );
  return NEW;
exception
  -- A concurrent inserter beat us to the partial unique index. That IS
  -- the dedup we want — silently swallow it, no notice (it's expected).
  when unique_violation then
    return NEW;
  -- Anything else is a real failure. Don't block the alert insert
  -- (webhook delivery is best-effort), but log loudly so the failure
  -- is observable in pg logs / Supabase dashboard.
  when others then
    raise warning 'alerts_enqueue_webhook: enqueue failed for alert % (sqlstate %): %',
      NEW.id, sqlstate, sqlerrm;
    return NEW;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

drop trigger if exists alerts_webhook_enqueue on public.alerts;
create trigger alerts_webhook_enqueue
  after insert on public.alerts
  for each row execute function public.alerts_enqueue_webhook();

-- Cron worker. Runs on a schedule; drains pending jobs in two passes:
--   1. Reconcile: for jobs already dispatched (pg_net_request_id set,
--      processed_at null), look up `net._http_response` and finalize.
--      2xx → mark processed_at; non-2xx → bump attempt_count + last_error.
--   2. Dispatch: for jobs not yet dispatched (pg_net_request_id null and
--      attempt_count < 3), call `net.http_post`, capture the request_id,
--      and stamp dispatched_at.
--
-- Iter2 follow-up (Codex): the prior implementation marked processed_at
-- right after `http_post` returned, but pg_net is itself async — that
-- recorded "queued for dispatch", not "delivered". Now we read
-- net._http_response and only finalize after the actual HTTP call
-- completes. Jobs older than 5 minutes with no response are
-- considered timed out and retried.
--
-- Note: app.supabase_url and app.service_role_key are GUCs configured
-- via `alter database <db> set ...` at deploy time. When unset, the
-- worker logs a notice and returns — useful for branch DBs and tests.
create or replace function public.process_webhook_jobs()
returns void as $$
declare
  v_job record;
  v_url text;
  v_key text;
  v_request_id bigint;
begin
  v_url := current_setting('app.supabase_url', true);
  v_key := current_setting('app.service_role_key', true);
  if v_url is null or v_key is null or v_url = '' or v_key = '' then
    raise notice 'process_webhook_jobs: app.supabase_url / app.service_role_key not set; skipping';
    return;
  end if;

  -- Pass 1: reconcile dispatched jobs against net._http_response.
  -- net._http_response.status_code is null while pending, populated on
  -- completion. Status 200..299 is success; anything else is recorded
  -- and may be retried on the next pass.
  for v_job in
    select id, pg_net_request_id, attempt_count
    from public.webhook_jobs
    where processed_at is null
      and pg_net_request_id is not null
      and dispatched_at < now() - interval '2 seconds'
    order by id
    limit 200
  loop
    declare
      v_status int;
      v_body text;
    begin
      select status_code, content
      into v_status, v_body
      from net._http_response
      where id = v_job.pg_net_request_id;

      if v_status is null then
        -- Still pending in pg_net. If it's been pending >5 min, give up
        -- this attempt and let the next pass dispatch a fresh one.
        update public.webhook_jobs
          set last_error = 'pg_net response not yet available',
              -- only retry-eligible after the timeout window
              pg_net_request_id = case
                when dispatched_at < now() - interval '5 minutes'
                then null else pg_net_request_id end
          where id = v_job.id;
      elsif v_status between 200 and 299 then
        update public.webhook_jobs
          set processed_at = now(),
              last_error = null
          where id = v_job.id;
      else
        update public.webhook_jobs
          set attempt_count = attempt_count + 1,
              last_error = 'HTTP ' || v_status::text || ': ' || coalesce(left(v_body, 200), ''),
              -- clear request_id so the next pass can re-dispatch
              pg_net_request_id = null,
              dispatched_at = null
          where id = v_job.id;
      end if;
    exception when others then
      -- Reconcile failure shouldn't poison the loop. Log and move on.
      raise warning 'process_webhook_jobs reconcile (job %): %', v_job.id, sqlerrm;
    end;
  end loop;

  -- Pass 2: dispatch new jobs. enqueued_at < now() - 5s gives the
  -- alert-insert xact time to commit before the cron worker reads.
  for v_job in
    select id, user_id, alert_id, alert_payload
    from public.webhook_jobs
    where processed_at is null
      and pg_net_request_id is null
      and attempt_count < 3
      and enqueued_at < now() - interval '5 seconds'
    order by id
    limit 100
  loop
    begin
      -- iter2 follow-up (Codex bot review on PR #6): pg_net exposes
      -- its request API as `net.http_post`, not `extensions.http_post`.
      -- Calling the wrong schema raises `function does not exist`, which
      -- the EXCEPTION block then silently swallowed — no requests ever
      -- got dispatched. `net` is already in this function's search_path.
      v_request_id := net.http_post(
        url := v_url || '/functions/v1/send-webhook',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_key,
          'X-Internal-Trigger', 'alerts_dispatch_webhook'
        ),
        body := jsonb_build_object(
          'user_id', v_job.user_id,
          'alert', v_job.alert_payload
        ),
        timeout_milliseconds := 5000
      );
      update public.webhook_jobs
        set pg_net_request_id = v_request_id,
            dispatched_at = now(),
            attempt_count = attempt_count + 1,
            last_error = null
        where id = v_job.id;
    exception when others then
      update public.webhook_jobs
        set attempt_count = attempt_count + 1,
            last_error = 'http_post failed: ' || sqlerrm
        where id = v_job.id;
    end;
  end loop;
end;
$$ language plpgsql security definer set search_path = pg_catalog, extensions, public, net;

-- pg_cron schedule. Iter2 follow-up (Codex): switched from 6-field cron
-- (`*/30 * * * * *`) to pg_cron's interval form (`30 seconds`), which is
-- broadly supported across pg_cron 1.5+ and avoids the seconds-resolution
-- code path that some Supabase configurations don't enable.
--
-- Idempotent: unschedule any prior entry by jobname before scheduling.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid)
      from cron.job
      where jobname = 'process_webhook_jobs';
    perform cron.schedule(
      'process_webhook_jobs',
      '30 seconds',
      'select public.process_webhook_jobs()'
    );
  else
    raise notice 'pg_cron extension missing — skipping process_webhook_jobs schedule. Install via dashboard.';
  end if;
end $$;
