# PROJECT FIX — DEVID self-updater: artifact authenticity + downgrade protection

**Date:** 2026-06-30 · **Train:** Trust Hardening v2 (PR-1 of 3)
**Plan:** `DEV_PLAN_2026-06-30_trust_hardening_v2.md` (Gemini 3.1 Pro: SHIP; Codex: SHIP-WITH-CHANGES — all findings folded in).

## Problem
The Developer ID self-updater (`AppUpdater`) fetched an **unsigned** `latest.json` and
only checked the downloaded DMG's SHA-256 against `manifest.sha256`. Since a manifest
attacker controls BOTH the `url` and the `sha256`, that proved download integrity, not
**authenticity** — and `install()` then mounted + presented the DMG to the user with no
codesign/notarization re-check. A compromised/MITM'd manifest could push a trojan, or
(downgrade) point a spoofed-high version at a legitimately-signed OLD vulnerable build.

## Fix (`AppUpdater.swift` + new `UpdateVerifier.swift`, both `#if os(macOS) && DEVID_BUILD`)
A layered, **fail-closed** verifier; `download()` now proves the artifact is a genuine,
current, Jason-notarized CLI Pulse build before `.readyToInstall`:
1. **Manifest hardening** (`fetchManifest`, runs on every refresh): require `https`, a
   strict `github.com/cli-pulse/cli-pulse-distrib/releases/download/` prefix, and a sane
   `size_bytes` (0 < n ≤ 200 MB). Untrusted `release_notes_url` ignored unless allowlisted.
2. **Download** to a fresh private 0700 dir (not a predictable temp path); assert byte
   size == manifest; SHA-256 == manifest (kept).
3. **Verify the DMG container BEFORE mounting** (mounting an attacker DMG parses the FS
   in-kernel — a pre-auth panic/privesc surface): `SecStaticCode` requirement
   `anchor apple generic and certificate leaf[subject.OU] = "KHMK6Q3L3K"` + `spctl --assess
   --type open --context context:primary-signature` (offline stapled-ticket notarization).
4. **Mount read-only/nobrowse/noautoopen**, then verify the inner `.app`: exactly one
   top-level `.app`, **no symlink masquerade**; `SecStaticCode` strict
   (`kSecCSStrictValidate|kSecCSCheckNestedCode|kSecCSCheckGatekeeperArchitectures`) with
   requirement pinning `identifier "yyh.CLI-Pulse"` + team OU + Developer ID marker OIDs;
   `spctl --assess --type execute` for notarization.
5. **Downgrade protection:** the mounted app's `CFBundleShortVersionString` == manifest
   version, `CFBundleVersion` == manifest build, and version strictly `> installed`.
6. **TOCTOU-safe handoff:** `install()` reveals the ALREADY-VERIFIED, still-mounted volume
   in Finder (no detach→reopen of the dmg file). Mount detached on next download / error.
7. **Fail closed** on any verification OR tooling error (missing `spctl`/`hdiutil` ⇒
   "Couldn't verify this update", never a pass).

### Deliberate choices (from the adversarial review)
- **No `stapler` on the client** — it ships with Xcode CLT, absent on end-user Macs;
  `spctl --assess` (always in macOS) is the notarization decider, offline via the stapled
  ticket. `kSecCSCheckGatekeeperArchitectures` covers architectures, NOT notarization.
- **No `kSecCSEnforceRevocationChecks`** — online OCSP is flaky / firewall-blocked and
  would brick the channel; the offline stapled ticket is deterministic.
- Requirement pins the **bundle id**, not just the team (team-only accepts any app from
  the team). DMG identifier is version-specific so the DMG check pins team + Apple anchor.
- Cryptographic manifest signing (Ed25519/minisign) is a documented fast-follow; this PR
  is artifact authenticity, which already blocks wrong-signer malware + downgrade.

## Tests / CI
- `UpdateVerifierTests` (17): manifest-URL allowlist (https/host/path/garbage), size,
  size-match, upgrade/downgrade, version/build match (incl. the spoofed-high downgrade),
  aux-URL allowlist. Plus `test_realDMG_passes_whenProvided` (env-gated `CLIPULSE_TEST_DMG`)
  — **run locally against the real notarized 1.34.0 DMG: PASS (no false-reject)**, full
  container+mount+app+version verification in 2.2s.
- New CI step in `swift-ci.yml` `test-core`: `swift test -Xswiftc -DDEVID_BUILD --filter
  UpdateVerifierTests --filter AppUpdaterTests` — compiles the package under DEVID_BUILD
  (closes the compile-rot gap: these files were NEVER compiled by the default `swift test`)
  and runs the updater tests.
- Default `swift test`: 1834 tests, 0 failures (unaffected — new code is DEVID-gated).

## Latent issue surfaced (flagged separately, NOT fixed here)
Running the FULL `swift test -Xswiftc -DDEVID_BUILD` fails
`SubscriptionTierResolutionTests.testUpdateEntitlementsWithoutApiClientRecordsNoApiClient`
(3 asserts): under DEVID_BUILD, a missing `apiClient` resolves to a CONFIRMED
`devid-beta-channel` tier instead of the degraded/`noApiClient` path the test expects.
Passes under the default build. Either the DEVID entitlement path legitimately grants the
beta tier offline (test should assert that) or it's an over-grant — worth a focused look.
The new CI step is filtered to the updater suites so it does not depend on resolving this.
