# PROJECT FIX — make the full DEVID test suite green + run it in CI

**Date:** 2026-06-30 · **Found by:** the local full build+test sweep (the only red in 5 scheme builds + 3 test suites).

## Problem
`swift test -Xswiftc -DDEVID_BUILD` failed (3 asserts in one test):
`SubscriptionTierResolutionTests.testUpdateEntitlementsWithoutApiClientRecordsNoApiClient`
asserts the apiClient-race path (`.resolvedDegraded`/`.noApiClient`/`local-only-fallback`),
but under `DEVID_BUILD` `SubscriptionManager.updateCurrentEntitlements()` short-circuits to
a LOCAL Pro-Lifetime grant (`.resolvedConfirmed`/`devid-beta-channel`/nil) BEFORE the
apiClient check. The grant is **intentional and documented** (v1.19 SR1,
SubscriptionManager.swift:343-365): DEVID DMG users have no Mac App Store receipt and are
positioned as a power-user beta tier; it is **local-only** — server endpoints still reject
the beta channel — so it does NOT silently unlock paid server resources. The test simply
wasn't DEVID-aware. (The PR-1 #259 CI step had filtered the DEVID run to the updater suites
to dodge this; the proper fix is to make the test correct and run the full suite.)

## Fix
- `SubscriptionTierResolutionTests`: make the test DEVID-aware — assert the
  confirmed/`devid-beta-channel`/nil grant under `#if DEVID_BUILD`, keep the
  degraded/`noApiClient`/`local-only-fallback` race assertions under `#else`.
- `.github/workflows/swift-ci.yml`: drop the `--filter UpdateVerifierTests
  --filter AppUpdaterTests` from the DEVID step → run the **FULL** suite under
  `-DDEVID_BUILD`, catching the whole class of DEVID-only divergences (not just the
  updater path), now that the one pre-existing divergence is resolved.

## Verification (local)
- `swift test -Xswiftc -DDEVID_BUILD`: **1863 tests, 0 failures** (was 3 failures).
- `swift test` (default): **1834 tests, 0 failures** (regression-safe — the `#else` path).
- The rest of the sweep was already green: HelperSwift `swift test`; `xcodebuild build` of
  all 5 schemes (Bar/iOS/Watch/Widgets/Helper).
