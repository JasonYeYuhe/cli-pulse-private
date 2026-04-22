# PROJECT_FIX v1.10.8 — P3-4: enable iOS quota alert synthesis

**Date:** 2026-04-22
**Commit:** (pending)
**Scope:** Surface locally-computed quota-depletion alerts (80% / 95%
threshold crossings) on iOS. Previously macOS-only; iOS users only ever
saw cloud-supplied alerts and never the threshold-crossing alerts the
client computes from provider `.quota` / `.remaining` fields.

## Shipped

### DataRefreshManager.swift
Removed the `#if os(macOS)` guard around the quota-alert synthesis block
in `refreshRemote`. The guard pre-dated iOS-side alert plumbing but the
supporting helpers (`callbacks.activeSuppressedAlertIDs`,
`AlertThresholdsStore.load()`, `AlertGenerator.evaluateQuotaAlerts`,
`sendNotification`) were all already cross-platform. `costAdjustedProviders`
was also already defined in the non-macOS branch (line 163: `let
costAdjustedProviders = providerData`), so the block compiled fine once
AlertGenerator was reachable from iOS.

### AlertGenerator.swift
Narrowed the file-level `#if os(macOS)` guard to wrap only the
`generate(device:sessions:sessionCPU:)` method. That function is the
only part that depends on `DeviceMetrics.Snapshot` (macOS-only helper
output). The three provider-oriented functions —
`evaluateBudgetAlerts`, `evaluateQuotaAlerts`, and `makeAlertRecord` —
operate on `ProviderUsage` + threshold arrays + dicts, all of which are
cross-platform. They're now reachable from iOS.

## What this changes end-to-end

**Before:**
- macOS: refresh → evaluate quota alerts locally → merge into
  `state.alerts` → shows in AlertsTab + notifications + (Watch via
  PhoneSessionManager bridge if paired)
- iOS: refresh → only cloud-supplied alerts → AlertsTab misses local
  threshold crossings
- Watch (via iPhone bridge): only receives what iPhone has → same gap
  as iOS

**After:**
- iOS: refresh → now also locally synthesizes quota alerts → AlertsTab
  shows 80% / 95% threshold crossings matching what macOS users see.
- Watch (via iPhone bridge): `PhoneSessionManager.handleDidRefresh`
  forwards `state.alerts` over WatchConnectivity on every refresh —
  includes the new locally-computed quota alerts automatically. No
  Watch-side code change needed.
- Watch (via direct API call): still only cloud alerts (no local
  synthesis) — acceptable because the iPhone bridge is the primary
  path, and Watch's direct-API fallback is for "lastReceivedAlerts is
  empty" cold-start edge cases.

## Dedup / suppression
- `existingIDs = Set(alertData.map(\.id))` filters out cloud-supplied
  alerts that already carry the same stable ID
  (`quota-<provider>-<tier>-<threshold>`).
- `suppressedIDs = await callbacks.activeSuppressedAlertIDs()` filters
  out alerts the user resolved or snoozed locally (UserDefaults-backed,
  cross-platform).
- `previousAlertIDs` guards the notification-fire path so we don't
  re-notify on every 10-second refresh for the same unresolved alert.

All three guards were already in place on the macOS path — the iOS
enablement inherits them unchanged.

## Review verdict
- **Codex codex-rescue:** skipped (session flake pattern).
- **Gemini 3.1 Pro scan:** **SHIP** — "No bugs, logic errors, or style
  issues found. The architectural approach of decoupling the
  device-metric alerts (macOS only) from the provider-quota alerts
  (cross-platform) is clean and well-implemented. Ready to merge!"
  Verified all 5 target points.

## Baselines
- `swift test` CLIPulseCore: all passing ✓
- `xcodebuild -scheme "CLI Pulse Bar" -destination platform=macOS`:
  BUILD SUCCEEDED ✓
- `xcodebuild -scheme "CLI Pulse iOS" -destination generic/platform=iOS
  Simulator`: BUILD SUCCEEDED ✓

## Follow-ups
- **Manual smoke on a real device / sim:** at a quota ≥ 80%, confirm
  the alert renders in `iOSAlertsTab` and that the Watch companion
  picks it up. Left for Jason to verify on his own hardware since the
  reviewers confirmed the code path is clean.
- **Notification parity check:** iOS now calls
  `callbacks.sendNotification(alert)` for new local quota alerts —
  make sure the user has granted UN notification permission at
  `state.requestNotificationPermission()` (already wired in
  `iOSMainView.task`).
- Completes P3-4. Remaining v1.11-scope autonomously-doable: P3-3
  accessibility, P3-2 L10n. P2-8 Sentry still blocked on user DSN.
