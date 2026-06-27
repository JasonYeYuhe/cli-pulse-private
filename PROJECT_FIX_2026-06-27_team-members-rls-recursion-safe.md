# PROJECT FIX — Recursion-safe team_members RLS (block admin self-promotion) (P1)

**Date:** 2026-06-27
**Train:** Backend trust hardening — **PR2 (P1, NEW-H2v)**
**Branch:** `security/team-members-rls-recursion-safe`
**Plan:** `DEV_PLAN_2026-06-27_nextphase_trust_hardening.md` §2 PR2

---

## Summary

Replaced the drifted single `ALL` `team_members` RLS policy with the secure,
**recursion-safe** split design (SECURITY DEFINER membership helpers), closing an
admin → owner self-promotion gap **and** repairing a latent infinite-recursion
bug that currently breaks `team_members` direct reads in prod.

## Root cause (VERIFIED LIVE — prod `gkjwsxotmwrgqsvfijzs`, read-only)

Prod `team_members` carries one policy `"Owner/admin can manage members"`:
`cmd = ALL`, `with_check = NULL`, `using = team_id IN (SELECT team_id FROM
team_members WHERE user_id = (select auth.uid()) AND role = ANY('{owner,admin}'))`.

Two distinct defects, both proven on a throwaway Postgres as a non-`service_role`
`authenticated` role (`backend/supabase/tests/rls/` + the 3-stage proof below):

1. **Role-escalation gap.** On an `ALL` policy with `with_check = NULL`, Postgres
   reuses the `USING` expression as the INSERT/UPDATE `WITH CHECK`. That
   expression only asserts "caller is owner/admin of the team" — it never
   constrains the *resulting role*. So a member with `role='admin'` can
   `PATCH team_members SET role='owner'` on their own row via direct PostgREST
   and escalate to owner, bypassing the only owner-gated path
   (`update_member_role()`, which restricts role to `('admin','member')`).

2. **Infinite recursion (latent, now live-confirmed).** The policy's `USING`
   selects from `team_members` *inside* a `team_members` policy →
   `SQLSTATE 42P17 infinite recursion detected in policy for relation
   "team_members"` on ANY direct table access. **Confirmed on live prod**
   (impersonating the one real authenticated team member, read-only): the direct
   read **errors**. The Android team feature reads members via direct REST
   (`SupabaseClient.kt:870,887`), so those reads are currently broken in prod;
   masked elsewhere because the app otherwise uses SECURITY DEFINER RPCs
   (`my_teams`, `team_usage_summary`). ⇒ this fix is also a **functional repair**.

`schema.sql` documented a *split* design but it too self-referenced
`team_members` (same recursion) and never matched prod (drift). `migrate_v0.57`
explicitly deferred this pending recursion validation.

## 3-stage validation (non-service_role authenticated role, throwaway Postgres)

| Stage | Setup | Result |
|---|---|---|
| **A** | live prod policy shape | admin direct UPDATE → **42P17 infinite recursion** (prod RLS path non-functional/masked) |
| **B** | recursion removed via helper, but role unguarded (`ALL` with check = USING) | admin UPDATE `role='owner'` → **succeeds** (escalation gap is real, not theoretical) |
| **C** | `migrate_v0.59` applied | admin self-promote → **0 rows, role still admin, no recursion**; non-member read → 0 rows (no recursion); owner can still manage (1 row) |

## What changed

- **NEW** `backend/supabase/migrate_v0.59_team_members_rls_recursion_safe.sql`:
  - 3 SECURITY DEFINER, search_path-pinned helpers — `_is_team_member(uuid)`,
    `_is_team_admin(uuid)`, `_is_team_owner(uuid)` — that read membership with
    RLS bypassed (so policies stop self-referencing → recursion-free).
  - DROP the drifted `"Owner/admin can manage members"` ALL policy (+ idempotent
    drops) and recreate the split: SELECT = member; INSERT = admin & role='member';
    DELETE = admin; **UPDATE = owner only (USING + WITH CHECK)** ← blocks
    self-promotion.
- **EDIT** `backend/supabase/schema.sql` — reconciled the `teams` / `team_members`
  / `team_invites` policies to the same helper-based, recursion-safe forms so the
  tracked source of truth converges with prod-after-apply.

Behaviorally safe: all team-member mutations flow through owner-gated SECURITY
DEFINER RPCs (`invite_member`/`accept_invite`/`remove_member`/`update_member_role`),
which bypass RLS; no live client writes `team_members` directly (only the dead
`archive/backend-fastapi-legacy` does). The RLS is defense-in-depth + the
read path.

## Verification checklist

- [x] Recursion + escalation + denial proven on throwaway Postgres (stages A/B/C).
- [x] Full cross-user suite green (PR3 harness applies the reconciled schema.sql).
- [x] `ci_check_search_path.py` green (helpers pinned); `ci_check_rpc_contract.py` green.
- [x] No live client direct `team_members` writes (grep).
- [x] Live-prod recursion confirmed (read-only impersonation).
- [x] **APPLIED to prod 2026-06-27** (owner go-ahead): `migrate_v0.59` + `migrate_v0.59.1`.
      Verified: old ALL policy gone, 4 split policies live (UPDATE=owner-only via
      `_is_team_owner`), the previously-live 42P17 recursion fixed (demo/team-owner read
      returns 1 row), helpers authenticated/service_role-only (anon revoked).

## Post-apply follow-up (migrate_v0.59.1)

After applying v0.59, a `proacl` check showed the helpers had `anon=X` — Supabase's
default privileges grant EXECUTE to anon at CREATE time, and v0.59's `revoke all ...
from public` doesn't drop the explicit anon grant. Harmless today (anon's auth.uid()
is null → helpers return false), but per the repo convention (migrate_v0.53) anon
must not hold EXECUTE on RLS-bypassing SECURITY DEFINER functions. Fixed by
`migrate_v0.59.1` (applied to prod) + reconciled `schema.sql` to `revoke ... from
public, anon`.

## Notes / follow-ups

- ⚠️ **Owner-facing:** the team-member direct-read recursion is LIVE in prod today
  — the Android team roster reads error (42P17). This migration fixes it. Low blast
  radius (one team in prod), but worth knowing it's a functional fix, not only
  hardening.
- Prod apply order: this (PR2) before merging the PR3 harness (which applies the
  reconciled `schema.sql`).
