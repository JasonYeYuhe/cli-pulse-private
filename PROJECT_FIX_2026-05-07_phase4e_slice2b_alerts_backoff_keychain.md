# PROJECT_FIX — Phase 4E Slice 2b — AlertGenerator + OAuthBackoff + KeychainReader

**Date:** 2026-05-07
**Branch:** `phase4e-slice2b-alerts-backoff-keychain` (cut from `main` after Slice 2a merge `a453f31`)
**Plan:** [docs/PHASE_4E_DEV_PLAN.md](docs/PHASE_4E_DEV_PLAN.md) — Slice 2b of 4 sub-slices

## What ships

Sub-slice 2b — alert generation + OAuth-429 backoff + macOS Keychain reader. All three are dependencies of Slice 2c's `ClaudeQuotaFetcher`, which is why they land first.

| File | Change |
|---|---|
| `HelperKit/SystemCollection/AlertGenerator.swift` | NEW. Pure-function generator of `CollectedAlert` from sessions + device snapshot. Three thresholds (device CPU≥85, session CPU≥80, session requests≥400), cap at 6. Threshold values pinned in tests. Project-id slugifier mirrors Python `_project_id`. |
| `HelperKit/SystemCollection/OAuthBackoff.swift` | NEW. **Actor-isolated single-writer** (Phase 4E v2 P1). `fingerprint(forToken:)` via SHA256 prefix. 15-min cooldown. Second register inside the active window does NOT reset the expiry. |
| `HelperKit/SystemCollection/KeychainReader.swift` | NEW. Async wrapper over `security find-generic-password`. 5 s watchdog timeout (Phase 4E v2.1 P1). 24 h denial cache with explicit-refresh override. Distinguishes `errSecItemNotFound` (NOT cached) from user-denied / watchdog-tripped (cached). |
| `HelperKit/SystemCollection/SubprocessRunner.swift` | EXTENDED. New `runCapturingExit` variant returns granular `RunResult` so callers can distinguish exit codes (44 = errSecItemNotFound vs 51 = errSecAuthFailed vs timedOut). The simpler `run(...) -> String?` is preserved for Slice 2a callers as a delegating wrapper. |
| `HelperKit/Tests/HelperKitTests/AlertGeneratorTests.swift` | NEW. 9 tests — threshold pinning, device CPU spike, session CPU spike, session-too-long, nil-fields-no-fire, top-6 cap, project-id slugify, snake_case wire shape. |
| `HelperKit/Tests/HelperKitTests/OAuthBackoffTests.swift` | NEW. 9 tests — fingerprint stability/distinctness, register/expire/reset lifecycle, per-fingerprint isolation, single-writer guarantee inside active window, fresh-window-after-expiry, reset-all. |
| `HelperKit/Tests/HelperKitTests/KeychainReaderTests.swift` | NEW. 8 tests — happy path trim, empty success → service-not-found, errSecItemNotFound (44) does NOT cache, errSecAuthFailed (51) caches, watchdog times out cached, 24 h expiry, force-retry clears cache, per-service isolation. |

## Per-fix notes

### Initial implementation

Followed Slice 2b spec. Three modules, each focused. AlertGenerator is pure-function (no actor needed); OAuthBackoff is an actor (per Phase 4E v2 P1 single-writer decision); KeychainReader is an actor (per-service denial cache state).

### Gemini diff review — 2 catches applied (1 P0 fixed, 1 P1 documented)

**(P0) `KeychainReader` treated `errSecItemNotFound` as denial.** First draft of `KeychainReader` mapped any non-zero `security` exit to a 24 h denial cache. But `security find-generic-password` exits **44** (`errSecItemNotFound`) when the user simply hasn't paired with the service yet — a perfectly normal absent-service case, NOT a denial. Caching that for 24 h would lock out every user who hadn't installed Claude CLI from quota fetches for a full day, even after they install it.

Fix:
1. Extended `SubprocessRunner` with a granular `runCapturingExit` variant returning `enum RunResult { success | nonZeroExit(code, stdout) | spawnError | timedOut | cancelled }`. The simpler `run(...) -> String?` is now a delegating wrapper — Slice 2a callers (DeviceSnapshotCollector, SessionDetector) keep their existing API.
2. `KeychainReader.find` switches on `runResult` and only caches a denial for `nonZeroExit(code != 44)` or `timedOut`. `errSecItemNotFound` returns `.unavailable(reason: .serviceNotFound)` without caching, so subsequent reads pick up a freshly-installed Claude CLI immediately.
3. New regression test: `testItemNotFoundDoesNotCacheDenial` runs the absent-service → success transition across 1 second of mock-clock advance and asserts no cache short-circuit.

**(P1) Device CPU alert ID includes timestamp → potential row flooding.** Gemini noted that `alertId: "cpu-spike-\(nowEpochInt)"` produces a new unique alertId every collection cycle, so a sustained spike floods the Supabase Alerts table. The current Python helper has the EXACT same shape (`f"cpu-spike-{int(datetime.now().timestamp())}"`) — fixing in Swift only would create cross-platform drift. Decision: accepted as parity-with-Python, documented as a comment block at the alert generation site (`AlertGenerator.swift:74-83`) noting that switching to a stable id like `"device-cpu-spike"` is a cross-platform schema change tracked separately. Server-side dedup handles the practical impact today.

## Verification

| Step | Result |
|---|---|
| `swift test --filter AlertGeneratorTests` | **9/9 passed** |
| `swift test --filter OAuthBackoffTests` | **9/9 passed** |
| `swift test --filter KeychainReaderTests` | **10/10 passed** |
| `swift test` (full HelperKit) | **206/206 passed** (was 178 after Slice 2a; +28 across the 3 new test files; zero regressions) |

## Out of scope / what 2c–2d ship next

- **2c** — `ChromiumCookieReader` (PBKDF2 + AES-CBC + SQLite read of Chrome/Edge/Arc/Brave/Chromium Cookies db) + `ClaudeQuotaFetcher` (uses 2b's KeychainReader + OAuthBackoff) + `CodexQuotaFetcher` + `GeminiQuotaFetcher` + the `QuotaProvenance` enum surfacing per Gemini Phase 4E v2 P0 (silent-fallback visibility).
- **2d** — Snapshot writers (deep-equality JSON parity) + SystemCollector façade wired via `withTaskGroup` + 3 snapshot parity tests.

## Cross-team note

Sub-slice 2b of Phase 4E Slice 2. No cross-platform contract changes; Windows v0.7.0 unaffected.
