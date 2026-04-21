# PROJECT_FIX v1.9.7 — P1-6: macOS characterization tests

**Date**: 2026-04-21
**Scope**: `CLIPulseCore` tests only. No runtime code change.

---

## Why

Plan P1-6 makes characterization tests a **hard prerequisite** for the
v1.10 P2 refactor of `AppState` / `DataRefreshManager`. Without a frozen
behavior net, a 1284-line refactor can silently change provider-card
output, alert filtering, or cost rollup without any CI catching it.

## What shipped

**New file**
`CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/DataRefreshManagerCharacterizationTests.swift`

**24 passing tests** (`#if os(macOS)`) pinning two `nonisolated static`
helpers that together drive every provider card:

### `DataRefreshManager.mergeCloudWithLocal` — 13 tests

Behaviors pinned:
- empty/empty; cloud-only pass-through; local-only promotion
- `.statusOnly` collector results ignored; `.credits` treated same as `.quota`
- overlap: local quota / remaining / tiers replace cloud
- overlap preserves cloud trend + recent_sessions (activity series)
- empty local `tiers` preserves cloud tiers (must NOT wipe)
- ancillary merge fields (`plan_type`, `reset_time`, `status_text`,
  `metadata`) — non-empty local wins, else cloud survives
- sort order: descending by `today_usage`
- `supplemented` set: all local providers minus `.statusOnly`
- local `today_usage > 0` wins; local `today_usage == 0` falls back to cloud
- local `week_usage > 0` wins; local `week_usage == 0` falls back to cloud

### `DataRefreshManager.applyCostScan` — 11 tests

Behaviors pinned:
- nil scan / empty entries → passthrough
- provider missing from scan → unchanged
- `max(scan, cloud)` cost semantics (never decreases)
- scan > cloud → merged and `cost_status_*` flips to `"Estimated"`
- non-quota provider → `today_usage` = Σ(input+output) from scan
- quota provider → `today_usage` (= % utilization) NOT overwritten
- rolling-week window: day -6 inclusive, day -7 excluded (off-by-one guard)
- yesterday's entries excluded from `todayCost`
- multiple rows per (provider, day) aggregate (guard against last-write-wins refactor)
- week-side cost + `cost_status_week` update via same rollup rule

## Coverage gaps documented (not in this PR)

Per Codex review (all acknowledged as follow-ups before any P2 refactor touches the covered surfaces):

1. **`AppState.buildProviderDetails`** — instance-bound on `@MainActor AppState`; needs either extraction to a pure helper or `@MainActor` test scaffolding. Codex called out this is the user-visible tier synthesis + source-label rules and must have a safety net before P2 touches it.
2. **Date-injection on `applyCostScan`** — the test uses live `Date()`/`Calendar.current` to derive `todayYMD()` / `ymd(daysAgo:)`; `applyCostScan` also reads `Date()` internally. Midnight rollover could flake. Fix requires adding a `now`-injectable overload (minor production-code tweak, deferred as separate PR).
3. **Tie-break ordering in the merged sort** — currently sort-by-`today_usage` has no secondary key. Either document the non-determinism or add a secondary key explicitly. No test in this PR pins either direction.

## Verification

```
$ swift test   # in CLI Pulse Bar/CLIPulseCore
Test Suite 'All tests' passed
$ xcodebuild build ... -scheme "CLI Pulse Bar"
** BUILD SUCCEEDED **
```

All 24 new tests + existing suite green.

## Files changed

```
CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/DataRefreshManagerCharacterizationTests.swift  (new, 24 tests)
docs/PROJECT_FIX_v1.9.7_p1_6_characterization_tests.md                                            (this doc)
```

## Review audit trail

- **Codex rescue, pass 1** — ship-with-notes. Flagged 5 concrete coverage
  gaps (zero-today fallback, empty local tiers, ancillary precedence, week
  rollup, multi-entry aggregation) plus tie-ordering observation and
  flakiness risk.
- **Actioned**: added 5 targeted tests (19 → 24). Remaining items
  documented above as follow-ups before P2 touches related code.
