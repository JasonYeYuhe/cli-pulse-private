# PROJECT_FIX v1.10.5 — P2-3 slice 5: ProviderState (final god-class decomposition)

**Date:** 2026-04-22
**Commit:** (pending)
**Scope:** Final P2-3 slice. Extract the 5 provider-related `@Published`
fields (`providers`, `providerConfigs`, `providerDetails`, `costSummary`,
`editingProviderKind`) from `AppState` into a dedicated
`ProviderState: ObservableObject`. Completes the god-class decomposition —
`AppState` is now a facade over 3 child ObservableObjects + its own
remaining dashboard / session / cost-forecast / yield-score / UI-state
fields.

## Shipped

### New file
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/ProviderState.swift` —
  `@MainActor public final class ProviderState: ObservableObject` with 5
  `@Published` fields + `enabledProviderNames` computed property mirroring
  `AppState`'s (so direct ProviderState observers don't need to route through
  AppState.objectWillChange, which no longer fires for these fields).

### AppState refactor
- Removed 5 `@Published` fields. Added `public let providerState =
  ProviderState()` child + 5 computed `public var X { get/set }` forwarders.
  All fields were originally `@Published public var X` (no `internal(set)`
  modifier), so the forwarders remain `public var` — step 8 of the template
  (access-control preservation) is a no-op here.

### Root injection (3 scenes)
- `CLIPulseBarApp.swift` — `.environmentObject(appState.providerState)` on
  `MenuBarExtra` root and `Window("provider-config")` root.
- `CLIPulseApp_iOS.swift` — `.environmentObject(appState.providerState)` on
  `WindowGroup` root.

### Cross-contract updates (step 6 of the template — 2 sites this slice)
1. **MenuBarLabel** now observes 4 publishers (appState + authState +
   alertState + providerState). `menuBarIcon` reads `mostUsedProvider`, which
   reads `providers` + `enabledProviderNames` (derived from `providerConfigs`).
   Without the observer, the menu-bar icon wouldn't refresh when
   top-provider usage changes.
2. **ProviderConfigWindowContent** (in `CLIPulseBarApp.swift`) reads
   `editingProviderKind` to gate the editor. Migrated to
   `@EnvironmentObject var providerState: ProviderState` and read
   `providerState.editingProviderKind` — otherwise opening the
   "Provider Settings" window from the macOS Settings gear button wouldn't
   switch views when another provider is selected.

### View migration (11 files)
Added `@EnvironmentObject var providerState: ProviderState` and rewired reads
from `state.X` → `providerState.X` for provider fields:

**macOS (8 files):**
- `MenuBarView.swift` (2 reads — providers, providerConfigs)
- `OverviewTab.swift` (~25 reads — costSummary subproperties, providers,
  enabledProviderNames)
- `ProvidersTab.swift` (5 reads — providerDetails, providers, costSummary)
- `ProviderSettingsSection.swift` (2 — providerConfigs, editingProviderKind
  mutation)
- `DisplaySection.swift` (2 — providerConfigs)
- `AdvancedSection.swift` (1 — providers.count)
- `CLIPulseBarApp.swift` (MenuBarLabel + ProviderConfigWindowContent, both
  above)
- `ProviderConfigEditor.swift` — **NOT migrated**. The editor is
  `@ObservedObject state: AppState` (passed as a parameter, not env) and
  manages its own `@State` for field edits. Its only reads of
  `providerConfigs` are in `loadExistingConfig`/`save` (cold paths), and
  mutations write through `state.providerConfigs[idx].X = v` which flow
  through the computed setter correctly (O(n) COW per mutation on save —
  acceptable).

**iOS (3 files):**
- `iOSProvidersTab.swift` (6 — providerDetails, providers, costSummary)
- `iOSSettingsTab.swift` (5 across two structs — iOSSettingsTab and
  ProviderManagementView)
- `iOSOverviewTab.swift` (~22 — costSummary subproperties, providers,
  enabledProviderNames)

### iOS defensive re-injection
`iOSMainView` + `iPadSplitView` both add `@EnvironmentObject var providerState`
and re-inject `.environmentObject(providerState)` alongside the existing
defensive `state`/`authState`/`alertState` injections in 8 sites
(iOSLoginView, iPadSplitView, detailView, 5 TabView children).

### Out of scope
- **Watch target:** uses `WatchAppState` — separate class, unaffected.
- **`PhoneSessionManager.swift:75`:** `state.providers` — non-view helper,
  reads through AppState forwarder, works unchanged.
- **`DataRefreshManager` (inside `extension AppState`):** all mutations
  (`providers = payload.providers`, `providerConfigs[idx] = ...`,
  `costSummary = ...`) flow through the computed setter on implicit `self`.

## Review verdict
- **Codex codex-rescue:** skipped (session flake pattern).
- **Gemini 3.1 Pro focused review (14 files, 184/-88 LOC):** functionally
  correct; all 5 verification points confirmed:
  1. MenuBarLabel observes all 4 publishers ✓
  2. ProviderConfigWindowContent reads `providerState.editingProviderKind` ✓
  3. Access control preserved (public var → public var) ✓
  4. ProviderConfigEditor subscript mutations work via setter (O(n) COW
     noted) ✓
  5. Build green across targets ✓

  Residual risk note: unmigrated AppState-only observers would miss provider
  updates. Audited — all reactive consumers migrated; non-view helpers
  (PhoneSessionManager, AuthManager sign-out reset, DataRefreshManager
  payload/setProviderEnabled) go through setter forwarder.

## Baselines
- `swift test` CLIPulseCore: all passing ✓
- `xcodebuild -scheme "CLI Pulse Bar" -destination platform=macOS`: BUILD
  SUCCEEDED ✓
- `xcodebuild -scheme "CLI Pulse iOS" -destination generic/platform=iOS
  Simulator`: BUILD SUCCEEDED ✓

## God-class decomposition complete
All 3 planned child ObservableObjects extracted over slices 2–5:
- **Slice 2** (v1.10.2): SubscriptionManager decoupling (cancellable
  anti-pattern removal)
- **Slice 3** (v1.10.3): AuthState (4 @Published)
- **Slice 4** (v1.10.4): AlertState (2 @Published)
- **Slice 5** (v1.10.5): ProviderState (5 @Published)

Net: AppState shed 11 `@Published` fields (plus the subscription cancellable
forwarder). Views that previously re-rendered on every AppState mutation
now observe only the child(ren) they actually care about. MenuBarLabel
became the single cross-contract choke point — it observes all 4 publishers
by design because the menu-bar `menuBarIcon`/`menuBarLabel` computed
properties span every domain (auth + alerts + providers + server-online).

## Follow-ups / not done here
- **P2-8** Sentry observability baseline across 4 platforms. Multi-day.
- Long-tail micro-refactors (e.g. SettingsTab non-provider subsections that
  still observe whole AppState but only read a handful of fields) — low
  priority; the big structural wins are all in.
