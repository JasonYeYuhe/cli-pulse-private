-- ============================================================
-- v0.56 — R0: Secure Remote Realtime Terminal — per-subscriber authz
-- Date: 2026-06-24 · *** WRITTEN, NOT YET APPLIED — OWNER-GATED ***
--
-- Operationalizes DEV_PLAN_R0_remote_realtime_terminal_2026-06-22.md (§2
-- design, §3 B1) + ~/.claude/plans/r0-realtime-auth-spec.md. Dual-reviewed
-- (Gemini 3.1 Pro 2026-05-30 + Gemini 3-Pro 2026-06-22, verdict GO).
--
-- ADDITIVE + INERT. Read by nobody until ALL of:
--   (a) the dedicated R0 ES256 keypair is generated and its public JWKS
--       registered as a Supabase Third-Party Auth trusted issuer, and
--   (b) the `mint-realtime-token` edge fn is deployed with the private
--       key as a secret, and
--   (c) a per-user `user_settings.realtime_private_enabled` flips TRUE
--       (the forced cutover — owner-gated).
-- Until (c), every session is created with realtime_private=false, the
-- helper keeps streaming to the PUBLIC `term:<uuid>` topic, and these
-- policies/columns govern nothing → ZERO behavior change. Safe to apply
-- even around an ASC review.
--
-- 🔴 PRIVATE topic uses a DISTINCT prefix `pterm:<uuid>`, NOT `term:`
--    (Gemini-3-Pro CRITICAL 2026-06-22). RLS on realtime.messages governs
--    PRIVATE joins only; a PUBLIC join to `term:<uuid>` ALWAYS bypasses
--    RLS. You therefore cannot make a single topic "private-only" — an
--    attacker could still join `term:<uuid>` publicly and eavesdrop. So a
--    private session broadcasts to `pterm:<uuid>` (RLS-governed) and the
--    public path keeps `term:<uuid>` for old clients. The cutover removes
--    the only `term:` producer → no public topic carries the stream → no
--    public eavesdrop is possible.
--
-- DRIFT RULE ([[feedback_supabase_function_body_drift]]): the two re-emitted
-- function bodies below were dumped LIVE from prod (gkjwsxotmwrgqsvfijzs)
-- via pg_get_functiondef on 2026-06-24 and re-emitted with ONLY the marked
-- [R0] additive change — every other semantic preserved verbatim. (The
-- 2026-05-30 draft on branch backend/migrate-v0.56-r0-realtime-authz is
-- SUPERSEDED: it predated commit e386c8d which enabled codex/gemini managed
-- sessions, so its re-emit would have regressed the provider allowlist to
-- claude-only, and it used the `term:` prefix.)
--
-- This whole script is intended to run as ONE transaction (the Supabase SQL
-- editor and `supabase db push` both wrap a migration in a single tx).
-- ============================================================

-- ------------------------------------------------------------
-- (1) Session-level mode flag — decided ATOMICALLY at session-create
--     (Codex #2: deciding at helper-register races the helper).
-- ------------------------------------------------------------
alter table public.remote_sessions
  add column if not exists realtime_private boolean not null default false;

-- ------------------------------------------------------------
-- (2) Per-user opt-in that decides the mode — the cutover switch.
-- ------------------------------------------------------------
alter table public.user_settings
  add column if not exists realtime_private_enabled boolean not null default false;

-- ------------------------------------------------------------
-- (3) READ policy on realtime.messages — owner-of-topic only, on the
--     PRIVATE `pterm:` prefix.
--
--     NEVER cast realtime.topic() — a `::uuid` cast throws 22P02 on a
--     malformed topic → DoS. Compare a CONSTRUCTED string instead:
--     'pterm:' || rs.id::text = realtime.topic().
--
--     `rs.realtime_private is true` server-enforces the gate (Codex HIGH):
--     only sessions explicitly marked private are reachable on `pterm:`.
--     `(select auth.uid())` is wrapped per the v0.55 RLS init-plan perf
--     convention.
-- ------------------------------------------------------------
drop policy if exists "r0 read own remote session terminal" on realtime.messages;
create policy "r0 read own remote session terminal"
  on realtime.messages for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and exists (
      select 1 from public.remote_sessions rs
      where rs.user_id = (select auth.uid())
        and rs.realtime_private is true
        and 'pterm:' || rs.id::text = realtime.topic()
    )
  );

-- ------------------------------------------------------------
-- (4) WRITE policy — mirror of read. The `mint-realtime-token` edge fn
--     signs a token whose sub = the session owner, so auth.uid() resolves
--     to the owner and this passes ONLY for that owner's own private
--     topics → cross-user INJECTION is structurally closed here.
--
--     The direct-HTTP `/realtime/v1/api/broadcast` path can't enforce an
--     event-name allowlist server-side; ownership (this policy) is the
--     security boundary, and event/payload SHAPE is validated helper-side
--     (trusted, on its OWN topic only).
--
--     Gemini MEDIUM: the broadcast HTTP API's evaluation of THIS insert
--     policy must be proven (a wrong aud/role token, or the realtime schema
--     not API-exposed, can silently no-op). See the pgTAP write-policy proof
--     in tests/ + the owner runbook's integration-verify step.
-- ------------------------------------------------------------
drop policy if exists "r0 broadcast own remote session terminal" on realtime.messages;
create policy "r0 broadcast own remote session terminal"
  on realtime.messages for insert to authenticated
  with check (
    realtime.messages.extension = 'broadcast'
    and exists (
      select 1 from public.remote_sessions rs
      where rs.user_id = (select auth.uid())
        and rs.realtime_private is true
        and 'pterm:' || rs.id::text = realtime.topic()
    )
  );

-- ------------------------------------------------------------
-- (5) Authorize RPC — the gate-done-RIGHT (ASSIGN → CHECK → SCOPE).
--
--     A bare `perform _remote_authenticate_helper_gated(...)` DISCARDS the
--     NULL-on-bad-secret return → gate BYPASS (the recurring R0 bug from
--     [[feedback_realtime_authz_design]]). We ASSIGN the result, CHECK for
--     null, then SCOPE ownership by the returned user — and additionally
--     require the session to be private (so a token is never minted for a
--     public session). Called by the edge fn (service role); also granted
--     to anon to mirror the sibling remote_helper_* fns (it is gated
--     internally by helper_secret, so anon-reachability is safe).
-- ------------------------------------------------------------
create or replace function public.remote_helper_authorize_broadcast(
  p_device_id uuid,
  p_helper_secret text,
  p_session_id uuid
) returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
declare
  v_user  uuid;
  v_owner uuid;
begin
  v_user := public._remote_authenticate_helper_gated(p_device_id, p_helper_secret);  -- ASSIGN
  if v_user is null then
    raise exception 'unauthorized' using errcode = '42501';                          -- CHECK
  end if;

  select rs.user_id into v_owner
  from public.remote_sessions rs
  where rs.id = p_session_id
    and rs.device_id = p_device_id
    and rs.user_id = v_user                                                           -- SCOPE by user
    and rs.realtime_private is true;                                                  -- private-only
  if v_owner is null then
    raise exception 'session not authorized for private broadcast' using errcode = '42501';
  end if;

  return v_owner;
end;
$function$;

revoke all on function public.remote_helper_authorize_broadcast(uuid, text, uuid) from public;
grant execute on function public.remote_helper_authorize_broadcast(uuid, text, uuid) to anon, service_role;

-- ------------------------------------------------------------
-- (6) Re-emit remote_app_request_session_start — set realtime_private
--     ATOMICALLY in the same insert from the caller's opt-in.
--     LIVE body (pg_get_functiondef 2026-06-24) preserved verbatim;
--     the ONLY changes are the two [R0] lines.
-- ------------------------------------------------------------
create or replace function public.remote_app_request_session_start(
  p_device_id uuid,
  p_provider text,
  p_cwd_basename text DEFAULT ''::text,
  p_cwd_hmac text DEFAULT NULL::text,
  p_client_label text DEFAULT NULL::text
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_device_owner uuid;
  v_session_id uuid;
  v_command_id uuid;
  v_provider text;
  v_payload text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    raise exception 'Remote Control is disabled';
  end if;

  v_provider := coalesce(p_provider, '');
  if v_provider not in ('claude', 'codex', 'gemini') then
    raise exception 'Invalid provider for managed session: %', p_provider;
  end if;

  select user_id into v_device_owner
  from public.devices
  where id = p_device_id;

  if v_device_owner is distinct from v_user_id then
    raise exception 'Device not found';
  end if;

  v_session_id := gen_random_uuid();

  insert into public.remote_sessions (
    id, user_id, device_id, provider, cwd_basename, cwd_hmac, client_label,
    status, last_event_at,
    realtime_private                                                       -- [R0] added column
  ) values (
    v_session_id, v_user_id, p_device_id, v_provider,
    coalesce(left(p_cwd_basename, 255), ''),
    p_cwd_hmac,
    nullif(left(coalesce(p_client_label, ''), 128), ''),
    'pending', now(),
    coalesce(                                                              -- [R0] atomic mode decision
      (select realtime_private_enabled from public.user_settings where user_id = v_user_id),
      false)
  );

  v_payload := jsonb_build_object(
    'provider',     v_provider,
    'cwd_basename', coalesce(left(p_cwd_basename, 255), ''),
    'cwd_hmac',     p_cwd_hmac,
    'client_label', nullif(left(coalesce(p_client_label, ''), 128), '')
  )::text;

  insert into public.remote_session_commands (
    user_id, device_id, session_id, kind, payload, status
  ) values (
    v_user_id, p_device_id, v_session_id, 'start',
    left(v_payload, 8192),
    'pending'
  )
  returning id into v_command_id;

  return jsonb_build_object(
    'session_id', v_session_id,
    'command_id', v_command_id
  );
end;
$function$;

-- ------------------------------------------------------------
-- (7) Re-emit remote_app_list_sessions — RETURN realtime_private so clients
--     pick the pterm:-private vs term:-public join (and rejoin on change).
--     LIVE body (pg_get_functiondef 2026-06-24) preserved verbatim; the
--     ONLY change is the [R0] key in the per-row jsonb_build_object.
-- ------------------------------------------------------------
create or replace function public.remote_app_list_sessions()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'extensions'
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if not public._remote_control_enabled_for_caller() then
    return '[]'::jsonb;
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id',               s.id,
          'device_id',        s.device_id,
          'device_name',      d.name,
          'provider',         s.provider,
          'cwd_basename',     s.cwd_basename,
          'cwd_hmac',         s.cwd_hmac,
          'status',           s.status,
          'client_label',     s.client_label,
          'created_at',       s.created_at,
          'last_event_at',    s.last_event_at,
          'realtime_private', coalesce(s.realtime_private, false)          -- [R0] added key
        )
        order by coalesce(s.last_event_at, s.created_at) desc
      )
      from public.remote_sessions s
      left join public.devices d on d.id = s.device_id
      where s.user_id = v_user_id
        and s.status in ('pending', 'running')
    ),
    '[]'::jsonb
  );
end;
$function$;

-- ------------------------------------------------------------
-- Post-apply verification (run manually after APPLY; expect the noted rows):
--   -- columns exist:
--   select column_name from information_schema.columns
--     where table_schema='public' and table_name='remote_sessions'
--       and column_name='realtime_private';                 -- 1 row
--   select column_name from information_schema.columns
--     where table_schema='public' and table_name='user_settings'
--       and column_name='realtime_private_enabled';         -- 1 row
--   -- both policies present:
--   select policyname, cmd from pg_policies
--     where schemaname='realtime' and tablename='messages'
--     order by policyname;                                  -- read (SELECT) + broadcast (INSERT)
--   -- authorize RPC granted to anon + service_role only (not public/authenticated):
--   select grantee, privilege_type from information_schema.role_routine_grants
--     where routine_schema='public' and routine_name='remote_helper_authorize_broadcast';
-- ============================================================
