-- migrate_v0.59.1: revoke anon EXECUTE on the team RLS helper functions.
-- (2026-06-27 — follow-up to migrate_v0.59, APPLIED to prod gkjwsxotmwrgqsvfijzs)
--
-- Supabase's default privileges grant EXECUTE to anon at CREATE time, and
-- migrate_v0.59's `revoke all ... from public` only drops the implicit PUBLIC
-- grant — not the explicit anon grant. These SECURITY DEFINER helpers bypass
-- team_members/teams RLS, so per the repo convention (migrate_v0.53) anon must
-- not hold EXECUTE. (They already return false for anon today — auth.uid() is
-- null — but this closes the grant as defense-in-depth and clears the
-- anon_security_definer_function advisor finding.)
--
-- schema.sql's grant block now revokes anon directly (`from public, anon`), so a
-- fresh restore is correct without this file; it is kept to mirror the prod
-- migration history (v0.59 was applied before this follow-up).

revoke execute on function
  public._is_team_member(uuid),
  public._is_team_admin(uuid),
  public._is_team_owner(uuid)
from anon;
