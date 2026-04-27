# CLI Pulse Fix Archive — 2026-04-27 (sessions/alerts iter2)

> Reporter: Jason (user, after a deep self+AI review)
> Reviewed by: Gemini 3 Pro + Codex (independent), 2026-04-27
> **Implementation re-reviewed by Gemini 3 Pro + Codex 2026-04-27 evening; 9 follow-up amendments applied (see "Iter2 follow-ups" section below).**
> Branch: `sessions-alerts-hardening-iter2`
> Plan: `PROJECT_DEV_PLAN_2026-04-27_sessions_alerts_hardening.md` (v2)
> Git state: branch open, no commit yet
> ASC/Play: not affected (server-side migration + edge function + Android-only client changes; the macOS/iOS client carries one new AppStorage flag and a small `cpu-spike` id rename — ships on the next regular release train)

## Symptom

Pre-iter2 audit revealed **17 issues** in the sessions/alerts pipeline — a mix of correctness regressions, cross-platform feature gaps, and one GDPR-shaped data-retention gap. The most user-visible:

1. **Webhook type-filter completely broke notifications** — UI offered `cost_spike|quota_exceeded|session_long|device_offline` slugs; edge function did exact-string `includes()` against real `alert.type` values like `Cost Spike` and `Helper Offline`. Any user toggling filters silenced ALL their webhooks.
2. **Webhook fan-out tied to client-side notification delivery** — `sendWebhook` only fired inside `DataRefreshManager.sendNotification`, which itself was gated behind `notificationsEnabled` and required the macOS app to be foreground. Android: nothing. App closed: nothing. Cron-generated alerts: nothing.
3. **`project_hash` discarded on insert** — `helper_sync` INSERT column list omitted the field even though `HelperDaemon.sessionToDict` shipped it; yield_score join broken since v0.14 (2026-04-17) for cloud sessions.
4. **Static `cpu-spike-global` id** — once user resolved the device-CPU alert, helper_sync's ON CONFLICT preserved `is_resolved`, so future spikes upserted into the resolved row and never surfaced.
5. **Per-project budget alert overcounting** — `evaluate_budget_alerts` summed lifetime `sessions.estimated_cost` filtered by `last_active_at >= week_start`, meaning a multi-week stale session contributed its entire cumulative cost to "this week" and re-fired budget alerts on stale data.
6. **Android had no budget alerts at all** — never called `evaluate_budget_alerts` RPC; only Swift clients did.
7. **Android polling burned battery** — `while(true) { delay(30_000) }` in 5 ViewModels, no lifecycle awareness.
8. **Helper concurrent-sync race** — no DB-level lock; LoginItem + Xcode debug helper running together would race `helper_sync`'s "end missing sessions" sweep and partially mark each other's sessions Ended.
9. **Single helper partial scan ghost-end** — non-empty `helper_sync` immediately marked any not-reported running session Ended, with no grace window.

Plus: webhook edge had dead-code dedup, no auth on the planned internal-trigger path (SSRF risk), `xmax`-based plan was wrong idiom (Postgres `AFTER INSERT` doesn't fire on `ON CONFLICT DO UPDATE`'s UPDATE branch — guard would be dead code or worse), and the type-alias drift had no CI guard.

## Root cause / decisions

Architectural lessons from the dual-AI review:

- **Webhook fan-out belongs server-side, not client-side.** Client-side fan-out scoped to "while macOS app is foreground" silently broke for every other surface. The fix: alerts INSERT trigger → `webhook_jobs` queue → `pg_cron` worker → `send-webhook` edge function. This makes Android, watchOS, and cron-time alerts all reachable, and lets us add real dedup/retry/observability in the queue table.
- **`AFTER INSERT FOR EACH ROW` triggers do NOT fire for the `ON CONFLICT DO UPDATE` UPDATE branch in Postgres.** Codex caught a subtle error in Plan v1 where I'd added an `xmax` guard "just in case." Removed.
- **Header-based "internal trigger" auth is spoofable.** The cron worker MUST send `Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>` AND the edge MUST verify it before trusting `body.user_id`. Both reviewers flagged this.
- **Cascade-by-FK is the right answer for GDPR delete.** `daily_usage_metrics.user_id REFERENCES profiles(id) ON DELETE CASCADE` already handles erasure when `delete_user_account` runs `delete from auth.users`. Adding redundant explicit DELETEs is noise; the right move is a CI script that asserts the invariant for every new table.
- **A $20-per-session "clamp" doesn't fix the wrong-data-source problem.** When the budget evaluator pulls from a column with the wrong semantics, capping its values is putting lipstick on a pig. The right fix is to disable that branch until `daily_project_metrics` exists; ship with `evaluate_budget_alerts` returning `alerts_created=0` for the per-project path.

## Changes (11)

### Server-side / SQL

| Change | File | Effect |
|---|---|---|
| 3 | `migrate_v0.25_*.sql` (helper_sync) | Adds `project_hash` column to INSERT; ON CONFLICT preserves prior value via COALESCE for older helpers. |
| 5 | `migrate_v0.25_*.sql` (helper_sync) | `pg_advisory_xact_lock` per `device_id` so two helper instances can't race the Ended sweep. |
| 10 | `migrate_v0.25_*.sql` (helper_sync) | Non-empty Ended sweep now requires `last_active_at < now() - interval '10 minutes'` — same floor the empty-sweep already had. Closes ghost-end on partial scans. |
| 6 | `migrate_v0.25_*.sql` (evaluate_budget_alerts) | Per-project block short-circuited; cost-spike block keeps running and now also gates on `is_resolved = false` so resolving a spike doesn't silence next day's spike. |
| 2a | `migrate_v0.25_*.sql` (webhook fan-out) | New `public.webhook_jobs` queue table + `alerts_enqueue_webhook` AFTER INSERT trigger + `process_webhook_jobs` cron worker scheduled every 30s. Partial unique index on `(user_id, grouping_key) where processed_at is null` provides 60s server-side dedup. |

### Edge function

| Change | File | Effect |
|---|---|---|
| 1 | `functions/send-webhook/index.ts` | `TYPE_ALIASES` map for slug→emitted-type. Covers `Cost Spike`/`Project Budget Exceeded`/`Usage Spike`/`Quota Warning`/`Session Too Long`/`Helper Offline`. |
| 2b | same | Two-path auth: internal-trigger callers MUST present `Authorization: Bearer <service-role>` + `X-Internal-Trigger: alerts_dispatch_webhook`; client callers verified via JWT as before. Removed dead 60s suppression_key dedup probe. |

### Client (Swift / CLIPulseCore)

| Change | File | Effect |
|---|---|---|
| 7 | `AlertGenerator.swift` | `cpu-spike-global` → `cpu-spike-<deviceID>-<hour>`. Hourly bucket rotates id so re-spike after resolve creates a new row; `deviceID` qualifier keeps multi-device users' alerts independent. `now` and `deviceID` are injectable for tests. |
| 7 | `HelperDaemon.swift` | Passes `HelperConfig.deviceId.uuidString` (or hostname fallback) into `AlertGenerator.generate(...)`. |
| 2c | `AppState.swift` | New `serverSideWebhookEnabled: Bool` AppStorage flag, default `true`. Kill-switch only — when `true`, `DataRefreshManager.sendNotification` skips inline `api.sendWebhook` because the server trigger handles it. |
| 2c | `DataRefreshManager.swift` | Inline `api.sendWebhook` call is now gated behind `!serverSideWebhookEnabled` — default behavior is server-side fan-out. |

### Android (Kotlin)

| Change | File | Effect |
|---|---|---|
| 8 | `SupabaseClient.kt` | New `evaluateBudgetAlerts()` RPC wrapper. |
| 8 | `AlertsViewModel.kt` | Calls `maybeEvaluateBudgetAlerts()` before each refresh, throttled to once per 5 minutes via in-memory `lastBudgetEvalAtMs`. Best-effort; failures don't block. |
| 9 | `LifecyclePollingEffect.kt` (new) | Centralised `LifecycleEventObserver` — `ON_START → setPolling(true)`, `ON_STOP → setPolling(false)`. |
| 9 | 5× ViewModels (`SessionsViewModel`, `AlertsViewModel`, `OverviewViewModel`, `ProvidersViewModel`, `DevicesViewModel`) | Each gets `_isPolling: MutableStateFlow<Boolean>(true)` + `setPolling(active)`. Polling loop respects the flag. |
| 9 | 5× Composables (`SessionsScreen`, `AlertsScreen`, `OverviewScreen`, `ProvidersScreen`, `DevicesScreen`) | Each invokes `LifecyclePollingEffect(viewModel::setPolling)` at top. |

### CI

| Change | File | Effect |
|---|---|---|
| 11 | `ci_check_alert_types.py` (new) | Drift guard: walks Swift+SQL for emitted `alert.type` literals; fails if any aren't covered by edge's `TYPE_ALIASES`. |
| 4 | `ci_check_user_id_cascade.py` (new) | GDPR right-to-erasure cascade audit: every `public.*` table with a `user_id uuid` column must reference profiles(id)/auth.users(id) `ON DELETE CASCADE`. Currently 14 tables verified. |

## Files changed

### Modified

| File | Change |
|------|--------|
| `backend/supabase/functions/send-webhook/index.ts` | Type-alias map; Bearer-auth two-path; removed dead 60s dedup probe |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertGenerator.swift` | cpu-spike id scheme; injectable `now` + `deviceID` params |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift` | `serverSideWebhookEnabled` AppStorage flag |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift` | Inline webhook call now gated behind kill-switch |
| `CLI Pulse Bar/CLIPulseHelper/HelperDaemon.swift` | Passes `HelperConfig.deviceId` into `AlertGenerator.generate` |
| `CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/AlertGeneratorTests.swift` | 2 new tests: hour rotation + device scoping |
| `android/app/src/main/java/com/clipulse/android/data/remote/SupabaseClient.kt` | `evaluateBudgetAlerts()` |
| `android/app/src/main/java/com/clipulse/android/ui/sessions/SessionsViewModel.kt` | `_isPolling` + `setPolling` |
| `android/app/src/main/java/com/clipulse/android/ui/alerts/AlertsViewModel.kt` | `_isPolling` + `setPolling` + 5min budget-RPC throttle |
| `android/app/src/main/java/com/clipulse/android/ui/overview/OverviewViewModel.kt` | `_isPolling` + `setPolling` |
| `android/app/src/main/java/com/clipulse/android/ui/providers/ProvidersViewModel.kt` | `_isPolling` + `setPolling` |
| `android/app/src/main/java/com/clipulse/android/ui/devices/DevicesViewModel.kt` | `_isPolling` + `setPolling` |
| `android/app/src/main/java/com/clipulse/android/ui/sessions/SessionsScreen.kt` | `LifecyclePollingEffect(viewModel::setPolling)` |
| `android/app/src/main/java/com/clipulse/android/ui/alerts/AlertsScreen.kt` | same |
| `android/app/src/main/java/com/clipulse/android/ui/overview/OverviewScreen.kt` | same |
| `android/app/src/main/java/com/clipulse/android/ui/providers/ProvidersScreen.kt` | same |
| `android/app/src/main/java/com/clipulse/android/ui/devices/DevicesScreen.kt` | same |
| `PROJECT_DEV_PLAN_2026-04-27_sessions_alerts_hardening.md` | v1 → v2 (full rewrite incorporating Gemini-3-Pro + Codex review) |

### Added

| File | Purpose |
|------|---------|
| `backend/supabase/migrate_v0.25_sessions_alerts_hardening.sql` | helper_sync hardening, evaluate_budget_alerts rewrite, webhook_jobs queue + trigger + cron |
| `backend/supabase/ci_check_alert_types.py` | Drift guard for `TYPE_ALIASES` map |
| `backend/supabase/ci_check_user_id_cascade.py` | GDPR cascade audit |
| `android/app/src/main/java/com/clipulse/android/ui/components/LifecyclePollingEffect.kt` | Shared lifecycle-toggle helper |
| `PROJECT_FIX_2026-04-27_sessions_alerts_iter2.md` | This file |

### Infrastructure (deploy-time, NOT in git)

- Supabase project `gkjwsxotmwrgqsvfijzs`: `app.supabase_url` and `app.service_role_key` GUCs need to be set via `alter database <db> set app.supabase_url = '<url>'; alter database <db> set app.service_role_key = '<key>'` before the trigger's outbound HTTP works. Migration logs a notice and skips when unset (safe for branch DBs / tests).
- pg_cron must be enabled on the project (it already is per existing `migrate_v0.21_cleanup_cron.sql`).

## Verification

### Automated

- `swift test --package-path "CLI Pulse Bar/CLIPulseCore"`
  → **489 tests, 0 failures, 1 skipped** (the 2 new `AlertGeneratorTests` cases included).
- `python3 backend/supabase/ci_check_search_path.py` → OK (every non-legacy SECURITY DEFINER function pinned).
- `python3 backend/supabase/ci_check_rpc_contract.py` → OK (32 SQL functions, 32 client call sites).
- `python3 backend/supabase/ci_check_date_windows.py` → OK (32 SQL files, rolling windows match Swift contract).
- `python3 backend/supabase/ci_check_alert_types.py` → ok: 6 emitted alert.type strings all covered by TYPE_ALIASES.
- `python3 backend/supabase/ci_check_user_id_cascade.py` → ok: 14 public.* tables with user_id all cascade-covered to auth.users.
- `swift build --package-path "CLI Pulse Bar/CLIPulseCore"` → BUILD SUCCEEDED.

### Manual (run before pushing migration to prod)

Server side:

1. Deploy migration v0.25 to a Supabase branch DB. Confirm `helper_sync`, `evaluate_budget_alerts`, `process_webhook_jobs`, and the `alerts_enqueue_webhook` trigger all created. Confirm `pg_cron` shows the `process_webhook_jobs` schedule.
2. With service-role key set as the `app.service_role_key` GUC: insert a fake row into `public.alerts` for a test user → `webhook_jobs` should get a row within ~30s → cron worker fires → edge function logs "200 sent" or 500 (depending on user's webhook config).
3. Test the dedup: insert 2 rows with the same `(user_id, grouping_key)` within 60s → second insert no-ops on the partial unique index.
4. Test the type filter: configure `webhook_event_filter = {"types": ["cost_spike"]}`, insert a `Project Budget Exceeded` alert → fires; insert a `Quota Warning` → no fire.

Client side:

5. macOS app foreground: trigger a real `Cost Spike` alert via the cron path → confirm the user gets exactly ONE webhook (server trigger fires; client `sendWebhook` is gated off by `serverSideWebhookEnabled = true` default).
6. Toggle `serverSideWebhookEnabled = false` (debug-only): confirm inline path still works as fallback.
7. Resolve a `cpu-spike-<deviceID>-<hour>` alert → wait an hour → spike again → new alert with new id appears (was: silently suppressed by `is_resolved=true` on the static id).

Android side:

8. First launch after this update: `AlertsViewModel.refresh()` triggers `evaluate_budget_alerts` → if user has cost-spike conditions met, the alert appears in the feed.
9. Second refresh within 5 minutes: `maybeEvaluateBudgetAlerts` returns without RPC call (verify via Charles or `tail -F /var/log/supabase/...`).
10. Background the app for 1 minute: confirm the polling loop in any of the 5 ViewModels stops hitting Supabase (verify via Logcat http logging).

## Rollout sequence

1. Migrate Supabase: `psql -f backend/supabase/migrate_v0.25_sessions_alerts_hardening.sql`. Set GUCs.
2. Deploy edge function: `supabase functions deploy send-webhook`.
3. Ship macOS/iOS client (carries `serverSideWebhookEnabled=true` default + new cpu-spike id). User-visible: nothing (defaults preserve behavior).
4. Ship Android app (lifecycle polling + budget RPC).
5. Watch `webhook_jobs` table for `last_error` populated rows for 1 release cycle.
6. After confidence: delete `api.sendWebhook` and the kill-switch flag.

## Risk

- **pg_net failure modes** are the highest-risk surface. If the cron worker can't reach the edge function, jobs accumulate with `attempt_count=3` ceiling. We log into `last_error`. Mitigation: monitoring query `select count(*) from webhook_jobs where attempt_count >= 3 and processed_at is null` should be added to the dashboard.
- The `cpu-spike` id rename will leave any currently-resolved `cpu-spike-global` alerts orphaned in the feed forever — they'll never get auto-resolved by the helper because the new ids don't match. Acceptable: those alerts will age out of the 50-row `alerts()` query window naturally as new alerts come in, OR the user can manually delete them. If we want to clean them up explicitly, ship a one-time `delete from alerts where id = 'cpu-spike-global' and is_resolved = true` in a hotfix migration. Defer to user feedback.

## Iter2 follow-ups (post-implementation review)

After landing the 11 changes, the implementation diff was sent back to
Gemini 3 Pro and Codex for verification. Both flagged a mix of real
runtime bugs and tighter-correctness amendments. All landed on the same
branch:

### P0 (would have broken in production)

1. **`ON CONFLICT ON CONSTRAINT` syntax error** (Codex + Gemini, both
   independent). Postgres rejects `ON CONFLICT ON CONSTRAINT <name>` when
   `<name>` is a partial unique index, not a named constraint. The trigger
   would have raised on every alert insert and the `EXCEPTION WHEN OTHERS`
   block would have *silently swallowed* the error — webhook fan-out
   completely broken with no visibility. **Fix**: replaced the `on conflict`
   clause with an explicit `EXISTS` pre-check; the partial unique index
   still protects against truly concurrent races (caught by the
   `unique_violation` exception arm, which is now distinct from the
   generic `OTHERS` arm so a real failure raises a `WARNING`).
   `migrate_v0.25_*.sql:310-326,342-353`

2. **Cost-spike "infinite respawn" loop** (Gemini, independent). The
   added `is_resolved = false` filter combined with a date-keyed
   `suppression_key` (`costspike:<uid>:<date>`) meant: user clicks
   Resolve → next 30s refresh finds no UNRESOLVED row → re-inserts a
   duplicate with a fresh UUID. Today's spike alert could never be
   silenced. **Fix**: per next finding, the entire cost-spike block was
   short-circuited.

3. **Cost-spike same lifetime-cost flaw as per-project block** (Gemini,
   independent). `sessions.estimated_cost` is per-session CUMULATIVE.
   A session active today that started yesterday has its full lifetime
   cost shift OUT of `last_active_at < current_date` and INTO
   `last_active_at >= current_date` just by being touched once today.
   Yesterday's number gets crushed; today's gets inflated; `today >
   2 * yesterday` fires nearly every time. The fix in Plan v2 only
   patched the per-project block — same root cause as cost-spike and
   the iter2 patch missed it. **Fix**: `evaluate_budget_alerts` now
   short-circuits BOTH blocks and returns `alerts_created = 0`. Re-enable
   in iter3 once `daily_project_metrics` (or a project column on
   `daily_usage_metrics`) exists. `migrate_v0.25_*.sql:182-219`

4. **CI scripts not wired into GitHub workflow** (Codex, independent).
   `ci_check_alert_types.py` and `ci_check_user_id_cascade.py` existed
   on disk but `.github/workflows/supabase-ci.yml` stopped after the
   date-windows step. The drift guards weren't actually enforced at
   merge time. **Fix**: added two new jobs to the workflow + extended
   the `paths:` triggers to include `AlertGenerator.swift`,
   `Models.swift`, `DemoDataProvider.swift` so changes in those files
   trip the alert-types CI. `.github/workflows/supabase-ci.yml`

5. **`ci_check_alert_types.py` allow-list filter silently ignored
   unknown types** (Codex, independent). The script filtered emitted
   types through `ALERT_TYPES_CANONICAL`, so anything new was dropped
   on the floor instead of failing CI. Also: Plan v2 specified scanning
   `Models.swift` enum cases via `case \w+ = "..."` regex but the
   script didn't include it (Gemini). **Fix**: rewrote to fail on
   unknown emitted types; explicit opt-out via `WEBHOOK_INELIGIBLE`
   dict (each entry has a written reason); now scans Models.swift
   `enum AlertType` block, AlertGenerator.swift, DemoDataProvider.swift,
   DataRefreshManager.swift, app_rpc.sql.

### P1 (correctness improvements)

6. **Android budget throttle moved Repository → ViewModel** (Gemini).
   ViewModels are scoped to `NavBackStackEntry` and get destroyed on
   tab navigation, dropping the 5-minute throttle. **Fix**: moved
   `lastBudgetEvalAtMs` + `maybeEvaluateBudgetAlerts()` to
   `@Singleton DashboardRepository`; `AlertsViewModel` now injects
   the repository and calls through it. AlertsViewModelTest updated to
   inject a mocked repository.

7. **`process_webhook_jobs` async-semantics bug** (Codex). The prior
   loop called `extensions.http_post()` and immediately marked
   `processed_at = now()`, but pg_net is itself async — that recorded
   "queued for dispatch" not "delivered to webhook target." **Fix**:
   added `pg_net_request_id BIGINT` and `dispatched_at TIMESTAMPTZ`
   columns; rewrote the worker as a two-pass dispatcher (Pass 1:
   reconcile dispatched jobs against `net._http_response`, finalising
   2xx and retrying non-2xx; Pass 2: dispatch new jobs and stash
   request_id). Jobs older than 5 minutes with no response are
   considered timed out and re-dispatched.
   `migrate_v0.25_*.sql:355-475`

8. **pg_cron 6-field syntax may not work everywhere** (Codex). The
   `'*/30 * * * * *'` form requires pg_cron's seconds-resolution code
   path, which not all Supabase configs enable. **Fix**: switched to
   pg_cron's interval form (`'30 seconds'`), which is broadly supported
   from pg_cron 1.5+ and avoids the seconds-resolution code path
   entirely.

9. **Rollout window double-send** (Codex). During the period between
   the migration shipping and the new macOS client rolling out, OLD
   clients still POST `send-webhook` directly with their JWT, while
   the trigger ALSO enqueues. The partial unique index only dedups
   trigger-driven inserts; old clients bypass it. **Fix**: re-added a
   60s dedup probe in the edge function for the client-path only. It
   queries `webhook_jobs` for a row with the same
   `(user_id, grouping_key)` enqueued in the last 60s and skips with
   `reason: "dedup (server trigger already enqueued)"`. Internal-trigger
   callers don't probe (they're the canonical source).

10. **Discord webhook 400 on `content: null`** (Gemini). Discord's
    webhook API rejects payloads where `content` is explicitly null.
    **Fix**: omit the `content` key entirely from the Discord embed
    payload (it's optional when embeds are present).
    `send-webhook/index.ts:152-167`

### Verdict on Iter2 follow-up

After all 9 amendments, all 5 CI checks pass:

- `ci_check_search_path.py` → OK
- `ci_check_rpc_contract.py` → OK
- `ci_check_date_windows.py` → OK
- `ci_check_alert_types.py` → ok: 6 emitted types covered, 7 explicit opt-outs
- `ci_check_user_id_cascade.py` → ok: 14 tables covered

`swift test`: 489 tests, 0 failures, 1 skipped.
`swift build`: BUILD SUCCEEDED.

## Open follow-ups (out of scope for this iter; punted to iter3)

- `local-<pid>` ID stability — needs `local-<pid>-<startTimeEpoch>` and a UserDefaults migration for any persisted suppression keys.
- Webhook DNS-rebinding fix — needs DNS resolution + per-IP filter inside the edge runtime.
- `AlertSuppression` keyed by `suppression_key` instead of `id`.
- iOS NavigationSplitView selection by id (UI polish).
- Quota alert generator port to Android — depends on whether to move generator into SQL.
- `evaluate_budget_alerts` per-project re-enable — needs `daily_project_metrics` (or a `project` column on `daily_usage_metrics` + backfill).
