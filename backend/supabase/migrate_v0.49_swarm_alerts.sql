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
-- 3. New `swarm_alert_eval` pg_cron @ '* * * * *' (every minute — the
--    plan's "evaluated in the async webhook_jobs worker, not the read
--    path"). No collision with existing cron slots. (Std 5-field cron,
--    not '1 minute': this pg_cron rejects that — see schedule note.)
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

-- Supporting index (Gemini R1 MINOR). The 1-min evaluator filters
-- public.remote_swarms by `updated_at` with NO user_id predicate, so
-- v0.48's idx_remote_swarms_user (user_id, updated_at desc) can't serve
-- it. A dedicated updated_at index keeps the recurring scan index-only.
-- Plain (non-CONCURRENTLY) is correct here: remote_swarms is empty at
-- apply time (feature dark) so the build is instant and lock-free, and
-- the file's no-CONCURRENTLY ⇒ no `-- supabase: no-transaction` invariant
-- holds. `if not exists` keeps the migration re-runnable.
create index if not exists idx_remote_swarms_updated_at
  on public.remote_swarms(updated_at);

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
      -- Defensive numeric extraction (Gemini R1 BLOCKER). A bare
      -- (v_elem->>'k')::int/::numeric on a present-but-NON-numeric helper
      -- value (e.g. "blocked":"x" / "" / true) raises 22P02 and aborts
      -- the WHOLE cron txn — silently halting swarm alerting for EVERY
      -- user until the bad payload ages out (or forever if a device keeps
      -- re-sending it). coalesce() only guards SQL NULL (missing key),
      -- NOT a bad scalar. So: cast ONLY when the JSON value really is a
      -- number (missing/null/string/bool → 0, fail-closed = no false
      -- alert), and numeric-clamp before ::int so a bug value can't
      -- overflow it (round(huge/60)::int → 22003, same txn-abort class).
      v_blocked := case
        when jsonb_typeof(v_elem->'blocked') = 'number'
          then least(greatest(floor((v_elem->>'blocked')::numeric), 0), 100000)::int
        else 0 end;
      v_age := case
        when jsonb_typeof(v_elem->'oldest_blocked_age_s') = 'number'
          then least(greatest((v_elem->>'oldest_blocked_age_s')::numeric, 0), 2592000)
        else 0 end;

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
          -- is_resolved explicit (Gemini R2 MINOR): the table default is
          -- already `false` (NOT NULL), so this changes no behavior — but
          -- writing it makes the hysteresis `and is_resolved = false`
          -- self-evidently correct and immune to any future change of the
          -- column default.
          insert into public.alerts (
            id, user_id, type, severity, title, message,
            related_provider, suppression_key, grouping_key, source_kind,
            is_resolved
          ) values (
            gen_random_uuid()::text, v_row.user_id,
            'Swarm Agent Blocked', 'Warning',
            'Swarm ' || v_handle || ': agent blocked',
            v_blocked || ' agent(s) in ' || v_handle ||
              ' blocked > 5 min (oldest ~' ||
              round(v_age / 60.0)::int || ' min). Approve from the app.',
            v_prov, v_skey, v_skey, 'swarm',
            false
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
-- Every minute — well under the 5-min threshold, no slot collision.
-- NOTE: this Supabase pg_cron only accepts standard 5-field cron OR an
-- interval string of the form '[1-59] seconds' — NOT '1 minute' (it
-- raises 22023 "invalid schedule"; confirmed live 2026-05-17, the exact
-- case Gemini R1 MINOR #3 flagged). The existing 30s jobs work because
-- they use the *seconds* interval form, which does not generalize to
-- minutes. '* * * * *' is the correct every-minute schedule.
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
      '* * * * *',
      $cron$select public._evaluate_swarm_alerts_internal();$cron$
    );
  else
    raise notice 'pg_cron extension missing — skipping swarm_alert_eval schedule.';
  end if;
end $$;
