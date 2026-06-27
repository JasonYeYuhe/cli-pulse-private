# PROJECT FIX — Collector concurrency cap + serialized error-log writes (P2)

**Date:** 2026-06-27
**Train:** Backend trust hardening — **PR6 (P2)**
**Branch:** `hardening/collector-concurrency`
**Plan:** `DEV_PLAN_2026-06-27_nextphase_trust_hardening.md` §2 PR6

---

## Summary

Bounded the per-refresh collector fan-out to a small in-flight window and
serialized the collector error-log appends through an actor, removing the
every-120s thundering herd of ~48 concurrent collectors and fixing the concurrent
`FileHandle` append race that corrupted the log exactly when many collectors
failed at once.

## Root cause

`DataRefreshManager.runCollectors` (`DataRefreshManager.swift:645`) spawned an
**unbounded** `withTaskGroup` task per enabled provider — ~48 collectors firing
at once on every 120s tick, plus every helper-sync notification and every manual
refresh. Each failing collector's `catch` opened the same temp log with
`FileHandle(forWritingAtPath:)` → `seekToEndOfFile()` → `write()` from its own
task with **no serialization**, so simultaneous failures interleaved and
truncated log lines.

## What changed

- **NEW** `CollectorConcurrency.swift`:
  - `maxConcurrentCollectors = 8` (tunable).
  - `mapWithConcurrencyLimit(_:maxConcurrent:_:)` — a generic bounded fan-out
    that keeps at most N tasks in flight (a new task starts only as one
    finishes), returning the non-nil outputs. Extracted so the bound is
    unit-testable.
  - `CollectorErrorLog` actor — funnels every append through one actor so each
    line is atomic w.r.t. the others. Path-injectable (`init(url:)`) for tests;
    `.shared` keeps the previous temp-dir path.
- **`DataRefreshManager.runCollectors`** — now filters to enabled+registered
  collectors and runs them via `mapWithConcurrencyLimit(..., maxConcurrent:
  maxConcurrentCollectors)`. The per-collector body moved to a `nonisolated
  static runOneCollector(config:)` whose failure path `await`s
  `CollectorErrorLog.shared.append(...)`. Refresh semantics (results dedup,
  cost-scan merge downstream) are unchanged — only the scheduling/log-write
  mechanics changed.

## Tests (CLIPulseCore, unit — `CollectorConcurrencyTests`)

- `never_exceeds_limit` — 40 items @ limit 4: peak in-flight ≤ 4 and > 1 (real
  concurrency).
- `limit_one_is_serial` — @ limit 1 the peak is exactly 1 (strict boundary proof).
- `drops_nil_and_handles_empty`.
- `serializes_concurrent_appends` — 200 concurrent `CollectorErrorLog.append`s
  to a temp file → exactly 200 intact, uniquely-parseable lines (no
  interleave/truncation). This **fails** against the old direct-`FileHandle`
  path.

## Verification checklist

- [x] `swift build` clean.
- [x] New `CollectorConcurrencyTests` (4) pass.
- [ ] Full `swift test` (no `--filter`) green — see PR CI.
- [ ] (manual/observational) refresh wall-time before/after — bounded fan-out
      trades a small amount of peak parallelism for far less subprocess/CPU
      contention; expected neutral-to-better under load. Not gating.

## Notes

- 8 is a starting value; if a future profiling pass shows refresh latency
  regressed on fast networks, bump `maxConcurrentCollectors`.
- Reuses the existing `nonisolated static` helper pattern already in
  `DataRefreshManager` (e.g. `mergeCloudWithLocal`, `dedupedByProvider`).
