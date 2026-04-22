# CLI Pulse — architecture notes

Consolidated from the 14 `PROJECT_FIX_v1.10_*.md` slice archives. The rules below are **load-bearing** for the post-v1.10 god-class-decomposition architecture — reintroducing any of the anti-patterns reintroduces the exact bugs v1.10 fixed.

---

## 1. Client state: AppState is a facade over child ObservableObjects

As of v1.10 the SwiftUI state is split like this:

```
AppState (@MainActor @StateObject)
├── AuthState        — isAuthenticated, isPaired, userId, userName, userEmail
├── AlertState       — alerts, suppressedAlertIDs
├── ProviderState    — providers, providerConfigs, providerDetails, costSummary, editingProviderKind
├── SubscriptionManager.shared — tier, products (observed via env, NOT via objectWillChange sink)
└── (remaining @Published fields) — dashboard, sessions, devices, UI state, forecast/yield, webhook/OTP
```

- Every view that reads only auth / alert / provider state **must** observe the child directly via `@EnvironmentObject`, not `state.X`.
- `AppState` exposes the extracted fields as `get/set` forwarders so non-view callers (AuthManager, DemoDataProvider, DataRefreshManager inside `extension AppState`) compile unchanged.
- The forwarder's access level **must** mirror the original `@Published` declaration. If the source was `@Published public internal(set) var X`, the forwarder is `public internal(set) var X { get { ... } set { ... } }` — the default `public var` silently widens the setter. (Slice 4 regression caught by Gemini.)

### When you add a new `@Published` field

Stop. Ask: which of the existing child classes owns this concept?

- Auth-related → `AuthState` (e.g., `otpSent`, `pairingInfo` are reasonable future additions)
- Alert-related → `AlertState`
- Provider/usage-related → `ProviderState`
- Subscription/billing → `SubscriptionManager`
- Otherwise, consider whether it's really orchestration state (refresh status, loading flags, UI tab selection) that stays on AppState, or a new domain that warrants its own child ObservableObject.

Don't create a new child for a single field — but also don't silently grow AppState. The split is about keeping invalidation fan-out contained.

---

## 2. Environment injection — where to inject

Scene roots that inject the child ObservableObjects:

| Root (file → line anchor) | State objects injected |
|---|---|
| `CLIPulseBarApp.swift` MenuBarExtra | appState, subscriptionManager, authState, alertState, providerState |
| `CLIPulseBarApp.swift` Window("provider-config") | same 5 |
| `CLIPulseApp_iOS.swift` WindowGroup | same 5 |
| *Watch uses its own `WatchAppState`* | not applicable |

### Defensive re-injection sites (iOS only)

`iOSMainView.swift` re-injects all 5 env objects at every transition where SwiftUI environment inheritance has historically been flaky (NavigationSplitView, TabView, conditional branching). Keep the pattern in sync when adding a new env-object:

- `iOSLoginView()` at the unauthenticated branch
- `iPadSplitView()` for the iPad regular-width branch
- `detailView` inside the NavigationSplitView
- All 5 `TabView` children on iPhone
- `ProviderManagementView()` from `iOSSettingsTab.swift`

When a future slice adds a new child ObservableObject: add it to every scene root AND every defensive re-injection site. Missing one → SwiftUI crashes with "No ObservableObject of type X found."

---

## 3. Cross-contract views — MenuBarLabel and friends

**The problem.** A SwiftUI scene `label:` closure (e.g. `MenuBarExtra { } label: { ... }`) observes only the *direct* object it holds via `@StateObject` / `@ObservedObject`. If that closure reads a computed property on AppState that in turn reads extracted-child state (e.g. `appState.menuBarIcon` → reads `authState.isPaired` + `alertState.alerts` + `providerState.providers`), the child publishers fire, AppState's does not, and the label never re-renders.

**The rule.** Any view consumed from a scene `label:` / toolbar / compact closure that reads AppState-computed projections spanning child state must be extracted into a dedicated View that `@ObservedObject`s every publisher it depends on.

**Canonical example.** `MenuBarLabel` in [CLIPulseBarApp.swift](CLI Pulse Bar/CLI Pulse Bar/CLIPulseBarApp.swift) observes **four publishers** (appState + authState + alertState + providerState) because `menuBarIcon` / `menuBarLabel` read fields from every domain. Four is not a code smell — it's the *correct* number for a one-element UI projection over the whole app. It would be a smell only if ordinary feature views needed the same fan-in.

**Second case.** `ProviderConfigWindowContent` in the same file observes `providerState.editingProviderKind` specifically because the `Window(id:)` scene body is likewise a `label:`-equivalent context. Without this the standalone "Provider Settings" window wouldn't switch content when the user picks a different provider from Settings.

**Test for the pattern.** If a slice extracts a `@Published` field AND any AppState computed property reads that field AND that computed is consumed from a Scene closure → you need a `children: .combine`/`.ignore` + `@ObservedObject`-both view. Grep for `appState.menuBarIcon`, `appState.menuBarLabel`, `MenuBarExtra { } label:`, `Window(id:`.

---

## 4. Concurrency — actor-crossing rules

- `APIClient` is an `actor`. Any access to an `actor` property from a `@MainActor` view is a Swift 6 violation (surfaces as a warning-today-error-tomorrow).
- Don't read `appState.api.userId` from a view. Cache that state on `AuthState` instead, driven by `AuthManager.applyAuthenticatedState(_:)`. Views should read `authState.userId` synchronously.
- Same rule for any other actor property that views need synchronous access to: bounce it through a `@MainActor`-isolated `@Published` on the relevant child ObservableObject.
- For Task-in-closure patterns (NotificationCenter observers, Timer handlers): bind `self` in the *outer* closure before the Task hop, not inside the Task. Swift 6 forbids referencing a captured `var` (the weak-self binding) from concurrently-executing code.

```swift
// Wrong (Swift 6 error)
NotificationCenter.default.addObserver(...) { [weak self] _ in
    Task { @MainActor in
        self?.doWork()              // `self` is a captured var
    }
}

// Right
NotificationCenter.default.addObserver(...) { [weak self] _ in
    guard let self else { return }  // local `let`
    Task { @MainActor in
        self.doWork()               // captures the `let`
    }
}
```

---

## 5. Backend — SECURITY DEFINER + pg_cron patterns

For any helper invoked by pg_cron or the HTTP RPC path:

1. Split into `_name_internal()` (no JWT gate, `REVOKE EXECUTE` from PUBLIC/authenticated/anon) and public `name()` (`service_role` JWT gate, delegates to internal).
2. `SECURITY DEFINER` + pinned `SET search_path = pg_catalog, public, extensions` on every function.
3. JWT role check **must** use `coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') != 'service_role'`. The raw expression returns NULL when called outside PostgREST (direct DB connection), and PL/pgSQL's `IF NULL` silently bypasses the gate. Coalesce to `''` makes the comparison three-valued-safe.
4. pg_cron runs as postgres superuser and bypasses the public wrapper — it invokes the `_internal` function directly. The public wrapper exists only for operator-triggered RPC.
5. Idempotent `cron.schedule`: wrap the prior `cron.unschedule('name')` in `DO $$ BEGIN PERFORM cron.unschedule('name'); EXCEPTION WHEN OTHERS THEN NULL; END; $$;` since unschedule raises on missing job.
6. Global DELETE-by-time-column predicates **must** have standalone time-column indexes. Composite indexes with leading `user_id` (which the retention pg_cron hits via unfiltered global DELETE) will degrade to seq scan as data grows. See v0.23.

---

## 6. Review tooling — when to trust what

- **Gemini 3.1 Pro `mcp__gemini__review`** catches cross-contract bugs that per-slice readers miss. It caught the MenuBarExtra reactivity bug on slice 3 (AuthState) that I missed. Use `depth: focused` for 10+ file slices, `depth: scan` for ≤10.
- Gemini times out regularly on small SQL diffs; treat a timeout as "needs self-review via inspection + live smoke," not a red flag.
- Gemini occasionally hallucinates format-specifier issues in diff rendering (seen on the P3-2 L10n slice: claimed `% @` space-separated in 4 locales that byte-verification proved were fine). Cross-check "critical" findings against `od -c` or `grep -l` before acting.
- **Codex rescue via `codex:codex-rescue`** stalls in "Searching:" loops on small diffs but ships clean verdicts on larger ones. Monitor + TaskStop after ~10 min if stuck.
- When both flake, self-review via direct grep + live smoke is adequate for SQL that mirrors a prior reviewed pattern.

---

## 7. Glossary — two "helpers"

- **CLIPulseHelper** (Swift, production): login-item target bundled in `CLI Pulse Bar.app/Contents/Library/LoginItems/`. Auto-starts after the user toggles Settings → Background Helper. Sync runs via `DispatchSourceTimer` in `HelperDaemon.swift`. **Zero terminal required.**
- **helper/cli_pulse_helper.py** (Python, legacy): standalone script predating the Swift helper. Still tested by CI but not shipped to users.

If someone asks "do I need to run the helper in terminal," the answer is no.
