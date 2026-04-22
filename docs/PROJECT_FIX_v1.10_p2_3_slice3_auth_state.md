# PROJECT_FIX v1.10.3 — P2-3 slice 3: AuthState child ObservableObject

**Date:** 2026-04-22
**Commit:** (pending)
**Scope:** Extract authentication state from AppState god-class into a dedicated
`AuthState: ObservableObject`, so view invalidation from auth changes no longer
dirties every AppState-observing view in the tree.

## Shipped

### New file
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AuthState.swift` — `@MainActor
  public final class AuthState: ObservableObject` with 4 `@Published` fields
  (`isAuthenticated`, `isPaired`, `userName`, `userEmail`).

### AppState refactor
- `AppState.swift`: removed 4 `@Published` auth fields. Added
  `public let authState = AuthState()` child + 4 computed `get/set` forwarders
  (`isAuthenticated`, `isPaired`, `userName`, `userEmail`) that proxy to
  `authState.X`. Keeps all in-package mutator call sites (AuthManager,
  DemoDataProvider, DataRefreshManager) compiling unchanged.

### AuthManager shadow resolution
- Renamed parameter `applyAuthenticatedState(_ authState: AuthSessionState)` →
  `applyAuthenticatedState(_ session: AuthSessionState)` to avoid shadowing the
  new `self.authState` child.
- Renamed 5 local `let authState = try await authManager.X(...)` shadow vars →
  `let session = ...`.
- Renamed `case .restored(let authState)` pattern match → `case .restored(let session)`.

### Root injection (3 scenes)
- `CLIPulseBarApp.swift` — `.environmentObject(appState.authState)` on
  `MenuBarExtra` root and `Window("provider-config")` root.
- `CLIPulseApp_iOS.swift` — `.environmentObject(appState.authState)` on
  `WindowGroup` root.

### View migration (9 files)
Added `@EnvironmentObject var authState: AuthState` and rewired reads from
`state.X` → `authState.X`:
- **macOS:** `MenuBarView.swift` (3 reads), `SettingsTab.swift` (2),
  `AccountCardView.swift` (4), `PairingSection.swift` (2),
  `OnboardingWizardView.swift` (1).
- **iOS:** `iOSSettingsTab.swift` (6), `iOSMainView.swift` (1),
  `iOSLoginView.swift` (1), `iOSProvidersTab.swift` (1).
- **Watch excluded:** `WatchMainView.swift` uses `WatchAppState` (separate class
  with its own `@Published isAuthenticated`), not `AppState` — out of scope.

### Post-review fixes (Gemini findings addressed)
1. **Critical — MenuBarExtra label reactivity.** The `MenuBarExtra { } label: {
   Image(systemName: appState.menuBarIcon); Text(appState.menuBarLabel) }` inline
   closure was subscribing only to `appState.objectWillChange`. Since
   `menuBarIcon`/`menuBarLabel` now read `isAuthenticated`/`isPaired` via the
   computed forwarders (`authState.X`), the `AuthState` publisher fired but
   `AppState`'s did not → menu bar wouldn't update on login/pair.
   **Fix:** extracted label content into a new `private struct MenuBarLabel:
   View` that holds `@ObservedObject var appState` + `@ObservedObject var
   authState`, subscribing to both publishers.
2. **Warning — iOS environment re-injection.** `iOSMainView` re-injects `state`
   into child views (a defensive pattern against SwiftUI environment drops in
   NavigationSplitView / TabView). Added `.environmentObject(authState)`
   alongside `state` in 7 places: `iOSLoginView`, `iPadSplitView`, `detailView`,
   and the 5 `TabView` child tabs. Also added `@EnvironmentObject var authState`
   to `iPadSplitView`.

## Review verdict
- **Codex codex-rescue:** flaked (stuck "Searching:" loop — known session
  pattern). Stopped and proceeded.
- **Gemini 3.1 Pro scan (first pass):** flagged the 2 issues above. Fixed.
- **Gemini 3.1 Pro scan (second pass):** **SHIP** — "No bugs or regressions
  found. Great work!" Confirmed both fixes.

## Baselines
- `swift test` CLIPulseCore: all passing ✓
- `xcodebuild -scheme "CLI Pulse Bar" -destination platform=macOS`: BUILD
  SUCCEEDED ✓
- `xcodebuild -scheme "CLI Pulse iOS" -destination generic/platform=iOS
  Simulator`: BUILD SUCCEEDED ✓

## Why this matters
AppState was a god-class. Every `@Published` field invalidated every view that
`@EnvironmentObject`-ed it. Auth-gated views (login, settings, onboarding)
changed rarely but dragged sessions tables, providers, alerts, dashboards
through re-render cycles whenever *any* other field updated. Inversely, auth
changes re-dirtied unrelated views. Slice 3 cleanly severs that coupling for
the 4 auth fields while preserving the public API surface for non-view
callers via computed forwarders.

## Follow-ups / not done here
- **Slice 4:** `AlertState` child ObservableObject (1 `@Published` field —
  smallest slice).
- **Slice 5:** `ProviderState` child ObservableObject (~5 `@Published` fields).
- These will follow the same pattern (extract → forward via computed accessors →
  inject at roots → migrate view reads → verify MenuBar label reactivity if any
  computed property depends on the extracted fields).
