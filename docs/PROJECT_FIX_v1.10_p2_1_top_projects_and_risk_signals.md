# PROJECT_FIX v1.10 — P2-1 slices 3+4: TopProjectsList + RiskSignalsList

**Date**: 2026-04-21
**Scope**: Continues the iOS↔macOS Overview de-dup after pilot + slice 2.

---

## Why

`topProjects(_:)` and `riskSignals(_:)` were the next-biggest blocks of
cross-platform duplication in Overview. Extracting them continues the
sweep established by the earlier slices (`OverviewFormatters` and
`ActivityTimelineChart`).

## What shipped

### Slice 3 — `TopProjectsList`

- **New** `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/TopProjectsList.swift`
  - `public struct TopProjectsList: View` with `Style { nameFont, amountFont, emptyFont, rowSpacing }`
  - Presets `.macOS` and `.iOS` matching the pre-extraction magic numbers
  - Body: empty-state text when `projects.isEmpty`, else `ForEach` with `HStack` rows and a `Divider()` after every row except the last
- Both `topProjects(_:)` methods now 7-line delegations with platform-specific header + background wrappers preserved
- **New** `TopProjectsListTests.swift` — 5 passing:
  - macOS / iOS style preset checks
  - Divider-after-row rule (last row should NOT get a divider)
  - Single-item list gets no divider
  - Empty list contract

### Slice 4 — `RiskSignalsList`

- **New** `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/RiskSignalsList.swift`
  - `public struct RiskSignalsList: View` with `Style { iconFont, textFont, hSpacing }`
  - Presets `.macOS` and `.iOS`
  - Body: `ForEach` of warning triangle + signal text
- Both `riskSignals(_:)` methods now one-line delegations inside the existing `VStack` wrapper; outer `if !dash.risk_signals.isEmpty` guard preserved (no behavior change)
- No dedicated test file — body is branchless pure SwiftUI layout, same rationale as `ActivityTimelineChart`

## Cumulative line-count delta (all 4 P2-1 slices)

| file | original | now | Δ |
|---|---|---|---|
| `OverviewTab.swift` (macOS) | 675 | 569 | **-106** |
| `iOSOverviewTab.swift` (iOS) | 598 | 506 | **-92** |
| `OverviewFormatters.swift` | — | 71 | +71 |
| `ActivityTimelineChart.swift` | — | 100 | +100 |
| `TopProjectsList.swift` | — | 74 | +74 |
| `RiskSignalsList.swift` | — | 53 | +53 |

**~198 lines of cross-platform duplication eliminated** replaced with 298
lines of shared+tested code.

## Verification

- CLIPulseCore `swift test` → all tests green (existing ~220 + 18 new)
- `xcodebuild build` macOS scheme → BUILD SUCCEEDED
- `xcodebuild build` iOS scheme → BUILD SUCCEEDED

## Remaining P2-1 work

- `metricsGrid` — **requires unifying** `MetricCard` (macOS, uses
  `subtitle`) and `iOSMetricCard` (iOS, uses `badge`) APIs, or adding
  an adapter layer. Codex flagged this as "not a forced share" — could
  defer / defer partially (extract the metric-data model but keep two
  card types).
- `providerBreakdown` — small core (ForEach of UsageBars, 8 lines);
  cross-platform empty-state divergence (macOS shows "No enabled
  providers", iOS does not). Low-value extraction without first
  deciding the empty-state policy.

After Overview: Providers tab → Alerts → Sessions → Settings (last,
depends on P2-3 AppState split).

## Noted caveats (pre-existing, surfaced by Codex)

1. `RiskSignalsList` uses `id: \.self` on `[String]` — duplicate signal
   strings collide. Caveat existed before extraction; flagged for
   tracking, not blocking.
2. `TopProjectsList` assumes `TopProject.id` unique for both ForEach
   and divider-suppression. Consistent with current model.

## Files changed

```
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/TopProjectsList.swift          (new, 74)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/RiskSignalsList.swift          (new, 53)
CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/TopProjectsListTests.swift  (new, 5 tests)
CLI Pulse Bar/CLI Pulse Bar/OverviewTab.swift                                  (topProjects + riskSignals delegation, -45 lines)
CLI Pulse Bar/CLI Pulse Bar iOS/iOSOverviewTab.swift                           (same, -50 lines)
docs/PROJECT_FIX_v1.10_p2_1_top_projects_and_risk_signals.md                   (this doc)
```

## Review audit trail

- **Codex rescue** — **ship-with-notes, no must-fix**. Same pattern as
  earlier slices; inline `Divider()` correct (not a SwiftUI `List`);
  skipping `RiskSignalsList` tests symmetric with `ActivityTimelineChart`;
  `metricsGrid` warrants an adapter layer before any merge attempt.
