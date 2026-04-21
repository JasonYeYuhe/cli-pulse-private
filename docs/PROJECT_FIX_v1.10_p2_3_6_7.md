# PROJECT_FIX v1.10 — P2-3 slice 1 + P2-6 + P2-7 (combined)

**Date**: 2026-04-21
**Scope**: CLIPulseCore only. Three small, independent wins.

---

## P2-3 slice 1 — Start AppState debloat via `AlertSuppression`

Plan P2-3's "AppState as facade" direction, first concrete step:

- **New** `AlertSuppression.swift` (62 lines) — public enum namespace with:
  - `Entry` value type (`until`, `dismissedAt`, `isPermanent`)
  - `legacyKey` / `currentKey` persistence key constants
  - `permanentRetentionDays` constant (180)
  - Pure `prune(_:now:retentionDays:)` method
- **Edited** `AppState.swift` — kept `@Published` suppressedAlertIDs for live
  observation; added facade aliases:
  - `public typealias SuppressionEntry = AlertSuppression.Entry`
  - `suppressedAlertsKey` / `suppressedAlertsV2Key` passthrough static lets
  - `permanentSuppressionRetentionDays` computed static var
  - `prunedSuppressions(_:now:retentionDays:)` thin wrapper
- Zero public-API change; all 10 P1-3 `SuppressionTests` pass unchanged
- Codex review: "Keep the AppState facade for now — dropping aliases would
  be churn, not architectural progress. Active callers still use the
  AppState-shaped API (SuppressionTests, DataRefreshManager's suppression
  flow)."

## P2-6 — `DateRange` utility

Plan: centralize the scattered `-6 days` rolling-week math (root of a
documented off-by-one bug that spanned 8 calendar days when someone
used `-7` thinking inclusive).

- **New** `DateRange.swift` (50 lines) with:
  - `ymd(_:)` — YMD string "YYYY-MM-DD"
  - `rollingWeekStart(from:)` — `now - 6 days` (same HH:MM:SS)
  - `rollingWeekStartYMD(from:)` — YMD of the above
  - `rollingMonthStart(from:)` — `now - 29 days`
- **Edited** 3 call sites:
  - `AppState.scanMessagesThisWeek(for:)`
  - `AppState.scanTokensThisWeek(for:)`
  - `DataRefreshManager.applyCostScan(...)`
- **New** `DateRangeTests.swift` — 5 passing tests including an
  explicit 7-calendar-day-span invariant to prevent the off-by-one
  regression
- **Contract clarification** (per Codex feedback): the file-level doc
  explicitly notes that `rollingWeekStart` preserves HH:MM:SS (returns
  raw `Date`); callers needing a date-only key use `rollingWeekStartYMD`

## P2-7 — `refreshTask` cancel guard

Plan P2-7: "`refreshTask?.cancel()` before overwriting the handle to
avoid concurrent network requests."

- **Edited** `DataRefreshManager.scheduleRefresh(...)`: added
  `refreshTask?.cancel()` before assigning the new Task
- **Caveat documented in the code** (per Codex feedback): cooperative
  cancellation only SIGNALS; `onRefreshRequested` checks `Task.isCancelled`
  once early but in-flight network calls complete on their own. Manual
  refresh buttons (OverviewTab, MenuBarView, CLIPulseBarApp) run their
  own unmanaged `Task { await state.refreshAll() }` and bypass this
  handle, so full overlap prevention requires a separate audit

## Verification

- CLIPulseCore `swift test` → All tests green (including 5 new DateRange tests)
- `xcodebuild build` macOS → BUILD SUCCEEDED

## Files changed

```
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertSuppression.swift   (new, 62)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DateRange.swift          (new, 50)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift           (facade + 2 DateRange call-site rewires)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift (DateRange + refreshTask guard)
CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/DateRangeTests.swift  (new, 5 tests)
docs/PROJECT_FIX_v1.10_p2_3_6_7.md                                       (this doc)
```

## Codex review — **ship-with-notes**

All three slices shipped with tightened docs. No blocking regressions.
Tracking as follow-up:
- P2-7 full overlap audit (manual refresh buttons)
- P2-3 next slice: decide whether to continue the facade pattern or
  promote `AlertSuppression.Entry` to canonical and migrate callers
