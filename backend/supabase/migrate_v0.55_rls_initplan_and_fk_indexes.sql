-- ============================================================
-- v0.55 — RLS init-plan perf + unindexed FK indexes (v1.27 Workstream A-safe).
-- Reviewed by Gemini 3.1 Pro + Codex (2026-05-30) — blessed as safe-now/additive.
--
-- (A) auth_rls_initplan: 21 policies call bare auth.uid()/auth.role(), which
--     Postgres re-evaluates PER ROW. Wrapping in a scalar subquery
--     `(select auth.uid())` lets the planner evaluate it ONCE per statement
--     (init-plan). SEMANTICALLY IDENTICAL — pure query-plan optimization, no
--     access change. Predicates below are the EXACT current pg_policies quals
--     (verified live 2026-05-30); only the function call is wrapped. The 18
--     remote_* / app_push_* policies were already wrapped and are untouched.
--
-- (B) unindexed_foreign_keys: 2 genuine unindexed FKs (pairing_codes.user_id,
--     teams.owner_id). The advisor's 3rd (remote_swarms.device_id) is already
--     covered by the composite PK — false positive, skipped.
--
-- NOT INCLUDED (per review): GraphQL anon revoke + pairing/promo policies are
-- DEFERRED until v1.26 build 67 clears ASC; the 7 "unused" index drops are
-- DROPPED from scope entirely (idx_scan=0 alone is unsafe — they back
-- retention/rate-limit DELETEs + may serve crons off the stat window).
-- ============================================================

-- (A) RLS init-plan wrapping ---------------------------------------------------

ALTER POLICY "Users can manage own alerts" ON public.alerts
  USING ((select auth.uid()) = user_id);

ALTER POLICY "commits_owner" ON public.commits
  USING (user_id = (select auth.uid()));

ALTER POLICY "Users own metrics" ON public.daily_usage_metrics
  USING ((select auth.uid()) = user_id);

ALTER POLICY "Users can manage own devices" ON public.devices
  USING ((select auth.uid()) = user_id);

ALTER POLICY "Users can manage own pairing codes" ON public.pairing_codes
  USING ((select auth.uid()) = user_id);

ALTER POLICY "Users can insert own profile" ON public.profiles
  WITH CHECK ((select auth.uid()) = id);

ALTER POLICY "Users can update own profile" ON public.profiles
  USING ((select auth.uid()) = id);

ALTER POLICY "Users can view own profile" ON public.profiles
  USING ((select auth.uid()) = id);

ALTER POLICY "Users can manage own quotas" ON public.provider_quotas
  USING ((select auth.uid()) = user_id);

ALTER POLICY "session_commit_links_owner" ON public.session_commit_links
  USING (EXISTS ( SELECT 1
     FROM commits c
    WHERE ((c.id = session_commit_links.commit_id) AND (c.user_id = (select auth.uid())))));

ALTER POLICY "Users can manage own sessions" ON public.sessions
  USING ((select auth.uid()) = user_id);

ALTER POLICY "Users can view own subscription" ON public.subscriptions
  USING ((select auth.uid()) = user_id);

ALTER POLICY "Team owner/admin can manage invites" ON public.team_invites
  USING (team_id IN ( SELECT team_members.team_id
     FROM team_members
    WHERE ((team_members.user_id = (select auth.uid())) AND (team_members.role = ANY (ARRAY['owner'::text, 'admin'::text])))));

ALTER POLICY "Owner/admin can manage members" ON public.team_members
  USING (team_id IN ( SELECT team_members_1.team_id
     FROM team_members team_members_1
    WHERE ((team_members_1.user_id = (select auth.uid())) AND (team_members_1.role = ANY (ARRAY['owner'::text, 'admin'::text])))));

ALTER POLICY "Team members can view members" ON public.team_members
  USING (team_id IN ( SELECT team_members_1.team_id
     FROM team_members team_members_1
    WHERE (team_members_1.user_id = (select auth.uid()))));

ALTER POLICY "Owner can manage team" ON public.teams
  USING ((select auth.uid()) = owner_id);

ALTER POLICY "Team members can view team" ON public.teams
  USING (id IN ( SELECT team_members.team_id
     FROM team_members
    WHERE (team_members.user_id = (select auth.uid()))));

ALTER POLICY "Users can manage own snapshots" ON public.usage_snapshots
  USING ((select auth.uid()) = user_id);

ALTER POLICY "Users can manage own settings" ON public.user_settings
  USING ((select auth.uid()) = user_id);

ALTER POLICY "Service role only" ON public.webhook_jobs
  USING ((select auth.role()) = 'service_role'::text)
  WITH CHECK ((select auth.role()) = 'service_role'::text);

ALTER POLICY "yield_score_daily_owner" ON public.yield_score_daily
  USING (user_id = (select auth.uid()));

-- (B) unindexed FK indexes -----------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_pairing_codes_user_id ON public.pairing_codes (user_id);
CREATE INDEX IF NOT EXISTS idx_teams_owner_id        ON public.teams (owner_id);

-- Verify:
--   SELECT count(*) FROM pg_policies WHERE schemaname='public'
--     AND (qual ~ 'auth\.(uid|role)\(\)' OR with_check ~ 'auth\.(uid|role)\(\)')
--     AND NOT (coalesce(qual,'')||coalesce(with_check,'') ~ 'select auth\.(uid|role)\(\)');
--   -- expect 0
--   get_advisors(performance): auth_rls_initplan + unindexed_foreign_keys cleared.
