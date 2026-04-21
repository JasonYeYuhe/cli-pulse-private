-- Migration v0.16: P0-4 register_helper brute-force hardening
-- Date: 2026-04-21
-- Closes two brute-force gaps:
--   (a) Invalid-pairing-code branch did not bump per-code failed_attempts.
--   (b) No backstop when attacker cycles random codes that don't exist at all.
-- Adds: pairing_attempt_log table + per-IP 10/min window. IP is read from
--       PostgREST-forwarded headers (cf-connecting-ip); direct DB callers
--       have NULL IP and fall back to the per-code counter.
--
-- IMPORTANT: All expected failure paths RETURN structured errors instead of
-- RAISE EXCEPTION. RAISE would roll back the pairing_attempt_log insert and
-- failed_attempts update made earlier in the function — defeating the whole
-- point of the counter. Clients must check response.error first.

-- 1. Log of recent pairing attempts for IP-window rate limiting.
--    Opportunistically pruned to rows within the last hour on every call.
CREATE TABLE IF NOT EXISTS public.pairing_attempt_log (
  id BIGSERIAL PRIMARY KEY,
  ip_addr TEXT,
  attempted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS pairing_attempt_log_ip_time_idx
  ON public.pairing_attempt_log (ip_addr, attempted_at DESC);
-- Second index supports the opportunistic prune by attempted_at alone.
CREATE INDEX IF NOT EXISTS pairing_attempt_log_time_idx
  ON public.pairing_attempt_log (attempted_at);

-- RLS: SECURITY DEFINER bypasses RLS, so the function still works.
-- Regular authenticated roles have no policy → no direct SELECT access.
ALTER TABLE public.pairing_attempt_log ENABLE ROW LEVEL SECURITY;

-- 2. register_helper: two-layer brute-force protection.
--    Response shape:
--      success: { device_id, user_id, helper_secret }
--      failure: { error: <code>, message: <human-readable> }
--    Error codes: rate_limited | invalid_code | too_many_failed_attempts | expired
CREATE OR REPLACE FUNCTION public.register_helper(
  p_pairing_code text,
  p_device_name text,
  p_device_type text default 'macOS',
  p_system text default '',
  p_helper_version text default '0.1.0'
)
RETURNS jsonb AS $$
DECLARE
  v_user_id uuid;
  v_device_id uuid;
  v_expires_at timestamptz;
  v_helper_secret text;
  v_failed_attempts integer;
  v_ip text;
  v_ip_attempt_count integer;
BEGIN
  -- Caller IP from PostgREST-forwarded headers. NULL for direct DB sessions
  -- or when cf-connecting-ip is absent; in that case the per-code counter
  -- is the only defense.
  BEGIN
    v_ip := nullif(current_setting('request.headers', true), '')::jsonb->>'cf-connecting-ip';
  EXCEPTION WHEN OTHERS THEN
    v_ip := NULL;
  END;

  -- Serialize concurrent same-IP calls to close the TOCTOU window on the
  -- count-then-insert rate limit check. No-op when IP is unknown.
  IF v_ip IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext(v_ip)::bigint);
  END IF;

  -- Opportunistic pruning (keeps table bounded to ~1 hour of attempts).
  DELETE FROM public.pairing_attempt_log WHERE attempted_at < now() - interval '1 hour';

  -- Log this attempt FIRST so the count below includes it. Returning (not
  -- raising) on subsequent failure paths preserves this row.
  INSERT INTO public.pairing_attempt_log (ip_addr) VALUES (v_ip);

  -- Per-IP rate limit: 10 attempts / rolling 1-minute window.
  IF v_ip IS NOT NULL THEN
    SELECT count(*) INTO v_ip_attempt_count
    FROM public.pairing_attempt_log
    WHERE ip_addr = v_ip
      AND attempted_at > now() - interval '1 minute';

    IF v_ip_attempt_count > 10 THEN
      RETURN jsonb_build_object(
        'error', 'rate_limited',
        'message', 'Too many pairing attempts — please wait a minute and try again'
      );
    END IF;
  END IF;

  -- Validate pairing code exists
  SELECT user_id, expires_at, failed_attempts
  INTO v_user_id, v_expires_at, v_failed_attempts
  FROM public.pairing_codes WHERE code = p_pairing_code;

  IF v_user_id IS NULL THEN
    -- Defense in depth: bump per-code counter on any row that matches.
    -- Matches 0 rows if the code never existed (attacker cycling random
    -- strings) — in which case the per-IP window is the backstop.
    UPDATE public.pairing_codes SET failed_attempts = failed_attempts + 1
    WHERE code = p_pairing_code;
    RETURN jsonb_build_object('error', 'invalid_code', 'message', 'Invalid pairing code');
  END IF;

  -- Per-code rate limit: block after 5 failed attempts
  IF v_failed_attempts >= 5 THEN
    RETURN jsonb_build_object(
      'error', 'too_many_failed_attempts',
      'message', 'Too many failed attempts — please generate a new pairing code'
    );
  END IF;

  IF v_expires_at < now() THEN
    UPDATE public.pairing_codes SET failed_attempts = failed_attempts + 1
    WHERE code = p_pairing_code;
    DELETE FROM public.pairing_codes WHERE code = p_pairing_code;
    RETURN jsonb_build_object('error', 'expired', 'message', 'Pairing code has expired');
  END IF;

  -- Success path
  v_helper_secret := 'helper_' || encode(gen_random_bytes(32), 'hex');

  INSERT INTO public.devices (user_id, name, type, system, helper_version, status, helper_secret)
  VALUES (v_user_id, left(p_device_name, 255), left(p_device_type, 50),
          left(p_system, 255), left(p_helper_version, 20), 'Online',
          encode(digest(v_helper_secret, 'sha256'), 'hex'))
  RETURNING id INTO v_device_id;

  UPDATE public.profiles SET paired = true WHERE id = v_user_id;
  DELETE FROM public.pairing_codes WHERE code = p_pairing_code;

  RETURN jsonb_build_object('device_id', v_device_id, 'user_id', v_user_id, 'helper_secret', v_helper_secret);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions;
