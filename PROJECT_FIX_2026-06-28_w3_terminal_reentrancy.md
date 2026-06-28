# PROJECT FIX — TerminalSessionAdapter.attachExisting reentrancy (W3)

**Date:** 2026-06-28
**Branch / PR:** `fix/w3-terminal-reentrancy`
**Plan:** `DEV_PLAN_2026-06-28_inapp_terminal_productionize.md` §7 (W3, 🔴 reentrancy)
**Depends on:** W1-A/W1-B/W2 — merged.

## Problem (Gemini deep-review catch)
`TerminalSessionAdapter.attachExisting(to:sessionId:)` subscribes to the live raw
stream, `await`s the tail snapshot, then paints snapshot + buffered live bytes.
To guard against a rapid re-attach to a DIFFERENT session superseding the
in-flight one, it checked `if Task.isCancelled { return }` after the await — but
the method never stores or cancels its own `Task`, so `Task.isCancelled` was
**always false**. A reconnect / re-attach to session B while A's snapshot was in
flight would therefore flush A's stale snapshot into B's freshly-installed
reattach buffer (garbled/duplicated terminal output).

## Fix
The adapter is `@MainActor`, so the only suspension point is the snapshot
`await`, and all state mutations are serialized around it. After resume, the live
`state` is the authoritative supersession signal: the reattach is superseded
unless `state` is still `.running` for the same `sessionId`. Replaced the dead
`Task.isCancelled` check with a pure, `nonisolated static`
`reattachSuperseded(state:targetSessionId:)` predicate:

```swift
nonisolated static func reattachSuperseded(state: State, targetSessionId: String) -> Bool {
    if case let .running(sid) = state { return sid != targetSessionId }
    return true
}
```

`attachExisting` now bails before painting iff `reattachSuperseded(...)`.

## Tests
`TerminalSessionAdapterTests` (W3): same running session → not superseded;
different running session → superseded; every non-running state → superseded.
The predicate is `nonisolated` + pure precisely so it is unit-tested WITHOUT a
WKWebView (the XCTest host aborts on WKWebView creation outside an AppKit loop —
the same reason render stays a manual on-device gate).

## Validation
`swift test` (full): 1825 tests, 0 failures.

## Deferred (documented, not done here)
- **`window.pushChunk` WKContentWorld isolation** — explicitly P2 / non-blocking
  per both reviewers. Moving `pushChunk` into an isolated content world while
  keeping xterm's `term.write` reachable is a non-trivial restructure of
  `index.html` + `TerminalView`, and render changes can't be validated headlessly
  (they need the W2 on-device smoke). The existing `TerminalNavigationGuard`
  already blocks navigation away from the bundle, so this is defense-in-depth.
  Tracked for a separate PR that the on-device smoke can validate.
- Helper-not-running UX is already covered by W1-B (#244): disabled menu items +
  the "Background helper not ready — open Settings…" affordance + the
  `newTerminal` readiness alert.
