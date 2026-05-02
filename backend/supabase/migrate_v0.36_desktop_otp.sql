-- ============================================================
-- migrate_v0.36 — Desktop OTP sign-in (cli-pulse-desktop v0.3.0)
--
-- Adds two strictly-additive RPCs so the Tauri desktop app can
-- onboard pure Windows / Linux users without going through the
-- Mac menu-bar pairing-code flow:
--
--   register_desktop_helper(p_device_name, ...) -- auth.uid()-based
--     mirror of register_helper. Mints a device_id + helper_secret
--     against the user's session JWT. Used after the desktop OTP
--     sign-in completes.
--
--   device_status(p_device_id, p_helper_secret) -- returns
--     {status: 'healthy' | 'device_missing' | 'account_missing'}.
--     Called by the helper_sync error classifier to distinguish
--     "device removed by another client" from a transient blip.
--
-- Both functions are SECURITY DEFINER and lock down search_path
-- to mirror existing register_helper hardening.
--
-- Spec: PROJECT_DEV_PLAN_2026-05-02_v0.3.0_otp_login.md (in the
-- cli-pulse-desktop repo).
-- ============================================================

-- pgcrypto is already enabled via schema.sql:7, but list it here so
-- this migration is self-contained against fresh Supabase projects.
create extension if not exists pgcrypto;

-- ────────────────────────────────────────────────────────────
-- register_desktop_helper
-- ────────────────────────────────────────────────────────────
-- Desktop direct sign-in path. Mirror of register_helper but skips
-- the pairing-code dance: trusts auth.uid() from the user JWT.
-- Returns the same shape as register_helper so the client code
-- path past this RPC is identical.
--
-- Per-user device cap (20) enforced here. Codex/Gemini review
-- flagged this as a JWT-replay DoS vector; legacy register_helper
-- currently lacks a cap. pg_advisory_xact_lock per-user makes the
-- count-then-insert race-safe without serializing across users.
create or replace function public.register_desktop_helper(
  p_device_name text,
  p_device_type text default 'desktop',
  p_system text default '',
  p_helper_version text default ''
) returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_device_id uuid;
  v_helper_secret text;
  v_existing_count integer;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Per-user transaction-scoped advisory lock. Concurrent calls for
  -- the same user_id serialize through this lock; different users
  -- do not contend. Prevents the count-then-insert race that would
  -- otherwise let two parallel calls each see 19 devices and both
  -- insert (final count 21).
  perform pg_advisory_xact_lock(hashtext(v_user_id::text)::bigint);

  -- Cap per-user devices at 20. Generous enough for power users
  -- (multiple Macs + Linux servers + Windows boxes) but blocks
  -- abuse / runaway scripts.
  select count(*) into v_existing_count
    from public.devices
    where user_id = v_user_id;
  if v_existing_count >= 20 then
    raise exception 'Device limit reached (20). Remove an existing device first.'
      using errcode = '53000'; -- insufficient_resources
  end if;

  -- Plaintext secret returned to client; column stores SHA-256 hash.
  -- Matches register_helper convention exactly (helper_rpc.sql:97).
  v_helper_secret := 'helper_' || encode(gen_random_bytes(32), 'hex');

  insert into public.devices (
    user_id, name, type, system, helper_version,
    status, helper_secret
  )
  values (
    v_user_id,
    left(p_device_name, 255),
    left(p_device_type, 50),
    left(p_system, 255),
    left(p_helper_version, 20),
    'Online',
    encode(digest(v_helper_secret, 'sha256'), 'hex')
  )
  returning id into v_device_id;

  update public.profiles set paired = true where id = v_user_id;

  return jsonb_build_object(
    'device_id', v_device_id,
    'user_id', v_user_id,
    'helper_secret', v_helper_secret
  );
end;
$$;

-- Authenticated callers only (anon key gets blocked by auth.uid() check).
grant execute on function public.register_desktop_helper(text, text, text, text)
  to authenticated;
revoke execute on function public.register_desktop_helper(text, text, text, text)
  from anon;

-- ────────────────────────────────────────────────────────────
-- device_status
-- ────────────────────────────────────────────────────────────
-- Used by the helper_sync error classifier to distinguish
-- "device or account is gone" from "transient auth blip" after a
-- 401 on helper_sync. Anon-callable (helper has device credentials,
-- not a user JWT) but verifies the supplied helper_secret hash
-- matches the stored hash — so this is not a device-id enumeration
-- oracle.
--
-- Returns 'device_missing' for both genuinely-missing devices and
-- hash-mismatches, so callers without a valid helper_secret cannot
-- enumerate which device_id UUIDs exist on the server.
create or replace function public.device_status(
  p_device_id uuid,
  p_helper_secret text
) returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid;
  v_stored_hash text;
  v_provided_hash text;
  v_account_active boolean;
begin
  v_provided_hash := encode(digest(p_helper_secret, 'sha256'), 'hex');

  select user_id, helper_secret into v_user_id, v_stored_hash
    from public.devices
    where id = p_device_id;

  -- Device row missing entirely (manual delete, account-cascade, etc.)
  if v_user_id is null then
    return jsonb_build_object('status', 'device_missing');
  end if;

  -- Hash mismatch — secret was rotated server-side, or wrong device_id
  -- supplied. Treat as 'device_missing' to the caller (don't leak
  -- existence vs auth-mismatch).
  if v_stored_hash is distinct from v_provided_hash then
    return jsonb_build_object('status', 'device_missing');
  end if;

  -- Account presence check. If the profiles row exists, account is
  -- live. (devices.user_id FK has ON DELETE CASCADE so a deleted
  -- account already drops the device row. This branch is defensive.)
  select true into v_account_active
    from public.profiles
    where id = v_user_id;
  if v_account_active is null then
    return jsonb_build_object('status', 'account_missing');
  end if;

  return jsonb_build_object('status', 'healthy');
end;
$$;

grant execute on function public.device_status(uuid, text) to anon, authenticated;
