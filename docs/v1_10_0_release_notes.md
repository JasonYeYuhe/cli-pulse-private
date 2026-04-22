# v1.10.0 release — 2026-04-22

## Platforms shipped

| Platform | Status | Details |
|---|---|---|
| iOS (App Store) | ✅ Waiting for Review | Build 33, submitted 2026-04-22 14:41 local |
| macOS (Mac App Store) | ✅ Waiting for Review | Build 33, submitted 2026-04-22 14:40 local |
| macOS (GitHub DMG) | ✅ Published | Notarized + stapled, in [GitHub release v1.10.0](https://github.com/JasonYeYuhe/cli-pulse/releases/tag/v1.10.0) (7.5M DMG) |
| Android (GitHub APK) | ✅ Published | In same GitHub release (3.8M APK) |
| Android (Google Play) | ⏳ Pending manual AAB upload | AAB at `/tmp/CLI-Pulse-v1.10.0.aab` (7.1M). Play Console extension blocks file upload; drag manually into open browser tab. Production access still blocked 5 more days (12 testers × 14-day requirement; currently 9 days) |

## ASC metadata set (via API)
- Version 1.10.0 records created on both iOS + macOS platforms
- Build 33 attached to each (iOS `d9c64b99`, macOS `55420abb`)
- "What's New in This Version" populated with 1101-char en-US string (see commit 570997b)
- macOS encryption compliance answered via UI: "None of the algorithms mentioned above" (app uses only Apple-provided HTTPS/Keychain/CryptoKit)
- Copyright: "2026 Yuhe Ye" inherited from prior version (API set "© 2026 CLI Pulse contributors" but ASC kept prior string — acceptable)

## Git state
```
570997b  v1.10.0: bump version for public release
3833d9a  ci: unblock swift/helper/android workflows (layer 1)
tag v1.10.0 → pushed to JasonYeYuhe/cli-pulse + cli-pulse-private
```

## Production Supabase
- Schema v0.22 (Tokyo region)
- 2 pg_cron jobs active:
  - `cleanup_expired_data_nightly` — 03:07 UTC (per-user retention)
  - `retention_cleanup_nightly` — 03:27 UTC (global 18-month GDPR cap)
- Both ran successfully overnight (verified via cron.job_run_details)
- 0 search-path advisor warnings

## CI state after layer-1 fixes
- ✅ Helper CI: green (cryptography added to pip install)
- ✅ Lint (warning-only): green
- ✅ Supabase CI: green
- ⏳ Android CI: in progress (secret set — should turn green)
- ❌ Swift CI: **layer 2 pre-existing failures** surfaced after layer 1:

### Layer-2 CI follow-ups (NOT v1.10 regressions — all pre-date this session)

**1. `ClaudeStrategyTests.testNormalizeWeeklyResetPrefersCanonicalWhenSnapshotLooksBogus`**
- `XCTAssertEqual failed: ("Optional("2026-04-03T23:00:00Z")") is not equal to ("Optional("2026-04-03T14:00:00Z")")`
- **Root cause:** test asserts timezone-specific string output; CI runner is UTC while the implementation uses local timezone somewhere
- **Fix:** pin the test env TZ (e.g. `TZ=America/Los_Angeles` in env) or change the assertion to parse + compare instants, not string reps

**2. `ExportServiceTests.testExportAlertsCSV_resolvedAndRead`**
- `XCTAssertTrue failed` at line 179
- **Root cause:** unknown without log inspection — possibly related to timezone/locale formatting in CSV output
- **Fix:** inspect test expectation, probably the same timezone issue as #1

**3. `WatchAppState.swift:79, 86, 231` — "reference to captured var 'self' in concurrently-executing code"**
- **Root cause:** Swift 6 strict concurrency check; CI's Xcode promotes warning→error
- **Fix:** replace `self` captures with `[weak self]` or `[self]` in the 3 Task closures (or make the class `final` if not already, and review isolation)

**4. `TeamView.swift:65:50` — "actor-isolated property 'userId' can not be referenced from the main actor"**
- **Root cause:** `appState.api` is a `@MainActor` proxy but `api.userId` is on an `actor APIClient`; CI enforces stricter isolation
- **Fix:** either `await appState.api.userId` (make surrounding code async) OR cache `userId` as a `@MainActor`-isolated copy on AppState

## Not in this release — file as v1.10.1 or v1.11 work
- Fix the 4 CI layer-2 failures above (each is 5-30 min of focused work)
- Commit the `ITSAppUsesNonExemptEncryption=false` macOS Info.plist patch that's currently staged locally (needed for future macOS uploads to skip the compliance dialog)
- P2-8 Sentry observability (blocked on user-supplied DSN)
- P3-1A Android placeholder planning
- Professional translation review of the 5 new a11y strings in ja/es/ko/zh-Hans
- VoiceOver real-device smoke of P3-3 accessibility pass
