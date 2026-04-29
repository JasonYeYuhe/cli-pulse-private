-- ============================================================
-- v0.33 — Push notification advisor follow-ups
-- Date: 2026-04-29
--
-- Post-deploy Supabase advisor (security + performance) on v0.32 flagged
-- three actionable items. None are correctness bugs; all are tightening:
--
--   1. `public.remote_request_after_insert_push()` is the trigger function
--      called by `AFTER INSERT remote_permission_requests`. v0.32 left it
--      executable by anon and authenticated via `/rest/v1/rpc/...`.
--      Calling it directly does no harm (it inspects NEW which is null in
--      that context, so it just returns), but the RPC surface should not
--      include trigger functions. REVOKE.
--
--   2. `app_push_jobs.Service role only on app_push_jobs` policy uses
--      `auth.role()` directly, which Postgres re-evaluates per row. Wrap
--      in `(select auth.role())` so the planner caches once per query.
--      Same fix v0.31 applied to remote_* policies.
--
--   3. `app_push_jobs.user_id` is a foreign key without a covering index.
--      Cascade DELETEs (e.g. profile delete cascading to push jobs) would
--      seq-scan child rows. Trivial to add.
--
-- Intentional non-changes (advisor flagged but correct as-is):
--
--   * `app_push_tokens` and `app_push_jobs` GraphQL anon/authenticated SELECT
--     warnings — RLS already protects rows. Matches the codebase-wide
--     pattern (every public table is GraphQL-discoverable; data access is
--     RLS-gated). A single-table revoke would be inconsistent.
--
--   * `register_app_push_token` / `unregister_app_push_token` callable by
--     authenticated — by design. The iOS app needs to call these via JWT.
--
-- Idempotent: safe to re-run.
-- ============================================================

-- 1. Revoke direct RPC access to the trigger function. It's only ever
--    invoked by the trigger machinery, never from PostgREST.
revoke all on function public.remote_request_after_insert_push()
  from PUBLIC, authenticated, anon;

-- 2. Re-emit the app_push_jobs RLS policy with (select auth.role()) so the
--    planner caches the expression once per query instead of re-evaluating
--    per row.
drop policy if exists "Service role only on app_push_jobs" on public.app_push_jobs;
create policy "Service role only on app_push_jobs"
  on public.app_push_jobs for all
  using ((select auth.role()) = 'service_role')
  with check ((select auth.role()) = 'service_role');

-- 3. Add the missing FK-covering index. user_id is the only outgoing FK
--    on app_push_jobs (the request_id FK already has the unique partial
--    index idx_app_push_jobs_pending_dedup).
create index if not exists idx_app_push_jobs_user_id
  on public.app_push_jobs(user_id);
