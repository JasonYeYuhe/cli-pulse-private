-- Migration v0.19: pairing_attempt_log cleanup hygiene
--
-- Addresses Gemini 3.1 Pro review finding #3 (2026-04-22):
--   register_helper ran
--     DELETE FROM public.pairing_attempt_log WHERE attempted_at < now() - interval '1 hour';
--   synchronously on EVERY call. Under concurrent pairing from many IPs,
--   that's table-wide lock contention every pairing attempt.
--
-- Fix: hybrid cleanup strategy
--   1. Keep a cleanup path inside register_helper but gate it with a 1%
--      probability → ~100x reduction in DELETE frequency while still
--      bounding table growth without external scheduling dependency.
--   2. Also add the same cleanup to cleanup_expired_data so if service
--      role-scheduled cleanup is running (pg_cron or edge function), we
--      get a guaranteed sweep even without hitting the probabilistic path.
--
-- Trade-off: under extreme write bursts between 1% cleanup hits, the
--   table can accumulate entries older than 1h. The per-IP rate-limit
--   query in register_helper uses `attempted_at > now() - interval
--   '1 minute'` so stale > 1h rows don't skew rate counting — only
--   table size matters, and 100× frequency reduction keeps it bounded
--   at any realistic user scale.

-- Step 1: replace register_helper with a version that probabilistically
-- cleans up instead of always-cleaning. Keeps all other behavior (v0.16
-- device brute-force hardening + v0.17.1 search_path pin) intact.
CREATE OR REPLACE FUNCTION public.register_helper(
  p_pairing_code text,
  p_device_name text,
  p_device_type text DEFAULT 'macOS',
  p_system text DEFAULT '',
  p_helper_version text DEFAULT '0.1.0'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
DECLARE
  v_user_id uuid;
  v_device_id uuid;
  v_expires_at timestamptz;
  v_helper_secret text;
  v_failed_attempts integer;
  v_ip text;
  v_ip_attempt_count integer;
BEGIN
  BEGIN
    v_ip := nullif(current_setting('request.headers', true), '')::jsonb->>'cf-connecting-ip';
  EXCEPTION WHEN OTHERS THEN
    v_ip := NULL;
  END;

  IF v_ip IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext(v_ip)::bigint);
  END IF;

  -- v0.19: probabilistic cleanup. Was unconditional DELETE on every call.
  -- 1% = on average once per 100 pair attempts → lock contention amortised.
  IF random() < 0.01 THEN
    DELETE FROM public.pairing_attempt_log WHERE attempted_at < now() - interval '1 hour';
  END IF;

  INSERT INTO public.pairing_attempt_log (ip_addr) VALUES (v_ip);

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

  SELECT user_id, expires_at, failed_attempts
  INTO v_user_id, v_expires_at, v_failed_attempts
  FROM public.pairing_codes WHERE code = p_pairing_code;

  IF v_user_id IS NULL THEN
    UPDATE public.pairing_codes SET failed_attempts = failed_attempts + 1
    WHERE code = p_pairing_code;
    RETURN jsonb_build_object('error', 'invalid_code', 'message', 'Invalid pairing code');
  END IF;

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
$$;

-- Step 2: guaranteed sweep path inside cleanup_expired_data.
-- We replicate the existing function body and append pairing_attempt_log cleanup
-- as the last step (before the return). Keeps all prior cleanup semantics.
CREATE OR REPLACE FUNCTION public.cleanup_expired_data()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions AS $$
DECLARE
  v_user RECORD;
  v_total_sessions integer := 0;
  v_total_alerts integer := 0;
  v_total_snapshots integer := 0;
  v_pairing_log_deleted integer := 0;
  v_deleted integer;
BEGIN
  IF current_setting('request.jwt.claims', true)::jsonb ->> 'role' != 'service_role' THEN
    RAISE EXCEPTION 'Forbidden: service_role required';
  END IF;

  FOR v_user IN
    SELECT us.user_id, us.data_retention_days
    FROM public.user_settings us
    WHERE us.data_retention_days > 0
  LOOP
    BEGIN
      DELETE FROM public.sessions
      WHERE user_id = v_user.user_id
        AND status = 'Ended'
        AND last_active_at < now() - (v_user.data_retention_days || ' days')::interval;
      GET DIAGNOSTICS v_deleted = ROW_COUNT;
      v_total_sessions := v_total_sessions + v_deleted;

      DELETE FROM public.alerts
      WHERE user_id = v_user.user_id
        AND created_at < now() - (v_user.data_retention_days || ' days')::interval;
      GET DIAGNOSTICS v_deleted = ROW_COUNT;
      v_total_alerts := v_total_alerts + v_deleted;

      DELETE FROM public.device_snapshots
      WHERE user_id = v_user.user_id
        AND captured_at < now() - (v_user.data_retention_days || ' days')::interval;
      GET DIAGNOSTICS v_deleted = ROW_COUNT;
      v_total_snapshots := v_total_snapshots + v_deleted;

    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'cleanup_expired_data: failed for user %, skipping: %', v_user.user_id, SQLERRM;
    END;
  END LOOP;

  -- v0.19: pairing_attempt_log scrub — guaranteed path if this function is
  -- scheduled. Register_helper also probabilistically cleans up (1%) as a
  -- belt-and-suspenders fallback if this function isn't scheduled.
  DELETE FROM public.pairing_attempt_log WHERE attempted_at < now() - interval '1 hour';
  GET DIAGNOSTICS v_pairing_log_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'sessions_deleted', v_total_sessions,
    'alerts_deleted', v_total_alerts,
    'snapshots_deleted', v_total_snapshots,
    'pairing_attempt_log_deleted', v_pairing_log_deleted
  );
END;
$$;
