# PROJECT_FIX v1.9.7 — P1-3: suppressedAlertIDs distantFuture TTL

**Date**: 2026-04-21
**Scope**: CLIPulseCore only. No UI changes.

---

## Why

`activeSuppressedAlertIDs` only pruned entries with `until <= now`. User
"dismiss forever" writes `Date.distantFuture`, so those IDs accumulated
in UserDefaults indefinitely.

## What shipped

### Data model + migration
- **`AppState.SuppressionEntry`** (new nested type): `{ until: Date; dismissedAt: Date; isPermanent: Bool }`
  - `isPermanent`: heuristic — `until.timeIntervalSince(dismissedAt) > 50 years` treats `.distantFuture` as "never reappear"
- **`AppState.permanentSuppressionRetentionDays = 180`** (public constant)
- **`AppState.prunedSuppressions(_:now:retentionDays:)`** (public nonisolated static) — pure logic that returns `(active, kept)`; testable without `@MainActor` instance
- UserDefaults:
  - v2 key: `cli_pulse_suppressed_alert_ids_v2`, value `[id: [until_ts, dismissedAt_ts]]`
  - v1 key kept for one-way migration; removed after first v2 save

### Behavior
- `suppressAlert(id:until:now:)` stamps `dismissedAt = now`
- `activeSuppressedAlertIDs(now:)` uses the shared pure logic:
  - time-boxed entry: keep if `until > now`
  - permanent entry: keep if `dismissedAt > now - 180d` (strict `>` → exact
    180d boundary prunes, matches "recycle at 180d" policy)
- `loadSuppressedAlertIDs()` prefers v2; v1 falls back with
  `dismissedAt = Date()` (biases toward a fresh 180d grace, no spurious
  resurrection)

### Tests
- **`SuppressionTests.swift`** (new, 10 tests):
  - `isPermanent` for distantFuture / 1-hour / 1-year snoozes
  - Time-boxed active/expired
  - Permanent within retention / past retention / exactly at boundary
  - Mixed batch
  - Empty input
- All pass; full `swift test` suite green; macOS build SUCCEEDED

## Policy notes (ship-with-notes from Codex)

1. **50-year heuristic** — robust today because only writers emit either
   distantFuture or minute-based snoozes. If future code creates a
   non-sentinel suppression > 50 years, rework to an explicit flag.
2. **v1 migration** stamps `dismissedAt = now` because we lack history.
   Worst case: someone who dismissed 179 days ago gets a full new 180d.
   Accepted.
3. **v1 key wipe on first v2 save** — intentional; prevents stale v1 data
   from resurrecting on downgrade+upgrade cycles. Downgrade would lose
   the record, which we accept.
4. **Exact-180d boundary prunes**. Off-by-one-day from "inclusive 180d" if
   that were the spec, but the spec is "recycle at 180d" and strict `>`
   matches.

## Files changed

```
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift             (nested type + constants + pure logic)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift   (suppressAlert + activeSuppressedAlertIDs + save/load)
CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/SuppressionTests.swift  (new, 10 tests)
docs/PROJECT_FIX_v1.9.7_p1_3_suppression_ttl.md                            (this doc)
```

## Review audit trail

- **Codex rescue** — **ship-with-notes**. Confirmed no data-loss or
  correctness bug; only policy-level caveats documented above.
