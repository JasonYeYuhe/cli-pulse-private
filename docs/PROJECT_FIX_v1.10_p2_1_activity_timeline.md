# PROJECT_FIX v1.10 — P2-1 slice 2: ActivityTimelineChart extraction

**Date**: 2026-04-21
**Scope**: Continues the iOS↔macOS Overview tab de-dup from the P2-1 pilot.

---

## Why

The activity-timeline bar chart was the single largest duplicated block
in `OverviewTab` / `iOSOverviewTab` — ~40 lines of GeometryReader + bar
math + hour-label HStack, copied with slight styling tweaks. Extracting
it eliminates the highest-value piece of duplication after the formatter
helpers in the pilot.

## What shipped

### Shared view
- **New** `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/ActivityTimelineChart.swift`
  - `public struct ActivityTimelineChart: View` with inner `Style` struct
    (barSpacing, barCornerRadius, minBarHeight, chartHeight, labelFont)
  - Preset styles `.macOS` (1/1/1/40/.system(size:7)) and `.iOS` (2/2/2/60/.caption2)
  - Body: GeometryReader bars + hour-label HStack, delegating label
    formatting to `OverviewFormatters.hourLabel`

### Call sites rewired
- **Edited** `OverviewTab.swift` — `activityTimeline(_:)` reduced from
  ~40 lines of inline layout to:
  ```swift
  VStack(alignment: .leading, spacing: 6) {
      SectionHeader(title: L10n.dashboard.activity, icon: "chart.bar.fill")
      ActivityTimelineChart(trend: trend, style: .macOS)
  }
  .padding(10).background(...).clipShape(...)
  ```
  Outer wrapper kept per-platform — headers use `SectionHeader`, background
  is `.cardBackground.opacity(0.3)`, corner radius 8

- **Edited** `iOSOverviewTab.swift` — same pattern. Outer wrapper has an
  inline icon+text header, full-opacity `.cardBackground`, corner radius 12,
  `.padding(.horizontal)` chrome. Those differences are intentional, not
  duplication.

### Tests
- **New** `ActivityTimelineChartTests.swift` — 5 passing:
  - macOS / iOS style presets match the pre-extraction magic numbers
  - Label indexing for count 2 / 3 / 4 — regression guards for the
    "show first + maybe middle + last" rule using `trend[count/2]`

## Line count delta (cumulative across pilot + slice 2)

| file | before pilot | after slice 2 | Δ |
|---|---|---|---|
| OverviewTab.swift (macOS) | 675 | 598 | **-77** |
| iOSOverviewTab.swift (iOS) | 598 | 533 | **-65** |
| OverviewFormatters.swift (new, shared) | — | 71 | +71 |
| ActivityTimelineChart.swift (new, shared) | — | 100 | +100 |

Net shared/public surface: +171 lines.
**Duplication eliminated: ~142 cross-platform lines.**

## Verification

- CLIPulseCore `swift test` → all green (existing 200+ tests + 8 formatter
  tests + 5 new chart tests)
- `xcodebuild build` CLI Pulse Bar scheme → BUILD SUCCEEDED
- `xcodebuild build` CLI Pulse iOS scheme → BUILD SUCCEEDED

## Remaining P2-1 work

Per plan order:
- `providerBreakdown` — both files ~30 lines each, identical business logic (%, cost), different layout styling
- `metricsGrid` — 4 metric cards, platform-specific layout
- `topProjects` — 40+ lines, similar to providerBreakdown
- `riskSignals` — 20+ lines on both sides

After Overview is done: Providers → Alerts → Sessions → Settings (depends on P2-3 AppState split).

## Deferred as `P2-1` non-blockers (Codex notes)

1. **Bar overflow risk** at very high `trend.count` relative to available
   width — not a practical problem today since trends are capped at ~12
   cells, but a latent scalability limit if we ever expand the series.
2. **Public API surface**: `ActivityTimelineChart` + `Style` are `public`
   from CLIPulseCore. Intentional — shared surface. Revisit access level
   if we later decide the chart shouldn't be reusable package API.

## Files changed

```
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/ActivityTimelineChart.swift           (new)
CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/ActivityTimelineChartTests.swift   (new, 5 tests)
CLI Pulse Bar/CLI Pulse Bar/OverviewTab.swift                                         (delegation, -35 lines)
CLI Pulse Bar/CLI Pulse Bar iOS/iOSOverviewTab.swift                                  (delegation, -40 lines)
docs/PROJECT_FIX_v1.10_p2_1_activity_timeline.md                                      (this doc)
```

## Review audit trail

- **Codex rescue** — **ship-with-notes**. Style-struct + platform preset is
  the right shape; keeping outer wrapper per-platform is the correct
  boundary; no dedicated UI tests needed because label logic delegates to
  already-tested `OverviewFormatters.hourLabel`. Actioned: added the
  5 regression-guard tests for label indexing + style presets.
