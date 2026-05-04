-- ============================================================
-- v0.40 — Hotfix: remote_helper_pull_commands top-level CTE
-- Date: 2026-05-04
--
-- Fixes a runtime PostgreSQL error 0A000 ("WITH clause containing a
-- data-modifying statement must be at the top level") that has been
-- present since v0.26 and re-emitted by v0.27. The original body
-- wrapped a data-modifying CTE inside a SELECT subquery used as the
-- argument to coalesce(...) inside the RETURN expression:
--
--   return coalesce(
--     (with picked as (update ... returning ...) select jsonb_agg(...) from picked),
--     '[]'::jsonb
--   );
--
-- PostgreSQL rejects this pattern at runtime: data-modifying CTEs
-- (UPDATE/INSERT/DELETE) must appear at the top level of a SQL
-- statement, not nested inside a subquery or expression. CREATE
-- FUNCTION succeeded because plpgsql validates bodies lazily on first
-- call; the bug only fired when a helper actually invoked the RPC.
--
-- Symptom: PR #10's helper daemon (running with DEBUG logs) emits
--   pull_commands skipped: Supabase error 400:
--   {"code":"0A000","message":"WITH clause containing a
--    data-modifying statement must be at the top level"}
-- every tick (~1/sec), so commands stay in `pending` forever.
--
-- Fix: move the WITH to the top of a SELECT … INTO statement inside
-- the plpgsql body, then RETURN the captured value. Semantics are
-- byte-identical for any well-formed input — same auth gate, clamp,
-- advisory lock, FOR UPDATE SKIP LOCKED, ORDER BY created_at ASC,
-- LIMIT v_max, returned JSON keys.
--
-- CREATE OR REPLACE preserves grants, so no GRANT/REVOKE is needed
-- here; the v0.26 grants (anon/authenticated/service_role EXECUTE)
-- carry forward unchanged.
--
-- Idempotent: safe to re-run.
-- ============================================================

create or replace function public.remote_helper_pull_commands(
  p_device_id uuid,
  p_helper_secret text,
  p_max integer default 10
) returns jsonb as $$
declare
  v_user_id uuid;
  v_max integer;
  v_result jsonb;
begin
  v_user_id := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);
  if v_user_id is null then
    raise exception 'Device not found or unauthorized';
  end if;

  v_max := least(greatest(coalesce(p_max, 10), 1), 50);

  perform pg_advisory_xact_lock(hashtextextended(p_device_id::text, 0));

  -- Top-level CTE: WITH ... SELECT ... INTO is a single statement, so
  -- the data-modifying UPDATE inside `picked` is at the top level
  -- as PostgreSQL requires.
  with picked as (
    update public.remote_session_commands
    set status = 'delivered', picked_up_at = now()
    where id in (
      select id from public.remote_session_commands
      where device_id = p_device_id
        and user_id = v_user_id
        and status = 'pending'
      order by created_at asc
      limit v_max
      for update skip locked
    )
    returning id, session_id, kind, payload, created_at
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',         id,
        'session_id', session_id,
        'kind',       kind,
        'payload',    payload,
        'created_at', created_at
      )
    ),
    '[]'::jsonb
  )
  into v_result
  from picked;

  return v_result;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;


-- ── Manual verification (run after applying):
--   select pg_get_functiondef('public.remote_helper_pull_commands'::regproc);
--   -- Confirm the body now has WITH ... SELECT ... INTO at top level
--   -- (no `return coalesce((with …) …)` wrapper).
