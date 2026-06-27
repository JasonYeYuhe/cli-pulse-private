-- migrate_v0.59: recursion-safe team_members RLS — block admin self-promotion
-- (2026-06-27 trust-hardening PR2 — P1 — NEW-H2v, deferred by migrate_v0.57)
--
-- VERIFIED live against prod (gkjwsxotmwrgqsvfijzs, read-only pg_policies):
-- team_members carries a SINGLE policy "Owner/admin can manage members" with
--   cmd = ALL, with_check = NULL,
--   using = team_id IN (SELECT team_id FROM team_members
--                       WHERE user_id = (select auth.uid())
--                         AND role = ANY(ARRAY['owner','admin'])).
-- Because with_check is NULL on an ALL policy, Postgres reuses the USING
-- expression as the INSERT/UPDATE WITH CHECK. That expression only asserts
-- "caller is an owner/admin of the team" — it never constrains the *resulting
-- role*. So an authenticated ADMIN can `PATCH team_members SET role='owner'` on
-- their own row via direct PostgREST and silently escalate to owner. The only
-- owner-gated path, the update_member_role() RPC, restricts role to
-- ('admin','member') and is bypassed entirely by the direct-table write.
--
-- This prod policy ALSO drifted from schema.sql, which documents the secure
-- SPLIT design (separate insert/delete/update policies). Neither the prod ALL
-- policy NOR schema.sql's split policies are recursion-safe under *direct* table
-- access: their subqueries select from team_members inside a team_members policy
-- → "infinite recursion detected in policy for relation team_members". It is
-- masked today only because the app reads teams via SECURITY DEFINER RPCs
-- (my_teams / team_usage_summary), never a direct table SELECT. migrate_v0.57
-- deferred this fix precisely to validate the recursion behavior first; that
-- validation was done on a throwaway Postgres (non-service_role authenticated
-- role) — see PROJECT_FIX_2026-06-27_team-members-rls-recursion-safe.md.
--
-- FIX: route every membership/role test through SECURITY DEFINER helper
-- functions that read team_members/teams with RLS bypassed, so the policies no
-- longer self-reference → recursion-free. Then express the secure split:
--   SELECT  members of a team I belong to            (_is_team_member)
--   INSERT  only owner/admin, only role='member'     (_is_team_admin + role guard)
--   DELETE  only owner/admin                         (_is_team_admin)
--   UPDATE  only the team OWNER (USING + WITH CHECK)  (_is_team_owner)
-- UPDATE-owner-only is what blocks admin self-promotion: an admin is not the
-- owner, so the UPDATE matches zero rows (no escalation) with no recursion.
-- All real mutations still flow through the owner-gated SECURITY DEFINER RPCs,
-- so this only tightens the direct-table defense-in-depth path.
--
-- Idempotent: `create or replace function` + `drop policy if exists`.
-- Recursion-safety + denial proven on a branch/throwaway DB before prod apply.

-- ── recursion-safe membership predicates (DEFINER → bypass team_members RLS) ──
create or replace function public._is_team_member(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, extensions
as $$
  select exists (
    select 1 from public.team_members tm
    where tm.team_id = p_team_id and tm.user_id = (select auth.uid())
  );
$$;

create or replace function public._is_team_admin(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, extensions
as $$
  select exists (
    select 1 from public.team_members tm
    where tm.team_id = p_team_id
      and tm.user_id = (select auth.uid())
      and tm.role = any (array['owner', 'admin'])
  );
$$;

create or replace function public._is_team_owner(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, extensions
as $$
  select exists (
    select 1 from public.teams t
    where t.id = p_team_id and t.owner_id = (select auth.uid())
  );
$$;

revoke all on function
  public._is_team_member(uuid),
  public._is_team_admin(uuid),
  public._is_team_owner(uuid)
from public;
grant execute on function
  public._is_team_member(uuid),
  public._is_team_admin(uuid),
  public._is_team_owner(uuid)
to authenticated, service_role;

-- ── rebuild team_members policies (drop the drifted ALL policy + recreate split) ──
drop policy if exists "Owner/admin can manage members" on public.team_members;
drop policy if exists "Team members can view members" on public.team_members;
drop policy if exists "Owner/admin can add members (as member role only)" on public.team_members;
drop policy if exists "Owner/admin can delete members" on public.team_members;
drop policy if exists "Only owner can update member roles" on public.team_members;

create policy "Team members can view members"
  on public.team_members for select
  using (public._is_team_member(team_id));

create policy "Owner/admin can add members (as member role only)"
  on public.team_members for insert
  with check (role = 'member' and public._is_team_admin(team_id));

create policy "Owner/admin can delete members"
  on public.team_members for delete
  using (public._is_team_admin(team_id));

create policy "Only owner can update member roles"
  on public.team_members for update
  using (public._is_team_owner(team_id))
  with check (public._is_team_owner(team_id));
