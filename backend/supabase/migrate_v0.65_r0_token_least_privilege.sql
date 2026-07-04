-- ============================================================
-- v0.65 — R0: least-privilege realtime broadcast token (deep-audit 2026-07-04, F1)
-- Date: 2026-07-04 · *** ADDITIVE + INERT — SAFE TO APPLY (see below) ***
--
-- Verified 2026-07-04 against prod (gkjwsxotmwrgqsvfijzs):
--   select count(*) from public.user_settings where realtime_private_enabled;  -- 0
-- The realtime_private cutover is OFF for 100% of users, so mint-realtime-token
-- produces NO live tokens and these policies/grants govern NOTHING until the
-- owner-gated cutover. Applying this changes ZERO current behavior.
--
-- ── PROBLEM (F1) ──────────────────────────────────────────────
-- mint-realtime-token signs an ES256 JWT with role='authenticated', sub=owner.
-- The dedicated R0 keypair is registered as a PROJECT-WIDE Third-Party trusted
-- issuer, so PostgREST (/rest/v1) trusts it too. A LEAKED minted token is thus
-- indistinguishable from the owner's own GoTrue session JWT: it carries
-- account-wide, owner-scoped PostgREST authority (every app RPC/table granted
-- `to authenticated` + RLS `auth.uid() = user_id`), not merely the ability to
-- broadcast a terminal stream. Confinement today is only the ~1h TTL and no
-- revocation. (The token is consumed by exactly ONE caller — the Python helper's
-- broadcast producer — as the Bearer on POST /realtime/v1/api/broadcast; it is
-- never used for PostgREST by our own code. So dropping `authenticated` is safe
-- for every real call site; mobile subscribers use their OWN login JWT.)
--
-- ── FIX ───────────────────────────────────────────────────────
-- (1) Mint role='r0_broadcast' — a dedicated NOLOGIN role with ZERO privileges
--     on schema public (verified: cannot SELECT devices/remote_sessions/
--     user_settings, cannot EXECUTE delete_user_account or any remote_app_*).
--     Its ONLY reach is INSERT on realtime.messages (broadcast write). A leaked
--     r0_broadcast token can therefore only WRITE to its own pterm: topic — it
--     cannot read app data, cannot read other topics (no SELECT grant, and the
--     READ policy stays `to authenticated`), and cannot act as the owner via
--     PostgREST.
-- (2) Bind the token to the ONE session it was minted for: the WRITE policy now
--     additionally requires the topic to equal pterm:<the token's session_id
--     claim>. This closes cross-session-WITHIN-owner (a token minted for
--     session A can no longer write to the owner's session B).
-- (3) Close the residual escalation surface reachable via the PUBLIC pseudo-role
--     (a custom role inherits PUBLIC grants). Three SECURITY DEFINER functions
--     are PUBLIC-granted AND scope by auth.uid(): a leaked r0_broadcast token
--     carries sub=owner, so it could invoke them AS the owner. Most damaging:
--     register_desktop_helper RETURNS a fresh helper_secret → a persistent
--     owner-impersonating device credential. These three are uid-scoped (they
--     `raise 'Not authenticated'` when auth.uid() is null), so their anon/PUBLIC
--     grants are DEAD (no anon caller can use them) and their real callers are
--     authenticated (the desktop app + the phone app). Re-scope them to
--     authenticated + service_role.
--
-- The READ (SELECT) policy is UNCHANGED (`to authenticated`) — the phone/desktop
-- subscribers read pterm: with their own GoTrue login token, not a minted token.
--
-- ⚠️ OWNER RUNBOOK — Supabase Realtime selects the Postgres role from the JWT
--    `role` claim ("inspects the `role` claim … to assign the correct Postgres
--    role when using … Realtime authorization") and evaluates realtime.messages
--    RLS via an insert-and-rollback under that role. This migration's DB-layer
--    mechanics are validated (r0_broadcast is grantable to `authenticator`,
--    which CAN `set role` into it; the WRITE policy admits it for its own
--    session topic and denies cross-session; it has no app-data reach). But
--    Supabase docs only DEMONSTRATE the three built-in roles and do not
--    explicitly bless a custom role NAME for the broadcast HTTP path. So BEFORE
--    the cutover (flipping user_settings.realtime_private_enabled), run the
--    end-to-end mint→broadcast integration check (owner runbook): mint an
--    r0_broadcast token and confirm POST /realtime/v1/api/broadcast to the
--    session's pterm: topic delivers (and a cross-session token does NOT). This
--    is the SAME integration gate migrate_v0.56 already requires (its Gemini
--    MEDIUM note). If Realtime rejects the custom role name, fall back to a
--    service-relay broadcast (helper→edge fn→service-role realtime.send) — no
--    user is affected either way because the path is gated OFF.
--
-- This whole script runs as ONE transaction.
-- ============================================================

-- ------------------------------------------------------------
-- (1) Dedicated least-privilege role for realtime broadcast writes.
--     NOLOGIN: assumed only via the minted JWT's `role` claim (Realtime/
--     PostgREST `set role`). Idempotent.
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'r0_broadcast') then
    create role r0_broadcast nologin;
  end if;
end
$$;

-- The PostgREST/Realtime login role must be able to SET ROLE into r0_broadcast
-- (authenticator is NOINHERIT, so this grants SET-ROLE capability, not
-- inherited privileges — exactly what we want). Idempotent.
grant r0_broadcast to authenticator;

-- Minimal realtime grants: schema USAGE + INSERT on messages (broadcast write
-- ONLY — deliberately NO select/update, so a leaked token cannot even read
-- back other topics at the table level).
grant usage on schema realtime to r0_broadcast;
grant insert on realtime.messages to r0_broadcast;

-- ------------------------------------------------------------
-- (2a) Authorization ORACLE for the broadcast write. The least-privilege
--      r0_broadcast role has NO SELECT on public.remote_sessions (by design),
--      so the WRITE policy CANNOT inline `select ... from remote_sessions` — a
--      policy expression is evaluated as the CURRENT role, and that would fail
--      "permission denied for table remote_sessions" under r0_broadcast. Wrap
--      the ownership+session+topic check in a SECURITY DEFINER function the
--      role can EXECUTE. It reads the per-request session GUCs (auth.uid() /
--      request.jwt.claims persist across a SECURITY DEFINER boundary) and
--      resolves remote_sessions as the definer.
--
--      Binds the token to the ONE session it was minted for: the topic must be
--      exactly pterm:<the token's session_id claim>, that session must belong
--      to the token owner (auth.uid()=sub) and be realtime_private.
--
--      NEVER cast realtime.topic() (a ::uuid cast throws 22P02 on a malformed
--      topic → DoS). Compare constructed strings. Read the session_id claim the
--      same robust way auth.uid() reads sub: nullif(...,'')::jsonb ->> key
--      (empty/absent → NULL → no match → fail closed).
-- ------------------------------------------------------------
create or replace function public.r0_broadcast_topic_allowed(p_topic text)
returns boolean
language sql
security definer
stable
set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
  select exists (
    select 1 from public.remote_sessions rs
    where rs.user_id = (select auth.uid())
      and rs.realtime_private is true
      and rs.id::text = nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'session_id'
      and 'pterm:' || rs.id::text = p_topic
  );
$function$;
revoke all on function public.r0_broadcast_topic_allowed(text) from public;
grant execute on function public.r0_broadcast_topic_allowed(text) to r0_broadcast, service_role;

-- (2b) Retarget the WRITE policy from `authenticated` to the least-privilege
--      role, delegating the ownership+session+topic check to the oracle.
drop policy if exists "r0 broadcast own remote session terminal" on realtime.messages;
create policy "r0 broadcast own remote session terminal"
  on realtime.messages for insert to r0_broadcast
  with check (
    realtime.messages.extension = 'broadcast'
    and public.r0_broadcast_topic_allowed(realtime.topic())
  );

-- The READ policy ("r0 read own remote session terminal", to authenticated) is
-- intentionally left as migrate_v0.56 defined it — mobile subscribers read with
-- their own GoTrue login token. Documented here for a complete picture; not
-- re-emitted.

-- ------------------------------------------------------------
-- (3) Re-scope the three PUBLIC-granted, auth.uid()-scoped SECURITY DEFINER
--     functions a leaked r0_broadcast token (sub=owner) could otherwise invoke
--     AS the owner. They already `raise 'Not authenticated'` for anon (uid
--     null) → their anon/PUBLIC grants are DEAD; real callers are authenticated
--     (register_desktop_helper: the desktop app; upsert_daily_usage /
--     get_daily_usage_by_device: the phone app). Idempotent.
-- ------------------------------------------------------------
revoke execute on function public.register_desktop_helper(text, text, text, text) from public, anon;
grant  execute on function public.register_desktop_helper(text, text, text, text) to authenticated, service_role;

revoke execute on function public.upsert_daily_usage(jsonb, uuid) from public, anon;
grant  execute on function public.upsert_daily_usage(jsonb, uuid) to authenticated, service_role;

revoke execute on function public.get_daily_usage_by_device(integer) from public, anon;
grant  execute on function public.get_daily_usage_by_device(integer) to authenticated, service_role;

-- ------------------------------------------------------------
-- Post-apply verification (run manually after APPLY):
--   -- role exists + minimal:
--   select rolname, rolcanlogin from pg_roles where rolname='r0_broadcast';   -- 1 row, f
--   select has_table_privilege('r0_broadcast','public.devices','SELECT');     -- false
--   select has_table_privilege('r0_broadcast','realtime.messages','INSERT');  -- true
--   select pg_has_role('authenticator','r0_broadcast','SET');                 -- true
--   -- WRITE policy now targets r0_broadcast:
--   select roles from pg_policies where schemaname='realtime' and tablename='messages'
--     and policyname='r0 broadcast own remote session terminal';              -- {r0_broadcast}
--   -- the three functions no longer reachable by anon/PUBLIC:
--   select has_function_privilege('anon','public.register_desktop_helper(text,text,text,text)','EXECUTE'); -- false
--   select has_function_privilege('authenticated','public.register_desktop_helper(text,text,text,text)','EXECUTE'); -- true
-- ============================================================
