-- ============================================================
-- v0.29 — Remote Control gate tightening (post-Gemini review)
-- Date: 2026-04-28
--
-- Two follow-ups from the v0.26-v0.28 code review (Gemini 3.1 Pro):
--
--   1. v0.26 created `public._remote_authenticate_helper(uuid, text)` as the
--      original (un-gated) auth helper. v0.27 introduced the gated variant
--      `_remote_authenticate_helper_gated` and re-emitted every helper RPC
--      to use it, but it left the un-gated variant defined in `public`.
--      Even though no current RPC calls it, it remains callable as a
--      SECURITY DEFINER function — a stale client or a future copy-paste
--      could re-introduce the bypass. Drop it.
--
--   2. `remote_app_list_pending_approvals` was intentionally left RLS-only
--      in v0.26 / v0.27 — the argument was that listing zero pending rows
--      naturally falls out of the helper-side gate (helper can't insert
--      new rows when off). But the cross-device window where Device A
--      toggles Remote Control off while Device B still has a stale UI
--      cache means Device B can still pull pending rows that pre-date the
--      toggle. Cheap to also gate the read path so the toggle is uniformly
--      enforced from both ends.
--
-- Idempotent: safe to re-run.
-- ============================================================

-- 1. Drop the legacy un-gated helper. v0.27 + v0.29 only use the gated form.
drop function if exists public._remote_authenticate_helper(uuid, text);


-- 2. Re-emit list_pending_approvals with the same gate the write RPCs use.
--    Returning '[]' (rather than raising) when off so the UI still gets a
--    clean empty response instead of an error banner.
create or replace function public.remote_app_list_pending_approvals()
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  -- Server-side gate. Mirrors the write-side check in v0.27. When Remote
  -- Control is off we hide pending rows even if some still exist server-
  -- side from before the user toggled off — the UI client-side guard
  -- already does this, but doing it server-side too closes the cross-
  -- device race (Device A flips off, Device B fetches before its settings
  -- snapshot refreshes).
  if not public._remote_control_enabled_for_caller() then
    return '[]'::jsonb;
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', id,
          'session_id', session_id,
          'device_id', device_id,
          'provider', provider,
          'tool_name', tool_name,
          'summary', summary,
          'risk', risk,
          'status', status,
          'created_at', created_at,
          'expires_at', expires_at
        )
        order by created_at desc
      )
      from public.remote_permission_requests
      where user_id = v_user_id and status = 'pending' and expires_at > now()
    ),
    '[]'::jsonb
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;
