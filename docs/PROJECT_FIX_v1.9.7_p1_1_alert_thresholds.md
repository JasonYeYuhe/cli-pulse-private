# PROJECT_FIX v1.9.7 — P1-1: user-configurable quota alert thresholds

**Date**: 2026-04-21
**Scope**: CLIPulseCore + macOS/iOS Settings UI. Android deferred.

---

## Why

`AlertGenerator.evaluateQuotaAlerts(...)` accepted a `thresholds: [Int]`
parameter but both `DataRefreshManager` call sites used the
`[80, 95]` default, and no UI surfaced the knob. Plan P1-1 called this
out as a high-value, low-cost quick win.

## What shipped

### Core
- **New** `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertThresholds.swift`
  - `AlertThresholds` value type (`warning`, `critical`)
  - `AlertThresholdsStore` — UserDefaults-backed load / save / reset under
    key `cli_pulse_alert_thresholds_v1`, accepts an injectable
    `UserDefaults` for testing
  - Invariants: `50 ≤ warning ≤ 94`, `warning + 1 ≤ critical ≤ 99`, clamped
    on every save and on every load from malformed data

- **Edited** `CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift`
  - Both `evaluateQuotaAlerts(providers:)` call sites now pass
    `thresholds: AlertThresholdsStore.load().asArray`

- **Edited** `CLIPulseCore/Sources/CLIPulseCore/AlertGenerator.swift:165-173`
  - **Fix from Codex review**: severity is now positional
    (`crossed == sortedThresholds.first → "Critical"`, else `"Warning"`)
    rather than hard-coded to 95%/80%. This keeps the defaults working
    identically but lets user-configured `[60, 85]` correctly render 85%
    as Critical and 65% as Warning

### UI
- **Edited** `CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift`
  - New `alertThresholdRow` inside the Notifications section: two
    Steppers (warning 50–94 step 5, critical warning+1 to 99 step 5) plus
    a Reset-to-defaults link that only appears when values diverge
  - Local `@State` seeded from `AlertThresholdsStore.load()`, every change
    runs `AlertThresholds.clamped(...)` before `AlertThresholdsStore.save(...)`

- **Edited** `CLI Pulse Bar/CLI Pulse Bar iOS/iOSSettingsTab.swift`
  - iOS mirror inside the existing `Section(L10n.settings.notifications)`;
    same semantics

### Tests
- **New** `CLIPulseCore/Tests/CLIPulseCoreTests/AlertThresholdsTests.swift`
  — 11 tests covering defaults, load-fallback on missing/malformed,
  save roundtrip, all four clamp scenarios, reset, asArray shape
- **Extended** `AlertGeneratorTests.swift` with
  `testQuotaAlertSeverityPositionalForCustomThresholds` proving the
  severity-from-position fix

All 200+ CLIPulseCoreTests green; macOS + iOS builds green.

---

## Deferred (v1.9.7 follow-ups, not blockers)

1. **Android parity**: `android/.../ui/settings/SettingsScreen.kt` has no
   quota-threshold UI. Codex flagged this as a parity gap but not a
   release blocker. Tracking as a dedicated follow-up task within
   v1.9.7 sprint.
2. **Cross-view observation**: Settings views use `@State` initialized once.
   If another component ever writes `AlertThresholdsStore.save(...)` the
   Settings view won't update until reopen. Today only Settings writes,
   so OK — revisit when adding a second writer.

---

## Review audit trail

- **Codex rescue, pass 1** — ship-with-notes → **BLOCK**. Found hard-coded
  95/80 severity cutoffs in `AlertGenerator.swift:167-168` that would
  mis-label custom thresholds. Actioned.
- **Codex rescue, pass 2** — **SHIP**. Confirmed severity is now positional
  and the new test covers the regression.

---

## Files changed

```
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertThresholds.swift       (new)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift    (2 edits)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertGenerator.swift        (severity rewrite)
CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/AlertThresholdsTests.swift (new, 11 tests)
CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/AlertGeneratorTests.swift  (+1 test)
CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift                               (state + view)
CLI Pulse Bar/CLI Pulse Bar iOS/iOSSettingsTab.swift                        (state + view)
docs/PROJECT_FIX_v1.9.7_p1_1_alert_thresholds.md                            (this doc)
```

No changes to Android, backend, Python helper, or other Swift targets.
