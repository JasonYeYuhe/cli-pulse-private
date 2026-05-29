-- ============================================================
-- v0.54 — P1 RLS fixes (2026-05-29 deep audit).
-- APPLIED to prod (gkjwsxotmwrgqsvfijzs) 2026-05-29.
--
-- (A) provider_usage_today / provider_usage_week were SECURITY DEFINER views
--     (advisor ERROR security_definer_view). They project user_id + GROUP BY
--     user_id over the full sessions table with NO self-scoping, so as DEFINER
--     they bypassed sessions RLS and exposed every user's aggregates to any
--     authenticated caller (`SELECT * FROM provider_usage_today WHERE user_id =
--     '<other user>'`). They are UNREFERENCED by any RPC or client (legacy;
--     superseded by the dashboard_summary / provider_summary RPCs). Switch to
--     security_invoker so the caller's own sessions RLS applies. service_role
--     still bypasses RLS (any internal/analytics use keeps full visibility).
--
-- (B) subscriptions "Service can manage subscriptions" was FOR ALL TO public
--     USING(true) — ANY authenticated user could INSERT/UPDATE/DELETE ANY
--     subscription row (set their own billing tier to 'pro', tamper others').
--     No client writes subscriptions directly (IAP writes go through the
--     service_role validate-receipt edge function; handle_new_subscription is a
--     SECURITY DEFINER trigger — both bypass RLS). Restrict the management
--     policy to service_role. "Users can view own subscription" SELECT policy
--     (auth.uid() = user_id) is unchanged.
-- ============================================================

-- (A) views → security_invoker (Postgres 15+)
ALTER VIEW public.provider_usage_today SET (security_invoker = true);
ALTER VIEW public.provider_usage_week  SET (security_invoker = true);

-- (B) lock subscription management to service_role
DROP POLICY IF EXISTS "Service can manage subscriptions" ON public.subscriptions;
CREATE POLICY "Service can manage subscriptions" ON public.subscriptions
  AS PERMISSIVE FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- Verify:
--   SELECT relname, reloptions FROM pg_class
--    WHERE relname IN ('provider_usage_today','provider_usage_week');
--   -- expect reloptions = {security_invoker=true}
--   SELECT policyname, roles FROM pg_policies
--    WHERE tablename='subscriptions';
--   -- expect "Service can manage subscriptions" → {service_role}
