-- ============================================================================
-- 00_supabase_shim.sql — minimal Supabase-compatibility shim for PLAIN Postgres
-- ----------------------------------------------------------------------------
-- Lets the repo's real RLS (schema.sql + the remote-table DDL) be exercised on a
-- stock `postgres:N` image WITHOUT `supabase start` / Docker, so cross-user RLS
-- denial tests run in CI (resolves the long-standing C-3 schema.sql double-apply
-- blocker by NOT replaying schema.sql onto a Supabase snapshot — we seed a fresh
-- DB instead).
--
-- It recreates only what RLS needs:
--   * roles anon / authenticated / service_role (+ authenticator), as in Supabase
--   * the `auth` schema with auth.uid() / auth.role() / auth.jwt() reading the
--     `request.jwt.claims` GUC (exactly how Supabase/PostgREST exposes the JWT)
--   * a stand-in `auth.users` table that the public FKs reference
--   * default privileges so every public table created afterwards is granted to
--     `authenticated` (RLS — not a missing GRANT — must be the only thing that
--     denies access, otherwise a denial test could pass for the wrong reason)
--
-- NOTE: `service_role` is BYPASSRLS and `postgres` is superuser — both skip RLS,
-- exactly like prod. All denial assertions therefore run as `authenticated`.
-- ============================================================================

create extension if not exists pgcrypto;

-- ── Supabase roles ──────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator nologin noinherit;
  end if;
end $$;

grant anon, authenticated, service_role to authenticator;
-- so the test driver (running as postgres) can SET ROLE into them:
grant anon, authenticated, service_role to postgres;

grant usage on schema public to anon, authenticated, service_role;

-- Every public table/sequence created after this point is auto-granted to
-- authenticated (mirrors Supabase's default grants). schema.sql's later
-- `revoke select (helper_secret) on devices from authenticated` then correctly
-- claws that one column back.
alter default privileges for role postgres in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges for role postgres in schema public
  grant usage, select on sequences to authenticated;

-- ── auth schema + JWT accessors ─────────────────────────────────────────────
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

-- Stand-in for Supabase's auth.users (only the columns the public schema's FKs
-- and the on_auth_user_created trigger touch).
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function auth.uid()
returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
$$;

create or replace function auth.role()
returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'role', ''),
    'authenticated');
$$;

create or replace function auth.jwt()
returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
$$;

create or replace function auth.email()
returns text language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'email', '');
$$;

grant execute on function auth.uid(), auth.role(), auth.jwt(), auth.email()
  to anon, authenticated, service_role;
