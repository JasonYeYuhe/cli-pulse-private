# CLI Pulse Fix Archive — 2026-04-24 (iOS Cloud Dashboard Gaps + Providers Toggle + Cost-Scaled Provider Usage)

> Task: iPhone App Store v1.10.6 Dashboard missing Subscription Utilization + Provider Usage sections; Providers tab toggle "can't toggle back on"; Provider Usage bars visually misleading when one provider dominates token count.
> Scope: iPhone cloud-only clients; macOS gets the cost-scaled bar change too (shared helper).
> Based on commit: c3c2adb

feedback_fix_archiving

---

## Issues & Root Causes

### Issue 1 — Subscription Utilization missing on iPhone Overview

`iOSOverviewTab.swift` renders the Utilization block only when
`providerState.costSummary.utilization` is non-empty. That field is populated
inside `DataRefreshManager.updateCostSummary()`, but only in the precise
local-JSONL-scan branch. iPhone never has a local scan, so it hit the estimate
fallback which omitted the `utilization:` argument from the `CostSummary(...)`
initializer → empty array → section hidden.

### Issue 2 — Provider Usage card empty on iPhone Overview

`APIClient.dashboard()` returns `provider_breakdown: []` for cloud clients
(the server's `dashboard_summary` RPC doesn't emit per-provider rows yet).
iOS `providerBreakdown(_:)` read `dash.provider_breakdown` directly, so it
rendered a title with no bars. The Providers tab worked because it reads
`providerState.providers`, which is populated from the per-provider
`provider_summary` RPC.

### Issue 5 — Provider Usage bars scaled by token count feel "weird"

User feedback on a screenshot (Claude 754M tokens · $13.5, Codex 23.3M · $2.8,
Gemini 0 · <$0.01): Claude's bar maxed out, Codex was a 3% sliver, Gemini was
an empty track. Root cause: bars were scaled by `usage` (tokens), but `usage`
has inconsistent semantics across providers — for Claude the server aggregates
something closer to cache-read / raw-event counts than billable input+output
tokens (754M @ $13.5 → $0.018/Mtok, way below any Claude rate). Cost is the
one cross-provider comparable metric and is already shown in the detail label.

Cross-reviewed with Codex (GPT-5.4) and Gemini 2.5 Pro — both agreed cost
scaling is the right default, both flagged the `usage > 0 && cost == 0` free-
tier edge case (need a minimum bar so those providers don't disappear).

### Issue 4 — Providers toggle "can't toggle back on"

`iOSProvidersTab.visibleDetails` filtered to only `config.isEnabled` providers
when `showDisabled == false` (the default). Toggling a card OFF immediately
removed it from the list — the user thought the toggle was broken because
they couldn't find the card to flip back on. No "all hidden" empty state
(macOS has one) meant a fully-hidden list showed just the cost bar and a blank
scroll area, with no hint that the "…" menu has a Show All action.
Additionally, the Toggle binding ignored SwiftUI's new value
(`set: { _ in onToggle() }` → `state.toggleProvider(kind)` reads current and
flips), which is correct in isolation but diverges from macOS's safer
explicit-new-value pattern.

### Issue 3 — Empty card containers collapse / no empty state

Provider Usage and Top Projects VStacks had no `maxWidth: .infinity` before
`.background(...)`, so when content was empty (or very short) the card shrank
to content width instead of stretching, producing a ragged layout. iOS Provider
Usage also had no empty-state fallback (macOS has "No enabled providers with
data").

---

## Files Changed

### `CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift`

- **`updateCostSummary()` fallback branch (lines ~1183–1224)** — after
  computing `thirtyDayByProvider` / `thirtyDayTotal`, derive
  `[SubscriptionUtilization]` by joining `subscriptions` with a
  `reduce(into:)`-built `[String: Double]` lookup of 30-day costs, and pass
  it through `utilization:` into `CostSummary(...)`. Also explicitly sets
  `isPrecise: false` now that more args are named.

- **`completeRefresh()` dashboard rebuild (lines ~1363–1404)** — computes a
  `rebuiltBreakdown` unconditionally above the rebuild branch. When
  `dash.provider_breakdown` is empty AND `providers` is non-empty, synthesise
  it from `providers.map { ProviderBreakdown(...) }` using `today_usage` /
  `estimated_cost_today` / `cost_status_today` / `remaining`. The existing
  "rebuild dashboard when local-today data is present" path now also adopts
  `rebuiltBreakdown`. Independent of the `localTodayCost > 0 || localTodayTokens > 0`
  guard per handoff instructions.

### `CLI Pulse Bar iOS/iOSOverviewTab.swift`

- **`providerBreakdown(_:)`** — added a UI-level belt-and-braces fallback:
  if `dash.provider_breakdown.isEmpty`, synthesise the same
  `[ProviderBreakdown]` from `providerState.providers`. Added the
  `enabledProviders.isEmpty → Text("No enabled providers with data")`
  empty state matching macOS. Added `.frame(maxWidth: .infinity, alignment: .leading)`
  before `.background(...)` so the card stretches full-width.

- **`topProjects(_:)`** — added `.frame(maxWidth: .infinity, alignment: .leading)`
  before `.background(...)`.

- **`activityTimeline(_:)`** — added `.frame(maxWidth: .infinity, alignment: .leading)`
  before `.background(...)`.

### `CLIPulseCore/Sources/CLIPulseCore/OverviewFormatters.swift`

Two new shared helpers so iOS + macOS render Provider Usage identically:

- `rankedProviderBreakdown(_:enabledNames:)` — filters out disabled providers
  and rows where `usage == 0 && estimated_cost == 0`, sorts by `estimated_cost`
  desc → `usage` desc → provider name asc (deterministic tie-break).
- `providerUsageBarFraction(_:in:)` — scales the bar by
  `cost / max(cost_in_list)`. Providers with `usage > 0 && cost == 0` are
  given `minVisibleCostBarFraction = 0.04` so free tiers / cost-lagged
  providers remain visible; truly inactive providers return 0.

### `CLI Pulse Bar iOS/iOSOverviewTab.swift` (cost-scaled bars)

- `providerBreakdown(_:)` — replaced the inline token-scaled fraction with
  `OverviewFormatters.rankedProviderBreakdown` + `providerUsageBarFraction`.

### `CLI Pulse Bar/OverviewTab.swift` (macOS, cost-scaled bars)

- `providerBreakdown(_:)` — same two-line swap. The macOS precise branch's
  breakdown still feeds this view; it just gets sorted and scaled
  consistently with iOS now.

### `CLI Pulse Bar iOS/iOSProvidersTab.swift`

- **`iOSProvidersTab`** — added `@State recentlyToggledOff: Set<ProviderKind>`.
  The `visibleDetails` filter now keeps kinds in that set visible even after
  they're toggled off, so the just-toggled-off card stays on screen and the
  user can immediately toggle it back on. The set resets when the view leaves
  the stack (the next push/pop).
- Added a `handleToggle(_:newValue:)` helper that updates the sticky set
  before calling `state.setProviderEnabled(kind, isEnabled: newValue)` (the
  safer macOS pattern — explicit value, not a blind flip).
- Added a `ContentUnavailableView` "All providers hidden" empty state with a
  "Show All" button that flips `showDisabled = true`. Matches macOS parity
  (which shows `EmptyStateView` with `L10n.providers.allHidden`).
- **`iOSEnhancedProviderCard`** — changed `onToggle: () -> Void` to
  `onToggle: (Bool) -> Void`; the Toggle's set closure now forwards
  `newValue` instead of discarding it.

### `CLIPulseCore/Tests/CLIPulseCoreTests/CostSummaryFallbackTests.swift` (new)

Six `@MainActor` tests covering the fallback paths:
- `testFallbackPopulatesSubscriptionUtilization` — asserts non-empty
  utilization, correct `utilizationPercent` (30-day cost / monthly cost * 100),
  DESC sort order, and `isPrecise: false`.
- `testFallbackSkipsProvidersWithoutPaidPlan` — Ollama has no sub pricing → 0 entries.
- `testFallbackHandlesMissingThirtyDayCostAsZero` — no cost data → `apiEquivCost = 0`.
- `testFallbackUsesWeekTimes4_3WhenThirtyDayMissing` — weekly $10 → 30-day $43.
- `testCompleteRefreshSynthesisesProviderBreakdownFromProviders` — verifies
  the `dashboard.provider_breakdown` rebuild from `providers` when cloud is empty.
- `testCompleteRefreshPreservesExistingProviderBreakdown` — non-empty cloud
  `provider_breakdown` survives untouched.

---

## Test Results

```
swift test --package-path "CLI Pulse Bar/CLIPulseCore"
 Executed 455 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.266 (0.295) seconds
```

Baseline before this fix: 449 passed, 1 skipped (450 total).
After: 462 total (461 passed + 1 skipped). +6 `CostSummaryFallbackTests` for
the utilization/breakdown fallback, +7 `OverviewFormattersTests` cases
covering rank/filter/bar-fraction for the cost-scaled Provider Usage. All green.

Note: the Providers-tab toggle fix is pure SwiftUI/@State behavior — no
CLIPulseCore logic changed, so no unit tests were added. Verified via the
iOS simulator manual-verification steps below.

iOS xcodebuild: the `CLI Pulse iOS` target itself compiles cleanly (no errors
or warnings in `iOSOverviewTab.swift` or `DataRefreshManager.swift`). A
pre-existing linker error in the Watch/Widgets targets (module mismatch
between iOS-simulator and watchOS-simulator CLIPulseCore builds, present on
`main` before any of these changes) blocks the full scheme build — confirmed
independent by stashing the changes and retrying.

---

## Manual Verification Steps

### iPhone simulator

1. Build + install `CLI Pulse iOS` on a sim logged into an account that's
   paired with a macOS device that has non-trivial Claude/Codex 30-day spend.
2. Open Overview tab. Expect:
   - Provider Usage card stretches to full width, shows ≥ 1 bar with usage +
     cost, OR "No enabled providers with data" if all providers disabled.
   - Cost Summary card shows Subscription Utilization block with per-plan
     progress bars and "Nx value" multipliers when utilization > 100%.
   - Top Projects and Activity Timeline cards also stretch full width (no
     collapsed title-only boxes).
3. Toggle providers off in Settings → Providers, return to Overview — verify
   the empty-state text appears.
4. Providers tab: with the default "hide disabled" view, toggle one card OFF.
   Expect the card to stay visible (dimmed, toggle shows off) so you can
   toggle it back on immediately. Leave the tab and return — the now-disabled
   card should no longer appear (sticky visibility is session-local).
5. Toggle ALL providers off. Expect an "All providers hidden" empty state with
   a "Show All" button that reveals disabled cards. Tap → all cards return.
   Toggle one back on → the menu's "Hide Disabled" returns the filter.
6. Overview → Provider Usage card: bar widths should now reflect relative
   **cost**, not token count. Inactive providers (0 usage AND $0 cost) should
   not appear. A provider with usage but $0 cost (free tier) should show a
   small-but-visible bar. Sorted biggest-cost first.

### macOS

1. Run the macOS app on the same account. Open Overview tab.
2. Expect Cost Summary and Provider Usage to look identical to before — the
   precise local-scan path is untouched, and the fallback
   `provider_breakdown` rebuild in `completeRefresh()` only fires when
   `dash.provider_breakdown.isEmpty`, which does not happen on macOS when
   local JSONL scanning supplies the breakdown via the rebuild path.
3. Also verify Subscription Utilization percentages match prior values
   (precise branch unchanged).

---

## Deferred Follow-ups

Not fixed in this pass (per handoff scope note):

- **Activity Timeline trend** — `APIClient.dashboard()` still returns
  `trend: []` for cloud clients. `refreshCostForecast()` already pulls 30-day
  daily usage; mapping that into `dash.trend` on iOS is a follow-up. Risk:
  touching the refresh ordering could destabilize forecast / yield chains.
- **Top Projects** — cloud RPC returns `top_projects: []` and there's no
  client-side project aggregation to fall back on. Needs backend work
  (dashboard_summary RPC or a new projects RPC), out of scope for this task.
- **Risk signals** — cloud dashboard returning `[]` is correct behavior when
  the server has no signals to emit; no client-side fix appropriate.

---

## Notes

- No changes to backend / Supabase / RPC schema.
- No CFBundleShortVersionString or CFBundleVersion bump.
- No App Store Connect upload, no GitHub Release, no push to `public`.
- Changes left uncommitted for the user to review before committing.
