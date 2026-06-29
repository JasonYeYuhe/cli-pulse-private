# PROJECT FIX — ClaudePricingOpus47Tests: hermetic totalCost (sandbox the Codex sessions root)

**Date:** 2026-06-29
**Area:** CLIPulseCore tests (`ClaudePricingOpus47Tests`)
**Type:** test hermeticity (no production behavior change)

## Symptom
`ClaudePricingOpus47Tests` exercises `CostUsageScanner.scan()` and then asserts on
`result.totalCost(for: dayKey)`. The Claude roots were sandboxed (synthetic temp
projects), but the Codex sessions root was NOT overridden, so `scan()` — which
ALWAYS scans Codex alongside Claude — fell back to the developer's real
`~/.codex/sessions/`. `totalCost(for:)` sums cost across ALL providers, so any
real Codex usage dated `dayKey` (3 days ago) leaked into the asserted total.

Result: green in CI (runners have no Codex data) but flaky locally — failing with
e.g. `0.0885 → 4.15…` whenever the dev had real Codex sessions on that calendar
day. A classic non-hermetic test that passes only because of a missing fixture.

## Fix
Sandbox the Codex sessions root too: create an empty temp `codex-sessions/`
directory and pass it via `CostUsageScanner.Options(codexSessionsRoot:)`. The
scanner then sees a real, zero-file Codex root, so the total reflects only the
synthetic Claude usage under test. Mirrors the sibling
`CostUsageScannerSessionSynthTests` setup, which already does this.

Single-file change in
`CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/ClaudePricingOpus47Tests.swift`
(test-only; no source change).

## Verification
Full `swift test` (no `--filter`) on CLIPulseCore: **1826 tests, 0 failures, 4
skipped, exit 0**. The Claude-only assertions above the change are unaffected
(their roots were already sandboxed); the change only removes the real-Codex leak
into `totalCost`.
