# Iteration 2 Dev Plan — Sessions & Alerts hardening (v2)

**Date:** 2026-04-27 (v2: 2026-04-27 evening, post Gemini-3-Pro + Codex review)
**Target:** `helper_sync` RPC, `evaluate_budget_alerts` RPC, `send-webhook` edge function, `delete_user_account` audit, Android alert/budget parity, `cpu-spike` id scheme, CI guard.
**Scope:** P0 + P1 fixes from the 2026-04-27 dual-AI review. v2 incorporates Gemini-3-Pro and Codex's amendments to v1.
**Ships across:** 1 branch, 1 SQL migration (v0.25), 1 edge function rewrite, 1 helper-package update (Swift), 1 Android update, 1 CI script.

## Why v2 (what changed since v1)

- **Change 2 trigger design rewritten** — Codex correctly observed `AFTER INSERT FOR EACH ROW` triggers in Postgres do **not** fire for the `ON CONFLICT DO UPDATE` branch (it fires `AFTER UPDATE` instead). The `xmax` guard from v1 is therefore dead code. Removed.
- **Change 2 auth tightened** — header-only `X-Internal-Trigger` is spoofable. v2 requires the edge function to validate `Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}` *and then* read the header. Caught by both reviewers.
- **Change 2 fan-out moved to queue** — Gemini's amendment: introduce `public.webhook_jobs` + a `pg_cron` worker, instead of direct `pg_net.http_post` from inside the helper_sync transaction. Same table doubles as the rollout-window 60s dedup (Codex's N3).
- **Change 4 simplified** — Gemini correctly noted `daily_usage_metrics.user_id REFERENCES profiles(id) ON DELETE CASCADE` already covers the GDPR delete via the `delete from auth.users` at the end of `delete_user_account`. v2 drops the explicit DELETE but keeps a written user_id-column audit as a PR-time gate.
- **Change 6 reverted** — Codex correctly pointed out a $20 clamp doesn't fix the wrong-data-source problem. Long-running sessions still get their multi-week lifetime cost mis-attributed to the current week. v2 short-circuits the per-project budget block until `daily_project_metrics` exists. Cost-spike block keeps running (it uses today/yesterday windows, no cross-week leakage).
- **Change 7 device-scoped id** — Codex caught: `cpu-spike-global-<hour>` collides across multiple devices for the same user. v2 scopes the id by `device_id`.
- **Change 8 throttled** — both reviewers want a 5-minute in-memory throttle on Android's budget RPC call instead of running it every 30s polling cycle.
- **Change 9 broadened** — Codex caught: only Sessions/Alerts ViewModels were targeted in v1, but Overview/Providers/Devices ViewModels have the same `while(true) { delay(30_000) }` pattern. v2 uses `repeatOnLifecycle(STARTED)` and covers all 5.
- **Change 10 new** — v1 didn't address S1 (single-helper partial-sync ghost-end). v2 adds the same 10-minute grace to the non-empty `helper_sync` sweep.
- **Change 11 new** — `ci_check_alert_types.py` drift guard so the type-alias map can't silently rot when a generator adds a new alert.type.
- **Change 1 alias coverage broadened** — v1's map missed `Helper Offline` (the actual emitted type per [Models.swift:110](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/Models.swift:110)) and the `Usage Spike` orphan (UI has no chip for it). v2 maps both.

## P0 — must-fix this iteration

### Change 1 — webhook type-filter alias map

**File:** `backend/supabase/functions/send-webhook/index.ts`
**Severity:** S1 — any user enabling type filters silences ALL their webhooks today.

UI offers `cost_spike|quota_exceeded|session_long|device_offline` (`GeneralSection.swift:186`, `SettingsScreen.kt:307`). Real `alert.type` strings, by grep:

| Generator | type emitted |
|---|---|
| `AlertGenerator.swift:35,61` | `Usage Spike` |
| `AlertGenerator.swift:80` | `Session Too Long` |
| `AlertGenerator.swift:122`, `app_rpc.sql:321` | `Project Budget Exceeded` |
| `AlertGenerator.swift:139`, `app_rpc.sql:360` | `Cost Spike` |
| `AlertGenerator.swift:197` | `Quota Warning` |
| `Models.swift:110`, `DemoDataProvider.swift:105` | `Helper Offline` |

UI chip "cost_spike" must cover both `Cost Spike` and `Project Budget Exceeded` (intentionally grouped for users), AND `Usage Spike` (which has no UI chip — must be reachable through some slug). Mapping:

```ts
const TYPE_ALIASES: Record<string, string[]> = {
  cost_spike:     ["Cost Spike", "Project Budget Exceeded", "Usage Spike"],
  quota_exceeded: ["Quota Warning"],
  session_long:   ["Session Too Long"],
  device_offline: ["Helper Offline"],
};

function shouldSendAlert(alert, filter) {
  if (!filter) return true;
  if (filter.severities?.length && !filter.severities.includes(alert.severity)) return false;
  if (filter.types?.length) {
    const matched = filter.types.some(slug =>
      (TYPE_ALIASES[slug] ?? [slug]).includes(alert.type ?? "")
    );
    if (!matched) return false;
  }
  if (filter.providers?.length && alert.related_provider && !filter.providers.includes(alert.related_provider)) return false;
  return true;
}
```

**Tests:** `tests/edge/send-webhook.spec.ts` (new) — 4-case matrix (each slug × matching/non-matching alert.type).

### Change 2 — webhook fan-out via `webhook_jobs` queue + Bearer auth

**Files:**
- `backend/supabase/migrate_v0.25_sessions_alerts_hardening.sql` (new — see Change 5/10/3 also)
- `backend/supabase/functions/send-webhook/index.ts`
- `CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift`
- `CLIPulseCore/Sources/CLIPulseCore/APIClient.swift`

**Severity:** S1 — webhooks today only fire if the macOS app is foreground+notifications-enabled. Android, watchOS, closed-client, and cron-generated alerts get no webhook.

#### 2a. New table + cron worker (in v0.25 migration)

```sql
create table public.webhook_jobs (
  id              bigserial primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  alert_id        text not null,
  alert_payload   jsonb not null,
  enqueued_at     timestamptz not null default now(),
  processed_at    timestamptz,
  attempt_count   int not null default 0,
  last_error      text
);
-- 60s dedup index — prevents the same (user, grouping_key) from queuing twice
-- inside the rollout-window where old client + new trigger both fire.
create unique index idx_webhook_jobs_dedup
  on public.webhook_jobs (user_id, (alert_payload->>'grouping_key'))
  where processed_at is null;
create index idx_webhook_jobs_pending on public.webhook_jobs (enqueued_at)
  where processed_at is null;

-- Trigger: AFTER INSERT only. Postgres auto-skips ON CONFLICT DO UPDATE branch
-- (it fires AFTER UPDATE, which we don't register for). Per Codex/Gemini:
-- no xmax guard needed.
create or replace function public.alerts_enqueue_webhook()
returns trigger as $$
begin
  if NEW.type is null or NEW.type = 'Test' then
    return NEW;
  end if;
  insert into public.webhook_jobs (user_id, alert_id, alert_payload)
  values (NEW.user_id, NEW.id, jsonb_build_object(
    'id', NEW.id, 'type', NEW.type, 'severity', NEW.severity,
    'title', NEW.title, 'message', NEW.message,
    'related_provider', NEW.related_provider,
    'related_project_name', NEW.related_project_name,
    'grouping_key', NEW.grouping_key,
    'suppression_key', NEW.suppression_key,
    'created_at', NEW.created_at
  ))
  on conflict do nothing;  -- 60s dedup
  return NEW;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

drop trigger if exists alerts_webhook_enqueue on public.alerts;
create trigger alerts_webhook_enqueue
  after insert on public.alerts
  for each row execute function public.alerts_enqueue_webhook();

-- Cron worker: every 30 seconds, drain pending jobs.
-- Process inside the worker by calling the edge function with a service-role
-- bearer; results write back to webhook_jobs.last_error / processed_at.
-- Implementation note: pg_net.http_post is itself queued + async, so the
-- worker just enqueues outbound HTTPs in pg_net's queue. We then mark
-- processed_at when pg_net's response is recorded. This keeps the
-- transactional cost on alerts INSERT to ~0.
create or replace function public.process_webhook_jobs()
returns void as $$
declare
  v_job record;
  v_url text := current_setting('app.supabase_url', true);
  v_key text := current_setting('app.service_role_key', true);
begin
  if v_url is null or v_key is null then
    raise notice 'process_webhook_jobs: not provisioned';
    return;
  end if;
  for v_job in
    select id, user_id, alert_id, alert_payload
    from public.webhook_jobs
    where processed_at is null
      and (last_error is null or attempt_count < 3)
      and enqueued_at < now() - interval '5 seconds'  -- give helper_sync xact a moment to commit
    order by id
    limit 100
  loop
    begin
      perform net.http_post(
        url := v_url || '/functions/v1/send-webhook',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_key,
          'X-Internal-Trigger', 'alerts_dispatch_webhook'
        ),
        body := jsonb_build_object('user_id', v_job.user_id, 'alert', v_job.alert_payload),
        timeout_milliseconds := 5000
      );
      update public.webhook_jobs
        set processed_at = now(), attempt_count = attempt_count + 1
        where id = v_job.id;
    exception when others then
      update public.webhook_jobs
        set attempt_count = attempt_count + 1, last_error = sqlerrm
        where id = v_job.id;
    end;
  end loop;
end;
$$ language plpgsql security definer set search_path = pg_catalog, net, public;

-- Schedule via pg_cron. 30s gives sub-minute fan-out without DDOSing pg_net.
select cron.schedule('process_webhook_jobs', '*/30 * * * * *', $$select public.process_webhook_jobs()$$);
```

Note: `app.supabase_url` and `app.service_role_key` GUCs are set via `alter database ... set ...` in the same migration but with values pulled from a Supabase secret env at deploy time, NOT committed to the migration file. The migration only sets `current_setting(..., true)` (the trailing `true` returns NULL on missing, which the function handles).

#### 2b. Edge function — verify Bearer first, then accept internal-trigger

```ts
const authHeader = req.headers.get("authorization");
const internalTrigger = req.headers.get("x-internal-trigger");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

let user_id_authoritative: string;

if (internalTrigger === "alerts_dispatch_webhook") {
  // Server-side trigger path: require service-role bearer.
  if (authHeader !== "Bearer " + serviceKey) {
    return new Response(JSON.stringify({ error: "Forbidden — internal-trigger requires service role" }), { status: 403 });
  }
  // Trust body.user_id since the trigger built it.
  const { user_id, alert } = await req.json();
  user_id_authoritative = user_id;
  // ...
} else {
  // Client-side path (test webhooks): existing JWT path.
  // ...
}
```

#### 2c. Client side — feature-flag the inline webhook

`DataRefreshManager.sendNotification(for:)` currently calls `api.sendWebhook(alert:)` inline. To avoid double-fire during rollout:

```swift
// new on AppState (or SubscriptionManager / dedicated FeatureFlags struct):
@AppStorage("cli_pulse_server_side_webhook_enabled") public var serverSideWebhookEnabled: Bool = true

// in DataRefreshManager.sendNotification:
if !serverSideWebhookEnabled, webhookEnabled, !webhookURL.isEmpty {
    Task { try? await api.sendWebhook(alert: alert) }
}
```

Default to true so anyone on a fresh install gets server-side. The flag exists as a kill-switch if the trigger has a bad day.

`api.testWebhook()` keeps the old JWT path so users can hit "Send test webhook" and verify their URL works without going through the alert-insert pipeline.

#### 2d. Rollout order

1. Migration v0.25 ships first (idempotent — drops/re-creates trigger; queue table is new).
2. Edge function `send-webhook` ships with Bearer-auth + internal-trigger path.
3. macOS/iOS clients ship with `serverSideWebhookEnabled = true` default.
4. Android keeps doing nothing webhook-side (it never had it) — server trigger now covers it.

During the window between step 1 and step 3, old clients still call the inline path. Edge function deduplicates because `webhook_jobs.idx_webhook_jobs_dedup` blocks duplicate inserts within 60s for the same `(user_id, grouping_key)`.

### Change 3 — `helper_sync` writes `project_hash`

**File:** `backend/supabase/migrate_v0.25_sessions_alerts_hardening.sql` (in same migration)

**Severity:** S2 — yield_score has been broken for cloud sessions since v0.14 (2026-04-17). Helper computes the HMAC and ships it; RPC ignores it.

```sql
-- in helper_sync, REPLACE the sessions INSERT block with:
insert into public.sessions (
  id, user_id, device_id, name, provider, project, status,
  total_usage, estimated_cost, requests, error_count,
  collection_confidence, project_hash,
  started_at, last_active_at, synced_at
)
values (
  left(v_session->>'id', 128), v_user_id, p_device_id,
  coalesce(v_session->>'name', ''), v_session->>'provider',
  coalesce(v_session->>'project', ''), coalesce(v_session->>'status', 'Running'),
  coalesce((v_session->>'total_usage')::integer, 0),
  least(greatest(coalesce((v_session->>'exact_cost')::numeric, 0), 0), 9999),
  coalesce((v_session->>'requests')::integer, 0),
  coalesce((v_session->>'error_count')::integer, 0),
  coalesce(v_session->>'collection_confidence', 'medium'),
  nullif(v_session->>'project_hash', ''),
  least(coalesce((v_session->>'started_at')::timestamptz, now()), now() + interval '10 minutes'),
  least(coalesce((v_session->>'last_active_at')::timestamptz, now()), now() + interval '10 minutes'),
  now()
)
on conflict (id, user_id) do update set
  name = excluded.name, status = excluded.status,
  total_usage = excluded.total_usage, estimated_cost = excluded.estimated_cost,
  requests = excluded.requests, error_count = excluded.error_count,
  collection_confidence = excluded.collection_confidence,
  project_hash = coalesce(excluded.project_hash, public.sessions.project_hash),
  last_active_at = excluded.last_active_at, synced_at = now();
```

Tests: `tests/sql/test_helper_sync_project_hash.sql` — assert that a sync containing `"project_hash": "abc..."` lands in the row.

**Backfill:** none. `project_hash = HMAC(user_secret, abs_path)` and historical rows have no abs_path; user secret is per-device so cross-device backfill is meaningless either way.

### Change 4 — `delete_user_account` user_id audit

**File:** PR description (no code change in this iter)

**Severity:** S1 (compliance), but **already covered by cascade**.

Gemini-3-Pro confirmed `daily_usage_metrics.user_id NOT NULL REFERENCES profiles(id) ON DELETE CASCADE`, and `profiles.id REFERENCES auth.users(id) ON DELETE CASCADE` (verify in `schema.sql`). The final `delete from auth.users` therefore wipes:

- profiles (cascade)
- daily_usage_metrics (cascade)
- commits (cascade)
- session_commit_links (cascade through commits)
- yield_score_daily (cascade)
- usage_snapshots (cascade)
- ... etc.

**v2 change:** instead of bloating `delete_user_account` with redundant DELETEs, ship a `backend/supabase/ci_check_user_id_cascade.py` that programmatically inspects every `public.*` table with a `user_id` column and asserts the FK chain ultimately reaches `auth.users` with cascade. CI fail → schema regression caught at merge time.

### Change 5 — `helper_sync` advisory lock per device

**File:** `backend/supabase/migrate_v0.25_sessions_alerts_hardening.sql`

```sql
-- at top of helper_sync, after the auth check:
perform pg_advisory_xact_lock(hashtextextended(p_device_id::text, 0));
```

Tests: `tests/sql/test_helper_sync_advisory_lock.sql` — open two transactions calling helper_sync for the same device; second blocks until first commits.

### Change 6 — disable per-project budget block

**File:** `backend/supabase/migrate_v0.25_sessions_alerts_hardening.sql`

**Severity:** S2 — current per-project block fires false positives because it sums lifetime `sessions.estimated_cost` for any session active in the last 7 days. Multi-week sessions get the entire history mis-attributed to "this week." A simple clamp doesn't fix the wrong-source problem.

```sql
-- replace evaluate_budget_alerts to short-circuit the per-project loop.
-- Cost-spike block still runs (today/yesterday window, no cross-week issue).
create or replace function public.evaluate_budget_alerts()
returns jsonb as $$
declare
  v_user_id uuid := auth.uid();
  v_alert_count integer := 0;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;

  -- Per-project block: temporarily disabled until daily_project_metrics exists
  -- (sessions.estimated_cost is a lifetime cumulative number that doesn't
  -- correctly bucket by week). Re-enable in iter3 once we have a daily-bucketed
  -- per-project source.

  -- Cost spike block: keep — uses today vs yesterday windows.
  declare
    v_today_cost numeric;
    v_yesterday_cost numeric;
    v_spike_key text := 'costspike:' || v_user_id || ':' || current_date;
  begin
    select coalesce(sum(estimated_cost), 0) into v_today_cost
    from public.sessions
    where user_id = v_user_id
      and last_active_at >= current_date and last_active_at < current_date + interval '1 day';
    select coalesce(sum(estimated_cost), 0) into v_yesterday_cost
    from public.sessions
    where user_id = v_user_id
      and last_active_at >= current_date - interval '1 day'
      and last_active_at < current_date;
    if v_yesterday_cost >= 1.0 and v_today_cost > v_yesterday_cost * 2 then
      if not exists (
        select 1 from public.alerts
        where user_id = v_user_id and suppression_key = v_spike_key and is_resolved = false
      ) then
        insert into public.alerts (id, user_id, type, severity, title, message,
          suppression_key, grouping_key)
        values (
          gen_random_uuid()::text, v_user_id,
          'Cost Spike', 'Warning',
          'Unusual cost spike detected',
          'Today''s cost ($' || round(v_today_cost::numeric, 2) ||
            ') is more than 2x yesterday ($' || round(v_yesterday_cost::numeric, 2) || ')',
          v_spike_key, 'costspike:daily'
        );
        v_alert_count := v_alert_count + 1;
      end if;
    end if;
  end;

  return jsonb_build_object('alerts_created', v_alert_count);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public, extensions;
```

Note the existence check now also requires `is_resolved = false` — fixes Plan v1's A9 finding (resolved spike alert should not silence next day's spike). Same idiom should be applied to per-project block when re-enabled in iter3.

### Change 7 — `cpu-spike` id scoped by device + hour

**File:** `CLIPulseCore/Sources/CLIPulseCore/AlertGenerator.swift`

**Severity:** S2 — current static `cpu-spike-global` id never re-fires after first resolve (helper_sync ON CONFLICT preserves `is_resolved`).

```swift
#if os(macOS)
public static func generate(
    device: DeviceMetrics.Snapshot,
    sessions: [SessionRecord],
    sessionCPU: [String: Double] = [:],
    deviceID: String = ProcessInfo.processInfo.hostName,   // injected for testability
    now: Date = Date()
) -> [[String: Any]] {
    var alerts: [[String: Any]] = []
    let nowStr = sharedISO8601Formatter.string(from: now)
    let hourBucket = Int(now.timeIntervalSince1970 / 3600)

    if device.cpuUsage >= 85 {
        let stableID = "cpu-spike-\(deviceID)-\(hourBucket)"
        alerts.append([
            "id": stableID,
            "type": "Usage Spike",
            "severity": "Warning",
            "title": "Device CPU usage is elevated",
            "message": "helper sampled CPU usage at \(device.cpuUsage)%.",
            "created_at": nowStr,
            "source_kind": "device",
            "grouping_key": "Usage Spike:device:\(deviceID)",
            "suppression_key": stableID,
        ])
    }
    // ... rest unchanged ...
```

Caller in `HelperDaemon.collectAndSync()` passes the helper's actual `device_id` from `HelperConfig` (not the hostname):

```swift
let alerts = AlertGenerator.generate(
    device: device, sessions: scanResult.sessions, sessionCPU: scanResult.sessionCPU,
    deviceID: HelperConfig.load()?.deviceId ?? ProcessInfo.processInfo.hostName
)
```

Tests: `AlertGeneratorTests.testCpuSpikeIdRotatesByHour`, `testCpuSpikeIdScopedByDevice` — golden-time + golden-device-id covering rotation and per-device isolation.

## P1 — ships in same iter

### Change 8 — Android budget RPC with 5min throttle

**File:** `android/app/src/main/java/com/clipulse/android/data/remote/SupabaseClient.kt`, `…/data/repository/DashboardRepository.kt`

```kotlin
// SupabaseClient.kt
suspend fun evaluateBudgetAlerts(): Int {
    val response = postRpc("evaluate_budget_alerts", emptyMap<String, Any>())
    return (response["alerts_created"] as? Number)?.toInt() ?: 0
}

// DashboardRepository.kt — singleton, in-memory throttle:
@Singleton
class DashboardRepository @Inject constructor(...) {
    private var lastBudgetEvalAtMs: Long = 0L
    private val budgetEvalCooldownMs = 5 * 60 * 1000L

    suspend fun maybeEvaluateBudgetAlerts() {
        val now = System.currentTimeMillis()
        if (now - lastBudgetEvalAtMs < budgetEvalCooldownMs) return
        lastBudgetEvalAtMs = now
        runCatching { supabase.evaluateBudgetAlerts() }
    }
}
```

Call site: `AlertsViewModel.refresh()` calls `repository.maybeEvaluateBudgetAlerts()` before `supabase.alerts()`.

### Change 9 — Android polling lifecycle

**Files:** all 5 polling ViewModels:
- `ui/sessions/SessionsViewModel.kt`
- `ui/alerts/AlertsViewModel.kt`
- `ui/overview/OverviewViewModel.kt`
- `ui/providers/ProvidersViewModel.kt`
- `ui/devices/DevicesViewModel.kt`

Pattern: replace each `init { startAutoRefresh() }` with a `MutableStateFlow<Boolean> isPolling` toggled by the host Composable's lifecycle. Polling loop respects the flag.

```kotlin
// In each ViewModel:
private val _isPolling = MutableStateFlow(false)

init {
    refresh()
    viewModelScope.launch {
        while (true) {
            if (_isPolling.value) {
                runCatching { supabase.sessions() }.onSuccess { sessions ->
                    _state.value = _state.value.copy(sessions = sessions, error = null)
                }
            }
            delay(30_000)
        }
    }
}

fun setPolling(active: Boolean) { _isPolling.value = active }
```

```kotlin
// In each Composable:
@Composable
fun SessionsScreen(viewModel: SessionsViewModel = hiltViewModel()) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> viewModel.setPolling(true)
                Lifecycle.Event.ON_STOP -> viewModel.setPolling(false)
                else -> {}
            }
        }
        lifecycle.addObserver(obs)
        onDispose { lifecycle.removeObserver(obs) }
    }
    // ...
}
```

(Could also use `repeatOnLifecycle(STARTED)` directly in the Composable, but the ViewModel-state approach lets the loop continue running across config changes without restarting on rotation. Pick one consistently.)

### Change 10 — partial-sync 10-minute grace

**File:** `backend/supabase/migrate_v0.25_sessions_alerts_hardening.sql`

**Severity:** S2 — single-helper partial scan immediately ghost-ends sessions not in `v_synced_ids`. v1 missed this; Codex's N1.

```sql
-- replace the "non-empty sweep" branch in helper_sync:
if coalesce(array_length(v_synced_ids, 1), 0) > 0 then
  update public.sessions set status = 'Ended'
  where device_id = p_device_id and user_id = v_user_id
    and status = 'Running' and id != all(v_synced_ids)
    and last_active_at < now() - interval '10 minutes';   -- ← new grace
else
  update public.sessions set status = 'Ended'
  where device_id = p_device_id and user_id = v_user_id
    and status = 'Running' and last_active_at < now() - interval '10 minutes';
end if;
```

Both branches now use the same 10-minute floor. Symmetric semantics.

### Change 11 — `ci_check_alert_types.py`

**File:** `backend/supabase/ci_check_alert_types.py` (new)

**Severity:** maintenance — prevents the type-alias map from rotting.

Walks the repo, greps for `"type": "..."` and `'type', '...'` literals in `AlertGenerator.swift`, `DemoDataProvider.swift`, `Models.swift` (`AlertType` enum), and `app_rpc.sql`. Builds the union of emitted types. Loads `TYPE_ALIASES` from `send-webhook/index.ts` (parsed via regex). Asserts every emitted type appears in at least one alias-map value array. Fails CI with a diff if not.

```python
# backend/supabase/ci_check_alert_types.py
"""Drift guard: every emitted alert.type must be reachable through the
edge-function TYPE_ALIASES map. Run in CI before merge."""
import pathlib, re, sys

REPO = pathlib.Path(__file__).parents[2]

EMIT_PATTERNS = [
    (REPO / "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertGenerator.swift",
     re.compile(r'"type":\s*"([^"]+)"')),
    (REPO / "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DemoDataProvider.swift",
     re.compile(r'type:\s*"([^"]+)"')),
    (REPO / "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Models.swift",
     re.compile(r'case\s+\w+\s*=\s*"([^"]+)"')),
    (REPO / "backend/supabase/app_rpc.sql",
     re.compile(r"'(?:Cost Spike|Project Budget Exceeded|Quota Warning|Session Too Long|Usage Spike|Helper Offline)'")),
]

def main():
    emitted = set()
    for path, pat in EMIT_PATTERNS:
        if not path.exists():
            continue
        text = path.read_text()
        for m in pat.finditer(text):
            v = m.group(0).strip("'\"") if m.lastindex is None else m.group(1)
            if " " in v or any(c.isupper() for c in v):  # human-readable alert type
                emitted.add(v)
    # Filter to known alert-type strings (drop unrelated enum cases)
    alert_types = {t for t in emitted if t in {
        "Cost Spike", "Project Budget Exceeded", "Quota Warning",
        "Session Too Long", "Usage Spike", "Helper Offline"
    }}
    aliases_text = (REPO / "backend/supabase/functions/send-webhook/index.ts").read_text()
    alias_values = set(re.findall(r'"([^"]+)"', re.search(
        r'TYPE_ALIASES[^{]*\{([^}]+)\}', aliases_text, re.S).group(1)))
    missing = alert_types - alias_values
    if missing:
        print(f"FAIL: alert types not in TYPE_ALIASES: {sorted(missing)}", file=sys.stderr)
        sys.exit(1)
    print(f"ok: {len(alert_types)} alert types covered by TYPE_ALIASES")

if __name__ == "__main__":
    main()
```

Add to `.github/workflows/*` (or whatever CI runner is used) alongside the existing `ci_check_*.py` scripts.

## Tests

### SQL

- `tests/sql/test_helper_sync_project_hash.sql`
- `tests/sql/test_helper_sync_advisory_lock.sql`
- `tests/sql/test_helper_sync_partial_grace.sql` — assert that a sync with 1 reported session keeps a 5-min-old session Running, but ends a 15-min-old session.
- `tests/sql/test_alerts_webhook_enqueue.sql` — INSERT a row → webhook_jobs gets a row; INSERT a duplicate within 60s → no second row.
- `tests/sql/test_evaluate_budget_alerts_short_circuit.sql` — assert per-project never fires.

### Swift

- `AlertGeneratorTests.testCpuSpikeIdRotatesByHour`
- `AlertGeneratorTests.testCpuSpikeIdScopedByDevice`

### Edge

- `tests/edge/send-webhook.spec.ts` — TYPE_ALIASES coverage + Bearer-auth required for internal-trigger.

### Android

- `AlertsViewModelTest.testBudgetEvalThrottledTo5Minutes`
- `SessionsViewModelTest.testPollingPausesOnLifecycleStop` (and 4 more for Overview/Providers/Devices)

### CI

- `ci_check_alert_types.py` runs in the same CI step as `ci_check_rpc_contract.py`.

## Rollout sequence

1. **Migration v0.25** — single transaction. Smoke against branch DB first.
2. **Edge function send-webhook redeploy** — Bearer-auth path + alias map.
3. **macOS/iOS client release** with `serverSideWebhookEnabled=true` default + new cpu-spike id.
4. **Android release** with budget RPC + lifecycle polling.
5. After 1 release cycle of telemetry confirming no double-fires, drop `cli_pulse_server_side_webhook_enabled` AppStorage flag and remove the inline `api.sendWebhook` path.

## Risk / reversibility

| Change | Risk | Reversibility |
|---|---|---|
| 1 | Low | Re-deploy edge function |
| 2 | Med — pg_net + cron failure modes; webhook fan-out has external side-effects | Drop trigger + cron schedule; queue table can stay (idempotent) |
| 3 | Low | Revert migration; column already exists |
| 4 | None (CI-only) | Remove ci_check |
| 5 | Low | Revert migration |
| 6 | Low — conservative (disables a noisy alert) | Revert migration; rewires to old code |
| 7 | Low — fresh alerts only | Revert Swift change |
| 8 | Low — best-effort | Revert Kotlin change |
| 9 | Low — UI polish | Revert Kotlin change |
| 10 | Low | Revert migration |
| 11 | None (CI-only) | Remove file |

## Out of scope (explicitly punted)

- **`local-<pid>` ID stability (S5)** — needs `local-<pid>-<startTimeEpoch>` and a UserDefaults migration. Iter3.
- **Webhook DNS-rebinding fix (Gemini N5)** — needs DNS resolution + per-IP filter. Iter3.
- **`AlertSuppression` keyed by `suppression_key`** — UserDefaults schema change. Iter3.
- **iOS NavigationSplitView selection by id (S6)** — UI polish.
- **Quota alert generator port to Android (A6 second half)** — depends on whether to move generator into SQL. Iter3 architectural decision.
- **`evaluate_budget_alerts` per-project re-enable** — needs `daily_project_metrics` (or `project` column on `daily_usage_metrics`). Iter3.
