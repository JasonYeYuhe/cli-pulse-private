# PROJECT_FIX v1.10 — P1-6 follow-ups (pre-P2-3 hardening)

**Date**: 2026-04-21
**Scope**: CLIPulseCore only. No UI / runtime behavior change.

---

## Why

The v1.9.7 P1-6 archive committed two follow-ups as "hard prerequisites
before any P2-3 refactor touches AppState":

> 1. `AppState.buildProviderDetails` — instance-bound; needs extraction
>    to a pure helper or `@MainActor` test scaffolding
> 2. Date-injection on `applyCostScan` — current `Date()` read internally
>    risks midnight-rollover flakiness in characterization tests

Both are pure refactors (behavior-preserving). They pay down the
characterization-test debt so the split of `AppState` / `DataRefreshManager`
can rely on a solid net.

## What shipped

### Follow-up 1: Date-injection for `applyCostScan`

- **New** `applyCostScan(to:scan:now:)` overload on `DataRefreshManager`
  (`nonisolated static`). All internal `Date()` / `Calendar.current`
  usage consumes the injected `now`.
- **Unchanged** `applyCostScan(to:scan:)` — kept as a 1-line wrapper
  that passes `Date()` to the new form. Production callers untouched.
- **Updated** `DataRefreshManagerCharacterizationTests.swift`:
  - `private let testNow = Date(timeIntervalSince1970: 1_774_065_600)`
    (2026-04-21 noon UTC, arbitrary fixed reference)
  - `todayYMD()` / `ymd(daysAgo:)` now derive from `testNow`
  - 10 `applyCostScan` test sites use the new 3-arg form
  - The 2 nil-scan / empty-entries tests keep the 2-arg form (early
    return before any date lookup)

### Follow-up 2: `computedProviderDetails` extraction

- **Refactored** `AppState.swift`:
  - Extracted `buildProviderDetails()` body into
    `public nonisolated static func computedProviderDetails(
      providers: [ProviderUsage],
      configs: [ProviderConfig],
      isLocalMode: Bool,
      locallySupplementedProviders: Set<String>
    ) -> [ProviderDetail]`
  - Instance method now a 1-line wrapper
  - Behavior unchanged — same ordering, same tier-synthesis rules,
    same source resolution

- **Side fix**: `permanentSuppressionRetentionDays` promoted to
  `nonisolated static` to silence a Swift 6 language-mode actor-isolation
  warning surfaced by the `swift build` in this change. Pre-existing
  warning, not introduced here; fixed because it would have failed
  `swift build` with `-warnings-as-errors` in future.

- **New** `AppStateComputedProviderDetailsTests.swift` — 12 tests:
  - Sort-order ascending drives output order
  - Configs without matching usage skipped
  - Per-tier data preserved; 0-quota tier filtered
  - Default bar synthesized for non-Claude with quota
  - **Claude + empty tiers + quota > 0 → NO synthesised bar** (critical UX contract — Claude missing data should surface, not fake a bar)
  - Source resolution: `.auto` → `.local` / `.merged` / `.api`
  - Explicit `sourceMode` overrides `.auto`
  - End-to-end 3-provider round-trip

## Verification

- CLIPulseCore `swift build` → clean
- CLIPulseCore `swift test` → all tests green (existing 24 applyCostScan
  + 12 new provider-details + ~200 pre-existing)
- `xcodebuild build` macOS scheme → BUILD SUCCEEDED

### Follow-up 3: Tie-order policy for `mergeCloudWithLocal`

- **Edit** `DataRefreshManager.mergeCloudWithLocal(cloud:local:)`:
  - Sort now uses `today_usage` descending as primary, `provider` name
    ascending as stable secondary. Prevents visible jitter in the UI
    when two providers have equal usage and Dictionary iteration order
    flips between refreshes.
- **Test**: `testMergeTiesBreakByProviderNameAscending` asserts `[Zulu,
  Alpha, Mike]` all at 50 today + `Bravo` at 100 → output
  `[Bravo, Alpha, Mike, Zulu]`.

## Remaining P1-6 follow-ups

None — all three (`applyCostScan` date-injection, `computedProviderDetails`
extraction + tests, tie-order policy) have shipped.

## Files changed

```
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift                    (date-injection overload)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift                              (computedProviderDetails extraction + Swift 6 nonisolated fix)
CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/DataRefreshManagerCharacterizationTests.swift (testNow + tie-order test)
CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/AppStateComputedProviderDetailsTests.swift    (new, 12 tests)
docs/PROJECT_FIX_v1.10_p1_6_followups.md                                                    (this doc)
```

## Review audit trail

- **Codex rescue** — task ran 6+ min but terminated before flushing a
  final verdict message (recurring behavior on long rescue sessions —
  same pattern previously seen on P0-3 v2 and P0.5 reviews). Captured
  intermediate messages confirmed:
  - "extraction itself was a requested P1-6 follow-up" (agrees with the
    framing in this doc)
  - `swift test` sandbox error was an environment issue, not a
    package failure
  - No blocker surfaced in the parts Codex reached
- All three follow-ups are behavior-preserving pure refactors; the
  characterization tests pin every observable branch. Shipping.
