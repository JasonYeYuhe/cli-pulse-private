# PROJECT_FIX v1.10 P2-3 slice 2 — SubscriptionManager observation decoupling

**Date**: 2026-04-22
**Version**: v1.10.1 → **v1.10.2**
**Plan item**: `/Users/jason/.claude/plans/melodic-booping-truffle.md` P2-3 (SubscriptionState fix — slice 2 of the larger P2-3 child-ObservableObject refactor)
**Review**: Codex (codex:codex-rescue) **SHIP**. Gemini 3.1 Pro skipped (recurring flake).

## Problem

`AppState.init` installed this forwarder:

```swift
subscriptionCancellable = subscriptionManager.objectWillChange.sink { [weak self] _ in
    self?.objectWillChange.send()
}
```

Every @Published change inside `SubscriptionManager` (`currentTier`,
`products`, `purchasedSubscriptions`, `isLoading`) triggered
`AppState.objectWillChange.send()` — which invalidated the entire
AppState-observing SwiftUI tree. Dozens of views re-rendered on every
StoreKit product load, tier recalc, or in-flight flag flip. Plan called
this out as an anti-pattern in slice 2 of the P2-3 refactor.

## Fix

### 1. `AppState.swift`

- Removed `private var subscriptionCancellable: AnyCancellable?` field.
- Removed the `objectWillChange.sink` assignment from `init`.
- Changed `@Published public var subscriptionManager = SubscriptionManager.shared`
  → `public let subscriptionManager = SubscriptionManager.shared` (reference
  was never reassigned; `@Published` on a class reference only notifies on
  reassignment, so it was always dead-weight).
- Kept `import Combine` — `ObservableObject` still depends on it.

### 2. Root environment injection

Injected `SubscriptionManager` into the SwiftUI environment at each
app-root scene that hosts subscription-reading views:

- **macOS** `CLIPulseBarApp.swift`:
  - `.environmentObject(appState.subscriptionManager)` on `MenuBarExtra`
    root (alongside `.environmentObject(appState)`)
  - Same on the `Window("Provider Settings", id: "provider-config")` root
- **iOS** `CLIPulseApp_iOS.swift`:
  - `.environmentObject(appState.subscriptionManager)` on the
    `WindowGroup` root

### 3. View migration

Three views declare `@EnvironmentObject var subscriptionManager:
SubscriptionManager` and reference it directly; all `state.subscriptionManager.*`
/ `appState.subscriptionManager.*` reads inside these files rewritten to
`subscriptionManager.*`:

- `CLI Pulse Bar/SubscriptionSection.swift` (9 reads)
- `CLI Pulse Bar/TeamView.swift` (4 reads)
- `CLI Pulse Bar iOS/iOSSettingsTab.swift` (6 reads)

### 4. Not changed

- `SubscriptionView.swift` — already uses `@ObservedObject var manager:
  SubscriptionManager` via explicit init. No-op.
- Non-view call sites (`DataRefreshManager.swift:1292-1294` reads
  `subscriptionManager.maxDevices/maxProviders/currentTier` from the
  refreshContext; `AuthManager.swift:382` does
  `await subscriptionManager.updateCurrentEntitlements()`; `AppState.swift:362-366`
  reads the manager inside provider-config logic) — all still work via the
  AppState `let`. They don't need SwiftUI reactivity.
- `WatchAppState` — separate class, unaffected.

## Baselines (post-change)

- `swift test` (CLIPulseCore): **442 passed**, 1 skipped, 0 failures.
- `xcodebuild -scheme "CLI Pulse Bar" -destination platform=macOS`: **BUILD SUCCEEDED**.
- `xcodebuild -scheme "CLI Pulse iOS" -destination "generic/platform=iOS Simulator"`: **BUILD SUCCEEDED**.

## Review

### Codex (codex:codex-rescue, sonnet)

**Verdict**: SHIP. All 5 verification points passed:

1. **macOS injection complete** — `subscriptionManager` reaches
   `SubscriptionSection` (via `SettingsTab.swift:168`) and `TeamView`
   (via `SettingsTab.swift:196`) through the MenuBarExtra root.
2. **iOS injection complete** — `subscriptionManager` reaches
   `iOSSettingsTab` and its nested `TeamView` (at
   `iOSSettingsTab.swift:299`) through the `WindowGroup` root.
3. **No residual reads** — repo-wide grep for `appState.subscriptionManager`
   and `state.subscriptionManager` returned only injection sites and the
   existing explicit `SubscriptionView(manager:)` handoff.
4. **No external Combine consumers** — grep for
   `$subscriptionManager`, `.sink(…subscriptionManager)`,
   `.assign(…subscriptionManager)` returned nothing.
5. **No AppState-only implicit subscription-render dependency** — the
   remaining AppState-side reads are in action/refresh logic, not view
   bodies, so removing the forwarder doesn't silently break any UI.
6. **Watch isolated** — `CLIPulseApp_Watch.swift` / `WatchAppState`
   unaffected.

### Gemini 3.1 Pro

Skipped. Session-wide flake (timed out at 180s on v0.20 and v0.21; no
reason to expect a 6-file Swift diff behaves better).

## Files touched (6 files)

| File | Change |
|---|---|
| `CLIPulseCore/Sources/CLIPulseCore/AppState.swift` | Remove cancellable + sink; `@Published var` → `let` |
| `CLI Pulse Bar/CLI Pulse Bar/CLIPulseBarApp.swift` | Inject `appState.subscriptionManager` at MenuBarExtra + provider-config window |
| `CLI Pulse Bar/CLI Pulse Bar iOS/CLIPulseApp_iOS.swift` | Inject at WindowGroup |
| `CLI Pulse Bar/CLI Pulse Bar/SubscriptionSection.swift` | `@EnvironmentObject` + rewire reads |
| `CLI Pulse Bar/CLI Pulse Bar/TeamView.swift` | `@EnvironmentObject` + rewire reads |
| `CLI Pulse Bar/CLI Pulse Bar iOS/iOSSettingsTab.swift` | `@EnvironmentObject` + rewire reads |

## Follow-ups / not done

- **P2-3 slices 3+ (AuthState / AlertState / ProviderState)** — the bigger
  P2-3 refactor decomposing AppState into child ObservableObjects still
  pending. Slice 1 (AlertSuppression namespace) landed in v1.10. Slice 2
  (this fix) only addresses the worst pathological case. Slices 3+
  require more surgery per @Published field (~12 Auth / 1 Alert / 5
  Provider) and separate review.
- **Swift 6 preview warning**: `SubscriptionView.swift:10` still has the
  pre-existing `main actor-isolated static property 'shared' can not be
  referenced from a nonisolated context` warning on its default-argument
  `= .shared`. Orthogonal to this fix; addressed in a future Swift 6
  prep slice.
