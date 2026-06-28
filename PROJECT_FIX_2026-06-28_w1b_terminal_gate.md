# PROJECT FIX — In-app terminal menu gate: helper-reachable ∧ localControlEnabled (W1-B)

**Date:** 2026-06-28
**Branch / PR:** `feat/w1b-terminal-gate`
**Plan:** `DEV_PLAN_2026-06-28_inapp_terminal_productionize.md` §7 (W1-B, folds in after W1-A)
**Depends on:** PR #243 (W1-A) — merged.

## Problem
After W1-A unsandboxed the DEVID build, `MASSandboxGate.canHostInAppTerminal`
(== `!isSandboxed`) now correctly means "this is the Developer-ID channel." But
the **Terminal menu** (`CLIPulseBarApp.swift`) was still gated on that alone — it
showed on every DEVID launch even when the background helper was unreachable or
Local Session Control was off, so "New Terminal — …" would fail deep in the spawn
with an error (confusing "is the app broken?" UX). The review (§7) asked to gate
on `channel policy ∧ helper reachability ∧ localControlEnabled`.

The Sessions tab "Open Terminal" button + preview hint were already correctly
gated — they use `shouldRouteSessionLocally` (= `localHelperReachable ∧
localControlEnabled ∧ owns-session`). So only the menu needed the change.

## Fix
- Menu stays VISIBLE on DEVID (`canHostInAppTerminal` = channel policy; MAS stays
  hidden, W5a). Within DEVID, the "New Terminal" items are **disabled** when
  `appState.canStartLocalManagedSession` is false (helper reachable ∧ local
  control on ∧ paired device — `LocalSessionControlState`). Disabling (not hiding
  the whole menu) avoids menu-bar flicker as the helper probe flaps, and keeps the
  affordance discoverable. A trailing "Background helper not ready — open
  Settings…" item appears when not ready.
- `newTerminal(provider:)` gained a readiness guard (defense-in-depth for the
  gate flipping between menu render and tap): a clear, actionable alert with an
  "Open Settings" action instead of a deep spawn failure.

### Why reading `appState` in the menu is safe
The App body already observes `appState` via `@StateObject`, so reading
`canStartLocalManagedSession` in `.commands` adds no new scene invalidation. The
known "don't read @Published in a Scene closure" caveat (see
`ProviderConfigWindowContent`) was about a *Window's content* destabilizing; menu
items re-evaluating + `.disabled()` is standard, stable AppKit/SwiftUI behavior.

## Validation
- `xcodebuild build` of the "CLI Pulse Bar" scheme (SwiftUI Scene change isn't
  covered by `swift test`).
- `canStartLocalManagedSession` semantics already locked by
  `SessionControlIntegrationGapTests` (requires deviceId; independent of
  `remoteControlEnabled`).
- Menu disabled-state + alert are UX; final confirmation is the W2 on-device smoke.

## Not in this PR
- W2 on-device smoke (still MANDATORY before promoting DEVID `latest.json`).
- W3 helper-not-running "repair" affordance beyond the Settings deep-link.
