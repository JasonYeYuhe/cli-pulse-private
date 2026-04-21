-- Migration v0.20: incremental yield_score_daily rebuild on ingest_commits
--
-- Problem: `ingest_commits` calls `_recompute_yield_scores_for_user_internal`,
--   which DELETEs the user's entire `yield_score_daily` and rebuilds from
--   scratch. For a user with months of history, every helper sync pays O(N)
--   over all of their sessions even when the batch is just today's commits.
--
-- Fix: scope the rebuild to the days actually touched by the batch.
--
--   1. New private helper
--      `_recompute_yield_scores_for_days_internal(p_user_id, p_days date[])`
--      DELETEs and rebuilds rows only for `day = ANY(p_days)`. Empty /
--      NULL `p_days` → no-op.
--
--   2. `ingest_commits` collects affected session_ids during the FOR loop
--      (via RETURNING session_id from the session_commit_links INSERT),
--      then derives distinct days from `sessions.last_active_at` and calls
--      the day-scoped helper.
--
-- Edge case: commit on day X linked to a session on day X-1 — we scope by
--   session.last_active_at's day (not commit.committed_at), so the correct
--   session-day is rebuilt. Handled because we derive days from the
--   affected-session rows, not from commit timestamps.
--
-- The full-user helper `_recompute_yield_scores_for_user_internal` is kept
-- for the public `recompute_yield_scores_for_user` entrypoint (manual /
-- admin full reset).

-- Step 1: day-scoped recompute helper.
CREATE OR REPLACE FUNCTION public._recompute_yield_scores_for_days_internal(
  p_user_id UUID,
  p_days date[]
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
BEGIN
  -- Trusted entrypoint. Callers must have already authenticated the user.
  IF p_days IS NULL OR array_length(p_days, 1) IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM public.yield_score_daily
  WHERE user_id = p_user_id
    AND day = ANY(p_days);

  WITH session_costs AS (
    SELECT s.id, s.provider, s.estimated_cost,
           date_trunc('day', s.last_active_at)::date AS day
    FROM public.sessions s
    WHERE s.user_id = p_user_id
      AND date_trunc('day', s.last_active_at)::date = ANY(p_days)
  ), session_weights AS (
    SELECT scl.session_id,
           SUM(scl.weight) AS weighted_commits,
           COUNT(*) AS raw_commits,
           SUM(CASE WHEN scl.is_ambiguous THEN 1 ELSE 0 END) AS ambiguous_commits
    FROM public.session_commit_links scl
    JOIN public.commits c ON c.id = scl.commit_id
    JOIN public.sessions s ON s.id = scl.session_id
    WHERE c.user_id = p_user_id
      AND s.user_id = p_user_id
      AND date_trunc('day', s.last_active_at)::date = ANY(p_days)
    GROUP BY scl.session_id
  )
  INSERT INTO public.yield_score_daily
    (user_id, provider, day, total_cost, weighted_commit_count, raw_commit_count, ambiguous_commit_count)
  SELECT
    p_user_id, sc.provider, sc.day,
    SUM(COALESCE(sc.estimated_cost, 0)),
    COALESCE(SUM(sw.weighted_commits), 0),
    COALESCE(SUM(sw.raw_commits)::int, 0),
    COALESCE(SUM(sw.ambiguous_commits)::int, 0)
  FROM session_costs sc
  LEFT JOIN session_weights sw ON sw.session_id = sc.id
  GROUP BY sc.provider, sc.day;
END;
$$;

-- Only reachable inside the database by other SECURITY DEFINER functions.
REVOKE ALL ON FUNCTION public._recompute_yield_scores_for_days_internal(UUID, date[])
  FROM PUBLIC, authenticated, anon;

-- Step 2: rewrite ingest_commits to use the day-scoped recompute.
CREATE OR REPLACE FUNCTION public.ingest_commits(
  p_device_id uuid,
  p_helper_secret text,
  p_commits jsonb
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
DECLARE
  v_user_id UUID;
  v_commit jsonb;
  v_commit_id TEXT;
  v_committed_at TIMESTAMPTZ;
  v_project_hash TEXT;
  v_affected_session_ids TEXT[] := ARRAY[]::TEXT[];
  v_new_session_ids TEXT[];
  v_affected_days date[];
BEGIN
  -- Device auth (matches helper_sync / get_track_git_activity pattern).
  SELECT user_id INTO v_user_id
  FROM public.devices
  WHERE id = p_device_id
    AND helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Device not found or unauthorized';
  END IF;

  -- Serialize concurrent ingest for the same user to avoid PK races on
  -- yield_score_daily(user_id, provider, day) when two devices sync the same
  -- day simultaneously. Transaction-scoped; released at commit/rollback.
  PERFORM pg_advisory_xact_lock(hashtext(v_user_id::text)::bigint);

  -- DoS guard: cap batch size. Helper client shards ≤ 200 per call.
  IF jsonb_typeof(p_commits) <> 'array' THEN
    RAISE EXCEPTION 'p_commits must be a JSON array';
  END IF;
  IF jsonb_array_length(p_commits) > 500 THEN
    RAISE EXCEPTION 'batch_too_large';
  END IF;

  FOR v_commit IN SELECT * FROM jsonb_array_elements(p_commits) LOOP
    v_commit_id := v_user_id::text || ':' || (v_commit->>'commit_hash');
    v_committed_at := (v_commit->>'committed_at')::timestamptz;
    v_project_hash := v_commit->>'project_hash';

    INSERT INTO public.commits (id, user_id, commit_hash, project_hash, committed_at, is_merge)
    VALUES (v_commit_id, v_user_id, v_commit->>'commit_hash', v_project_hash, v_committed_at,
            COALESCE((v_commit->>'is_merge')::boolean, false))
    ON CONFLICT (user_id, commit_hash) DO NOTHING;

    -- Skip merge commits in attribution
    IF COALESCE((v_commit->>'is_merge')::boolean, false) THEN CONTINUE; END IF;

    -- Normalized attribution: each commit's total weight across sessions = 1.0
    WITH candidates AS (
      SELECT s.id AS session_id,
             GREATEST(0.05,
               1.0 - LEAST(1.0,
                 EXTRACT(EPOCH FROM ABS(v_committed_at - s.last_active_at)) / 1800.0
               )
             ) AS recency_score
      FROM public.sessions s
      WHERE s.user_id = v_user_id
        AND s.project_hash IS NOT NULL
        AND s.project_hash = v_project_hash
        AND v_committed_at BETWEEN s.started_at AND (s.last_active_at + interval '30 minutes')
    ), totals AS (
      SELECT SUM(recency_score) AS total_score FROM candidates
    ), normalized AS (
      SELECT c.session_id, (c.recency_score / t.total_score)::real AS weight
      FROM candidates c, totals t
      WHERE t.total_score > 0
    ), top_weight AS (
      SELECT MAX(weight) AS top FROM normalized
    ), inserted AS (
      INSERT INTO public.session_commit_links (session_id, commit_id, weight, is_ambiguous)
      SELECT n.session_id, v_commit_id, n.weight,
             (SELECT top FROM top_weight) < 0.6
      FROM normalized n
      ON CONFLICT (session_id, commit_id) DO NOTHING
      RETURNING session_id
    )
    SELECT array_agg(session_id) INTO v_new_session_ids FROM inserted;

    IF v_new_session_ids IS NOT NULL THEN
      v_affected_session_ids := v_affected_session_ids || v_new_session_ids;
    END IF;
  END LOOP;

  -- Nothing newly linked (all merges, or no matching sessions) → skip recompute.
  IF array_length(v_affected_session_ids, 1) IS NULL THEN
    RETURN;
  END IF;

  -- Collect distinct session-days to rebuild (scoped by session.last_active_at,
  -- not commit.committed_at, so cross-midnight commits land on the right day).
  SELECT array_agg(DISTINCT date_trunc('day', last_active_at)::date)
  INTO v_affected_days
  FROM public.sessions
  WHERE id = ANY(v_affected_session_ids)
    AND user_id = v_user_id;

  PERFORM public._recompute_yield_scores_for_days_internal(v_user_id, v_affected_days);
END;
$$;

GRANT EXECUTE ON FUNCTION public.ingest_commits(uuid, text, jsonb) TO anon, authenticated;
