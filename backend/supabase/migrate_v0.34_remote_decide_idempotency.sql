-- migrate_v0.34_remote_decide_idempotency.sql
-- iter20 (2026-04-29) — Remote Approvals concurrent-decide hardening.
--
-- Background:
-- The v0.27 `remote_app_decide_permission` SECURITY DEFINER function checks
-- `v_status = 'pending'`, then INSERTs into `remote_permission_decisions`,
-- then UPDATEs `remote_permission_requests`. Between the status check and
-- the INSERT there is a TOCTOU window: two concurrent calls (e.g. the same
-- user approving from two iPhone Pro instances of the iOS app, or an
-- accidental double-tap that races faster than the iOS optimistic-remove)
-- can both pass the check while the row is still 'pending'. Both reach the
-- INSERT, where `remote_permission_decisions(request_id)` UNIQUE rejects
-- the second one with an unhandled `23505` constraint violation. The first
-- decision lands correctly; the second caller receives a raw Postgres error
-- message rather than a graceful "Request already decided" exception, and
-- (depending on PL/pgSQL transaction state) the subsequent UPDATE in that
-- caller's transaction is skipped without a clean rollback signal to the
-- client.
--
-- Per iter20 review (consolidating Codex + independent review):
--   - This is not a P0/P1 — the data invariant is preserved by the UNIQUE
--     constraint and the first decision lands cleanly.
--   - The user-facing impact is a confusing 500-style error on the second
--     device instead of a "Request already decided" message that a future
--     client could surface gracefully.
--   - Worth fixing in a small standalone migration before any release that
--     emphasizes Remote Approvals.
--
-- Fix:
--   1. Replace the bare INSERT with `INSERT ... ON CONFLICT (request_id)
--      DO NOTHING RETURNING id INTO v_decision_id`. This is atomic and
--      idempotent: the second concurrent caller will see `v_decision_id IS
--      NULL` and can branch on that.
--   2. If `v_decision_id IS NULL`, raise `'Request already decided'` —
--      same human-readable shape as the existing pre-INSERT check at
--      line 453 of v0.27. Clients already know how to surface this string.
--   3. Only run the UPDATE on `remote_permission_requests` when the INSERT
--      actually succeeded (i.e. v_decision_id IS NOT NULL). Without this
--      guard, the second caller would silently bump `decided_at` to a
--      later timestamp without owning the underlying decision row.
--
-- Compatibility:
--   - Function signature unchanged: same args, same JSONB return on success.
--   - Auth / expiry / pending checks unchanged.
--   - Codex `alwaysSession` downgrade unchanged.
--   - SECURITY DEFINER + search_path unchanged.
--   - RLS policies unchanged.
--   - Append-only: this file does not edit prior migrations.

create or replace function public.remote_app_decide_permission(
  p_request_id uuid,
  p_decision text,
  p_scope text default 'once',
  p_decided_by_device_id uuid default null
) returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_provider text;
  v_status text;
  v_expires timestamptz;
  v_decision_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    raise exception 'Remote Control is disabled';
  end if;
  if p_decision not in ('approve', 'deny') then
    raise exception 'Invalid decision: %', p_decision;
  end if;
  if p_scope not in ('once', 'alwaysSession') then
    raise exception 'Invalid scope: %', p_scope;
  end if;

  select provider, status, expires_at into v_provider, v_status, v_expires
  from public.remote_permission_requests
  where id = p_request_id and user_id = v_user_id;

  if v_provider is null then
    raise exception 'Permission request not found';
  end if;

  -- v0.26-iter2: don't allow approving/denying a request that has already
  -- aged out. Mark expired, then refuse the decision.
  if v_status = 'pending' and v_expires < now() then
    update public.remote_permission_requests
    set status = 'expired'
    where id = p_request_id;
    raise exception 'Request expired';
  end if;

  -- Pre-INSERT happy-path check: same as v0.27. The INSERT below carries
  -- the actual race-safe enforcement, but this branch surfaces the
  -- already-decided case earlier when the second caller's transaction
  -- arrives well after the first one has landed and the SELECT above
  -- saw the post-decision status.
  if v_status <> 'pending' then
    raise exception 'Request already decided (%): cannot re-decide', v_status;
  end if;

  -- Codex MVP: alwaysSession not supported (Codex updatedPermissions is not a
  -- usable capability yet). Force 'once' so a stale UI cannot accidentally
  -- promise a scope the helper can't honor.
  if v_provider = 'codex' and p_scope = 'alwaysSession' then
    p_scope := 'once';
  end if;

  -- iter20: race-safe INSERT. Two concurrent calls that both saw
  -- `v_status = 'pending'` would previously both fall through to a bare
  -- INSERT and the second would raise an unhandled UNIQUE constraint
  -- violation on `remote_permission_decisions(request_id)`. ON CONFLICT
  -- DO NOTHING RETURNING id leaves `v_decision_id` NULL on the loser of
  -- the race; we branch on that to raise the same human-readable
  -- 'Request already decided' exception that the pre-INSERT check above
  -- raises for the non-racing case. Clients see one consistent error
  -- shape regardless of timing.
  insert into public.remote_permission_decisions (
    request_id, user_id, decision, scope, decided_by_device_id
  ) values (
    p_request_id, v_user_id, p_decision, p_scope, p_decided_by_device_id
  )
  on conflict (request_id) do nothing
  returning id into v_decision_id;

  if v_decision_id is null then
    -- Concurrent decide won the race. Re-read the now-final status so
    -- the error message is informative.
    select status into v_status
    from public.remote_permission_requests
    where id = p_request_id;
    raise exception 'Request already decided (%): cannot re-decide',
      coalesce(v_status, 'unknown');
  end if;

  -- Only run the status UPDATE when this caller actually owns the
  -- decision row. Without this guard, a losing-race caller would still
  -- bump `decided_at` to its own `now()` after the winner's update.
  update public.remote_permission_requests
  set status = case when p_decision = 'approve' then 'approved' else 'denied' end,
      decided_at = now()
  where id = p_request_id;

  return jsonb_build_object(
    'request_id', p_request_id,
    'decision', p_decision,
    'scope', p_scope
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;
