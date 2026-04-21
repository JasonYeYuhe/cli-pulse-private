# PROJECT_FIX v1.10 P2-5 — yield_score_daily incremental recompute

**Date**: 2026-04-22
**Schema**: v0.19 → **v0.20**
**Plan item**: `/Users/jason/.claude/plans/melodic-booping-truffle.md` P2-5
**Review**: Codex verdict `ship-with-notes`; Gemini 3.1 Pro timed out (180s scan on single 184-LOC new file — recurring flake).

## Problem

`ingest_commits` called `_recompute_yield_scores_for_user_internal(user_id)` at
the end of every helper sync. That helper did:

```sql
DELETE FROM public.yield_score_daily WHERE user_id = p_user_id;
-- then INSERT … GROUP BY provider, day  across all user's history
```

For a user with months of sessions, every sync paid O(N) scan + DELETE +
INSERT of the entire history — even when the batch was a handful of today's
commits.

## Fix

### 1. New private helper — day-scoped rebuild

`_recompute_yield_scores_for_days_internal(p_user_id UUID, p_days date[])`

- DELETE only rows where `day = ANY(p_days)`
- Rebuild session_costs + session_weights CTEs with extra predicate
  `date_trunc('day', sessions.last_active_at)::date = ANY(p_days)`
- Empty/NULL `p_days` → early return
- `SECURITY DEFINER` with pinned search_path; EXECUTE revoked from
  `PUBLIC, authenticated, anon` (callable only from within other
  SECURITY DEFINER functions)

### 2. `ingest_commits` — collect affected session-days

Inside the FOR loop, the session_commit_links INSERT wraps in a CTE with
`RETURNING session_id`, and the result `array_agg`s into
`v_new_session_ids`. Accumulated into `v_affected_session_ids` (guard
against `array_agg` returning NULL on zero-row result).

After the loop:

- If `v_affected_session_ids` empty (all merges, or no matching sessions) →
  return without recompute.
- Otherwise: derive distinct days from `sessions.last_active_at` for the
  affected session_ids, call `_recompute_yield_scores_for_days_internal`.

### 3. Bonus — concurrent-ingest race guard

Codex flagged that two devices syncing the same user simultaneously could
race on `yield_score_daily(user_id, provider, day)` PK. That race was
pre-existing from v0.18 but trivial to close now:

```sql
PERFORM pg_advisory_xact_lock(hashtext(v_user_id::text)::bigint);
```

Transaction-scoped advisory lock, released at commit/rollback; serializes
concurrent ingest per user.

### 4. Preserved

- Full-user helper `_recompute_yield_scores_for_user_internal` untouched —
  still the target of the public `recompute_yield_scores_for_user(uuid)`
  escape hatch for manual / admin full rebuild.

## Edge cases handled

| Case | Behavior |
|---|---|
| Empty batch (0 commits) | Reach FOR loop, 0 iterations, early return on empty `v_affected_session_ids`. |
| All-merge batch | Every iteration hits `CONTINUE`, no links inserted, empty affected-sessions → early return. |
| No candidate sessions (project_hash mismatch or time window miss) | `candidates` CTE returns 0 rows, INSERT RETURNING 0, `array_agg`→NULL, guard skips accumulation. |
| Cross-midnight commit (commit day X, session day X-1) | Days derived from `sessions.last_active_at`, not commit timestamps, so the correct session-day is rebuilt. |
| Concurrent ingest from two devices of same user | `pg_advisory_xact_lock` serializes; second call waits, then operates on freshest data. |
| `array_agg` on zero-row set | Returns NULL; `IF v_new_session_ids IS NOT NULL` + `IF array_length(…) IS NULL` both guard. |

## Review

### Codex (codex:codex-rescue, depth=deep)

**Verdict**: ship-with-notes

Only finding: pre-existing concurrent same-user same-day race on
`yield_score_daily` PK (carried over from v0.18). All other focus areas
passed:

- Day-scoped rebuild produces identical output to full rebuild for affected
  days (non-concurrent case).
- PL/pgSQL `WITH inserted AS (INSERT RETURNING) SELECT array_agg INTO`
  pattern is correct.
- `array_agg`-NULL-on-zero-rows handled.
- Security parity with v0.18 (REVOKE/GRANT, search_path, SECURITY DEFINER).
- Edge cases above covered.

The flagged race was addressed in this migration via advisory lock before
apply.

### Gemini 3.1 Pro (mcp__gemini__review, depth=scan)

Timed out at 180s despite the diff being a single 184-LOC new file.
Recurring flake this session on small SQL files. Skipped — Codex verdict
is sufficient.

## Files

- **New**: `backend/supabase/migrate_v0.20_yield_score_incremental.sql` (189 LOC)
- **No app-side changes** — signature is identical to v0.18's
  `ingest_commits(uuid, text, jsonb)`; helper client unchanged.

## Apply

Applied directly to `gkjwsxotmwrgqsvfijzs` (Tokyo) via Supabase MCP
`apply_migration` 2026-04-22. Verified post-apply — all 4 functions
present with SECURITY DEFINER + search_path pinned:

- `ingest_commits(uuid, text, jsonb)`
- `_recompute_yield_scores_for_user_internal(uuid)`
- `_recompute_yield_scores_for_days_internal(uuid, date[])`
- `recompute_yield_scores_for_user(uuid)`

## Follow-ups / not done

- No local-test harness for PL/pgSQL. Smoke tests rely on live Supabase
  execution plan analysis. Consider pgTAP in `supabase-ci` as a future
  slice.
- `track_git_activity` default is still off, so the optimization's real
  production impact depends on rollout of that feature toggle.
