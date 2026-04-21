# PROJECT_FIX v1.10 — P2-1 pilot: OverviewFormatters extraction

**Date**: 2026-04-21
**Scope**: Smallest verifiable slice of the iOS↔macOS Overview tab de-dup.

---

## Why

Plan P2-1 targets ~1270 lines of duplicated display logic between
`OverviewTab.swift` (macOS, 675 lines) and `iOSOverviewTab.swift`
(iOS, 598 lines). Landing the whole thing in one PR would have a
huge blast radius. This pilot ships the smallest extraction — the
two pure formatter helpers — to prove the pattern and fix iOS's
per-call allocator waste, without touching any view body.

Plan order: Overview → Providers → Alerts → Sessions → Settings.
Within Overview: formatters pilot → `activityTimeline` → `providerBreakdown` → `metricsGrid` → `topProjects` → `riskSignals`.

## What shipped

### Extraction
- **New** `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/OverviewFormatters.swift`
  - `OverviewFormatters.utilizationColor(_: Double) -> Color`
    - Thresholds: ≥200 → purple, ≥100 → blue, ≥50 → green, else gray
  - `OverviewFormatters.hourLabel(_: String) -> String`
    - Parses ISO-8601 (fractional + basic); falls back to substring + "h";
      else returns raw input
  - Three cached `nonisolated(unsafe) static let` formatters with an
    explicit immutability comment (per Codex recommendation) — never
    mutate post-init

### Call sites rewired
- **Edited** `OverviewTab.swift` — `utilizationColor` + `hourLabel` now
  1-line wrappers; removed ~43 lines of in-place formatter+logic
- **Edited** `iOSOverviewTab.swift` — `iOSUtilizationColor` + `hourLabel`
  same delegation; removed ~27 lines. **Side effect**: iOS was allocating
  a fresh `ISO8601DateFormatter` + `DateFormatter` per timeline cell
  (12+ per render) — now shares macOS's cached formatters

### Tests
- **New** `OverviewFormattersTests.swift` — 8 passing:
  - Threshold boundaries 0/49/50/99/100/199/200/500 + negative
  - ISO fractional parsed → am/pm lowercase shape
  - ISO non-fractional parsed → same
  - Fractional vs non-fractional → identical label
  - ≥13-char unparseable → chars[11..13] + "h"
  - <13-char → raw input returned
  - 100-call idempotency (cached-formatter correctness guard)
  - Tests are timezone-agnostic — `DateFormatter` uses local TZ (pre-existing behavior preserved, documented, not changed)

### Verification
- `swift test` on CLIPulseCore → All tests green
- `xcodebuild build` macOS scheme → BUILD SUCCEEDED
- `xcodebuild build` iOS scheme → BUILD SUCCEEDED

## Deferred to subsequent P2-1 PRs

- ~~`activityTimeline` — shared SwiftUI view with timeline rendering~~ **shipped in slice 2**
- `providerBreakdown` / `metricsGrid` / `topProjects` / `riskSignals`
- Eventually: remove tab-local wrappers once no call sites reference
  them (Codex suggestion, tracks once all extraction is done)
- Timezone policy — pilot keeps local-TZ; consider pinning to UTC
  in a dedicated policy PR with real screenshots on a non-UTC device

## Files changed

```
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/OverviewFormatters.swift                      (new)
CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/OverviewFormattersTests.swift              (new, 8 tests)
CLI Pulse Bar/CLI Pulse Bar/OverviewTab.swift                                                 (delegation, -43 lines)
CLI Pulse Bar/CLI Pulse Bar iOS/iOSOverviewTab.swift                                          (delegation, -27 lines)
docs/PROJECT_FIX_v1.10_p2_1_overview_formatters_pilot.md                                      (this doc)
```

## Review audit trail

- **Codex rescue** — **ship-with-notes**. Wrappers are the right pilot
  shape; `nonisolated(unsafe)` is safe in this narrow form; TZ
  behavior correctly preserved. Actioned: immutability comment added
  next to the cached formatters.
