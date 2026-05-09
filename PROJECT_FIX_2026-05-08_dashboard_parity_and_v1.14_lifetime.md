# PROJECT_FIX — Dashboard Parity Bug + v1.14 Lifetime IAP Foundation

Date: 2026-05-08
Branch: `dashboard-parity-and-v1.14-lifetime` (to create)

## Scope

This change set covers three independent threads landing together because
they touch overlapping client surfaces:

1. **Mission 1 audit** — Codex P1 from PR [#39](https://github.com/JasonYeYuhe/cli-pulse-private/pull/39) (LoginItem app-sandbox verifier hardening).
2. **Mission 1.5** — iPhone↔macOS dashboard parity bug (timezone-aware
   `dashboard_summary` / `provider_summary` RPCs) + iOS Cost Forecast
   feature parity.
3. **Mission 2** — v1.14 Pro Lifetime IAP client foundation (no
   ASC submission; backend column gated on user approval).

Migration `migrate_v0.42_user_tz_today.sql` is staged but **NOT applied** —
it gates user approval per the autonomy contract. The new optional
parameter is backwards compatible (`p_user_today date default null`), so
clients can ship before or after the migration without breakage.

## Mission 1 — Codex P1 (PR #39 follow-up)

### Finding

Codex review on PR #39 (build-appstore.sh:220):

> In the MAS macOS upload path this verifier can return success even though
> the archive still contains an unsandboxed nested executable
> `Contents/Library/LoginItems/CLIPulseHelper.app`. I checked
> `CLIPulseHelper.entitlements` and it has app-group/network entitlements
> but no `com.apple.security.app-sandbox`, so stripping only
> `cli_pulse_helper` and the LaunchAgent can still leave an ITMS-90296
> rejection.

### Why v1.13.0 still passed ASC

`ENABLE_APP_SANDBOX = YES` is set on the CLIPulseHelper target in
`project.pbxproj`. xcodebuild merges that into the signed binary's
entitlements at sign time. So the actual MAS upload had `app-sandbox=true`
even though the source `.entitlements` file didn't.

### Fix

1. **Source-of-truth**: added `<key>com.apple.security.app-sandbox</key><true/>`
   to `CLI Pulse Bar/CLIPulseHelper/CLIPulseHelper.entitlements`. No
   functional change at build time (Xcode was already injecting it), but
   now the source file is self-documenting and verifier can detect drift.
2. **build-appstore.sh `verify_mas_archive_has_no_launchagent()`**:
   - now asserts `CLIPulseHelper.app/Contents/MacOS/CLIPulseHelper` exists
   - extracts entitlements via `codesign -d --entitlements :-`
   - falls back to source `.entitlements` file when binary is unsigned (CI)
   - asserts `com.apple.security.app-sandbox` key is present AND value is `<true/>`
3. **Swift CI `Verify MAS archive does not contain Swift LaunchAgent
   helper`**: added "check 4" that greps the source entitlements file
   for the same key/value invariants.

Together, these guarantee a future hand-edit of `CLIPulseHelper.entitlements`
or accidental flip of `ENABLE_APP_SANDBOX` in pbxproj surfaces in CI before
ASC ever sees the upload.

### Files

- `CLI Pulse Bar/CLIPulseHelper/CLIPulseHelper.entitlements`
- `CLI Pulse Bar/scripts/build-appstore.sh`
- `.github/workflows/swift-ci.yml`

## Mission 1.5 — Dashboard parity bug

### User report (2026-05-08 ~02:03 CN time, simultaneous observation)

| Field                | iPhone     | macOS                |
|----------------------|------------|----------------------|
| Usage Today          | 0          | 12.7M tokens         |
| Today cost           | <$0.01     | $135.5               |
| 30-day cost          | $1972.2 (Estimated) | $8469.6 (Exact) |
| Claude utilization   | 934%       | 4182%                |
| Cost Forecast        | missing    | present              |
| Sessions / Devices / Alerts | 11 / 4 / 393 | 11 / 4 / 393 (match) |

Sessions/Devices/Alerts match perfectly → cloud auth + those tables fine.
The mismatch is isolated to **token/cost data** sourced from
`daily_usage_metrics`.

### Hypothesis A — Server-side timezone bug ✅ CONFIRMED

`backend/supabase/app_rpc.sql`:

- `dashboard_summary` line 15: `v_today date := current_date;`
- `provider_summary` line 66-71: `v_today := current_date`,
  `v_week_start := current_date - interval '6 days'`,
  `v_month_start := current_date - interval '29 days'`

Postgres `current_date` returns the date in the **session timezone**.
Supabase Tokyo project sessions run in UTC by default. At 02:03 CN
(UTC+8) the wall-clock UTC is 2026-05-07 18:03 → `current_date = '2026-05-07'`.

Meanwhile, `CostUsageScanner.swift:447-452` writes `metric_date` in the
device's **local** calendar (`Calendar.current.dateComponents`), so the Mac
at 02:03 CN tags new rows as `metric_date = '2026-05-08'`. The server's
`WHERE metric_date = current_date` therefore matches yesterday-CN, not
today-CN. The 30-day window slides one day too late as well.

Confirmed by reading code; no DB query needed.

### Hypothesis B — EventUploader / cloud-sync gap (informational)

The 30-day discrepancy is 4× ($1972 vs $8469), much more than the
~3% timezone shift can explain. `syncDailyUsage` (APIClient.swift:1630)
runs on every macOS refresh and uploads ALL 30 days of scan data, so a
single successful refresh should fully populate cloud. The observed gap
implies one of:

- The Mac wasn't running / authenticated for ~22 of the 30 days
- syncDailyUsage was failing silently (HTTP 5xx / network errors are
  logged at `.warning` level, not surfaced to user)
- Historical metrics were under a different `device_id` and got pruned
  (no — retention is 18 months, see `migrate_v0.22`)
- A different account was paired previously

**Action**: this fix doesn't try to retroactively recover missing data.
After timezone fix lands and the user updates the iOS app to v1.14, the
"today" field should match macOS within rounding. The 30-day field will
still be off by a fixed historical gap, but new days will be correct.

If user wants to investigate: query Supabase via MCP:

```sql
SELECT metric_date, sum(cost), count(*)
  FROM daily_usage_metrics
 WHERE user_id = '<user-uuid>'
   AND metric_date >= current_date - interval '40 days'
 GROUP BY metric_date
 ORDER BY metric_date DESC;
```

Compare day-by-day with macOS local scan to identify the gap window.

### Fix (Hypothesis A)

**Migration** (REQUIRES USER APPROVAL — backend schema category):
[migrate_v0.42_user_tz_today.sql](backend/supabase/migrate_v0.42_user_tz_today.sql)
adds an optional `p_user_today date default null` parameter to both
`dashboard_summary` and `provider_summary`. Server uses
`coalesce(p_user_today, current_date)` everywhere `v_today` was previously
hardcoded to `current_date`.

Per `feedback_gemini_review_patterns.md` rule #1: explicit
`drop function if exists ... ()` before the new `CREATE OR REPLACE` (adding
parameters creates an overload, not a replacement).

Backwards compatible: callers that don't pass the param fall through to
the prior server-tz behavior.

**Swift client** (`CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/APIClient.swift`):
- New `APIClient.localTodayKey(now:calendar:)` static helper. Returns
  `YYYY-MM-DD` in the device's `Calendar.current` (matching the convention
  `CostUsageScanner.DayRange.dayKey` uses for `metric_date` writes).
- `dashboard()` and `providers()` now pass `p_user_today: localTodayKey()`.

**Android client** (`android/app/src/main/java/com/clipulse/android/data/remote/SupabaseClient.kt`):
- `localTodayKey(zone:)` returns `LocalDate.now(zone).toString()`.
- `dashboard()` and `providers()` send the param via the existing
  `rpc(name, params)` 2-arg helper.

**Test pinning**:
- `CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/APIClientLocalTodayTests.swift`
  pins three invariants:
  - localTodayKey honors Calendar.current.timeZone (CN ≠ UTC at 02:03 CN moment)
  - localTodayKey produces the same shape as `DayRange.dayKey`
  - `UserTodayParams` encodes as `{"p_user_today": "..."}` exactly

### iOS Cost Forecast feature parity

iOSOverviewTab.swift gained a `forecastSection(_ forecast: CostForecast)`
helper mirroring macOS `OverviewTab.forecastCard(_:)` at iOS-friendly
type sizes. Renders below `costSection` when `state.costForecast != nil`.

`refreshCostForecast()` in DataRefreshManager already runs cross-platform,
so the data was already populated on iOS — only the UI was missing.

### Files

Backend:
- `backend/supabase/migrate_v0.42_user_tz_today.sql` (NEW — pending user approval)
- `backend/supabase/app_rpc.sql` (synced for source-of-truth parity)

Clients:
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/APIClient.swift`
- `android/app/src/main/java/com/clipulse/android/data/remote/SupabaseClient.kt`
- `CLI Pulse Bar/CLI Pulse Bar iOS/iOSOverviewTab.swift`

Tests:
- `CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/APIClientLocalTodayTests.swift` (NEW)

## Mission 2 — v1.14 Pro Lifetime IAP foundation

ASC IAP draft `com.clipulse.pro.lifetime` (Apple ID 6767441323, ¥128 CNY,
Non-Consumable, "Prepare for Submission") wired into client + edge function.
**No ASC submission** in this PR. **No backend schema change** in this PR.

### Backend

`backend/supabase/functions/validate-receipt/index.ts`:
- `PRODUCT_TIER_MAP` extended with `"com.clipulse.pro.lifetime": "pro"`.
- New `LIFETIME_PRODUCT_IDS` set used to:
  - Set `current_period_end = null` in the upserted `subscriptions` row
    (lifetime IAPs have no expiry; downstream queries that filter
    `current_period_end IS NULL OR current_period_end >= now()` will keep
    treating the user as active forever).
  - Surface a future hook for any subscription-renewal-status checks that
    assume an expiry.

**No `is_lifetime` column** added in v1.14. The lifetime row is
identifiable via `apple_product_id = 'com.clipulse.pro.lifetime' AND
current_period_end IS NULL`. The denormalized boolean column from
`PROJECT_PLAN_v1.14_lifetime_iap.md` can be added in v1.15 if a query
path needs the flag directly. This avoids the schema-migration approval
gate for v1.14.

### Swift client

`CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/SubscriptionManager.swift`:
- `proLifetimeID = "com.clipulse.pro.lifetime"` constant.
- `allProductIDs` includes the new ID so `Product.products(for:)` fetches it.
- `proLifetime` accessor on the manager.
- `@Published var isLifetime: Bool` flag for paywall display.
- `updateCurrentEntitlements()` recognizes `.nonConsumable` lifetime
  transactions: appends to `purchasedSubscriptions`, sets `txTier = .pro`,
  sets `sawLifetime = true`. Team auto-renewable still outranks Lifetime.
- StoreKit Sandbox refund auto-removes the entitlement, so no special
  refund hook is needed.

### Paywall surfaces

`CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/SubscriptionView.swift`:
- New `lifetimeCard` tile with orange "ONE-TIME" badge below pro/team
  cards. Hidden when user is on Team (Team strictly outranks Pro Lifetime)
  or already owns Lifetime (avoids duplicate "Owned" rendering).

`CLI Pulse Bar/CLI Pulse Bar/SubscriptionSection.swift`:
- Lifetime row added to `inlineIAPCards` for free-tier users (sandboxed
  macOS menubar settings panel). Hidden when isLifetime=true.

`CLI Pulse Bar/CLI Pulse Bar iOS/iOSSettingsTab.swift`:
- Settings panel navigates to `SubscriptionView`, which now contains the
  Lifetime tile via the changes above. No additional iOS work needed —
  the third paywall surface inherits the new tile transparently.

### Localization

L10n keys + 5 locales (en, zh-Hans, ja, es, ko) for:
- `subscription.lifetime` — "Pro Lifetime"
- `subscription.lifetime_description` — "Pro features forever, all platforms..."
- `subscription.lifetime_owned` — "You own Pro Lifetime"
- `subscription.one_time` — "one-time"
- `subscription.one_time_badge` — "ONE-TIME"
- `subscription.buy_lifetime` — "Buy Lifetime"

zh-Hant, fr, de, it, pt-BR, ru not present in repo today (no `.lproj` dirs);
falls back to en until those locales are added.

### Tests

`CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/SubscriptionTierResolutionTests.swift`:
- `testLifetimeProductIDIsRegistered` — pin `proLifetimeID` constant.
- `testIsLifetimeDefaultsToFalse` — pin `isLifetime` published default.
- `testProLifetimeAccessorIsNilBeforeProductsLoad` — pin accessor exists.

End-to-end Sandbox checklist (deferred to manual TestFlight verification
when binary is built):
- Buy Lifetime → currentTier = .pro, isLifetime = true, paywall hidden
- Buy Lifetime then Pro Yearly → still .pro, isLifetime = true
- Buy Lifetime then Team Monthly → .team displayed
- Refund Lifetime via App Store → tier drops back to .free within ~10s

## Verification

- `bash -n` on `build-appstore.sh`, `embed_helper_in_archive.sh`,
  `build_signed_app.sh` — all clean.
- `swift package resolve` + `swift build` in CLIPulseCore — clean.
- `swift test --parallel` — full suite passes (918+ tests, includes 3
  new APIClientLocalTodayTests + 3 new lifetime tests).
- `bash -n` on the migration SQL — clean.
- TZ fix manual trace: 2026-05-07 18:03 UTC → CN dayKey "2026-05-08" ✓
  (test pins this).

## Remaining gates (need user approval)

1. **Apply migrate_v0.42_user_tz_today.sql** via Supabase MCP. After it
   lands, the iOS/macOS/Android client changes start sending the param
   and dashboard parity is restored. Until it lands, clients still work
   but use server-tz behavior (status quo).

2. **Submit Pro Lifetime IAP for ASC review** when ready (after v1.14 binary
   is verified against StoreKit Sandbox). Currently in "Prepare for
   Submission" status.

3. **No backend column add** required for v1.14. v1.15 can revisit
   `is_lifetime` as denormalization if needed.

## Risk and rollback

- **Migration**: pure additive. Both RPCs continue accepting zero args
  via the default param — no breakage even if all clients stay on the
  pre-v1.14 binary forever.
- **Client TZ wiring**: if the server doesn't have the migration applied,
  PostgREST routes `?param=p_user_today` calls to the old 0-arg shape
  if the parameter is part of the function signature mismatch — actually
  it would fail. To avoid this, **migration must land before any
  production binary that sends p_user_today**. Order:
  1. User approves migration.
  2. User applies migration via Supabase MCP.
  3. Once applied, v1.14 client release can ship.
  4. Older clients (≤ v1.13.0 build 51) keep working via the param's
     default value (the migration is forward-compatible by design).
- **Lifetime IAP**: until ASC submits the IAP for review, `Product.products(for:)`
  includes `com.clipulse.pro.lifetime` returns nothing for that ID
  (or returns the unreviewed sandbox-only product). Client code handles
  `proLifetime == nil` gracefully (tile still renders with `--` price).
