-- ============================================================
-- v0.49 — Swarm-level alerts: "agent blocked > 5 min" (S6)
-- Date: 2026-05-17 (v1.22.0 P0 "Mission Control for the agent swarm")
--
-- Goal:
-- Fire a user alert (and, via the existing webhook pipeline, an
-- optional Slack/Discord message) when an agent in a swarm has been
-- blocked on an approval for more than 5 minutes — evaluated in an
-- async cron worker, NOT on any read path, with >60s hysteresis so it
-- can't flap at the heartbeat boundary.
--
-- Architecture:
-- 1. `_evaluate_swarm_alerts_internal()` — cron-driven evaluator.
--    Scans `remote_swarms` rows whose heartbeat is fresh
--    (`updated_at > now()-interval '90 seconds'` — RK8: never alert on
--    a ghost/stale device, matches the v0.48 stale threshold), unrolls
--    the `swarms` jsonb, and for any swarm with `blocked > 0` AND
--    `oldest_blocked_age_s > 300` inserts ONE `public.alerts` row.
-- 2. The existing `alerts_enqueue_webhook` AFTER-INSERT trigger →
--    `webhook_jobs` → the existing 30s `process_webhook_jobs` cron →
--    `send-webhook` edge fn does Slack/Discord delivery automatically.
--    NO new webhook table / column / edge function (v0.25 pipeline).
-- 3. New `swarm_alert_eval` pg_cron @ 1 minute (async worker — the
--    plan's "evaluated in the async webhook_jobs worker, not the read
--    path"). No collision with existing cron slots.
--
-- Hysteresis (>60s — PLAN_v1.22 §2/R1-A5):
-- A new alert fires only if there is NO unresolved alert for the same
-- `suppression_key` AND no alert for that key was created in the last
-- 60s. So once an alert fires it won't re-fire for >60s even if the
-- helper heartbeat blips the swarm in/out of the blocked state — the
-- anti-flap window. There is no prior server-side hysteresis precedent
-- (existing alerts are pure week/day suppression-key existence gates);
-- this is the new pattern.
--
-- Privacy (RK7): the alert title/message uses ONLY the opaque
-- `handle` (`swarm-6hex`) the helper uploads — never a repo path or
-- branch name (the helper never sends those; v0.48).
--
-- SCOPE NOTE — blocked-age only in v1.22.0:
-- The plan also lists a "swarm burn > X tokens/min" alert. The helper
-- swarm heartbeat (S1b) deliberately carries NO token/burn field
-- (P0 ships zero `$` — R2-5, user-confirmed; tokens are the P1 Cost
-- Intelligence headline). The burn alert is therefore explicitly
-- DEFERRED to v1.22.1 (when C1 lands a token signal), not silently
-- dropped. v0.49 ships the blocked-age alert only.
--
-- FOLLOW-UP (not required for delivery): adding a `swarm_blocked`
-- slug to `send-webhook`'s TYPE_ALIASES would let users filter swarm
-- alerts with a dedicated chip. Delivery already works without it —
-- the default `webhook_event_filter` is null (= all types delivered).
--
-- Return type `void` (NOT RETURNS TABLE) ⇒ CREATE OR REPLACE needs no
-- DROP and preserves grants. No CONCURRENTLY ⇒ no `-- supabase:
-- no-transaction` directive (runner wraps in a txn).
--
-- Idempotency:
-- `CREATE OR REPLACE FUNCTION`; `cron.unschedule` (try/catch) then
-- guarded `cron.schedule` — safe to re-run.
-- ============================================================

create or replace function public._evaluate_swarm_alerts_internal()
returns void as $$
declare
  v_row    record;
  v_elem   jsonb;
  v_skey   text;
  v_handle text;
  v_blocked int;
  v_age    numeric;
  v_prov   text;
begin
  for v_row in
    select user_id, swarms
    from public.remote_swarms
    where updated_at > now() - interval '90 seconds'   -- RK8: skip ghosts
  loop
    if jsonb_typeof(v_row.swarms) <> 'array' then
      continue;
    end if;

    for v_elem in select * from jsonb_array_elements(v_row.swarms)
    loop
      v_blocked := coalesce((v_elem->>'blocked')::int, 0);
      v_age     := coalesce((v_elem->>'oldest_blocked_age_s')::numeric, 0);

      -- Threshold: at least one agent blocked > 5 minutes.
      if v_blocked > 0 and v_age > 300 then
        v_handle := coalesce(v_elem->>'handle', 'swarm');
        v_skey   := 'swarm_blocked:' || v_row.user_id::text || ':'
                    || coalesce(v_elem->>'swarm_key', v_handle);

        -- First provider (if any) for nicer webhook context; opaque,
        -- not sensitive.
        v_prov := nullif(
          coalesce(v_elem->'providers'->>0, ''), '');

        -- >60s hysteresis (PLAN R1-A5): don't fire if there's an
        -- unresolved alert for this swarm, and don't re-fire within
        -- 60s of the last one for this swarm (anti-flap window).
        if not exists (
              select 1 from public.alerts
              where user_id = v_row.user_id
                and suppression_key = v_skey
                and is_resolved = false
           )
           and not exists (
              select 1 from public.alerts
              where user_id = v_row.user_id
                and suppression_key = v_skey
                and created_at > now() - interval '60 seconds'
           )
        then
          insert into public.alerts (
            id, user_id, type, severity, title, message,
            related_provider, suppression_key, grouping_key, source_kind
          ) values (
            gen_random_uuid()::text, v_row.user_id,
            'Swarm Agent Blocked', 'Warning',
            'Swarm ' || v_handle || ': agent blocked',
            v_blocked || ' agent(s) in ' || v_handle ||
              ' blocked > 5 min (oldest ~' ||
              round(v_age / 60.0)::int || ' min). Approve from the app.',
            v_prov, v_skey, v_skey, 'swarm'
          );
        end if;
      end if;
    end loop;
  end loop;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Internal: cron runs as the postgres superuser (bypasses REVOKE);
-- no caller should reach this directly.
revoke all on function public._evaluate_swarm_alerts_internal()
  from PUBLIC, authenticated, anon;

-- Async evaluator cron (the plan's "async worker, not the read path").
-- 1-minute cadence — well under the 5-min threshold, no slot collision.
do $$
begin
  perform cron.unschedule('swarm_alert_eval');
exception when others then
  null;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'swarm_alert_eval',
      '1 minute',
      $cron$select public._evaluate_swarm_alerts_internal();$cron$
    );
  else
    raise notice 'pg_cron extension missing — skipping swarm_alert_eval schedule.';
  end if;
end $$;
