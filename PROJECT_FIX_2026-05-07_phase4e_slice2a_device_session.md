# PROJECT_FIX — Phase 4E Slice 2a — DeviceSnapshotCollector + SessionDetector

**Date:** 2026-05-07
**Branch:** `phase4e-slice2a-harness-device-session` (cut from `main` after PR #25 merge)
**Plan:** [docs/PHASE_4E_DEV_PLAN.md](docs/PHASE_4E_DEV_PLAN.md) — Slice 2a of 4 sub-slices
**Source:** First sub-slice of Phase 4E Slice 2 (per Codex cross-team suggestion accepted in PR #25 amendment).

## What ships

Sub-slice 2a of the Phase 4E Mac helper Swift port. Foundation pieces of the SystemCollector, plus the shared subprocess runner used by 2a and reused by 2c.

| File | Change |
|---|---|
| [HelperSwift/Sources/HelperKit/SharedModels.swift](HelperSwift/Sources/HelperKit/SharedModels.swift) | EXTENDED. `CollectedSession` gains 13 Slice 2-specific fields (name, project, status, total_usage, requests, error_count, started_at, last_active_at, exact_cost, cpu_usage, command, collection_confidence, project_hash). All Optional with defaults so the Slice 1 minimal init still works. Added `DeviceSnapshot` struct. Snake_case `CodingKeys` on every field. |
| [HelperSwift/Sources/HelperKit/SystemCollection/DeviceSnapshotCollector.swift](HelperSwift/Sources/HelperKit/SystemCollection/DeviceSnapshotCollector.swift) | NEW. `collect() async -> DeviceSnapshot` reads 1-min load average + spawns `vm_stat`, computes int-percent CPU + memory clamped to 0…100. Pure parsing helpers (`cpuPercent`, `memoryPercent`, `parseVmStat`) exposed as `static` for unit tests. |
| [HelperSwift/Sources/HelperKit/SystemCollection/SessionDetector.swift](HelperSwift/Sources/HelperKit/SystemCollection/SessionDetector.swift) | NEW. `collect() async -> [CollectedSession]` runs `ps -axo pid=,pcpu=,pmem=,etime=,command=`, classifies each row by provider via 27 pattern rules mirroring `system_collector.py::PROCESS_PATTERNS`, dedupes by `(provider, project)` with confidence-rank tiebreak, sorts by CPU desc + last-active desc, caps at top 12. |
| [HelperSwift/Sources/HelperKit/SystemCollection/SubprocessRunner.swift](HelperSwift/Sources/HelperKit/SystemCollection/SubprocessRunner.swift) | NEW. Shared async subprocess utility — concurrent stdout drain (avoids 64 KB pipe-buffer deadlock), `withTaskCancellationHandler` for cooperative cancellation, SIGTERM grace + SIGKILL on timeout/cancel. Used by both DeviceSnapshotCollector (vm_stat) and SessionDetector (ps); will be reused by Slice 2c (Chromium cookie reader's SQLite-CLI invocations if needed). |
| [HelperSwift/Tests/HelperKitTests/DeviceSnapshotCollectorTests.swift](HelperSwift/Tests/HelperKitTests/DeviceSnapshotCollectorTests.swift) | NEW. 9 tests — CPU clamp, vm_stat parser, end-to-end collect, snake_case wire-shape parity. |
| [HelperSwift/Tests/HelperKitTests/SessionDetectorTests.swift](HelperSwift/Tests/HelperKitTests/SessionDetectorTests.swift) | NEW. 24 tests — etime parsing (4 forms), provider detection (claude+codex+gemini+cursor + non-AI + arg-flag boundary), ignored-command filter, prettyName, splitFirstFour parser, end-to-end collect (filter, dedup, sort, top-12 cap, full field shape, nil-output guard), CollectedSession snake_case wire-shape parity. |

## Per-fix notes

### Initial implementation

Followed Slice 2a spec: foundation modules + shared subprocess runner. Provider patterns and ignored-command patterns ported verbatim from Python (27 + 14 entries respectively). The "cut at first arg-flag" provider detection logic carries the same rationale as Python — Claude Code 2.x lives at `/Users/.../Library/Application Support/Claude/claude-code/<v>/...` (two embedded spaces in the path), and a naive whitespace-split would break detection there.

### Gemini diff review — 3 P0/P1 catches applied

A Gemini 3.1 Pro pass over the initial diff caught three issues:

**(P0) Thread starvation via `semaphore.wait()` inside an async caller.** First draft of `SessionDetector.livePsOutput` blocked the calling thread on a semaphore while a child `Task` drained stdout. If called from the daemon's `withTaskGroup`, the cooperative-pool thread blocks waiting for the drain task that itself needs a thread to run on — classic deadlock under load. Fix: hooks are now `@Sendable () async -> String?`. The live path uses `try await Task.sleep` in a polling loop and `await drainTask.value` for the drain — no semaphore.

**(P0) Cancellation bypassed via `Thread.sleep` polling.** First draft's `livePsOutput` and `liveVmStatOutput` polled `process.isRunning` via synchronous `Thread.sleep`. An outer task cancellation would be ignored — the thread would keep spinning until the hard timeout. Fix: poll loop now uses `try await Task.sleep`, wrapped in `withTaskCancellationHandler` so an outer cancel reaps the child cleanly. The `Thread.sleep(forTimeInterval: 1.0)` call survives ONLY in the `onCancel` reap path — same trade Slice 1's GitCollector made and same Gemini-validated pattern.

**(P1) Pipe-buffer deadlock not addressed in `liveVmStatOutput`.** First draft drained vm_stat's stdout AFTER the wait loop. If vm_stat ever produces >64 KB output (unlikely but unbounded as macOS evolves), the child blocks on `write()` and the parent never sees the EOF. Fix: shared `SubprocessRunner` utility wraps both `vm_stat` and `ps` in a concurrent-drain pattern; vm_stat path now goes through it.

The shared `SubprocessRunner` extracted from these fixes will be reused by Slice 2c's Chromium-related subprocesses, by Slice 3's `claude` PTY spawning if cloud-routed, and ideally by GitCollector (Slice 1) on a future cleanup pass.

## Verification

| Step | Result |
|---|---|
| `swift test --filter DeviceSnapshotCollectorTests` | **9/9 passed** |
| `swift test --filter SessionDetectorTests` | **24/24 passed** (after one fixture fix where path-scan project-name fallback was returning `"bin"` for all `/tmp/projN/bin/claude` cmds — changed to `/usr/local/bin/claude --cwd /Users/dev/projN`) |
| `swift test` (full HelperKit) | **178/178 passed** (was 145, +33 new) |

## Out of scope / what 2b–2d ship next

- **2b** — AlertGenerator (CPU spike + session-too-long thresholds, with the threshold-flapping pattern from `feedback_gemini_review_patterns.md`) + OAuthBackoff actor (per Gemini Phase 4E plan v2 P1: actor-isolated single-writer, NOT preserving Python's racy semantics) + KeychainReader (5 s watchdog timeout per Gemini v2 P1 — Chromium Safe Storage prompt blocks indefinitely).
- **2c** — ChromiumCookieReader (PBKDF2 + AES-CBC + SQLite read of Cookies db) + Claude/Codex/Gemini quota fetchers with `QuotaProvenance` enum surfacing (per Gemini v2 P0).
- **2d** — Snapshot writers (deep-equality JSON parity per Gemini v2 P1) + SystemCollector façade wired via `withTaskGroup` + 3 snapshot parity tests.

Each sub-slice continues to get its own Gemini diff review pre-commit.

## Cross-team note

Sub-slice 2a of Phase 4E Slice 2. No cross-platform contract changes; Windows v0.7.0 unaffected.
