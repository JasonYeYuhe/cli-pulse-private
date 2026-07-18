# Public Exposure Rotation Checklist

**Trigger:** 2026-04-28 — discovered that the public repo
`cli-pulse/cli-pulse` had carried full product source for an extended
period, including the most recent commit `b462fed…` before the rewrite.
Public refs are now distribution-only (`5d15080`, with all release tags
on `4f72f82` or earlier clean SHAs). This checklist tracks credential
rotation decisions.

This file should be updated with `[x]` as items are completed, and
amended with rotation dates / ticket links.

---

## Severity classification

The previously-public history exposed:

- **Embedded-by-design write tokens** (Supabase anon JWT, Sentry DSNs).
  Not "secrets" in the strict sense, but exposure narrows the defense
  surface and may attract abuse.
- **Public identifiers** (App Store Connect API Key ID, Issuer ID,
  bundle IDs, Google Play package name, Supabase project URL).
- **No private credentials** found in the scan: no `.p8`, no
  `service_role` Supabase key, no Google service-account JSON, no PEM
  private keys, no provider API keys, no GitHub PATs / Slack tokens.

The targeted scan was run against the worst-case contaminated commit
(`b462fed`). All matches were redacted in the remediation report.

---

## Action items

### Supabase anon key (project ref: `gkjws…ijzs`)

- Status before incident: embedded in 4 Apple `Info.plist` files,
  `APIClient.swift`, `HelperAPIClient.swift`, and as the Android
  default fallback in `android/app/build.gradle.kts`.
- Decoded JWT dates (rechecked 2026-04-28):
  - `iat = 2026-03-28 09:32:50 UTC` (≈ 31 days before the audit)
  - `exp = 2036-03-27 21:32:50 UTC` (≈ 10-year validity)
  - Plausible standard Supabase issuance. **No action needed on the
    dates themselves.** (The earlier "June 2026" mention was a decoding
    typo in the first report — see `## JWT date verification` below.)
- Action items:
  - [x] **RLS audit completed 2026-04-28.** Findings:
        - All 19 base + extension tables have RLS enabled (verified
          via `grep ENABLE ROW LEVEL SECURITY` across `schema.sql`
          and every `migrate_v*.sql`).
        - 31 policies reference the `anon` / `public` role list, but
          every policy condition is scoped by `auth.uid()` — anon
          callers without a Supabase session token cannot match.
        - Only 2 functions are `GRANT EXECUTE ... TO anon`:
          `public.get_track_git_activity(uuid, text)` and
          `public.ingest_commits(uuid, text, jsonb)`. Both use
          `SECURITY DEFINER` and gate access by checking
          `helper_secret = encode(digest(p_helper_secret, 'sha256'),
          'hex')` against `public.devices`. An attacker holding only
          the leaked anon JWT cannot guess valid `(device_id,
          helper_secret)` pairs, so neither function returns useful
          data or accepts writes.
        - `ingest_commits` additionally has DoS guards: 500-element
          batch cap and per-user advisory lock.
        - All RPC functions explicitly set
          `search_path = pg_catalog, public, extensions` (defense
          against search-path attacks; matches
          `migrate_v0.17_search_path_hardening.sql`).
        - service_role-gated functions (`cleanup_expired_data`,
          `cleanup_retention_data`, etc.) refuse calls without
          `request.jwt.claims->role = 'service_role'`. Anon callers
          cannot reach them.
  - [x] **Decision: do not rotate.** RLS + device-secret auth means
        the leaked anon JWT alone gives no useful access. Rotation
        would require a coordinated client release across macOS /
        iOS / watchOS / Android with no security gain. Item closed
        unless a future RLS regression surfaces.
  - [ ] If a future RLS regression is ever detected, schedule
        rotation alongside the planned release train, not as a
        hotfix.

### Sentry DSNs

- Status before incident: 2 DSNs in 4 `Info.plist` files
  (iOS+Watch shared DSN, separate macOS DSN). Android DSN stayed in
  `local.properties` — verified gitignored, never committed.
- Action items:
  - [x] **New DSNs generated 2026-04-28** via Sentry web admin
        (`jason-yeyuhe.sentry.io`). Two new client keys created:
        - `apple-ios` project — auto-named "COOL SLUG"
          (covers iOS app + watchOS app)
        - `apple-macos` project — auto-named "CAUSAL LADYBIRD"
        Old "DEFAULT" keys remain ENABLED so currently-shipped client
        versions keep reporting crashes. New DSN values are saved at
        `~/Library/Application Support/CLI-Pulse-Secrets/sentry-rotation-2026-04-28.txt`
        (mode 600, outside any git repo). Do not paste DSN values
        into any committed file other than the four `Info.plist`
        files at the next release.
  - [ ] **Next release:** swap the new DSN values into the four
        `Info.plist` files (iOS, Watch, macOS, Helper if applicable),
        bump version, build, sign, notarize, ship. Confirm the
        `beforeSend` scrubber is unchanged and
        `tracesSampleRate = 0` is preserved.
  - [ ] **2-3 weeks after the new release ships:** when crash-event
        traffic to the OLD `DEFAULT` keys drops to negligible (check
        the per-key event volume in Sentry), click `Disable` on the
        old `DEFAULT` keys in both projects to fully close the
        rotation. Update this checklist when done.
  - [x] Confirm Android Sentry DSN was never committed. Verified
        2026-04-28 — `git ls-files | grep local.properties` returns
        nothing; `android/.gitignore` lists `local.properties` and
        `/local.properties`. No rotation needed.

### App Store Connect API key

- Status before incident: Key ID `DMMFP…6XTXX` and Issuer ID
  `c5671c…49416` were embedded in 4 scripts under
  `CLI Pulse Bar/scripts/`. **The `.p8` private key was NOT
  committed.** Without the `.p8`, the IDs alone do not authenticate.
- Action items:
  - [x] Confirm the `.p8` file remains only in
        `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_DMMFP6XTXX.p8`
        on the development machine and is referenced by absolute path
        in scripts. Verified 2026-04-28: no `.p8` appears in any
        tracked git path (`git ls-files | grep -i '\.p8$'` empty);
        scripts reference `~/Library/.../AuthKey_*.p8` only.
  - [x] Add `*.p8` to root `.gitignore`. Done 2026-04-28 — same
        commit also adds `*.p12 *.pfx *.jks *.keystore *.key
        *.mobileprovision GoogleService-Info.plist
        google-services.json AuthKey_*` so future secret-shaped
        files are ignored by default.
  - [x] Do not rotate the ASC API key from this exposure. Decision
        documented; rotate only if the `.p8` itself leaks via another
        channel.

### Google Play upload keystore

- Status: `cli-pulse-upload.jks` is referenced in CI workflows via
  `${{ secrets.STORE_PASSWORD }}` / `${{ secrets.KEY_PASSWORD }}` only.
  The `.jks` itself was not committed.
- Action items:
  - [x] Verify `*.jks` is gitignored. Done 2026-04-28 — `*.jks` and
        `*.keystore` added to root `.gitignore`. No `.jks` appears in
        any tracked git path.
  - [x] Verify the keystore file itself remains only on the dev
        machine and Google Play's key-management side. No rotation
        needed.

### GitHub Actions secrets

- Status: every `.github/workflows/*.yml` file in the contaminated tree
  used `${{ secrets.X }}` indirection only. No hardcoded secret value
  appeared in committed YAML. Audited 2026-04-28.
- Action items:
  - [ ] Verify the *current* workflow secrets (`SUPABASE_ANON_KEY`,
        `GOOGLE_SERVICES_JSON`, `STORE_PASSWORD`, `KEY_PASSWORD`,
        `GOOGLE_WEB_CLIENT_ID`) match the values still in use; rotate
        any that have been around long enough to be considered stale by
        org policy. (Independent of this incident — does not need
        action from the public-exposure angle.)
  - [ ] Confirm CI logs from the contaminated period are not retained
        beyond the GitHub default retention (90 days) — those logs
        could have echoed values back into a public artifact if a
        misbehaving step ran with `set -x`. Spot-check one recent run.
        **Note:** logs on the *private* repo (`cli-pulse-private`) are
        the ones to check; public-repo CI did not run on the
        rewritten distribution-only state.

### Provider API keys / session cookies / OAuth secrets

- Status: targeted scan against `b462fed` found **no committed provider
  API keys, no `client_secret` strings, no real Google `ya29.…` tokens
  (only `ya29.test` test fixtures), no Anthropic `sk-ant-…`, no
  OpenAI `sk-…`, no GitHub PATs, no Slack tokens, no PEM private
  keys.**
  Re-scanned 2026-04-28 with broader patterns (api_key/apikey/api-key
  with quoted values, `BEGIN ... PRIVATE KEY` blocks, MII* base64
  prefixes) — no new findings. Apple Root CA G3 in
  `validate-receipt/index.ts` is the only PEM block and it is the
  public certificate.
- Action items:
  - [x] Final secret rescan completed 2026-04-28; no new findings.
  - [ ] Treat any future user-credential exposure as critical and
        page-worthy. This category was clean for this incident and
        must remain so.

### Supabase service_role / private keys / certificate material

- Status: scan found only the public Apple Root CA G3 certificate
  embedded in `backend/supabase/functions/validate-receipt/index.ts`
  (well-known, not a secret). **No `service_role` key, no private key
  blocks of any kind.**
  Re-scanned 2026-04-28: every `service_role` mention is either
  PL/pgSQL gate code (`if role != 'service_role' then raise
  exception`) or a `Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")`
  reference — values come from the runtime environment, never from
  committed code.
- Action items:
  - [x] Re-run the secret scan. Done 2026-04-28; no new findings.
  - [ ] Re-confirm once GitHub support GC ticket has completed
        (cheap to repeat; not blocking closeout).

---

## Remaining residual risk

- **Old commits may still be fetchable by SHA** until GitHub server-side
  GC runs. See `PUBLIC_REPO_GITHUB_SUPPORT_GC_REQUEST.md`.
- **Third-party clones / local downloads** of the previously-public
  archives cannot be revoked. Anyone who fetched
  `https://github.com/cli-pulse/cli-pulse/archive/refs/tags/v1.10.7.zip`
  before 2026-04-28 still has the source. There is no mitigation; this
  is the cost of having pushed source publicly. Treat the contained code
  as "publicly available historical leak" for any future
  threat-modelling.
- **Forks made before today** keep the source. Quick periodic check:
  ```bash
  gh api repos/cli-pulse/cli-pulse/forks --jq '.[].full_name'
  ```
  As of 2026-04-28 the public repo has **0 forks**.

---

## JWT date verification (correction to first report)

The first report said the Supabase anon JWT `iat` was around June 2026.
Re-decoding on 2026-04-28:

- `iat = 1774690370` → `2026-03-28T09:32:50+00:00`
- `exp = 2090266370` → `2036-03-27T21:32:50+00:00`

The "June 2026" reading was a decoding typo — the actual issuance is
March 28, 2026, about 31 days before the incident, which is plausible
(this matches when Supabase keys are typically rotated/issued for new
projects). 10-year validity is Supabase's default. **No clock or
timezone problem; no future-issued JWT.** No action recommended on the
date itself; the rotation decision (above) is independent.

---

## Closeout

This file is closed when:

- [ ] All `[ ]` items above are either `[x]` or have a written "won't
      do" rationale.
- [ ] GitHub Support GC ticket has been resolved.
- [ ] One final secret scan has been run against `b462fed` and any
      historical SHAs the user knows about, and no new findings have
      surfaced.
- [ ] `PUBLIC_REPO_GITHUB_SUPPORT_GC_REQUEST.md` has the support
      ticket ID recorded.
