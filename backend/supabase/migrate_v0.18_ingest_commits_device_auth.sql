-- Migration v0.18: fix ingest_commits + recompute_yield_scores device-auth path
--
-- Incident discovered by Gemini 3.1 Pro review 2026-04-21:
--   `ingest_commits(p_commits jsonb)` required auth.uid() but the Python helper
--   daemon authenticates to Supabase with the anon key (not a user JWT), so
--   auth.uid() was always NULL and the call returned HTTP 400 "Not
--   authenticated". Live curl confirmed. The Yield-Score git-tracking feature
--   was silently broken for any user who opted in to `track_git_activity`.
--
-- Root cause: `ingest_commits` used the same auth.uid() pattern as a
--   web/app-tier RPC, but it's actually a helper-tier RPC and must use the
--   same device+helper_secret auth that `helper_sync` and
--   `get_track_git_activity` already use.
--
-- Fix:
--   1. Split `recompute_yield_scores_for_user` into:
--      - public `recompute_yield_scores_for_user(p_user_id)` — user-JWT gated
--        (unchanged contract for any web/app caller)
--      - private `_recompute_yield_scores_for_user_internal(p_user_id)` — no
--        auth check, callable only by SECURITY DEFINER functions inside
--        the database (EXECUTE revoked from authenticated / anon)
--   2. Replace `ingest_commits(p_commits)` with
--      `ingest_commits(p_device_id uuid, p_helper_secret text, p_commits jsonb)`
--      that authenticates via the `devices.helper_secret` hash (same pattern
--      as `helper_sync`) and delegates to the internal recompute.
--
-- The old 1-arg signature never worked for its sole caller, so this is a
-- replace-in-place, not a deprecation.
--
-- Verified post-apply (see PROJECT_FIX_v1.9.6c archive):
--   - new signature returns "Device not found or unauthorized" for bad creds
--   - helper_secret hash comparison matches helper_sync exactly
--   - public recompute_yield_scores_for_user still rejects foreign UUIDs
--     via auth.uid() check

-- Step 1: internal helper (callable only inside SECURITY DEFINER context).
CREATE OR REPLACE FUNCTION public._recompute_yield_scores_for_user_internal(p_user_id UUID)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
BEGIN
  -- Trusted entrypoint. Callers must have already authenticated the user.
  DELETE FROM public.yield_score_daily WHERE user_id = p_user_id;

  WITH session_costs AS (
    SELECT s.id, s.provider, s.estimated_cost, date_trunc('day', s.last_active_at)::date AS day
    FROM public.sessions s
    WHERE s.user_id = p_user_id
  ), session_weights AS (
    SELECT scl.session_id,
           SUM(scl.weight) AS weighted_commits,
           COUNT(*) AS raw_commits,
           SUM(CASE WHEN scl.is_ambiguous THEN 1 ELSE 0 END) AS ambiguous_commits
    FROM public.session_commit_links scl
    JOIN public.commits c ON c.id = scl.commit_id
    WHERE c.user_id = p_user_id
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
REVOKE ALL ON FUNCTION public._recompute_yield_scores_for_user_internal(UUID)
  FROM PUBLIC, authenticated, anon;

-- Step 2: public recompute now delegates to the internal helper after auth.
CREATE OR REPLACE FUNCTION public.recompute_yield_scores_for_user(p_user_id UUID)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'permission denied';
  END IF;
  PERFORM public._recompute_yield_scores_for_user_internal(p_user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.recompute_yield_scores_for_user(UUID) TO authenticated;

-- Step 3: drop the broken 1-arg signature before creating the new one.
DROP FUNCTION IF EXISTS public.ingest_commits(jsonb);

-- Step 4: new device-authenticated ingest_commits.
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
BEGIN
  -- Device auth (matches helper_sync / get_track_git_activity pattern).
  SELECT user_id INTO v_user_id
  FROM public.devices
  WHERE id = p_device_id
    AND helper_secret = encode(digest(p_helper_secret, 'sha256'), 'hex');
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Device not found or unauthorized';
  END IF;

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
    )
    INSERT INTO public.session_commit_links (session_id, commit_id, weight, is_ambiguous)
    SELECT n.session_id, v_commit_id, n.weight,
           (SELECT top FROM top_weight) < 0.6
    FROM normalized n
    ON CONFLICT (session_id, commit_id) DO NOTHING;
  END LOOP;

  PERFORM public._recompute_yield_scores_for_user_internal(v_user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.ingest_commits(uuid, text, jsonb) TO anon, authenticated;
