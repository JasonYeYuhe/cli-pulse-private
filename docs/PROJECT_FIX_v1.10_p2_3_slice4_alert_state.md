# PROJECT_FIX v1.10.4 — P2-3 slice 4: AlertState child ObservableObject

**Date:** 2026-04-22
**Commit:** (pending)
**Scope:** Extract alert-related observable state from the AppState god-class
into a dedicated `AlertState: ObservableObject`, so the alerts tab, menu-bar
badge, and sidebar badge re-render on alert changes only — not on every
unrelated AppState mutation.

## Shipped

### New file
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertState.swift` —
  `@MainActor public final class AlertState: ObservableObject` with 2
  `@Published` fields: `alerts: [AlertRecord]` and `public internal(set) var
  suppressedAlertIDs: [String: AlertSuppression.Entry]`.

### AppState refactor
- `AppState.swift`: removed 2 `@Published` fields. Added `public let alertState
  = AlertState()` child + 2 computed `get/set` forwarders preserving the
  existing public API:
  - `public var alerts: [AlertRecord]` — proxies to `alertState.alerts`.
  - `public internal(set) var suppressedAlertIDs: [String: SuppressionEntry]`
    — explicit `internal(set)` restored on the forwarder to preserve the
    original access-control contract (Gemini-caught API-widening regression
    from the first pass).

### Root injection (3 scenes)
- `CLIPulseBarApp.swift` — `.environmentObject(appState.alertState)` on
  `MenuBarExtra` root and `Window("provider-config")` root.
- `CLIPulseApp_iOS.swift` — `.environmentObject(appState.alertState)` on
  `WindowGroup` root.

### MenuBarLabel cross-contract update (step 6 of the template)
`menuBarIcon`/`menuBarLabel` read `alerts.filter { !$0.is_resolved }.count`.
After the extraction, the backing `@Published` lives on `AlertState`, not
`AppState`. Added `@ObservedObject var alertState: AlertState` to
`MenuBarLabel` (alongside the existing `appState` + `authState` observers from
slice 3), so the menu-bar icon/text re-render on alert changes.

### View migration (4 files)
Added `@EnvironmentObject var alertState: AlertState` and rewired reads from
`state.alerts` → `alertState.alerts`:
- **macOS:** `AlertsTab.swift` (4 reads), `MenuBarView.swift` (1 read).
- **iOS:** `iOSAlertsTab.swift` (4 reads), `iOSMainView.swift` (2 reads —
  tab-badge + sidebar-badge; added property to both `iOSMainView` and
  `iPadSplitView`).

### iOS defensive re-injection (8 sites)
Added `.environmentObject(alertState)` alongside the existing defensive `state`
re-injections in `iOSMainView`: `iOSLoginView`, `iPadSplitView`, `detailView`,
and the 5 `TabView` children.

### Out of scope
- **Watch target:** `WatchAlertsView` + `WatchMainView` use a separate
  `WatchAppState` class with its own alerts property — untouched.
- **Android:** Kotlin, different state system — untouched.
- **`PhoneSessionManager.swift:77`:** reads `state.alerts` from a non-view
  helper, goes through the AppState computed getter — works unchanged.

### In-package mutators (verified)
All 3 sites flow through the computed setter:
- `AuthManager.applySignedOutState:448` — `alerts = []`
- `DemoDataProvider:200` — `alerts = demoData.alerts`
- `DataRefreshManager:1211` (inside `extension AppState`) — `alerts =
  payload.alerts`

## Review verdict
- **Codex codex-rescue:** skipped (session flake pattern — 2× stuck
  "Searching:" loops earlier).
- **Gemini 3.1 Pro scan (first pass):** flagged one warning — computed
  forwarder for `suppressedAlertIDs` dropped the original `public
  internal(set)` access control, widening the API contract. Fixed.
- **Gemini 3.1 Pro scan (second pass):** **SHIP** — "Code is solid and ready
  to merge." Confirmed fix and no new regressions.

## Baselines
- `swift test` CLIPulseCore: all passing ✓
- `xcodebuild -scheme "CLI Pulse Bar" -destination platform=macOS`: BUILD
  SUCCEEDED ✓
- `xcodebuild -scheme "CLI Pulse iOS" -destination generic/platform=iOS
  Simulator`: BUILD SUCCEEDED ✓

## Lesson reinforced
Step 6 of the decomposition template — "update MenuBarLabel to observe the new
child" — worked as designed. Gemini's separate catch (access-control
narrowing) is a new class of concern for slice 5: when extracting
`@Published public internal(set)` fields, the computed forwarder must
explicitly restate `internal(set)` or the API widens silently at compile time.

## Follow-ups / not done here
- **Slice 5 (last P2-3):** `ProviderState` child ObservableObject (~5
  `@Published` fields: providers, providerConfigs, providerDetails,
  costSummary, editingProviderKind? — audit during implementation). Multiple
  AppState computed properties read these (`mostUsedProvider`,
  `enabledProviderNames`) which are consumed from `menuBarIcon` → another
  `MenuBarLabel` observer addition likely needed.
- **P2-8:** Sentry observability baseline across 4 platforms. Multi-day.
