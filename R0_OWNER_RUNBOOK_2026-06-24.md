# R0 Owner Runbook — apply `migrate_v0.56` + deploy `mint-realtime-token` — 2026-06-24

This is the **owner-gated** half of R0 slice **B1**. The agent has WRITTEN + tested
everything; **applying / deploying / key-generation / issuer-config are yours** (autonomy:
backend schema + account-level + key material). Every artifact is **additive and inert** —
nothing here changes behavior until you run the **forced cutover** (step 8). Safe to do even
around an ASC review.

Artifacts in this PR:
- `backend/supabase/migrate_v0.56_realtime_terminal_authz.sql` — the migration (WRITE-only).
- `backend/supabase/functions/mint-realtime-token/` — edge fn (`index.ts` + `token.ts` +
  `request.ts`) and its deno tests (`token_test.ts`, `request_test.ts`, green in CI).
- `backend/supabase/tests/migrate_v0.56_realtime_terminal_authz.test.sql` — pgTAP (owner-run).

> **Plan refs:** `DEV_PLAN_R0_remote_realtime_terminal_2026-06-22.md` §3 B1 / §5 / §6;
> `~/.claude/plans/r0-realtime-auth-spec.md` §3b/§4.

---

## ✅ ACTIVATION RECORD — executed 2026-06-24 (owner-authorized, Gemini-3.1-Pro GO-WITH-CHANGES)

The infrastructure below is now **LIVE in prod** (`gkjwsxotmwrgqsvfijzs`), all **gated-OFF**
(every `user_settings.realtime_private_enabled` is false → no session is private → public
`term:` path unchanged → **zero behavior change for current users**):

- **migrate_v0.56 APPLIED** (tracked migration `v0_56_realtime_terminal_authz`). Verified:
  both columns, both `realtime.messages` policies (SELECT+INSERT), `authorize_broadcast`
  RPC, both re-emitted RPCs. Drift-reconfirmed against live bodies before apply.
- **Dedicated R0 ES256 keypair generated** → `~/Library/Application Support/CLI-Pulse-Secrets/r0-20260624/`
  (`r0_private_pkcs8.pem` SECRET + `r0_public_jwks.json`). **kid = `r0-20260624`**.
- **Third-Party Auth issuer registered via `jwks_url`** — TPA id
  `b87b4dc9-8c28-40e3-aab6-313ad62447e3`, `jwks_url = …/functions/v1/r0-jwks`. Supabase matches
  by **`kid`** (not `iss`), so this is additive and cannot affect existing GoTrue auth.
  ⚠️ **GOTCHA:** inline `custom_jwks` was tried first (TPA `bde24b8d…`) but this project's
  resolver **never resolved it** (`resolved_at` stayed null for 25+ min → tokens rejected
  `PGRST301`/401). Switching to a **hosted `jwks_url`** resolved **instantly** (`resolved_jwks:
  true`). On this project, use `jwks_url`, NOT `custom_jwks`.
- **`r0-jwks` edge fn DEPLOYED** (verify_jwt=OFF, `Cache-Control: public, max-age=3600`) — serves
  the public JWKS for the issuer. (Public verification key only; no secret.)
- **Edge-fn secrets set** (`R0_JWT_PRIVATE_KEY`/`R0_JWT_ISSUER=https://clipulse.app/r0`/
  `R0_JWT_KID=r0-20260624`/`R0_JWT_TTL_SECONDS=3600`).
- **`mint-realtime-token` edge fn DEPLOYED** (verify_jwt=ON). Verified: bogus→403, malformed→400,
  GET→405, and a **real mint produced a correctly-signed token** (`kid:r0-20260624, sub:<owner>,
  role/aud:authenticated, exp=iat+3600`).
- **✅ TPA token-trust FULLY VERIFIED end-to-end** (with a throwaway test user, since deleted):
  a minted token is **trusted by PostgREST** (`auth.uid()` resolved → RLS returned the owner's
  own row) AND by **Realtime** (broadcast to `pterm:<session>` → HTTP 202). The complete auth
  chain works. (The owner-vs-non-owner write-RLS *delivery* filtering — Gemini MEDIUM — is proven
  at the SQL level by the pgTAP suite and is the cutover's final failure-injection step §8.3.)

**STILL OWNER-GATED (do NOT do until B3 is in a shipped App Store build):** the forced cutover
+ disabling Public Channels (see §8). Flipping the flag now would blackhole every currently
deployed pre-B3 app.

---

## 0. Ground-truth correction (read first)

The plan's §0 said the v0.56 file "was never committed." **It actually exists** as a stale
2026-05-30 draft on branch `backend/migrate-v0.56-r0-realtime-authz`. That draft is
**SUPERSEDED and must not be applied**, because:
- it predates commit `e386c8d` (enable codex/gemini managed sessions), so its re-emit of
  `remote_app_request_session_start` would **regress the provider allowlist to claude-only**;
- it uses the public `term:` prefix, not the `pterm:` private prefix the 2026-06-22 Gemini
  CRITICAL requires.

This PR's migration was re-emitted from **live prod bodies dumped 2026-06-24** (see §4).

---

## 1. Order of operations

```
1. generate R0 ES256 keypair            (this machine; never commit the private key)   → §2
2. register public JWKS as a trusted issuer  (Supabase dashboard / mgmt API)           → §3
3. diff the re-emitted RPCs vs the live dumps below  (sanity)                           → §4
4. apply migrate_v0.56                   (SQL editor / supabase db push)                → §5
5. set edge-fn secrets + deploy mint-realtime-token                                     → §6
6. run pgTAP on a BRANCH db              (optional but recommended)                     → §7
7. (LATER, separate decision) forced cutover: flip realtime_private_enabled             → §8
```

(§0 below — the superseded-draft warning — is a read-first prerequisite, not a step.)
Steps 1–5 are safe anytime (inert). **Step 7 is the only one that changes behavior** and
gates the actual security; do it only once R0-capable clients (B3, shipping first) are
measurably deployed.

---

## 2. Generate the dedicated R0 ES256 keypair

A **dedicated** keypair (NOT the project GoTrue key — Supabase won't export it). ES256 =
ECDSA P-256. The edge fn imports the **PKCS8** private PEM; the issuer publishes the **public
JWKS**. Run locally; store the private key in `~/Library/Application Support/CLI-Pulse-Secrets/`
(same place as the other signing material) — **never in the repo**.

The most reliable path (emits BOTH the PKCS8 PEM and the public JWKS, no openssl coordinate
fiddling). Save as `gen_r0_keypair.ts`, run with `deno run gen_r0_keypair.ts`:

```ts
// gen_r0_keypair.ts — generate the R0 ES256 keypair + its public JWKS.
const kid = `r0-${new Date().toISOString().slice(0, 10)}`; // e.g. r0-2026-06-24
const pair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);

const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
const b64 = btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g)!.join("\n");
const privPem = `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`;

const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
const publicJwks = {
  keys: [{ kty: "EC", crv: "P-256", alg: "ES256", use: "sig", kid, x: jwk.x, y: jwk.y }],
};

// Write to an ABSOLUTE secrets dir (NOT the CWD) so a stray run from inside the
// repo can never drop the private key into a git-trackable path. (.gitignore
// also covers *.pem / r0_*.pem / gen_r0_keypair.ts as belt-and-suspenders.)
const dir = `${Deno.env.get("HOME")}/Library/Application Support/CLI-Pulse-Secrets`;
await Deno.mkdir(dir, { recursive: true });
await Deno.writeTextFile(`${dir}/r0_private_pkcs8.pem`, privPem);          // SECRET
await Deno.writeTextFile(`${dir}/r0_public_jwks.json`, JSON.stringify(publicJwks, null, 2)); // publish
console.log("kid =", kid);
console.log(`wrote ${dir}/r0_private_pkcs8.pem (SECRET) + r0_public_jwks.json (publish)`);
```

You now have:
- `r0_private_pkcs8.pem` → edge-fn secret `R0_JWT_PRIVATE_KEY` (step 6). **SECRET.**
- `r0_public_jwks.json` → the JWKS to publish at the issuer (step 3).
- `kid` → edge-fn secret `R0_JWT_KID`; must match the JWKS `kid`.

---

## 3. Register the public JWKS as a Supabase Third-Party Auth trusted issuer

Goal: make Realtime/PostgREST **trust ES256 tokens whose `iss` = your chosen issuer URL and
`kid` = the published key**, so the minted token's `auth.uid()` resolves to the session owner
in the RLS policies. This is **additive** (a new issuer) — it does not touch project auth and
won't log anyone out.

1. **Pick an issuer URL** you control, e.g. `https://<your-domain>/r0` (it just needs to be a
   stable, unique string used as both `iss` and the JWKS location root). This becomes edge-fn
   secret `R0_JWT_ISSUER`.
2. **Publish the JWKS** (`r0_public_jwks.json`) at `<issuer>/.well-known/jwks.json` over HTTPS
   (any static host — GitHub Pages, Cloudflare, the marketing site). It must be reachable by
   Supabase.
3. **Register it** in Supabase: Dashboard → **Authentication → Third-Party Auth** (a.k.a.
   external/custom JWT issuers) → add a custom issuer with the issuer URL + JWKS URL. Map the
   token's `role` claim → `authenticated` (the token already carries `role:"authenticated"`).
   If your project exposes this only via the management API / `config.toml`, set the
   equivalent `[auth.third_party]` issuer entry. (Ref: Supabase "Third-Party Auth" docs.)
4. **Verify trust** before relying on it: mint a token by hand (or via the deployed edge fn in
   step 6) and confirm a Realtime **private** join to a `pterm:` topic is accepted for the
   owner. The integration test in step 7/8 is the authoritative check.

> If the third-party-issuer setup proves fiddly, the spec's documented **fallback** (helper →
> coalescing edge fn → broadcast via the **service role**, helper holds no key) is available —
> but it puts the edge fn in the per-batch hot path. Prefer the dedicated-key direct-stream;
> only fall back if issuer registration is blocked. See `r0-realtime-auth-spec.md` §3b.

---

## 4. Live function dumps (diff against the re-emit before applying)

Captured **2026-06-24** via `pg_get_functiondef` from prod `gkjwsxotmwrgqsvfijzs` (the
drift-rule source of truth). The migration's re-emits (§6/§7 of the .sql) are these bodies
**verbatim** except the marked `[R0]` lines. Diff to confirm nothing else changed since:

<details><summary><code>remote_app_request_session_start</code> (live 2026-06-24)</summary>

```sql
CREATE OR REPLACE FUNCTION public.remote_app_request_session_start(p_device_id uuid, p_provider text, p_cwd_basename text DEFAULT ''::text, p_cwd_hmac text DEFAULT NULL::text, p_client_label text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
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
    status, last_event_at
  ) values (
    v_session_id, v_user_id, p_device_id, v_provider,
    coalesce(left(p_cwd_basename, 255), ''),
    p_cwd_hmac,
    nullif(left(coalesce(p_client_label, ''), 128), ''),
    'pending', now()
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
$function$
```
</details>

<details><summary><code>remote_app_list_sessions</code> (live 2026-06-24)</summary>

```sql
CREATE OR REPLACE FUNCTION public.remote_app_list_sessions()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
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
          'id',            s.id,
          'device_id',     s.device_id,
          'device_name',   d.name,
          'provider',      s.provider,
          'cwd_basename',  s.cwd_basename,
          'cwd_hmac',      s.cwd_hmac,
          'status',        s.status,
          'client_label',  s.client_label,
          'created_at',    s.created_at,
          'last_event_at', s.last_event_at
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
$function$
```
</details>

> **Re-dump right before applying** (`select pg_get_functiondef(...)`) and re-diff — if prod
> drifted again between now and apply, fold the newer body in. This is the
> [[feedback_supabase_function_body_drift]] discipline.

---

## 5. Apply `migrate_v0.56`

Run the whole file as one transaction (SQL editor or `supabase db push`). It requires
privilege to `create policy on realtime.messages` — the SQL editor's `postgres` role has it
(the same privilege the policy creation needs). Then run the post-apply verification block at
the bottom of the .sql (expect: 2 new columns, 2 realtime policies, the authorize RPC granted
to `anon`+`service_role` only).

The CI static guards already pass for this migration (search_path, RPC contract, user_id
cascade, date windows, alert types — all green in the PR).

---

## 6. Deploy `mint-realtime-token`

Set the secrets, then deploy with **default JWT verification ON** (the helper sends the
project anon key as the gateway bearer; real auth is the `helper_secret` inside the RPC):

```bash
SECRETS="$HOME/Library/Application Support/CLI-Pulse-Secrets"
supabase secrets set \
  R0_JWT_PRIVATE_KEY="$(cat "$SECRETS/r0_private_pkcs8.pem")" \
  R0_JWT_ISSUER="https://<your-domain>/r0" \
  R0_JWT_KID="r0-2026-06-24" \
  R0_JWT_TTL_SECONDS=3600
supabase functions deploy mint-realtime-token   # do NOT pass --no-verify-jwt
```

> `R0_JWT_TTL_SECONDS` is clamped to **[60, 3600]** by the edge fn (token.ts /
> request.ts) — a misconfigured huge value can't mint a long-lived token, since
> R0 has no revocation list and leans on short expiry.

`SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` are auto-provided. The fn:
- 400 on a malformed body; 403 on any authorize-gate reject; 500 only on misconfig/sign error.
- **Never logs** the helper_secret or the token (logs carry session_id + status only).

Smoke (expect **403** — no such device, proves the gate path without leaking which step
failed):

```bash
curl -s -X POST "$SUPABASE_URL/functions/v1/mint-realtime-token" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{"device_id":"00000000-0000-4000-8000-000000000000","helper_secret":"x","session_id":"00000000-0000-4000-8000-000000000000"}'
```

---

## 7. Run pgTAP on a BRANCH db (recommended)

`backend/supabase/tests/migrate_v0.56_realtime_terminal_authz.test.sql` is **owner-run** —
pgTAP isn't installed in prod and there's no SQL test runner in CI. On a branch DB (or local
`supabase start`) **after** applying the migration:

```sql
create extension if not exists pgtap;
\i backend/supabase/tests/migrate_v0.56_realtime_terminal_authz.test.sql
```

Expect **14/14 ok**. It runs in a transaction and rolls back (no fixtures/partition/rows
left behind). It needs privilege to create a `realtime.messages` partition and `SET ROLE` —
run it as `postgres`.

---

## 8. Forced cutover — the ONLY behavior change (separate, later decision)

R0 with the flag OFF is **mechanism, not protection** — the public `term:` eavesdrop+inject
hole stays open. Track as security debt until this step.

**Pre-req: B3 (clients subscribe-private) must be SHIPPED and baked** to a measured install
base FIRST, and B2 (the Python producer, default-OFF) deployed. Then:

0. **Enable the helper-side producer gate** (B2): set
   `"remote_realtime_broadcast_enabled": true` in `~/.cli-pulse-helper.json` on the test Mac
   and restart the helper. This is a SEPARATE field from `remote_realtime_enabled` (which is a
   vestigial Swift-round-trip flag defaulting true) — the broadcast producer reads ONLY
   `remote_realtime_broadcast_enabled`, which defaults false so R0 stays dark until you flip it.
   Even on, the helper only broadcasts sessions the mint edge fn authorizes (private-only).
1. Flip per-user opt-in: `update public.user_settings set realtime_private_enabled = true
   where user_id = '<test user>';` (start with your own account).
2. Start a NEW managed session → it is created `realtime_private=true` → helper emits ONLY to
   `pterm:<uuid>`; the iPhone joins `pterm:<uuid>` private with a minted token.
3. **The real security proof (failure-injection):** a **second account** must get **ZERO**
   messages when it tries the same `pterm:` topic (not a silent pass), AND the legacy
   `term:<uuid>` topic must carry **nothing** for that session.
4. Roll forward (more users / default-on) only after that proof passes.
5. 🔴 **FINAL step to actually close eavesdrop (Gemini-3.1-Pro CRITICAL, 2026-06-24):**
   `pterm:` + RLS does **NOT** structurally close eavesdrop while **Public Channels** are
   globally enabled — Supabase Realtime does not isolate public vs private joins on the same
   topic string, so an attacker who joins `pterm:<uuid>` with `private:false` **bypasses RLS
   entirely** and can eavesdrop/inject. Until you flip this, confidentiality rests ONLY on the
   122-bit session-UUID entropy (unguessable externally, but not "structurally closed"). Once
   ALL clients are on `pterm:`-private and `term:` is fully deprecated, **globally disable
   "Public Channels"** in the Supabase Dashboard → Project Settings → Realtime (or the mgmt API
   `realtime` config). Only then is the eavesdrop hole truly closed.

Rollback at any point: `update public.user_settings set realtime_private_enabled = false`
(new sessions revert to public `term:`); the columns/policies/RPC/edge-fn can stay (inert).
Re-enable Public Channels if you disabled them and need the legacy path back.

---

## Secret hygiene
- `R0_JWT_PRIVATE_KEY` lives ONLY as an edge-fn secret + in `CLI-Pulse-Secrets/`. Never in the
  repo. If a placeholder is ever needed in code, split the literal
  ([[feedback_github_secret_scanner]]).
- Never log the token or `helper_secret` (the fn and the B2 helper both already avoid it).
- The `r0_public_jwks.json` is public by design (it's the verification key) — safe to publish.
