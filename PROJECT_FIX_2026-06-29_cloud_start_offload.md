# PROJECT FIX — keep the Claude OAuth refresh off the cooperative pool (review follow-up)

**Date:** 2026-06-29
**Branch / PR:** `fix/cloud-start-offload-blocking-refresh`
**Found by:** Gemini 3.5 Flash (High) final review of the session changeset.

## Problem
PR #248 made `ManagedSessionManager.startSession` do a SYNCHRONOUS Claude OAuth
token refresh for `provider == "claude"` (rare — only on ~8h token expiry,
bounded by a timeout). The **local** UDS path runs `startSession` on a dedicated
per-connection `Thread`, so blocking there is fine. But the **cloud** path
(`RemoteAgentCloud.handleStart`, `async`) called it synchronously on the Swift
Concurrency **cooperative pool** — so a refresh could park a cooperative thread
for a few seconds, degrading other async work. (Gemini 3.1 Pro + the adversarial
workflow both cleared everything else; this was the one real finding.)

## Fix
`RemoteAgentCloud.handleStart` now runs the blocking `startSession` on a dedicated
global-queue thread and `await`s it via `withCheckedThrowingContinuation`, so no
cooperative thread is parked. Typed `ManagerError`s still propagate to the
existing catch. `ManagedSessionManager` is `@unchecked Sendable` (lock-guarded),
so the off-thread call is safe.

## Validation
`swift test` (HelperSwift): 431 tests, 0 failures.

## Review summary (this changeset is clean)
- Gemini 3.1 Pro (High): "No blocking issues."
- Gemini 3.5 Flash (High): 5 findings — this one fixed; the rest were false
  positives (MAS strips the unsandboxed helper via build-appstore.sh; no
  `register(defaults:)` so the migration's `object(forKey:)==nil` is sound) or
  low (getpwuid_r — runs single-threaded at launch).
- Adversarial workflow (4 skeptics + synthesis): no blocker/major; shippable.
