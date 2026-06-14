# PROJECT FIX — watchOS App Visual Redesign (2026-06-15)

Full visual redesign of the in-app watchOS views: a glance-first
"vital-signs monitor" for AI spend & quota. **Pure presentation layer** —
zero changes to `WatchAppState` / `APIClient` / `WCSession`. Target
watchOS 10.0. Shipped as 7 gate-green PRs (P0→P6) to `cli-pulse-private`.

Plan: `~/.claude/plans/watch-redesign-dev-plan.md` (reviewed by Gemini 3.1
Pro + Codex; binding fixes R1–R6). Mockup: `~/.claude/plans/watch-redesign-mockup.html`.

## What shipped (PRs, all merged to main)

| Phase | PR | Content |
|---|---|---|
| P0 | #160 | Foundation: vertical-page `TabView` shell (Digital-Crown pager) + `WatchRingMath` (CLIPulseCore, pure + tests) + `WatchTheme` tokens |
| P1 | #161 | Pulse home: `PulseWaveform` (animated ECG), `BigMetric` (ViewThatFits hero), `StatChip`; retired `WatchOverviewView` (folded in); `WatchPulseFormat` |
| P2 | #162 | Quota rings: `ProviderRingCluster` (concentric) + legend + relocated/restyled `WatchProviderDetailView`; retired `WatchProvidersView` |
| P3 | #163 | Live sessions: running `SessionCard`s + `ActivitySpark` + pulsing `LiveDot`; dimmed non-running |
| P4 | #164 | Alerts: severity-sorted `AlertCard`s + critical tint/pulse; `WatchAlertSort` (pure + tests); haptic/actions preserved |
| P5 | #165 | Login logo refresh; `.privacySensitive()` hero (Always-On); VoiceOver `combine` on cards; **L10n finalized across 6 locales** (es/ko `watch.*` backfill) |
| P6 | (this) | Rewrote `generate_watch_screenshots.swift` for the new 4-page design @ 422×514; regenerated `screenshots/watch/`; complication circular-gauge provider-colour tint; final multi-agent audit + cleanups |

## Navigation
Root is now `TabView(selection:).tabViewStyle(.verticalPage)` with four
glance pages — **Pulse / Quota / Live / Alerts** — each its own
`NavigationStack`, with `.containerBackground(WatchTheme.canvas, for: .tabView)`
for the full-bleed true-black look. The old root List-of-NavigationLinks
menu is gone; the standalone Overview + Providers-list views are retired.

## Hard invariants honored (review R1–R6)
- **R1** — every top-level page owns exactly one `ScrollView`/`List`; no
  fixed page height (Crown scrolls content, paginates at the edge).
- **R2** — Pulse hero uses `ViewThatFits` (full → abbreviated → smaller),
  `minimumScaleFactor` only as a last-resort rung.
- **R3** — `PulseWaveform` + `LiveDot` animate ONLY when
  `scenePhase == .active && !reduceMotion && !isLuminanceReduced`; otherwise
  a static representative path / no `TimelineView` (waveform) and a still
  dot via system `symbolEffect(.pulse, isActive:)` (battery-managed).
- **R4** — rings, legend, and the watch-face complication all read
  `ProviderUsage.usagePercent`; `WatchRingMath` only wraps the window /
  remaining helpers — no re-derived percentage.
- **R5** — dual data-flow untouched: `refreshAll()` (live RPC) +
  `applyFallbackData(preferLive:)` (WCSession merge) both survive; views
  read `state.*` only.
- **R6** — preserved product traps: quota-window math (`quota − remaining`),
  silent-401 → `lastError`, demo mode, `showCost`, **critical-alert haptic**
  (`WKInterfaceDevice.play(.failure)`), and every loading/error/empty/
  all-clear state.

## Testable logic in CLIPulseCore (app target is CI-only)
`WatchRingMath` (22 tests), `WatchPulseFormat` (11), `WatchAlertSort` (5) —
pure, `swift test`-able locally so regressions surface before the slow
watch CI build. App-target SwiftUI stays thin.

## Localization
All new strings via `L10n` across 6 locales (en/es/ja/ko/zh-Hans/zh-Hant).
Parity verified: all 19 `watch.*` keys referenced by `L10n.swift` resolve
in every locale. Fixed a **pre-existing** gap: es/ko were missing the
entire `watch.*` namespace (fell back to en) — backfilled in P5; the
Quota VoiceOver key `widget.percent_left` backfilled to es/ko in P6.

## Bugs caught pre-merge (couldn't be found locally — watch is CI-only)
- **`heroFont(size:)`** missing argument label — failed the first P1 CI run
  (the watch + iOS-embed builds); fixed by labelling the call sites.
- **arm64_32 overflow** — the `ActivitySpark` hash multiplier exceeded
  `Int32.max`; watch is a 32-bit-`Int` target, so the literal would
  overflow at compile time (passes on 64-bit iOS, invisible locally).
  Caught in self-review; clamped under `Int32.max`.
- **`WatchCard` `@ViewBuilder` init** — synthesized memberwise init won't
  accept a trailing closure; added an explicit `init`.
- **Waveform per-frame allocation** (Codex) — hoisted the ECG `Path` build
  out of the `TimelineView` closure via `GeometryReader`.
- **Ring centre overflow** (Codex) — constrained the centre label to the
  inner opening so long/localized provider names don't spill onto the rings.

## Review process
Each phase: local `swift test` → Gemini 3.1 Pro review of the diff (watchOS
API correctness, since CI is the only compiler) → CI full matrix (incl.
`Build CLI Pulse Watch`) verified via `gh run view --json` (never `gh run
watch` exit code) → merge. Codex dual-review on the highest-risk chunks
(P1 waveform, P2 rings); Codex runs erroring intermittently (known) were
covered by Gemini + CI. Final P6 step: a 6-agent **review→adversarially-
verify** workflow over the whole merged redesign — **0 confirmed-real
issues**; 1 finding refuted (es/ko `widget.percent_left` falls back to en
at runtime, since the watch never sets a locale override) and addressed
anyway; 5 NITs fixed (dead `WatchTheme` tokens wired/removed, stale doc
comment, `AlertSeverity` enum instead of the `"Critical"` magic string).

## Screenshots (P6)
`generate_watch_screenshots.swift` rewritten as a standalone AppKit mock
of the four new pages at **422×514** (Apple Watch Ultra App Store size —
the old script hardcoded 368×448, which no longer matched the committed
assets). Regenerated `screenshots/watch/{01_pulse,02_quota,03_live,04_alerts}.png`;
removed the stale old-design `01_home`/`02_overview`/`03_sessions`/
`05_providers` + `composed/`.

## Device-verification debt (CANNOT be CI-tested — needs a real Watch/Sim)
Ship default-safe; flagged for device QA:
- Waveform animation feel + dash-flow; reduce-motion static fallback;
  Always-On dimming/redaction; Crown scroll-vs-paginate gesture.
- Pulsing `LiveDot` cadence; critical-alert haptic firing.
- Ring legibility + tap targets at 41/45/49 mm; Dynamic Type at the largest
  accessibility sizes (the glance uses some fixed font sizes by design).
- VoiceOver reading order on each page.

## Out of scope (unchanged)
Backend/RPCs, data model, auth/WCSession, iOS/macOS/Android, complication
*structure* (only a colour-tint polish), any metric not already in the
models. Pre-existing orphan `L10n.watch.unreadCount` left as-is (predates
the redesign).
