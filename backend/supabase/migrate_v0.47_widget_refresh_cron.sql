-- ============================================================
-- v0.47 — Hourly silent-push pg_cron job for iOS widget refresh (F11)
-- Date: 2026-05-15 (v1.21 long-tail)
--
-- Goal:
-- Wake the iOS widget extension every hour via APNs silent push so it can
-- call WidgetCenter.shared.reloadAllTimelines() with fresh data even when
-- the user hasn't opened the host app. This is the primary path described
-- in D2 of the v1.21 plan — BGAppRefreshTask is unreliable in practice;
-- silent push is the only mechanism iOS will honour for low-engagement
-- apps.
--
-- Architecture:
-- 1. pg_cron fires `public.process_widget_refresh()` hourly.
-- 2. That function calls the `send-widget-refresh` edge function via
--    `net.http_post` using vault-stored credentials. Reuses the same
--    `app_supabase_url` + `app_service_role_key` vault keys established
--    by v0.32 for `send-approval-push`.
-- 3. The edge function itself queries `daily_usage_metrics` for users
--    active in the last 7 days, fans out APNs `content-available: 1`
--    silent pushes to their `app_push_tokens`, prunes 410 BadDeviceToken
--    rows, and returns a summary. We cap at 200 user_ids per tick to
--    keep the function within the edge runtime's wall-clock budget.
--
-- Privacy:
-- No user-facing content is included in the APNs payload — strictly
-- `{"aps":{"content-available":1}}`. iOS extension wakes, calls back to
-- Supabase via authenticated REST, and re-renders.
--
-- Failure isolation:
-- The cron function swallows http_post errors via a `begin ... exception
-- when others` guard so a single bad invocation doesn't terminate the
-- cron loop. Pattern is identical to v0.32's process_app_push_jobs.
--
-- Idempotency:
-- `cron.unschedule(...)` first, then `cron.schedule(...)` — safe to
-- re-run. CREATE OR REPLACE FUNCTION preserves grants.
-- ============================================================

create or replace function public.process_widget_refresh()
returns void as $$
declare
  v_url text;
  v_key text;
  v_request_id bigint;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'app_supabase_url';
  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'app_service_role_key';

  if v_url is null or v_key is null or v_url = '' or v_key = '' then
    raise notice 'process_widget_refresh: vault secrets not set; skipping';
    return;
  end if;

  begin
    v_request_id := net.http_post(
      url := v_url || '/functions/v1/send-widget-refresh',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_key,
        'X-Internal-Trigger', 'process_widget_refresh_cron'
      ),
      body := '{}'::jsonb,
      -- 60s — silent-push fan-out to ~200 tokens should comfortably fit
      -- in the edge function's wall-clock budget.
      timeout_milliseconds := 60000
    );
  exception when others then
    raise warning 'process_widget_refresh: http_post failed: %', sqlerrm;
  end;
end;
$$ language plpgsql security definer
   set search_path = pg_catalog, extensions, public, net;

revoke all on function public.process_widget_refresh()
  from PUBLIC, anon, authenticated;

-- ── pg_cron schedule: hourly at minute 13 ───────────────────────
-- Pick :13 to avoid colliding with v0.21/v0.22's nightly cleanup at
-- :03/:07 and any other on-the-hour crons that exist.
do $$
begin
  perform cron.unschedule('widget_refresh_hourly');
exception when others then
  null;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'widget_refresh_hourly',
      '13 * * * *',
      $cron$select public.process_widget_refresh()$cron$
    );
  else
    raise notice 'pg_cron extension missing — skipping widget_refresh_hourly schedule.';
  end if;
end $$;
