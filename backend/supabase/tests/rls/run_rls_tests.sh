#!/usr/bin/env bash
# ============================================================================
# run_rls_tests.sh — seed a fresh Postgres and run the cross-user RLS denial
# suite (DEV_PLAN §2 PR3 / C-3). Decoupled from the schema.sql double-apply
# blocker: it seeds a BRAND-NEW database, it does not replay schema.sql onto a
# Supabase snapshot.
#
# Apply order:
#   00_supabase_shim.sql   roles + auth.uid()/auth.users (Supabase compat)
#   ../../schema.sql       the REAL repo baseline (profiles, teams, team_members,
#                          subscriptions, daily_usage_metrics, …) incl. RLS
#   20_remote_tables.sql   faithful remote_* table DDL + policies (from prod)
#   30_seed.sql            deterministic userA/userB + team owner/admin/member
#   40_rls_denial_tests.sql  the assertions (psql aborts non-zero on any FAIL)
#
# Usage:
#   DATABASE_URL=postgres://user:pass@host:port/db ./run_rls_tests.sh
#   # or rely on libpq env (PGHOST/PGPORT/PGUSER/PGDATABASE)
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$HERE/../../schema.sql"

# psql connection: explicit DATABASE_URL wins, else libpq env vars.
PSQL=(psql -v ON_ERROR_STOP=1 --no-psqlrc -q)
if [[ -n "${DATABASE_URL:-}" ]]; then
  PSQL+=("$DATABASE_URL")
fi

run() { echo "── applying $1"; "${PSQL[@]}" -f "$1"; }

run "$HERE/00_supabase_shim.sql"
run "$SCHEMA"
run "$HERE/20_remote_tables.sql"
run "$HERE/30_seed.sql"

echo "── running denial assertions"
# -P pager=off so NOTICE/echo stream; ON_ERROR_STOP already set above.
"${PSQL[@]}" -f "$HERE/40_rls_denial_tests.sql"

echo "RLS cross-user denial suite: OK"
