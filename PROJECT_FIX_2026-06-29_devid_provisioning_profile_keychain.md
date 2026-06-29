# PROJECT FIX — DEVID app/LoginItem/helper can't launch (keychain entitlement without a profile)

**Date:** 2026-06-29
**Severity:** P0 ship-blocker (v1.34 DEVID build was un-launchable on every Mac)
**Caught by:** the mandatory on-device smoke gate (the *first* time a real
notarized DEVID build was ever launched — prior sessions only ad-hoc-tested,
which masked this by dropping the keychain entitlement).

## Symptom
The notarized v1.34 Developer-ID app (and its LoginItem and bundled helper) were
**AMFI-SIGKILLed at launch** (`open` → error 163 "Launchd job spawn failed";
direct exec → rc 137 / SIGKILL; no stderr, no log — AMFI kills pre-`main`).

## Root cause
An **unsandboxed, hardened-runtime, Developer-ID** binary with a **restricted
entitlement** (`keychain-access-groups`, `application-groups`, even
`com.apple.developer.team-identifier`) and **no provisioning profile to authorize
it** is rejected by AMFI. Isolated empirically with the real Developer ID cert:
- keychain present → killed; keychain dropped → app runs; *dummy* keychain group →
  killed (so it's the entitlement class, not the value).
- bare helper: only **empty** entitlements run; any restricted entitlement → killed.

Earlier DEVID builds (v1.19–1.33) survived only because they were **accidentally
sandboxed** (the sandbox authorizes these entitlements). W1-A unsandboxed the
build to expose the terminal but kept the entitlements unauthorized.

## Fix (proven locally with the real cert — all three binaries launch)
- **App** + **LoginItem** (`.app` bundles): embed a **Developer ID provisioning
  profile** (`MAC_APP_DIRECT`, created via the App Store Connect API; grants
  `keychain-access-groups: KHMK6Q3L3K.*` + the app group) at
  `Contents/embedded.provisionprofile` before signing. AMFI then authorizes their
  keychain use → they launch with the shared keychain **intact** (account auth
  tokens + provider API keys preserved — no user re-auth). Profiles committed at
  `scripts/devid-profiles/` (long-lived, exp 2044).
- **Helper** (`Contents/Helpers/cli_pulse_helper`, a **bare Mach-O** — cannot
  embed a profile): sign with **no restricted entitlements**
  (`HelperSwift/cli_pulse_helper_devid.entitlements`, empty). It reaches the
  Group Container by absolute path (`AuthToken.containerPath`, getpwuid — never
  the app-groups-gated `containerURL`) and uses the file-based auth token, so it
  needs none of them.
- `scripts/build_signed_app.sh` (DEVID path only; MAS/`build-appstore.sh` and the
  Debug-CI path untouched): embed both profiles, sign the helper with the minimal
  entitlements, and the step-7 verifier now asserts (DEVID) app+LoginItem have an
  embedded profile + keychain, and the helper has **no** restricted entitlements.

## Deferred to v1.34.1 (graceful, documented)
The bundled helper's **keychain-based remote-pairing-secret** read
(`AppGroupConfigReader.readSecretFromKeychain`) returns nil under the minimal
entitlements → remote-control pairing *via the bundled Swift helper* is
unavailable on a clean Mac (degrades gracefully, no crash). Mitigations: the
`.pkg` Python helper handles remote control on the upgrade cohort; v1.34.1 will
move the pairing secret to a 0600 file (like the existing auth token) so the bare
helper can read it.

## Verification
- All three binaries launch under the **real Developer ID cert** with the
  embedded profiles / minimal entitlements (local repro).
- `bash -n` + embedded-Python `ast.parse` clean; `plutil -lint` on the new
  entitlements OK.
- Full smoke + rebuild/re-notarize before promotion.
