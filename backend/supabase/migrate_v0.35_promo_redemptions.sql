-- ============================================================
-- v0.35: promo redemptions (XHS / Twitter 福利兑换)
--
-- Backend-only Pro/Team tier grant for the XHS pricing-poll
-- campaign (and future similar campaigns). v1.11.0 client
-- requires zero code changes:
-- `SubscriptionManager.updateCurrentEntitlements` already falls
-- through to `get_user_tier()` when no paid StoreKit transaction
-- is present (CLIPulseCore/SubscriptionManager.swift:158-178).
-- Android takes the same path (SupabaseClient.kt:408).
--
-- Apply via: Supabase MCP `apply_migration` tool, OR Supabase SQL
-- Editor with service-role JWT. Do NOT apply via authenticated
-- session — the RLS lockdown depends on service_role.
--
-- Daily op (after apply):
--   select public.grant_promo('user@example.com', 'xhs',
--     'xhs_pricing_poll_2026_05', 'pro', 14, 'liked+saved+shared+voted');
-- ============================================================

create table public.promo_redemptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  email text not null,
  source text not null check (source in ('xhs', 'twitter', 'manual')),
  campaign text,
  tier_granted text not null default 'pro' check (tier_granted in ('pro', 'team')),
  granted_at timestamptz not null default now(),
  granted_until timestamptz not null,
  notes text,
  constraint promo_redemptions_duration_positive check (granted_until > granted_at)
);

create index idx_promo_redemptions_user_active
  on public.promo_redemptions(user_id, granted_until desc);

alter table public.promo_redemptions enable row level security;
-- 不开任何 policy,只 service_role 能读写

-- ─────────────────────────────────────────────────────────────
-- get_user_tier: rank-safe precedence so an `pro` promo never
-- downgrades an `team` admin grant on profiles.tier.
--
-- Precedence:
--   1. active paid subscription with `tier != 'free'` wins
--      outright (StoreKit / RevenueCat → server)
--   2. otherwise return the highest of:
--        - active promo redemption  (granted_until > now())
--        - profiles.tier            (legacy admin override)
--        - 'free'
--      under rank: team > pro > free
--
-- Return shape: jsonb_build_object('tier', '<tier>')
-- ─────────────────────────────────────────────────────────────
create or replace function public.get_user_tier()
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_paid_tier text;
  v_promo_tier text;
  v_profile_tier text;
  v_tier text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  -- Step 1: paid subscription wins outright (server already
  -- excludes auto-created 'free' rows; the explicit predicate
  -- here is belt-and-suspenders).
  select s.tier into v_paid_tier
  from public.subscriptions s
  where s.user_id = v_user_id
    and s.status = 'active'
    and s.tier != 'free'
    and (s.current_period_end is null or s.current_period_end > now())
  limit 1;

  if v_paid_tier is not null then
    return jsonb_build_object('tier', v_paid_tier);
  end if;

  -- Step 2a: latest active promo (granted_until is unique enough
  -- as a tiebreaker since each grant_promo call inserts a new row).
  select tier_granted into v_promo_tier
  from public.promo_redemptions
  where user_id = v_user_id and granted_until > now()
  order by granted_until desc
  limit 1;

  -- Step 2b: legacy admin override on profiles.tier.
  select p.tier into v_profile_tier
  from public.profiles p where p.id = v_user_id;

  -- Step 2c: rank-safe max(promo, profile, free).
  v_tier := case
    when v_promo_tier = 'team' or v_profile_tier = 'team' then 'team'
    when v_promo_tier = 'pro'  or v_profile_tier = 'pro'  then 'pro'
    else 'free'
  end;

  return jsonb_build_object('tier', v_tier);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- ─────────────────────────────────────────────────────────────
-- grant_promo: service-role admin function. Called by hand from
-- the Supabase SQL Editor when an XHS DM comes in. Validates
-- inputs and bails with a descriptive jsonb error so the
-- operator (Jason) can read what went wrong without diffing
-- stack traces.
--
-- Validation rules:
--   - p_email   : trim + lower; reject empty
--   - p_source  : one of ('xhs', 'twitter', 'manual')
--   - p_tier    : one of ('pro', 'team')
--   - p_days    : integer > 0
--   - profile lookup must match (else user_not_found)
-- ─────────────────────────────────────────────────────────────
create or replace function public.grant_promo(
  p_email text,
  p_source text default 'xhs',
  p_campaign text default 'xhs_pricing_poll_2026_05',
  p_tier text default 'pro',
  p_days integer default 14,
  p_notes text default null
) returns jsonb as $$
declare
  v_email_clean text := lower(trim(coalesce(p_email, '')));
  v_user_id uuid;
  v_redemption_id uuid;
  v_granted_until timestamptz;
begin
  if v_email_clean = '' then
    return jsonb_build_object('ok', false, 'error', 'invalid_email', 'email', p_email);
  end if;
  if p_source is null or p_source not in ('xhs', 'twitter', 'manual') then
    return jsonb_build_object('ok', false, 'error', 'invalid_source', 'source', p_source);
  end if;
  if p_tier is null or p_tier not in ('pro', 'team') then
    return jsonb_build_object('ok', false, 'error', 'invalid_tier', 'tier', p_tier);
  end if;
  if p_days is null or p_days <= 0 then
    return jsonb_build_object('ok', false, 'error', 'invalid_days', 'days', p_days);
  end if;

  -- Single source of truth for the expiry timestamp — used by
  -- both the INSERT and the return JSON so they can never drift
  -- by microseconds.
  v_granted_until := now() + make_interval(days => p_days);

  select id into v_user_id from public.profiles
    where lower(email) = v_email_clean
    limit 1;

  if v_user_id is null then
    return jsonb_build_object('ok', false, 'error', 'user_not_found', 'email', p_email);
  end if;

  insert into public.promo_redemptions(
    user_id, email, source, campaign, tier_granted, granted_until, notes
  )
  values (
    v_user_id, v_email_clean, p_source, p_campaign, p_tier, v_granted_until, p_notes
  )
  returning id into v_redemption_id;

  return jsonb_build_object(
    'ok', true,
    'redemption_id', v_redemption_id,
    'user_id', v_user_id,
    'granted_until', v_granted_until
  );
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;

-- Service-role-only: lock down execution so a leaked anon JWT
-- can't grant itself promos.
revoke execute on function public.grant_promo(text, text, text, text, integer, text)
  from public, anon, authenticated;
grant execute on function public.grant_promo(text, text, text, text, integer, text)
  to service_role;
