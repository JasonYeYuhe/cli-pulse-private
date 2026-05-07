# Phase 4E Slice 3 — RemoteAgentCloud port

**Date:** 2026-05-07
**Branch:** `phase4e-slice3-remote-agent-cloud`
**Tests:** HelperKit 258 → 295 (+37). pytest 413/413 ✓. CLIPulseCore 918/918 ✓.

## Scope

Port the cloud-sync layer of `helper/remote_agent.py` to Swift HelperKit. After this slice merges, the Python `RemoteAgentManager.tick()` (poll Supabase commands, dispatch into managed sessions, observe exits, post events) has a complete Swift twin. Slice 4 will replace the LaunchAgent entry to actually flip the runtime over.

## Files

| File | Change | LoC |
|---|---|---|
| `HelperSwift/Sources/HelperKit/Redactor.swift` | NEW — extracted from `HookAdapter.swift` so RemoteAgentCloud + EventUploader share one implementation. `HookAdapter.redact` now delegates here. | 99 |
| `HelperSwift/Sources/HelperKit/EventBatcher.swift` | NEW — coalesces small stdout chunks into ≤4096-char rows. Mirrors Python `EventBatcher` (flush_bytes=3500, max_idle=0.5). | 90 |
| `HelperSwift/Sources/HelperKit/EventUploader.swift` | NEW — actor with bounded queue (256 events/session, drop-oldest), per-session monotonic seq counter, 5 s flush budget on SIGTERM. Posts via `remote_helper_post_event` RPC. | 252 |
| `HelperSwift/Sources/HelperKit/SupabaseRPCCaller.swift` | NEW — async URLSession wrapper. 2.5 s per-request timeout (matches v1.12.2 / Mac M2 backport). Throws `SupabaseRPCError.notConfigured` for unpaired helpers, `.http(...)` for non-2xx, `.transport(...)` for TLS/TCP failures, `.decode(...)` for JSON-decode. | 121 |
| `HelperSwift/Sources/HelperKit/RemoteAgentCloud.swift` | NEW — actor that polls `remote_helper_pull_commands`, dispatches start/prompt/stop/interrupt into ManagedSessionManager, subscribes to EventBroker for output_delta coalescing, observes session exits, posts status+info+stdout events through EventUploader. | 533 |
| `HelperSwift/Sources/HelperKit/HelperConfig.swift` | EXTEND — added read-only accessors for `device_id`, `helper_secret`, `supabase_url`, `supabase_anon_key`. New `CloudConfig` snapshot struct + `cloudConfigSnapshot()` for handing to RemoteAgentCloud / SupabaseRPCCaller without leaking the store's lock. | +56 |
| `HelperSwift/Sources/HelperKit/HookAdapter.swift` | REFACTOR — `redact()` and `redactionMarker` now delegate to `Redactor`. Existing tests (`HookAdapter.redact(...)`) still work. Removed ~110 LOC of duplicate regex tables. | -109 |
| `HelperSwift/Sources/HelperKit/ManagedSessionManager.swift` | EXTEND — added `interruptSession(_:)`, `ownsSession(_:)`, `forcedSessionId:` parameter to `startSession`, exit-code capture in drainLoop's session_stopped broker frame. | +59 |
| `HelperSwift/Tests/HelperKitTests/RemoteAgentCloudTests.swift` | NEW — 25 tests covering dispatch, fail-closed posture, status payload exactness, redaction, queue overflow, flush budget, exit observation, batcher, complete_command non-fatal failure, wstatus extraction. | 564 |
| `HelperSwift/Tests/HelperKitTests/SupabaseRPCCallerTests.swift` | NEW — 6 tests with URLProtocol-based interception. Validates URL shape, headers (apikey + Bearer), JSON body encoding, response decoding (array / object / empty), notConfigured + http error mapping. | 240 |
| `HelperSwift/Tests/HelperKitTests/RedactorTests.swift` | NEW — 6 tests on the extracted module. Asserts HookAdapter delegation invariant. | 43 |

## Wire-shape pinning (per Python parity contract)

1. **Status payloads MUST be exactly `'stopped'` or `'errored'`.** `RemoteAgentCloud.postStatus` `guard`s anything else. The SQL gate in `remote_helper_post_event` only updates `remote_sessions.status` on these exact strings; an earlier Python draft sent `f"errored: {exc}"` and silently kept failed sessions stuck on running. Pinned in `test_post_status_payload_must_be_exactly_stopped_or_errored`.

2. **Stop / interrupt for unknown session → fail-closed.** PR #18 lesson — marking `delivered` on no-op stops obscured stale-row bugs. `RemoteAgentCloud.dispatchOne` checks `sessionManager.ownsSession(_:)` before invoking. Pinned in `test_dispatch_stop_for_unknown_session_completes_failed` + interrupt twin.

3. **Per-session monotonic seq counter, starts at 1.** `EventUploader.nextSeq` increments + reads atomically (actor-isolated). Reset via `removeSession(_:)` after the final 'stopped'/'errored' status posts. Pinned in `test_post_status_seq_starts_at_one_per_session` + isolation test.

4. **Bounded queue 256/session, drop-oldest.** `EventUploader.ingest` evicts the front of the queue when full and emits an `onDrop(.queueOverflow)` breadcrumb. Pinned in `test_event_uploader_drops_oldest_when_session_queue_overflows` + seq-continues-after-drop test.

5. **Flush 5 s budget on SIGTERM.** `flush(timeout:)` runs `pumpOnce()` waves until empty or deadline. Surviving events drop with `.flushBudgetExceeded`. Pinned in `test_event_uploader_flush_drains_within_budget` + budget-exceeded twin.

6. **Pull-commands gate-off swallowed.** When the user disables Remote Control server-side, the RPC raises `Device not found or unauthorized`. `pollAndDispatchCommands` catches and logs at debug. Pinned in `test_pull_commands_failure_is_swallowed`.

7. **CR-only terminator on prompt write.** Inherited from `ManagedSessionManager.sendInput` (Phase 4D iter 9 — see `helper/test_remote_agent_submit.py`). Slice 3 doesn't re-touch the terminator logic.

## Gemini 2.5 Pro diff review

(`gemini-3.1-pro-preview` was capacity-exhausted today; `gemini-2.5-pro` substituted.)

Review verdict: **clean, mergeable.** 0 P0, 0 P1, 2 P2 minor suggestions, both applied:

- **P2 #1**: `EventUploader.flush()` could spin past its budget if `pumpOnce` makes no progress and the remaining budget is < 50 ms. Fix: bail before the backoff sleep when `(deadline - now) < 0.05`. (`EventUploader.swift:170-175`)
- **P2 #2**: `wstatus → exitCode` bit-twiddling in `ManagedSessionManager.drainLoop` had no direct unit test (only downstream "errored vs stopped" coverage). Added `test_wstatus_normal_exit_extracts_correct_code` to pin the POSIX layout.

After both fixes: 295/295 ✓.

## Verification

```bash
swift test --package-path HelperSwift            # 295/295 ✓
swift test --package-path "CLI Pulse Bar/CLIPulseCore"  # 918/918 ✓
python3 -m pytest -q helper/                     # 413/413 ✓
```

## Slice 3 unblocks

- **Slice 4**: `cli_pulse_helper` daemon main can wire `RemoteAgentCloud.tick()` into its 1 s timer alongside heartbeat / sync. The `--legacy-python` opt-in flag and crash-loop launcher script land in Slice 4 along with the LaunchAgent plist swap.

## What this slice explicitly does NOT do

- Does NOT change the LaunchAgent runtime. The Python helper still serves cloud sync until Slice 4 cuts over.
- Does NOT modify any Supabase migrations, RPCs, or schema. Pure transport-layer port.
- Does NOT delete `helper/remote_agent.py` or its tests. Atomic retirement happens in Slice 4 (Gemini Q7 resolution: leaves a safety net for mid-phase reverts).
- Does NOT add WebSocket realtime — polling preserved, deferred per dev plan Risks section.
