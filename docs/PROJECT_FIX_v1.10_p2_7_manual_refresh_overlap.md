# PROJECT_FIX v1.10 P2-7 extension — manual-refresh overlap

**Date**: 2026-04-22
**Version**: v1.10 → **v1.10.1**
**Plan item**: v1.10 P2-7 follow-up (manual-refresh audit)
**Review**: Codex (codex:codex-rescue) **SHIP**. Gemini 3.1 Pro skipped (recurring 180s timeout flake this session).

## Problem

v1.10 P2-7 wrapped the timer-driven and helper-sync-driven refresh path
in `DataRefreshManager.scheduleRefresh(using:)`, which cancels any
in-flight `refreshTask` before assigning a new one. Single-in-flight
discipline, prevents stacked fetches when the timer fires during a slow
sync.

But 7 user-facing refresh entry points spawned `Task { await
state.refreshAll() }` directly, bypassing `refreshTask`. If the user
tapped refresh while a timer-driven fetch was in flight — or tapped
refresh twice quickly — two concurrent `refreshAll` calls ran, doubling
network load and producing interleaved UI updates.

The v1.10 P2-7 comment explicitly acknowledged this:

> Manual user-triggered refreshes from the menu bar / overview button
> bypass this path and run their own unmanaged `Task { await
> state.refreshAll() }`, so full overlap prevention requires a bigger
> audit (tracked separately).

This is that audit.

## Fix

### 1. `DataRefreshManager.scheduleRefresh(using:)` → `requestRefresh(using:)`

Renamed for clarity (it no longer just *schedules* — it also *cancels*)
and promoted from `private` to `internal` so the AppState extension can
call it. Body unchanged:

```swift
func requestRefresh(using onRefreshRequested: @escaping @MainActor () async -> Void) {
    refreshTask?.cancel()
    refreshTask = Task { @MainActor in
        await onRefreshRequested()
    }
}
```

Two internal callers updated: `startRefreshLoop`'s Timer closure and
`observeHelperSync`'s DistributedNotification observer.

### 2. New public `AppState.requestRefresh()`

```swift
@MainActor
public func requestRefresh() {
    dataRefreshManager.requestRefresh(using: refreshRequest())
}
```

Fire-and-forget by design — the Task is owned by DataRefreshManager.
Don't `await`; the Button is already disabled via `state.isLoading` while
a refresh is in flight.

### 3. Call-site migration (7 sites)

**macOS (3):**
- `CLI Pulse Bar/CLI Pulse Bar/OverviewTab.swift:144` — toolbar refresh button
- `CLI Pulse Bar/CLI Pulse Bar/MenuBarView.swift:198` — menu-bar popover refresh
- `CLI Pulse Bar/CLI Pulse Bar/CLIPulseBarApp.swift:48` — ⌘R menu command

**iOS (4):**
- `iOSOverviewTab.swift:63` — nav-bar primary action
- `iOSOverviewTab.swift:444` — onboarding "check sync" button
- `iOSMainView.swift:135` — nav-bar primary action
- `iOSSettingsTab.swift:285` — Settings → Advanced → Force Refresh
- `CLIPulseApp_iOS.swift:52` — ⌘R menu command
- `CLIPulseApp_iOS.swift:68` — `handleWidgetRefreshRequest` (widget-initiated refresh)

All were either SwiftUI `Button` actions or one-shot event handlers with
no downstream `await` — semantically equivalent to fire-and-forget, so
dropping the `Task { await … }` wrapper and calling `requestRefresh()`
directly is safe.

### 4. Out of scope — `.refreshable` closures

SwiftUI `.refreshable { await state.refreshAll() }` in iOSOverviewTab
(line 87), iOSProvidersTab (83), iOSSessionsTab (36/77), iOSAlertsTab
(76) legitimately `await` so pull-to-refresh dismisses the spinner on
completion. Routing through `requestRefresh()` would break the UX
(spinner vanishes immediately while refresh runs in background).
**Known edge**: a pull-to-refresh does not cancel an in-flight scheduled
refresh. Acceptable — user explicitly wanted fresh data.

### 5. Out of scope — watchOS

`WatchAppState` in `CLI Pulse Bar Watch/` is a separate class with its
own simpler refresh loop (`startRefreshLoop` + `refreshAll` directly).
No `DataRefreshManager` involvement; no audit needed.

## Baselines

- `swift test` (CLIPulseCore): **442 passed**, 1 skipped, 0 failures.
- `xcodebuild -scheme "CLI Pulse Bar" -destination platform=macOS build`: **BUILD SUCCEEDED**.
- `xcodebuild -scheme "CLI Pulse iOS" -destination "generic/platform=iOS Simulator" build`: **BUILD SUCCEEDED**.

## Review

### Codex (codex:codex-rescue, sonnet)

**Verdict**: SHIP. All 4 investigation questions cleared:

1. No call site awaited `refreshAll()` completion meaningfully —
   `handleWidgetRefreshRequest` is fire-and-forget from `.onChange(of:
   scenePhase)`.
2. `AppState.requestRefresh()` actor isolation correct: both AppState
   and DataRefreshManager are `@MainActor`; no actor-hop introduced.
3. `isAuthenticated` guard preserved — `requestRefresh(using:)` only
   adds cancel-and-replace; `refreshAll()`'s existing
   `guard context.isAuthenticated, !context.isDemoMode else { return }`
   at DataRefreshManager.swift:67-68 still fires.
4. No remaining `Task { await (state|appState).refreshAll() }` sites
   outside WatchAppState. The `.refreshable` closures are legitimate
   (documented as out of scope above).

### Gemini 3.1 Pro (mcp__gemini__review)

Skipped. Recurring 180s-timeout flake this session on small Swift diffs
(same pattern hit v0.20 and v0.21). Codex verdict sufficient.

## Files touched (8 files, +41/-23 LOC)

| File | Change |
|---|---|
| `CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift` | Rename+promote `scheduleRefresh`→`requestRefresh`; add `AppState.requestRefresh()` |
| `CLI Pulse Bar/CLI Pulse Bar/OverviewTab.swift` | Call-site migration |
| `CLI Pulse Bar/CLI Pulse Bar/MenuBarView.swift` | Call-site migration |
| `CLI Pulse Bar/CLI Pulse Bar/CLIPulseBarApp.swift` | Call-site migration |
| `CLI Pulse Bar/CLI Pulse Bar iOS/iOSOverviewTab.swift` | Two call-site migrations |
| `CLI Pulse Bar/CLI Pulse Bar iOS/iOSMainView.swift` | Call-site migration |
| `CLI Pulse Bar/CLI Pulse Bar iOS/iOSSettingsTab.swift` | Call-site migration |
| `CLI Pulse Bar/CLI Pulse Bar iOS/CLIPulseApp_iOS.swift` | Menu + widget-refresh call-site migration |

## Follow-ups / not done

- `.refreshable` pull-to-refresh paths still don't cancel in-flight
  scheduled refreshes. Low-value fix (user explicitly wanted fresh
  data); documented as known edge above.
- WatchAppState has its own refresh loop that could benefit from the
  same single-in-flight discipline. Defer to a watchOS-specific slice.
