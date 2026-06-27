# PROJECT FIX — Cross-user RLS denial tests in CI (resolve C-3 coverage gap) (P1)

**Date:** 2026-06-27
**Train:** Backend trust hardening — **PR3 (P1, long pole / C-3)**
**Branch:** `security/cross-user-rls-ci` (stacked on `security/team-members-rls-recursion-safe`)
**Plan:** `DEV_PLAN_2026-06-27_nextphase_trust_hardening.md` §2 PR3

---

## Summary

Added a CI job + SQL harness that seeds a fresh Postgres from the repo schema and
asserts, as a non-superuser `authenticated` role, that one user cannot reach
another user's rows on every sensitive table — the durable net that would have
caught both P1s in this train.

## Why (C-3)

There was **zero** automated RLS coverage. The natural approach (`supabase start`
+ replay `schema.sql → migrate_v*.sql`) has been blocked for many trains because
`schema.sql` is a current-state snapshot and replaying migrations on top
double-applies (first conflict at `migrate_v0.9` `CREATE POLICY`). Per the plan,
**the denial assertions are the deliverable; the seeding mechanism is
negotiable** — so this decouples from the replay blocker by seeding a BRAND-NEW
database instead of replaying onto a snapshot.

## What changed

- **NEW** `backend/supabase/tests/rls/`:
  - `00_supabase_shim.sql` — minimal Supabase-compat shim for stock Postgres:
    roles (`anon`/`authenticated`/`service_role`/`authenticator`), `auth` schema
    with `auth.uid()/role()/jwt()` reading `request.jwt.claims`, a stand-in
    `auth.users`, and default privileges so RLS — not a missing GRANT — is the
    only thing that can deny (no false passes).
  - `20_remote_tables.sql` — faithful DDL + policies for the `remote_*` tables
    (transcribed from live prod; they live in big feature migrations, not
    schema.sql).
  - `30_seed.sql` — deterministic userA/userB + a team (owner/admin/member).
  - `40_rls_denial_tests.sql` — the assertions; `psql -v ON_ERROR_STOP=1` aborts
    non-zero on any cross-user success.
  - `run_rls_tests.sh` — applies shim → repo `schema.sql` → remote DDL → seed →
    assertions against `$DATABASE_URL`.
- **EDIT** `.github/workflows/supabase-ci.yml` — new `rls-cross-user` job
  (postgres:16 service) running the harness. It lives under the **Supabase CI**
  workflow, which the `CI Gate` already requires, so the net is enforced on every
  PR touching `backend/supabase/**` with no branch-protection change. Updated the
  stale F9/C-3 comment to note the RLS coverage gap is now closed (the full
  schema.sql replay remains separately deferred).

## Coverage (assertions)

- **Read denial** (userB sees 0 userA rows): `remote_sessions`,
  `remote_session_commands`, `remote_session_events`, `remote_permission_requests`,
  `remote_permission_decisions`, `daily_usage_metrics`, `subscriptions`.
- **Insert denial** (userB cannot forge userA rows): `remote_sessions`,
  `daily_usage_metrics`, `subscriptions`.
- **Update denial** (userB updates 0 userA rows): `remote_session_commands`,
  `daily_usage_metrics`.
- **team_members insider escalation**: non-member reads 0; admin direct UPDATE to
  owner denied (role unchanged); admin INSERT of owner-role membership denied;
  **positive controls** — owner can manage roles, member can read own roster
  without recursion (the regression guard for the prod 42P17 recursion).
- **Positive controls**: userA CAN read its own rows in every table (guards
  against an over-broad RLS giving false "denial" confidence).

Local run: **25 assertions PASS**, suite exits 0.

## Verification checklist

- [x] Harness green on local Postgres (25 PASS) via both libpq-env and
      `DATABASE_URL` paths (the CI path).
- [x] Job seeds a fresh DB — no `schema.sql` double-apply.
- [x] Covers PR2's `team_members` fix (uses the reconciled `schema.sql`).
- [ ] Green in CI (`rls-cross-user` job under Supabase CI; gate-required).

## Notes / follow-ups

- **Stacking:** depends on PR2 (the reconciled `schema.sql`). Merge PR2 first,
  then retarget/rebase this PR onto `main`.
- The `remote_*` table DDL is a faithful transcription, not the live migration
  text; if those tables' policies change, update `20_remote_tables.sql`. The
  baseline tables (team_members/subscriptions/daily_usage_metrics) ARE sourced
  from the real `schema.sql`, so a regression there fails the job.
