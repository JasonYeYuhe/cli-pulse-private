# Phase 4E Slice 4 — cli_pulse_helper daemon cloud-sync activation

**Date:** 2026-05-07
**Branch:** `phase4e-slice4-cutover`
**Tests:** HelperKit 295 → 307 (+12). pytest 413/413 ✓. CLIPulseCore 918/918 ✓.

## Scope

Activate the Phase 4E Slice 3 actors (`RemoteAgentCloud`, `EventUploader`, `SupabaseRPCCaller`) inside the existing `cli_pulse_helper daemon` subcommand. After this slice ships in v1.13, the LaunchAgent driver itself handles cloud-side managed-session sync (pull commands → dispatch → post events) instead of relying on a parallel Python helper process for that flow.

### What this slice is NOT

The original Phase 4E v2.1 dev plan envisioned Slice 4 as a full plist swap + `pair`/`heartbeat`/`sync`/`inspect` subcommand port + Python test deletion. Reality on `main` differs:

- **Phase 4D (PR #20) already cut over the LaunchAgent to the Swift binary.** `Library/LaunchAgents/yyh.CLI-Pulse.helper.plist`'s `BundleProgram` already points at `Contents/Helpers/cli_pulse_helper` (the Swift binary), and `HelperLifecycleManager` registers it. There is no plist swap to do.
- **`helper_heartbeat` and `helper_sync` are owned by the macOS app's `HelperDaemon`** (`CLI Pulse Bar/CLIPulseHelper/HelperDaemon.swift`), not the LaunchAgent. Those flows already run from the app process, so porting them into `cli_pulse_helper` would duplicate work. Pair / inspect remain user-invoked Python utilities.
- **Crash-loop launcher script (Gemini v2.1 P2)** deferred to v1.14: `HelperAgent.plist` already has `KeepAlive=true` + `ThrottleInterval=30`, which gives reasonable crash safety. Adding the bash launcher with 3-crash → Python fallback is insurance we'll revisit if Sentry shows Swift daemon crashes in production.
- **Atomic Python test deletion (dev plan Q7)** deferred to v1.14: the Python helper source still exists for the `--legacy-python` opt-out path and for direct user invocation (debugging, manual `python3 helper/cli_pulse_helper.py daemon`). Stranding code without test coverage isn't acceptable while it remains a fallback target.

The actual deliverable for Slice 4 is therefore tighter than the dev plan called for, but the **functional cutover is complete** — once Slice 4 merges and v1.13 ships, the LaunchAgent's `daemon` subcommand drives cloud-side managed-session sync entirely in Swift.

## Files

| File | Change | LoC |
|---|---|---|
| `HelperSwift/Sources/HelperKit/DaemonConfig.swift` | NEW — argv parsing for `cli_pulse_helper daemon`, lifted out of `main.swift` so it has a unit-test seam. Floors `intervalSeconds` at 60 s, `cloudTickSeconds` at 0.1 s, `cloudPullMax` at 1. | 80 |
| `HelperSwift/Sources/cli_pulse_helper/main.swift` | EXTEND — adds cloud-sync `Task` after the UDS server starts. Constructs `SupabaseRPCCaller` + `EventUploader` + `RemoteAgentCloud`, ticks every `cloud-tick-seconds` (default 1 s), responds to SIGTERM with synchronous bounded drain (4.5 s budget — Gemini P0 fix). Adds `--legacy-python`, `--cloud-tick-seconds`, `--cloud-pull-max` flags and bumps the version banner. | +80 / -10 |
| `HelperSwift/Tests/HelperKitTests/DaemonConfigTests.swift` | NEW — 9 tests: defaults, `--legacy-python`, `--interval`, `--cloud-tick-seconds`, `--cloud-pull-max`, combined flags, value floors, unknown-flag forward-compat, invalid numeric fallback. | 80 |
| `HelperSwift/Tests/HelperKitTests/DaemonCloudWireUpTests.swift` | NEW — 3 tests: paired helper drives `pull_commands` through, unpaired helper skips silently, cloud loop is cancellable in bounded time. | 105 |

## Behavior

- **Paired helper** (i.e. `~/.cli-pulse-helper.json` has `device_id`, `helper_secret`, `supabase_url`, `supabase_anon_key`): the daemon spawns a `Task` that loops `RemoteAgentCloud.tick()` every `cloud-tick-seconds` (default 1 s). Pulled commands route into `ManagedSessionManager.startSession/sendInput/stopSession/interruptSession` (Slice 3 wiring). Stdout / status / info events flow through `EventUploader` (256/session bounded queue, drop-oldest, posted via `SupabaseRPCCaller`).
- **Unpaired helper**: the daemon skips cloud sync entirely and only runs the local UDS server. Logs `unpaired — cloud sync skipped` to stderr. Matches the Python helper's behavior so existing dev / unpaired-install scenarios are undisturbed.
- **`--legacy-python` flag**: exits 0 with a diagnostic explaining how to manually run the Python daemon. Cutover safety net for one release cycle. Idempotent — flipping back to Swift is just removing the flag.

## SIGTERM contract (Gemini P0 fix)

Before this fix: `cloudTask?.cancel()` only marked the task cancelled; `stopSemaphore.signal()` fired immediately, racing `EventUploader.flush()`. The "5 s flush budget" comment was aspirational.

After: the signal handler synchronously waits up to 4.5 s for `cloudTask` to drain (via a `DispatchSemaphore` posted by `await task.value`), then signals stop. This bounds the SIGTERM-to-exit window at ~4.6 s — well under launchd's 30 s `ThrottleInterval`, but long enough for `flush()`'s 5 s internal budget to drain everything that can drain.

## Gemini 2.5 Pro diff review

- **P0 (FIXED)** — `cloudTask?.cancel()` shutdown race: see SIGTERM contract above.
- **P0 (NOT A BUG)** — `broker` not passed to `RemoteAgentCloud`: false alarm. The diff DOES pass `broker: broker` and calls `await remoteCloud.startObservingBroker()`. Gemini retracted.
- **P1 (CONFIRMED SAFE)** — `HelperConfigStore` thread safety: it's `@unchecked Sendable` with internal `NSLock`, all accessors lock around `raw` dict reads. Safe to share.
- **P1 (ACCEPTED)** — Pairing state only checked at startup: re-pairing requires LaunchAgent restart. Standard LaunchAgent pattern; the macOS app should call `launchctl kickstart -k gui/<uid>/yyh.CLI-Pulse.helper` after pairing config changes (already standard practice for LaunchAgent config refresh). Documented behavior, not a bug.
- **P2** — `--legacy-python` output: Gemini approved verbatim.

## Verification

```bash
swift test --package-path HelperSwift            # 307/307 ✓
swift test --package-path "CLI Pulse Bar/CLIPulseCore"  # 918/918 ✓
python3 -m pytest -q helper/                     # 413/413 ✓

# Smoke
HelperSwift/.build/debug/cli_pulse_helper version
# → "cli_pulse_helper Swift port phase4e-slice4 — protocol 1"
HelperSwift/.build/debug/cli_pulse_helper daemon --legacy-python
# → exit 0 with diagnostic
```

## What v1.13 ships

- LaunchAgent runs the Swift `cli_pulse_helper daemon`. Cloud-side managed-session sync is fully in-process (no Python subprocess for that flow).
- Heartbeat / sync continue to run in the macOS app's `HelperDaemon` (unchanged).
- `helper/cli_pulse_helper.py` still exists as the source for `--legacy-python` opt-out and direct user invocation. Python tests still pass and remain in CI.
- Phase 4E is **functionally complete**.

## Deferred to v1.14+ (with rationale)

- **Crash-loop launcher script with 3-failures → Python fallback.** Plist already has KeepAlive + 30 s ThrottleInterval. Add this if production Sentry shows persistent Swift crashes; otherwise it's premature insurance.
- **Atomic Python test retirement.** Hold this until `--legacy-python` is removed. Stranding production fallback code without coverage isn't a tradeoff worth taking.
- **`helper_heartbeat` / `helper_sync` port to Swift LaunchAgent daemon.** Currently owned by the macOS app's `HelperDaemon`. Moving them to the LaunchAgent would mean cross-process semantics change (sync runs even when app is closed) — that's a separate UX decision, not a code refactor.
