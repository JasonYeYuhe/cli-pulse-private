# Public Exposure Rotation Checklist

**Trigger:** 2026-04-28 — discovered that the public repo
`JasonYeYuhe/cli-pulse` had carried full product source for an extended
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
  - [ ] **Audit Row Level Security first.** For every table reachable
        by the `anon` role, confirm RLS policies prevent reads/writes
        beyond what an unauthenticated client should ever do. Note:
        anon JWTs are by-design embedded in clients; RLS is the actual
        protection.
  - [ ] **Decide whether to rotate.** Rotation requires a coordinated
        client release across macOS / iOS / watchOS / Android because
        all shipped versions have this anon key embedded. Only do this
        if the RLS audit surfaces a finding that the new clients can
        tighten. Do not rotate purely as theatre.
  - [ ] If rotating: schedule the cycle alongside a planned release
        train, not as a hotfix.

### Sentry DSNs

- Status before incident: 2 DSNs in 4 `Info.plist` files
  (iOS+Watch shared DSN, separate macOS DSN). Android DSN stayed in
  `local.properties` — verified gitignored, never committed.
- Action items:
  - [ ] Rotate both exposed DSNs from the Sentry org admin panel
        (`jason-yeyuhe.sentry.io`) — DSN replacement is cheap. Update
        the relevant `Info.plist` for the next release; a coordinated
        client rollout is not strictly required because old DSNs
        continue to work; rotation just narrows abuse surface.
  - [ ] After rotation, confirm `beforeSend` scrubber is unchanged and
        `tracesSampleRate = 0` is preserved (no PII / no perf traces).
  - [ ] Confirm Android Sentry DSN was never committed (audit:
        `git log --all -- android/local.properties` should be empty).

### App Store Connect API key

- Status before incident: Key ID `DMMFP…6XTXX` and Issuer ID
  `c5671c…49416` were embedded in 4 scripts under
  `CLI Pulse Bar/scripts/`. **The `.p8` private key was NOT
  committed.** Without the `.p8`, the IDs alone do not authenticate.
- Action items:
  - [ ] Confirm the `.p8` file remains only in
        `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_DMMFP6XTXX.p8`
        on the development machine and is referenced by absolute path
        in scripts (it is — verified during audit).
  - [ ] Add `*.p8` to a global gitignore if not already covered.
  - [ ] Do not rotate the ASC API key purely from this exposure. Rotate
        only if the `.p8` itself ever leaves the local machine through
        another channel.

### Google Play upload keystore

- Status: `cli-pulse-upload.jks` is referenced in CI workflows via
  `${{ secrets.STORE_PASSWORD }}` / `${{ secrets.KEY_PASSWORD }}` only.
  The `.jks` itself was not committed.
- Action items:
  - [ ] Verify `*.jks` is in the global / android gitignore.
  - [ ] Verify the keystore file itself remains only on the dev machine
        and Google Play's key-management side; no rotation needed
        unless the file leaks separately.

### GitHub Actions secrets

- Status: every `.github/workflows/*.yml` file in the contaminated tree
  used `${{ secrets.X }}` indirection only. No hardcoded secret value
  appeared in committed YAML. Audited 2026-04-28.
- Action items:
  - [ ] Verify the *current* workflow secrets (`SUPABASE_ANON_KEY`,
        `GOOGLE_SERVICES_JSON`, `STORE_PASSWORD`, `KEY_PASSWORD`,
        `GOOGLE_WEB_CLIENT_ID`) match the values still in use; rotate
        any that have been around long enough to be considered stale by
        org policy. (Independent of this incident.)
  - [ ] Confirm CI logs from the contaminated period are not retained
        beyond the GitHub default retention (90 days) — those logs
        could have echoed values back into a public artifact if a
        misbehaving step ran with `set -x`. Spot-check one recent run.

### Provider API keys / session cookies / OAuth secrets

- Status: targeted scan against `b462fed` found **no committed provider
  API keys, no `client_secret` strings, no real Google `ya29.…` tokens
  (only `ya29.test` test fixtures), no Anthropic `sk-ant-…`, no
  OpenAI `sk-…`, no GitHub PATs, no Slack tokens, no PEM private
  keys.**
- Action items:
  - [ ] Treat any future user-credential exposure as critical and
        page-worthy. This category was clean for this incident and
        must remain so.

### Supabase service_role / private keys / certificate material

- Status: scan found only the public Apple Root CA G3 certificate
  embedded in `backend/supabase/functions/validate-receipt/index.ts`
  (well-known, not a secret). **No `service_role` key, no private key
  blocks of any kind.**
- Action items:
  - [ ] Re-run the secret scan one final time before closing the
        incident, gated on the GitHub support GC ticket completing.

---

## Remaining residual risk

- **Old commits may still be fetchable by SHA** until GitHub server-side
  GC runs. See `PUBLIC_REPO_GITHUB_SUPPORT_GC_REQUEST.md`.
- **Third-party clones / local downloads** of the previously-public
  archives cannot be revoked. Anyone who fetched
  `https://github.com/JasonYeYuhe/cli-pulse/archive/refs/tags/v1.10.7.zip`
  before 2026-04-28 still has the source. There is no mitigation; this
  is the cost of having pushed source publicly. Treat the contained code
  as "publicly available historical leak" for any future
  threat-modelling.
- **Forks made before today** keep the source. Quick periodic check:
  ```bash
  gh api repos/JasonYeYuhe/cli-pulse/forks --jq '.[].full_name'
  ```

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
