# PROJECT FIX: v1.9.3 — App Store regressions (Claude tiers, toggle lag, alerts, costs)

**Date:** 2026-04-19
**Platform:** macOS (CLI Pulse Bar menu-bar app), shared core also benefits iOS / watchOS clients
**Severity:** High — four user-visible regressions in shipped App Store v1.9.2
**Reporter:** Jason (manual QA on v1.9.2 from the App Store)
**Status:** **IMPLEMENTED** — both `CLIPulseCore` swift build and macOS / iOS xcodebuild succeed.

---

## Summary

User QA on the shipped App Store build of v1.9.2 surfaced four regressions:

1. Claude card showed a single `Default 100% left` bar instead of three (`5h Window`, `Weekly`, `Sonnet only`).
2. Provider toggle in `ProvidersTab` did not flip visually until the manual refresh button was tapped.
3. Alerts effectively never fired — only CPU/long-session rules existed; no quota-depletion alerts.
4. Per-provider token / cost numbers were stuck at `0 · <$0.01` even after real usage; the JSONL `CostUsageScanner` existed but was never bridged into `ProviderUsage`.

This fix lands all four behind v1.9.3.

---

## Root causes (verified)

### Bug 1 — Claude tier collapse

Three separate layers conspired:

1. `ClaudeResultBuilder.build` ([ClaudeSourceStrategy.swift](../CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors/Claude/ClaudeSourceStrategy.swift)) hardcoded `quota: 100, remaining: overallRemaining ?? 100` even when the snapshot had **all three** of `sessionUsed` / `weeklyUsed` / `sonnetUsed` nil — i.e. when no strategy had captured any usage.
2. `mergeCloudWithLocal` ([DataRefreshManager.swift](../CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift)) preserved the local "100/100, tiers=[]" over the cloud value because the local quota was non-nil.
3. `AppState.buildProviderDetails` ([AppState.swift](../CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift)) saw `tiers=[]` plus `quota=100, remaining=100` and synthesised a misleading `Default 100% left` bar.

### Bug 2 — Toggle lag

`AppState.toggleProvider` mutated `providerConfigs[idx].isEnabled` and saved, but never called `buildProviderDetails()`. The `ProviderDetail` snapshot consumed by `EnhancedProviderCard` was a struct-by-value capture, so the SwiftUI Toggle's `isOn` getter kept reading the stale `config.isEnabled` until the next data-refresh cycle rebuilt `providerDetails`.

### Bug 3 — Alerts not firing

`AlertGenerator` only generated CPU-spike, session-spike, long-session, and budget alerts. There was **no quota-depletion path**, so a Claude weekly tier at 95% triggered nothing. Combined with Bug 4, budget alerts were dead because their inputs were always zero.

### Bug 4 — Token / cost stuck at 0

`ClaudeSourceStrategy.swift` (and similarly Codex / Cursor / OpenRouter collectors) hardcoded:

```swift
estimated_cost_today: 0, estimated_cost_week: 0,
cost_status_today: "Unavailable", cost_status_week: "Unavailable",
```

`CostUsageScanner` *did* scan local Claude / Codex JSONL session files into `CostUsageScanResult` (per-day, per-provider, per-model token counts and prices), but `DataRefreshManager` only used the result for `updateCostSummary` (overall dashboard totals). It never projected the per-provider rollup back into the `ProviderUsage.estimated_cost_*` fields, so individual cards were always zero. The reference mechanism the user wanted (codexbar) is exactly this JSONL-scan rollup.

---

## Fixes

### Bug 1 (3 files)

- **`ClaudeSourceStrategy.swift`**
  - Added `ClaudeSnapshot.hasAnyUsage` convenience.
  - In `ClaudeResultBuilder.build`, when `hasAnyUsage == false`, emit `quota: nil, remaining: nil` and a `status_text: "Quota data unavailable"`. This stops the collector from claiming a fake 100/100.
  - Added a `#if DEBUG` warning log when the unavailable path is taken so future regressions surface in `clipulse_claude_resolver.log`.

- **`AppState.swift`**
  - In `buildProviderDetails`, the synthetic "Default" tier branch now requires `quota > 0`, **non-nil** `remaining`, **and** `provider != ProviderKind.claude.rawValue`. Claude with empty tiers means "data unavailable", not "use the overall".

- **`ProvidersTab.swift`**
  - When a quota-supporting provider has no tiers and no overall quota, render a small inline placeholder ("Quota data unavailable — try `/usage` in the CLI") instead of nothing or a fake bar.

### Bug 2 (2 files)

- **`AppState.swift`**: `toggleProvider` and `moveProvider` now call `buildProviderDetails()` synchronously after mutating `providerConfigs`. The next SwiftUI tick has a fresh `ProviderDetail` and the Toggle's `isOn` getter reads the new value.
- **`ProvidersTab.swift`**: Added a defensive `.animation(.easeInOut(duration: 0.15), value: config.isEnabled)` on the Toggle so the visual transition is smooth.

### Bug 4 (1 file)

- **`DataRefreshManager.swift`**: New `applyCostScan(to:scan:) -> [ProviderUsage]` static helper that:
  - Rolls up per-provider today + last-7-day cost (USD) and tokens from `CostUsageScanResult.entries`.
  - Replaces `estimated_cost_today/week` and flips `cost_status_*` to `"Estimated"` when the scanner found data; preserves cloud values otherwise.
  - For non-quota providers (e.g. OpenRouter), also bumps `today_usage` / `week_usage` to the scanned token count if it's larger than the cloud number.
  - Wired into both the cloud-mode `refresh()` path and the `refreshLocal()` path before the payload is built.

### Bug 3 (2 files)

- **`AlertGenerator.swift`**:
  - New `evaluateQuotaAlerts(providers:thresholds:)` (default thresholds `[80, 95]`). Iterates per tier (or falls back to overall quota), emits Warning at ≥80% and Critical at ≥95%. Stable IDs (`quota-<provider>-<tier>-<threshold>`) so the existing `previousAlertIDs` dedupe handles repeats.
  - New `makeAlertRecord(from:)` to convert the dictionary alert into an `AlertRecord` for the typed alerts feed.
- **`DataRefreshManager.swift`**:
  - Cloud-mode path: synthesises quota alerts from the cost-adjusted providers, merges them into `alertData` (skipping any IDs the cloud already returned), and uses the augmented array for both notifications and the payload.
  - Local-mode path: same, populates the previously-empty `alerts: [AlertRecord] = []`.

---

## Verification

- `swift build` of `CLIPulseCore`: ✅ `Build complete! (3.87s)` (only pre-existing warnings, none introduced).
- `xcodebuild -scheme "CLI Pulse Bar" -destination 'platform=macOS' build`: ✅ `BUILD SUCCEEDED`.
- `xcodebuild -scheme "CLI Pulse iOS" -destination 'generic/platform=iOS' build`: ✅ `BUILD SUCCEEDED` (also embeds CLI Pulse Watch).

Manual on-device verification still pending (waiting for next refresh cycle to land the changes; not required to ship the diff but should be checked before App Store submission).

### Residual grep checks (per `feedback_fix_archiving.md`)

- `grep -rn "quota: 100, remaining: 100" CLI\ Pulse\ Bar/CLIPulseCore` → no remaining hardcoded 100/100.
- `grep -rn '"Default"' CLI\ Pulse\ Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift` → only the legitimate non-Claude fallback in `buildProviderDetails`.
- `grep -rn "evaluateQuotaAlerts" CLI\ Pulse\ Bar/CLIPulseCore` → defined in AlertGenerator.swift, called from both refresh paths.
- `grep -rn "applyCostScan" CLI\ Pulse\ Bar/CLIPulseCore` → defined in DataRefreshManager.swift, called from both refresh paths.

---

## Post-review adjustments (Gemini 3.1 Pro)

Gemini's `focused` review of the diff caught four actionable issues that were patched before sign-off:

1. **`ProvidersTab.swift` cloud-fallback bypass** — even with the AppState fix, the view still rendered an "Quota" bar from `provider.quota > 0` for Claude when cloud returned a stale 100 quota. Added an explicit `provider.provider != "Claude"` guard to the fallback branch so Claude only ever takes the per-tier or "data unavailable" paths.
2. **Toggle binding could double-flip on rapid taps** — added `setProviderEnabled(kind:isEnabled:)` to `AppState` and rewired the Toggle's `set` closure to forward the user's intended boolean. Old `toggleProvider(kind)` now delegates to it.
3. **Quota alerts were un-resolvable** — `api.resolveAlert(id:)` no-ops for locally-generated `quota-*` IDs because they don't exist in Supabase. Added a UserDefaults-backed `suppressedAlertIDs: [String: Date]` map on `AppState`, keyed by alert ID with an expiration date. `resolveAlert` writes `.distantFuture`, `snoozeAlert` writes `now + minutes`, and `evaluateQuotaAlerts` filters via the new `Callbacks.activeSuppressedAlertIDs` closure on every cycle. Loaded on `AppState.init`.
4. **Cost merge clobbered cloud values** — switched `mergedCostToday` / `mergedCostWeek` from `> 0 ? scan : cloud` to `max(scan, cloud)` to mirror the existing token-merge logic and avoid hiding multi-device usage. Status flips to "Estimated" whenever the merged value is > 0.
5. **Week cutoff off-by-one** — `cal.date(byAdding: .day, value: -7, to: now)` combined with `>= weekCutoff` covered 8 calendar days. Changed to `-6` so the rolling window is exactly 7 days (today + 6 prior).

Re-built after each: `swift build` ✅, `xcodebuild` macOS ✅, iOS ✅, `swift test` ✅.

Gemini also flagged a separate **Android OAuth CSRF** issue (`android/app/src/main/java/com/clipulse/android/MainActivity.kt:44` — `state` check fails open when `expectedOAuthState` is nil). Out of scope for v1.9.3 (Android isn't part of this release), but tracked for follow-up.

## Out of scope deferrals

- **Why the OAuth payload is empty in production** — needs a user-side log capture. v1.9.3 makes the symptom honest (placeholder text) rather than masking it with a fake 100% bar. Track separately.
- **Per-tier alert customisation UI** — only ships sane defaults (80/95) for v1.9.3.
- **Watch / iOS quota alerts surfacing UI** — the shared core now produces them; mobile UI can adopt later.

---

## Files touched

```
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertGenerator.swift
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors/Claude/ClaudeSourceStrategy.swift
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift
CLI Pulse Bar/CLI Pulse Bar/ProvidersTab.swift
docs/DEVELOPMENT_PLAN_v1.9.3.md   (new)
docs/PROJECT_FIX_v1.9.3_appstore_regressions.md  (this file)
```
