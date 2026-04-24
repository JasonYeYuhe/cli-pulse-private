# PROJECT_FIX — v1.10.6 (build 40)

**Date:** 2026-04-24 (JST)
**Supersedes:** PROJECT_FIX_2026-04-24_v1.10.5_iphone_dashboard.md (Bug A only — v1.10.5 fixed today-in-sync; v1.10.6 fixes the remaining cross-platform mismatches it exposed)

## Bugs Fixed

### 1. iPhone "30 Day Est." under-reporting by ~50%
**Symptom:** iPhone Cost Summary showed `30 Day Est. $2,544` while macOS and DB showed ~$5,843 for the same window.

**Root cause:** `DataRefreshManager.updateCostSummary` fallback path computed `thirtyDayTotal = week_cost × 4.3`. When recent 7-day spend was below the 30-day average (a normal pattern), this under-reported by ~50%. The server RPC only returned 7-day per-provider cost, so the client had nothing better to use.

**Fix:**
- `backend/supabase/app_rpc.sql` + prod migration `v0.24_provider_summary_30day`: `provider_summary` now returns `estimated_cost_30_day` (actual 30-day sum from `daily_usage_metrics`) alongside existing `estimated_cost` (7-day) and new `estimated_cost_today`.
- `Models.swift`: `ProviderUsage` gets `estimated_cost_30_day: Double` (default 0 in init — minimal blast radius).
- `APIClient.swift`: `ProviderSummaryPayload` decodes the new fields; `providers()` maps them.
- `DataRefreshManager.swift`: both precise and fallback paths prefer `estimated_cost_30_day` over `week × 4.3`; fall back only when server hasn't been upgraded.

### 2. iPhone per-provider Cost Summary rows all showed `<$0.01`
**Symptom:** Under the "30 Day Est." header, Claude/Codex/Gemini each displayed `<$0.01` even though totals were non-zero.

**Root cause:** Two-layer bug.
- Server `provider_summary` emitted `estimated_cost_today` but iOS `ProviderSummaryPayload` decoder didn't have that field → dropped → `estimated_cost_today = 0` hardcoded in `APIClient.swift:551`.
- `iOSOverviewTab.swift` rendered `todayByProvider` (all-zero) as the per-provider breakdown under the "30 Day" label when `!isPrecise`.

**Fix:**
- Payload decodes `estimated_cost_today`.
- `iOSOverviewTab.swift`: breakdown always uses `thirtyDayByProvider` to match the header (removed the `isPrecise` branch).

### 3. Device CPU spike alert fires every helper sync (~2 min)
**Symptom:** Alerts tab accumulated a new "Device CPU usage is elevated" row every ~2 min with a fresh timestamp. Local notifications fired for each.

**Root cause:** `AlertGenerator.swift` Rule 1 built `id = "cpu-spike-\(timestamp)"` — unique every cycle. The helper-sync upsert is keyed on `(id, user_id)`, so every cycle inserted a new row instead of updating.

**Fix:** Stable id `cpu-spike-global`. Now upserts the single row and updates its message/severity in place.

### 4. Notifications repeat for alerts sharing a suppression group
**Symptom:** Multiple related alerts (same project, same quota, repeated CPU spikes) each fired their own local notification, even after the user had acknowledged the group mentally.

**Root cause:** Client-side notification dedup only checked `alert.id`. Alerts with different IDs but the same `suppression_key` (a grouping key for "same issue class") each triggered notifications.

**Fix:** `DataRefreshManager` added `previousSuppressionKeys: Set<String>` persisted in `UserDefaults`. Across refresh cycles, alerts whose `suppression_key` is already in the set are skipped for notification. Set is rebuilt each cycle from **only unresolved** alerts in the feed, so a legitimate re-occurrence (after resolve) fires again.

### 5. iOS Alerts tab had no "Resolve All" (parity gap vs macOS)
**Fix:** Added `Resolve All` button on iOS mirroring the macOS design.

### 6. "Resolve All" would issue N sequential full refreshes
**Flagged by Gemini review of v1.10.6 diff before commit.**
**Root cause:** `state.resolveAlert(alert)` calls `refreshAll()` internally. Resolving 20 alerts = 20 back-to-back full dashboard fetches.

**Fix:** New `resolveAlerts(_:)` batch API on `DataRefreshManager` using `TaskGroup` for concurrent network resolves + single terminal `refreshAll()`. Both iOS and macOS "Resolve All" buttons route through it.

## Files touched

| File | Change |
|---|---|
| `backend/supabase/migrate_v0.24_provider_summary_30day.sql` | New migration (applied to prod) |
| `backend/supabase/app_rpc.sql` | Re-sync `dashboard_summary` + `provider_summary` with prod |
| `CLIPulseCore/Models.swift` | `ProviderUsage.estimated_cost_30_day` |
| `CLIPulseCore/APIClient.swift` | Decoder + mapping |
| `CLIPulseCore/DataRefreshManager.swift` | Real 30-day agg, suppression_key dedup, batched resolve |
| `CLIPulseCore/AlertGenerator.swift` | Rule 1 stable id |
| `CLI Pulse Bar iOS/iOSOverviewTab.swift` | Breakdown source |
| `CLI Pulse Bar iOS/iOSAlertsTab.swift` | Resolve All + batch call |
| `CLI Pulse Bar/AlertsTab.swift` | Resolve All → batch call |
| All `Info.plist` + `project.pbxproj` | 1.10.5→1.10.6, build 39→40 |

## Verification

- `swift build` + `swift test`: all CLIPulseCore suites pass.
- `xcodebuild` Debug: `CLI Pulse Bar` (macOS) + `CLI Pulse iOS` both `BUILD SUCCEEDED`.
- Live DB check against real user (`50a2b4a3-...`):
  - 30-day via new RPC: $5,843.07 (Claude $5,608.88 + Codex $234.18) — matches macOS dashboard exactly.
  - After v1.10.6 helper started, CPU spike table collapsed from 20 timestamped rows to single `cpu-spike-global` upsert.
- iPhone Dashboard verified against screenshots: today $2.9, 30-day $5,843.1, per-provider Claude $5,608.9 / Codex $234.2 — all match macOS.

## Reviews
- **Gemini 2.5-pro focused review** of the uncommitted diff caught two critical issues before commit:
  - Suppression keys were captured from ALL alerts (including resolved) → fixed to unresolved-only.
  - "Resolve All" triggered N-refresh storm → replaced with batched `resolveAlerts(_:)` + `TaskGroup`.
- **Codex rescue** was unavailable (`gpt-5.5 upstream 429/unavailable`) at time of review; Gemini served as the independent second pair of eyes per the "verify with a different reviewer" policy.

## Out-of-scope (tracked for later)
- Android `SupabaseClient.kt` still reads only `estimated_cost` (7-day) — new `estimated_cost_30_day` field is additive so old clients keep working; Android app update can land in a follow-up.
- Mac Providers card shows `I/O` (input+output, excl. cached) while iPhone shows total tokens (incl. cached). Cosmetic inconsistency; not a bug.
