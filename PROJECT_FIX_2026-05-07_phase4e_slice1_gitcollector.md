# PROJECT_FIX — Phase 4E Slice 1 — `GitCollector.swift` port

**Date:** 2026-05-07
**Branch:** `phase4e-slice1-gitcollector` (cut from `main` after Phase 4D PR #20 merged)
**Plan:** [docs/PHASE_4E_DEV_PLAN.md](docs/PHASE_4E_DEV_PLAN.md) — Slice 1 of 4
**Source:** Cross-team alignment 2026-05-07 (`memory/feedback_mac_windows_remote_track_alignment.md`) — Phase 4E Route A: Mac helper long-term all-Swift.

## What ships

Slice 1 of the Phase 4E Mac helper Swift port. Smallest module first (per the plan) to prove the integration toolchain on a Low-complexity target before tackling `SystemCollector` (Very High) and `RemoteAgentCloud` (High).

| File | Change |
|---|---|
| [HelperSwift/Sources/HelperKit/SharedModels.swift](HelperSwift/Sources/HelperKit/SharedModels.swift) | NEW. Minimal `CollectedSession` struct (Slice 1 reads `projectRoot`; Slice 2 will expand additively). Snake_case `CodingKeys` baked in for wire-shape parity with Python. |
| [HelperSwift/Sources/HelperKit/GitCollector.swift](HelperSwift/Sources/HelperKit/GitCollector.swift) | NEW. `actor GitCollector` mirroring `helper/git_collector.py`: same `git log --no-merges --since=… --pretty=%H\|%aI\|%P` shape, same per-project last-seen-hash cache, same dedupe-by-hash in `collect`, same HMAC-SHA256(secret, utf8(absolutePath)) project hash. Plus `GitProjectPaths.extract` pure-function helper. |
| [HelperSwift/Tests/HelperKitTests/GitCollectorTests.swift](HelperSwift/Tests/HelperKitTests/GitCollectorTests.swift) | NEW. 13 tests including HMAC parity against 5 Python-computed reference values, subprocess timeout zombie-reap regression, large-stdout pipe-buffer deadlock regression. |

## Per-fix notes

### Initial implementation

Followed the dev plan v2.1 spec exactly:
- `actor GitCollector(secret:sinceWindow:subprocessTimeout:gitPath:)` with public `scan(projectPath:)`, `collect(projectPaths:)`, `resetCache()`.
- `GitProjectPaths.extract(from sessions:)` static helper.
- HMAC scheme via `CryptoKit.HMAC<SHA256>` keyed on the user secret.
- Subprocess hygiene per Phase 4E v2 P1: `terminate()` + 1 s grace + `SIGKILL` on timeout/cancellation.

### Gemini diff review — 3 P0/P1 catches applied

A Gemini 3.1 Pro pass over the initial diff surfaced three concrete bugs that the plan-level review didn't anticipate at code level:

**(P0) JSON wire-shape mismatch.** Default `Codable` synthesis emits camelCase (`commitHash`, `projectHash`, …); Supabase `ingest_commits` expects snake_case (per Python's `helper/git_collector.py::CommitRecord.to_dict()`). Without explicit `CodingKeys` the server would silently drop the fields. Fix: explicit `CodingKeys` enum on both `CommitRecord` and `CollectedSession`.

**(P0) Pipe-buffer deadlock on large stdout.** macOS pipes default to ~64 KB. `runGit` polled `process.isRunning` in a loop and only called `readDataToEndOfFile()` AFTER the loop exited. A wide `--since=2 hours ago` window on an active monorepo can blow past 64 KB; git would block on the next pipe write, the parent would treat the hang as a timeout, SIGKILL the child, and silently drop commits. Fix: detached `Task` drains stdout concurrently with the wait loop; the wait loop awaits the drain task only after natural exit.

**(P1) `Task.sleep` inside catch-block bypasses 1 s SIGTERM grace on cancellation.** When `Task.checkCancellation()` throws and execution falls into the catch-block, the task is already cancelled. `Task.sleep(for: .seconds(1))` on a cancelled task throws `CancellationError` immediately rather than sleeping; the `try?` swallows the error and execution falls straight to `kill(pid, SIGKILL)`. Git typically handles SIGTERM cleanly within milliseconds, so the grace period is worth keeping. Fix: synchronous `Thread.sleep(forTimeInterval: 1.0)` — deliberate trade of "blocks the calling thread for 1 s during a one-time cancellation path" for "actually delivers the SIGTERM grace".

### New regression test

`testLargeStdoutDoesNotDeadlockOnPipeBufferLimit` uses a fake `git` script that emits ~256 KB of pipe-shaped output (4× the typical buffer) and asserts the result count is 4096 (not 0/truncated) and elapsed is < 4 s (deadlock would hit the 5 s timeout). Pins the concurrent-drain fix.

## Verification

| Step | Result |
|---|---|
| `swift test --filter GitCollectorTests` | **13/13 passed** in ~3.8 s |
| `swift test` (full HelperKit) | **145/145 passed** (132 from Phase 4D + 13 Slice 1, no regressions) |
| Subprocess timeout test | child process killed within 1.4 s (0.3 s timeout + 1 s SIGTERM grace), zero-result return matches Python contract |
| Large-stdout test | 256 KB drained in 0.62 s |
| HMAC parity test | 5/5 Python-computed reference values match Swift-computed values byte-for-byte |

## Out of scope / what's deferred to later slices

- **`CollectedSession` is minimal in Slice 1** (only `sessionId`, `provider`, `projectRoot`). Slice 2 (`SystemCollector`) will additively expand it with `pid`, `cpuPercent`, `etimeSeconds`, etc. The `Codable` synthesis tolerates additive fields under decode, so existing snapshot files written by older Python helpers parse cleanly during the upgrade transition.
- **Daemon wiring** (Slice 4) is what actually invokes `GitCollector` from the LaunchAgent run loop. Slice 1 ships the module + tests; the LaunchAgent still runs Python `helper/cli_pulse_helper.py` as the entry binary.
- **Python `helper/git_collector.py` retirement** is part of Slice 4 (atomic Python-test retirement). Slice 1 doesn't touch the Python file.

## Cross-team note

Slice 1 of Phase 4E (Mac helper Swift port). No cross-platform contract changes; Windows v0.7.0 unaffected.
