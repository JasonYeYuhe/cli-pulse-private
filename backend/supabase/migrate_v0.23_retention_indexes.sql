-- Migration v0.23: standalone time indexes for retention cron (P1 from
-- 2026-04-22 Codex v1.10.0 post-release review)
--
-- Background:
--   v0.22 added retention_cleanup_nightly which deletes by committed_at /
--   last_active_at / metric_date / day. The underlying tables only exposed
--   composite indexes with leading user_id (commits_user_time_idx,
--   sessions_user_project_active_idx, idx_daily_usage_metrics_user_date,
--   yield_score_daily_pkey). Those predicates are unusable for a global
--   time-range WHERE clause — Postgres would fall back to a seq scan as the
--   history grows. 1-year-small-dataset smoke hides the cost today, but
--   this becomes a lock-heavy sequential-scan at 2-3 year scale.
--
-- Fix: add standalone btree indexes on each of the 4 retention-target
--   columns. We intentionally use CREATE INDEX (not CONCURRENTLY) because:
--     (a) CONCURRENTLY is disallowed inside the migration transaction.
--     (b) The dataset is small enough that a brief exclusive lock during
--         build completes in milliseconds.
--   If we ever need to re-index a much larger table, run the statement
--   manually outside a transaction with CONCURRENTLY instead.
--
-- Idempotent via IF NOT EXISTS so re-running a seeded migration is safe.

CREATE INDEX IF NOT EXISTS commits_committed_at_idx
  ON public.commits (committed_at);

CREATE INDEX IF NOT EXISTS sessions_last_active_at_idx
  ON public.sessions (last_active_at);

CREATE INDEX IF NOT EXISTS daily_usage_metrics_metric_date_idx
  ON public.daily_usage_metrics (metric_date);

CREATE INDEX IF NOT EXISTS yield_score_daily_day_idx
  ON public.yield_score_daily (day);
