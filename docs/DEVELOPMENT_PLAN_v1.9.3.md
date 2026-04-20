# DEVELOPMENT_PLAN_v1.9.3 — App Store regression fixes

**Date:** 2026-04-19
**Target version:** macOS / iOS / watchOS v1.9.3
**Trigger:** User QA on shipped App Store build v1.9.2 found 4 issues.

---

## Scope (4 bugs)

1. **Claude Code provider** shows a single "Default 100% left" bar instead of the historical three bars (`5h Window`, `Weekly`, `Sonnet only`).
2. **Provider toggle** in `ProvidersTab` doesn't visually flip until the manual refresh button is tapped — the disable action only "lands" after the next refresh cycle.
3. **Alerts** rarely (or never) fire on-device — quota-depletion alerts appear to be missing entirely.
4. **Token / cost numbers** are stuck at `0 tokens · <$0.01` for every provider, even after real usage. Reference: codexbar's JSONL-scanning approach.

Out of scope: anything not on the list above (yield score, subscription features, iPad layouts, etc.).

---

## Root cause analysis

### Bug 1 — Claude tiers collapse to "Default"

Rendering & merge layers are correct:
- `AppState.swift:266-289` correctly emits multiple tiers when `usage.tiers` is non-empty.
- `DataRefreshManager.swift:445` (`mergeCloudWithLocal`) correctly preserves a non-empty `result.usage.tiers` over the cloud value.
- `ClaudeResultBuilder.build` ([ClaudeSourceStrategy.swift:82-122](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors/Claude/ClaudeSourceStrategy.swift)) appends three `TierDTO`s when the snapshot has non-nil `sessionUsed`/`weeklyUsed`/`sonnetUsed`.

The card shows `Source: merged` AND `Default 100% left`. The only path that produces this combo is:
- The **local Claude collector succeeded** (so `merged` flag is set), but its `ClaudeSnapshot` had **all three percentage fields nil**.
- `ClaudeResultBuilder` therefore returned `tiers: []` plus the hardcoded fallback `quota: 100, remaining: 100` ([ClaudeSourceStrategy.swift:117](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors/Claude/ClaudeSourceStrategy.swift)).
- `mergeCloudWithLocal` then adopted the local quota/remaining (because `result.usage.quota != nil`), yielding `quota=100, remaining=100, tiers=[]`.
- `AppState.buildProviderDetails` fell into the `else if let quota = usage.quota, quota > 0` branch and synthesised the misleading `Default 100% left` bar.

Why are the three percentage fields nil? Three plausible causes in a sandboxed App Store build (entitlements: `app-sandbox=true`):
- **OAuth strategy** ([ClaudeOAuthStrategy.swift:30-36](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors/Claude/ClaudeOAuthStrategy.swift)) returned a 200 OK with no `fiveHour`/`sevenDay` envelope (e.g. user hasn't run Claude recently, or response shape changed).
- **PTY strategy** can't run subprocesses inside the sandbox → falls through.
- **Web strategy** can't read `~/.claude/.credentials.json` inside the sandbox → falls through.

So the production bug is two-layered:
- (A) the **collector regression**: when nothing usable is captured we still claim success and emit a bogus 100/100 tier;
- (B) the **rendering regression**: `AppState` invents a meaningless "Default" bar from a 100/100 quota.

Both must be fixed; either alone leaves a misleading UI.

### Bug 2 — Toggle UI lag

[ProvidersTab.swift:135-142](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/ProvidersTab.swift):

```swift
Toggle("", isOn: Binding(
    get: { config.isEnabled },
    set: { _ in onToggle() }
))
```

The `set` closure discards the new value and calls `onToggle()`, which (via `state.toggleProvider(...)`) mutates `ProviderConfig` and triggers a refresh. `config` is captured by value in the SwiftUI row; the `Toggle`'s `isOn` `get` keeps reading the **stale** captured value until the parent view rebuilds with a new `config`. SwiftUI animates the switch from the binding, so until that rebuild, the knob doesn't move.

Fix direction: read `config.isEnabled` from an `@ObservedObject`/`@EnvironmentObject` source so the row rebuilds immediately, OR mirror to `@State` and apply optimistically before the async refresh completes.

### Bug 3 — Alerts never fire

`AlertGenerator.swift` only generates two alert categories:
- CPU/long-session alerts in `AlertGenerator.generate()` (gated on local helper-supplied process metrics).
- Budget/cost-spike alerts in `evaluateBudgetAlerts()` (driven by `estimated_cost_*`, which is always 0 — see Bug 4).

There is **no quota-depletion alert path**. Even if a Claude weekly tier hits 95%, nothing fires. Combined with Bug 4, the budget alerts are also dead because their inputs are zeros.

### Bug 4 — Token / cost stuck at 0

`ClaudeSourceStrategy.swift:113-116` hardcodes:

```swift
estimated_cost_today: 0, estimated_cost_week: 0,
cost_status_today: "Unavailable", cost_status_week: "Unavailable",
```

Other collectors (Codex, Cursor, OpenRouter) have the same pattern. `CostUsageScanner` and `CostUsageCache` exist and can scan Claude/Codex JSONL session logs to compute precise token counts and prices, but `DataRefreshManager` never **bridges** the scan result back into the `ProviderUsage` array. Codexbar's mechanism (per the user) is to scan local session logs and maintain a per-day cost roll-up; we already have the scanner — it just isn't wired up.

---

## Implementation plan

### Step 1 — Restore Claude tier visibility (Bug 1)

**Files:**
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors/Claude/ClaudeSourceStrategy.swift`
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift`
- `CLI Pulse Bar/CLI Pulse Bar/ProvidersTab.swift` (display fallback text)

**Changes:**
1. In `ClaudeResultBuilder.build`, when **all three** of `sessionUsed`/`weeklyUsed`/`sonnetUsed` are nil:
   - Set `quota: nil, remaining: nil` (don't lie with `100/100`).
   - Set `status_text` to `"Quota data unavailable"`.
   - Set a new metadata flag `quota_unavailable_reason` (added to `ProviderMetadata`) describing which strategy succeeded but returned no usage envelope (helps diagnose in field).
2. In `AppState.buildProviderDetails`, drop the synthetic "Default" tier path entirely. If `usage.tiers` is empty, return `tiers: []` and let the UI show a placeholder.
3. In `ProvidersTab` Claude card: if the tier list is empty, render a small grey row "Claude quota: data unavailable — try `/usage` in the CLI" instead of a fake bar. Codex, Gemini etc. cards already handle empty tiers gracefully — verify.
4. Add a `ClaudeSnapshot.hasAnyUsage` convenience and a `#if DEBUG` log line in `ClaudeResultBuilder` so future regressions surface in `clipulse_claude_resolver.log`.

**Note**: this fix surfaces the *underlying* OAuth-empty-payload symptom rather than masking it. Investigating *why* the OAuth payload is empty is tracked as a follow-up (see "Out of scope deferral" below) — it may need an SDK-level repro that we can't do in this pass without user-side captured logs.

### Step 2 — Fix Toggle binding (Bug 2)

**Files:** `CLI Pulse Bar/CLI Pulse Bar/ProvidersTab.swift`

**Change:** Refactor `EnhancedProviderCard` to take `@ObservedObject var config: ProviderConfig` (verify `ProviderConfig` is a class — if it's a struct, route through a wrapper `@StateObject` per-card, or read `config.isEnabled` via `state.providerConfigs.first(where: { ... })` inside the binding `get`). Bind the Toggle to `config.isEnabled` directly; have `onToggle()` flip the `@Published` field and **then** kick off the refresh. The Toggle visual is now driven by the model, not the captured value.

If `ProviderConfig` is a struct, the cleanest fix is:

```swift
Toggle("", isOn: Binding(
    get: { state.providerConfigs.first(where: { $0.id == config.id })?.isEnabled ?? config.isEnabled },
    set: { newValue in onToggle(newValue) }
))
```

…with `onToggle` taking the new value and applying it synchronously to `state.providerConfigs` before any async work. The state mutation forces a re-render and the toggle visual flips in the same frame.

### Step 3 — Add quota-depletion alerts (Bug 3)

**Files:** `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertGenerator.swift`, `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift`

**Changes:**
1. Add `AlertGenerator.evaluateQuotaAlerts(providers: [ProviderUsage], thresholds: [Int] = [50, 80, 95]) -> [Alert]`. For each provider tier with `quota > 0`, compute `usedPct = 100 * (quota - remaining) / quota` and emit an Info/Warning/Critical alert at each threshold crossing. Stable IDs: `quota-<provider>-<tierName>-<threshold>` (so we don't duplicate per refresh).
2. Wire the call into `DataRefreshManager.refreshLocal()` (and the API path) right after the providers list is built, merging the result into the alerts array that flows into `AppState`.
3. Add basic dedupe so the same alert doesn't re-fire every 30s — keep an `alertsSeenAt: [String: Date]` and skip if last seen within the last hour AND the threshold hasn't ratcheted up.
4. UI verification: open Alerts tab while a Codex tier is at 71% — should not fire; bump `Codex` weekly to 85% (mock) — Warning should appear.

### Step 4 — Wire token/cost scanner into ProviderUsage (Bug 4)

**Files:** `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift`, `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/CostUsageScanner.swift` (read-only), `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors/Claude/ClaudeSourceStrategy.swift`, plus the Codex/Cursor/OpenRouter collectors that hardcode 0.

**Changes:**
1. In `DataRefreshManager.refreshLocal()`, after we obtain `resolvedProviders` and `costUsageScanResult`, project per-provider `(today_usd, week_usd, today_tokens, week_tokens)` from the scan result and replace the hardcoded zeros via a small `applyCostScan(to:scan:)` helper.
2. The helper sets `cost_status_today` to `"Estimated"` when the scan covered the day, `"Unavailable"` otherwise. Same for week. Token counts get exposed via existing `today_usage`/`week_usage` (which already represent token counts for non-quota providers).
3. Make sure budget alerts (`evaluateBudgetAlerts`) now have non-zero inputs — manual sanity test.
4. Sandboxed-build note: `CostUsageScanner` reads from user-selected folders only (security-scoped bookmarks). Verify the scanner gracefully no-ops when no bookmarks are granted — UI should still show `<$0.01` with `Source: api` rather than crash.

### Step 5 — Cross-cutting: small data-model additions

- `ProviderMetadata`: optional `quota_unavailable_reason: String?`.
- `Alert`: ensure `category: "quota"` is supported — if not, add the case.
- No DB / cloud schema changes; everything is in-process.

### Step 6 — QA pass

- Local debug build with three known-good Claude account states (no usage / mid-week / near limit) → screenshot tier rendering for each.
- Local debug build with Codex JSONL present → confirm `Today` shows non-zero tokens and `>$0.00` cost.
- Toggle Claude off & on rapidly → toggle visual flips immediately; provider card greys out and re-appears without the bottom refresh button.
- Force a tier above 80% (mock data injection) → alert appears in Alerts tab within one refresh cycle.

### Step 7 — Version bump & ship prep

- iOS / macOS / watchOS bump to **1.9.3** (build numbers as needed).
- Add `archive/PROJECT_FIX_v1.9.3_*.md` capturing each of the 4 fixes (per `feedback_fix_archiving.md`), with a "verified by" grep showing no residual hardcoded `quota: 100, remaining: 100` and no `tiers = [Default]` synthesis.
- Notify user before ASC submission per `feedback_appstore_update.md`.

---

## Out of scope deferrals (explicit)

- **Why the OAuth payload is empty in production** — needs a user-side log capture (`~/Library/Caches/clipulse_claude_resolver.log`). Track separately; v1.9.3 makes the symptom honest rather than masking it.
- **Cross-platform alerts on iOS / watchOS** — quota alerts wired into shared core will benefit those clients automatically; UI surfacing on the watch is a v2.0 item.
- **Fancy alert customisation UI** — only ship sane defaults (50/80/95) for v1.9.3.

---

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Removing the synthetic "Default" tier breaks other providers' rendering | Low | The change is gated to `usage.tiers.isEmpty` — verify Codex/Gemini cards still render their existing tiers. Add UI placeholder text. |
| Toggle refactor breaks add/remove provider flows | Med | Manually test add/remove + reorder flows after the binding refactor. |
| New quota alerts spam users | Med | Per-threshold dedupe with 1h cooldown; only fire on threshold crossing. |
| Cost scan path crashes in sandboxed build with no bookmarks | Med | Scanner already returns empty result — add explicit guard + unit test for "no bookmark" branch. |

---

## Review gate

Before any code is written:
1. Hand this plan to **Codex** for review — focus on root cause #1 (is the "merged + empty tiers + synthetic Default" theory correct?) and step 2 (is the binding analysis right?).
2. After implementation, hand the diff to **Gemini 3.1 Pro** for a second-pass review.
3. Build + run, capture screenshots showing all 4 bugs resolved.
4. Notify user before App Store submission.
