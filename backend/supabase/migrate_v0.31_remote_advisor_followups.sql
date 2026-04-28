-- ============================================================
-- v0.31 — Remote Agent Sessions advisor follow-ups
-- Date: 2026-04-29
--
-- Post-deploy Supabase advisor (security + performance) flagged three
-- categories of fixable issues on the v0.26-v0.30 surface. None are
-- correctness bugs; all are tightening / optimisation:
--
--   1. SECURITY DEFINER internal helpers are still EXECUTABLE by
--      anon / authenticated by default (PostgREST exposes them at
--      /rest/v1/rpc/<fn>). v0.28 already REVOKE'd
--      `_cleanup_remote_retention_internal`; the other internal-only
--      helpers were not.
--
--   2. RLS policies use `auth.uid() = user_id` directly. Postgres
--      re-evaluates auth.uid() per row inside the policy. Wrapping
--      the call in `(select auth.uid())` lets the planner cache it
--      once per query. Real perf win as the tables grow.
--
--   3. Four foreign keys had no index. Cascade DELETEs (e.g. profile
--      delete cascading to remote_*) and FK-aware joins both pay a seq
--      scan without the index. Trivial to add.
--
-- The pg_graphql anon/authenticated SELECT warnings on remote_* tables
-- are NOT addressed here — RLS already prevents data access, schema-
-- level discoverability matches every other table in the project, and
-- revoking SELECT just on the new tables would be inconsistent.
--
-- Idempotent: safe to re-run.
-- ============================================================

-- ── 1. REVOKE EXECUTE on internal-only helpers ────────────────
-- Service-role-gated functions are still flagged because GRANT/REVOKE
-- doesn't apply to service_role (it bypasses), but explicit REVOKE
-- silences the advisor and enforces "anon/authenticated cannot even
-- *call* this" rather than relying on the function body's own gate.
revoke all on function public._remote_authenticate_helper_gated(uuid, text)
  from PUBLIC, authenticated, anon;

revoke all on function public._remote_control_enabled_for_caller()
  from PUBLIC, authenticated, anon;

revoke all on function public.cleanup_remote_retention_data(integer, integer, integer, integer, integer)
  from PUBLIC, authenticated, anon;


-- ── 2. RLS policies wrap auth.uid() in (select ...) ───────────
-- Per Supabase lint 0003 (auth_rls_initplan): re-evaluating auth.uid()
-- for every row is wasteful; (select auth.uid()) caches it once per
-- query. The RLS check is identical, just with a planner-friendly shape.

drop policy if exists "Users can read own remote sessions" on public.remote_sessions;
create policy "Users can read own remote sessions"
  on public.remote_sessions for select using ((select auth.uid()) = user_id);

drop policy if exists "Users can delete own remote sessions" on public.remote_sessions;
create policy "Users can delete own remote sessions"
  on public.remote_sessions for delete using ((select auth.uid()) = user_id);

drop policy if exists "Users can read own session events" on public.remote_session_events;
create policy "Users can read own session events"
  on public.remote_session_events for select using ((select auth.uid()) = user_id);

drop policy if exists "Users can read own commands" on public.remote_session_commands;
create policy "Users can read own commands"
  on public.remote_session_commands for select using ((select auth.uid()) = user_id);

drop policy if exists "Users can read own permission requests" on public.remote_permission_requests;
create policy "Users can read own permission requests"
  on public.remote_permission_requests for select using ((select auth.uid()) = user_id);

drop policy if exists "Users can read own decisions" on public.remote_permission_decisions;
create policy "Users can read own decisions"
  on public.remote_permission_decisions for select using ((select auth.uid()) = user_id);


-- ── 3. Add missing FK indexes ─────────────────────────────────
-- All four FKs back-reference parent tables. Without the index,
-- DELETE FROM parent triggers a seq scan on the child to enforce
-- cascade. Trivial cost to add; matters for retention-cron runs and
-- profile-delete cascades.

create index if not exists idx_remote_permission_decisions_user_id
  on public.remote_permission_decisions(user_id);

create index if not exists idx_remote_permission_requests_session_id
  on public.remote_permission_requests(session_id);

create index if not exists idx_remote_session_commands_user_id
  on public.remote_session_commands(user_id);

create index if not exists idx_remote_session_events_device_id
  on public.remote_session_events(device_id);
