-- ============================================================
-- migrate_v0.38 — Server-side unpair for cli-pulse-desktop v0.3.4
--
-- Strictly additive: adds public.unregister_desktop_helper. Mirrors
-- the helper_secret-gated, anon-callable auth pattern of
-- public.device_status (migrate_v0.36) — but instead of returning
-- status, deletes the device row.
--
-- Spec: cli-pulse-desktop/PROJECT_DEV_PLAN_2026-05-02_v0.3.4_dashboard_parity.md
--
-- Codex review (2026-05-02) on the v0.3.4 spec flagged that an
-- unconditional `paired = false` after one device is removed would
-- race multi-device accounts (Laptop A unpairs while Laptop B is
-- still active → account looks unpaired). Fix below: recompute
-- paired from the post-DELETE device count, in the same RPC
-- transaction.
-- ============================================================

create or replace function public.unregister_desktop_helper(
  p_device_id uuid,
  p_helper_secret text
) returns jsonb language plpgsql security definer
  set search_path = pg_catalog, public, extensions
as $$
declare
  v_user_id uuid;
  v_stored_hash text;
  v_provided_hash text;
  v_remaining integer;
begin
  v_provided_hash := encode(digest(p_helper_secret, 'sha256'), 'hex');

  select user_id, helper_secret into v_user_id, v_stored_hash
    from public.devices
    where id = p_device_id;

  -- Device row missing → idempotent success (matches local-only
  -- unpair UX: client sees the row is already gone and clears local
  -- state without fanfare). Privacy: same shape as hash-mismatch so
  -- callers without a valid helper_secret cannot enumerate which
  -- device_id UUIDs exist on the server.
  if v_user_id is null then
    return jsonb_build_object('deleted', false, 'reason', 'not_found');
  end if;

  -- Hash mismatch → reject with the same shape (not a leak).
  if v_stored_hash is distinct from v_provided_hash then
    return jsonb_build_object('deleted', false, 'reason', 'not_found');
  end if;

  -- DELETE first, then count remaining devices in the same tx so
  -- v_remaining sees the post-state. Recompute paired from the
  -- post-state — never blindly set false.
  delete from public.devices where id = p_device_id;

  select count(*) into v_remaining
    from public.devices
    where user_id = v_user_id;

  update public.profiles
    set paired = (v_remaining > 0)
    where id = v_user_id;

  return jsonb_build_object(
    'deleted', true,
    'remaining_devices', v_remaining
  );
end;
$$;

grant execute on function public.unregister_desktop_helper(uuid, text)
  to anon, authenticated;
