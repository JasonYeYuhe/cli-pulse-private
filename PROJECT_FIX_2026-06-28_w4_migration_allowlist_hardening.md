# PROJECT FIX — migration-allowlist hardening + gate-semantics comments (W4)

**Date:** 2026-06-28
**Branch / PR:** `fix/w4-migration-allowlist-hardening`
**Plan:** `DEV_PLAN_2026-06-28_inapp_terminal_productionize.md` §7 (W4) + adversarial
verification of the W1-A..W3 changeset.
**Depends on:** W1-A/W1-B/W2/W3 — merged.

## Context
After W1-A..W3 landed, a 5-way adversarial verification (each skeptic trying to
refute a correctness claim) confirmed MAS-safety, entitlement-verifier soundness,
and the reentrancy fix all hold, and surfaced **one real latent issue** + two
doc-comment drifts. (The bulk of W4 — the ship-config entitlement-invariant test —
already shipped in W1-A as `DevidEntitlementsInvariantTests`.)

## Fixes

### 1. Migration-allowlist completeness (the one real finding)
`ClaudeCredentials.keychainReadCooldownKey` was `"claudeCodeKeychainReadCooldownUntil"`,
written to `cooldownDefaults = UserDefaults(suiteName:"group.yyh.CLI-Pulse") ?? .standard`.
The primary app-group store doesn't move on unsandbox, but the `?? .standard`
fallback (fires only if the suite ever fails to init) would land a
non-`cli_pulse_`/non-`privacy.` key in standard defaults → **stranded** on the
DEVID unsandbox transition, falsifying `UnsandboxedDataMigration`'s "every
app-owned standard-defaults key is prefixed" invariant. Low likelihood + benign
data (a 30-min anti-prompt-spam timestamp), but cheap to close correctly:
- Renamed the key → `"cli_pulse_claude_keychain_read_cooldown_until"` so the
  allowlist covers it even on the fallback. (Orphans any old value once — benign.)
- Made the constant internal so a guard test can assert it directly.

### 2. Allowlist contract guard test
`UnsandboxedDataMigrationTests.test_appOwnedKeyPrefixes_coverEveryKnownStandardDefaultsKey`
asserts every audited app-owned `UserDefaults.standard` key (incl. the `privacy.*`
pair and `ClaudeCredentials.keychainReadCooldownKey` via the real constant)
matches `appOwnedKeyPrefixes`. A future revert to an unprefixed key fails here.

### 3. Gate-semantics comment accuracy (verifier: doc drift, NOT a behavior bug)
`canStartLocalManagedSession` requires `selfDeviceId` (the LOCAL `HelperConfig.deviceId`
— present once the local helper is installed/reachable, NOT cloud Remote-Control
consent), which the verifier confirmed is intentional + test-locked
(`SessionControlIntegrationGapTests`). Clarified the omitted `selfDeviceId`
precondition in the doc comment (`LocalSessionControlState`) and the W1-B menu
comment (`CLIPulseBarApp`). **No predicate change** — dropping the guard would
break the row-ownership invariants + the existing test.

## Validation
`swift test` (full): 1826 tests, 0 failures. Existing `ClaudeKeychainCooldownTests`
still pass (they go through the constant, transparent to the rename).

## Verification verdict (recorded)
4/5 adversarial claims held outright (MAS-safety high, verifier-soundness medium,
reentrancy high, gate-correctness = doc drift only); the migration-completeness
claim reduced to the single fallback-path key above, now closed. The risky
surfaces — MAS sandbox preservation, entitlement-verifier soundness, cross-session
buffer integrity — all verified clean. Remaining exposures are the explicitly
deferred `window.pushChunk` WKContentWorld isolation (P2) and the owner-gated
on-device smoke (W2).
