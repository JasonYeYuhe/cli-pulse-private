# DEV PLAN — Mobile on-plan status (iOS + Android parity for v1.35 managed-Codex on-plan)

**Date:** 2026-07-01 · **Owner directive:** build the mobile counterpart of the v1.35 macOS
managed-session work (view/control Mac sessions + on-plan status from the phone), first
principles, plan-first. Android eventually ships to **both Play + GitHub**.

## First-principles framing (what's actually missing)
The v1.35 work (managed Codex/Gemini "on your plan") is **macOS-helper-only**. Mapping the
codebase (backend + helper + iOS + Android + macOS-ref + gating) shows:
- **Both iOS and Android already have full remote managed-session UIs** (list/start/stream/stop
  via `remote_app_*` RPCs + a live terminal). So "the mobile session feature" already exists.
- The **one genuine gap corresponding to v1.35**: the per-provider **on-plan / off-plan signal
  (`provider_plan_status`) never leaves the Mac.** It's computed by the helper and surfaced
  ONLY over the local UDS `hello` reply → consumed ONLY by the macOS menu-bar picker
  (`SessionsTab.swift:252-266`). It is in **zero** backend SQL, not on iOS, not on Android.
- Consequence: when you start a managed **Codex** session **on your Mac from your phone**
  (`remote_app_request_session_start` already accepts `codex`), the phone can't warn that Codex
  will run **billed on the OpenAI API instead of your ChatGPT plan** — the exact warning macOS
  shows. **That warning is the feature.**

So: **plumb `provider_plan_status` (a `{provider: "on_plan"|"off_plan"}` map, "unknown" omitted)
from the helper → cloud → phones, and render the off-plan Codex warning in the iOS + Android
spawn pickers**, mirroring macOS exactly.

## Why this rides the LIVE path (no R0 dependency, no new gate)
There are two DISTINCT gates and one always-on path:
- `user_settings.remote_control_enabled` (v0.27, default false) — gates ALL `remote_helper_*` /
  `remote_app_list_*` session RPCs.
- `user_settings.realtime_private_enabled` (v0.56 R0, owner-gated, not yet applied) — gates the
  live realtime *terminal streaming* only.
- **Device-status path: `helper_heartbeat` → `devices` → mobile `select`/`dashboard_summary` /
  `provider_summary` — behind NEITHER gate. Always on.** This is the SAME proven pipe that
  already ships `provider_quotas.plan_type` to phones.

We attach on-plan status to the **device row** (a device capability, latest-wins), via the
heartbeat. Verdict from the mapping's gating agent: **GO** — additive, ungated, no secret
(on_plan/off_plan is a login-mode label, not a credential; `devices` is RLS-scoped to the user).

## UX spec (mirror macOS exactly — do NOT invent new UI)
From `SessionsTab.swift:252-274` / `LocalSessionControlState.swift:88`:
- Field: `providerPlanStatus: [String:String]`, values only `"on_plan"`/`"off_plan"`;
  **"unknown" is represented by ABSENCE** (map default `[:]`/`{}`).
- The ONLY visible effect: in the **new-session provider picker**, the **Codex** row label
  becomes `"Codex — OpenAI API (billed, not your plan)"` with `exclamationmark.triangle` iff
  `planStatus["codex"] == "off_plan"`. Otherwise plain `"Codex"`.
- **No affirmative "on-plan" UI** (no green badge). `on_plan` and absent render identically.
- The check is strictly `== "off_plan"`. Keyed off the **spawn target device's** map (mobile
  starts are always remote → read the selected device's `provider_plan_status`).
- **Do NOT conflate** with `ProviderUsage.plan_type` (subscription tier "Pro"/"Max", already an
  orange badge) — different concept, different source.
- Out of scope on mobile: the macOS Claude-API **version-floor** banner
  (`localHelperBelowOAuthFloor`) — that's a separate mechanism (helper < 1.20.0), local-helper
  only; phones have no local helper.

## Slices

### Slice 1 — Backend (`backend/supabase/migrate_v0.60_device_provider_plan_status.sql`)
- `alter table public.devices add column if not exists provider_plan_status jsonb not null
  default '{}'::jsonb;` (devices already RLS-SELECT-scoped to `auth.uid()=user_id`; `helper_secret`
  is the only excluded column — new column is user-visible, intended.)
- Extend `helper_heartbeat` to accept `p_provider_plan_status jsonb default '{}'::jsonb` and set
  it in the UPDATE.
  - **GOTCHA (feedback_supabase_function_body_drift):** `pg_get_functiondef` the LIVE
    `helper_heartbeat` first. v0.57 dropped an *insecure* overload — confirm only the
    `(uuid,text,int,int,int)` signature is live, then **DROP that + CREATE** the 6-arg version
    (a defaulted trailing param creates an OVERLOAD in PG, not a replacement → ambiguity; drop
    the 5-arg to keep exactly one).
  - **Re-GRANT execute to `anon, authenticated`** (helper calls via the anon key — see v0.53).
    Keep `SECURITY DEFINER` + the `(device_id, sha256(helper_secret))` auth check unchanged.
- pgTAP test (owner-run harness) — column exists + heartbeat writes the jsonb.
- **Apply to prod = OWNER-GATED** (flag; don't apply autonomously per feedback_cli_pulse_autonomy).
  Migration is additive + backward-compatible (old helpers omit the param → default `{}`).

### Slice 2 — Helper publish (Python + Swift; BOTH, or the last heartbeater clobbers to `{}`)
- **Python** `helper/cli_pulse_helper.py heartbeat()` (~L274-285): compute
  `provider_plan_statuses()` (already imported by `local_session_server.py:818`), pass as
  `p_provider_plan_status`. Fail-soft (`except → {}`).
- **Swift (macOS app)** — NOT the HelperSwift package daemon (it disclaims heartbeat,
  `main.swift:298-303`); the live heartbeat is the app's `CLIPulseHelper/HelperDaemon.swift`
  (~L171) → `CLIPulseCore/HelperAPIClient.swift heartbeat()` (~L61-74). Add
  `providerPlanStatus: [String:String]` param → `"p_provider_plan_status"`.
  - **OPEN Q for impl:** where does the app-side heartbeat COMPUTE the map? `ManagedSessionManager
    .providerPlanStatus()` lives in HelperKit — confirm it's linkable from HelperDaemon; if not,
    add a small `ProviderPlanStatus.compute()` in **CLIPulseCore** (reuse
    `CodexQuotaFetcher.extractAccessToken` to read `~/.codex/auth.json` auth_mode==chatgpt; agy
    resolvable → gemini on_plan) so BOTH the heartbeat and any future client share one impl.
- Tests: Python (heartbeat payload includes the map); Swift (HelperAPIClient params).

### Slice 3 — iOS (`CLI Pulse Bar iOS` + CLIPulseCore)
- Decode: add `providerPlanStatus: [String:String]` to `DeviceRecord` (`Models.swift:682`) +
  `DeviceRecordPayload` (`APIClient.swift:340`), populated in `APIClient.devices()` from the new
  `provider_plan_status` jsonb (default `[:]`).
- UI: `iOSSessionsTab.swift` new-session provider picker (iPhone `managedSection` ~L135-158 +
  iPad toolbar ~L421-444): Codex row off-plan label mirroring `SessionsTab.swift:254-274`, keyed
  off `targetDeviceForStart.providerPlanStatus["codex"] == "off_plan"`. Optional secondary:
  `ManagedSessionDetailView.header` (~L1267) for an already-spawned off-plan session.
- Tests: DeviceRecord decode (present/absent/on_plan/off_plan); a picker-label unit check if
  feasible.

### Slice 4 — Android (`com.clipulse.android`)
- Model: add `val providerPlanStatus: Map<String,String> = emptyMap()` to
  `data/model/DeviceRecord.kt`.
- Decode: `data/remote/SupabaseClient.kt devices()` (~L271-285) parse the jsonb via org.json
  (`iterate keys()`); + Room `cached_devices` entity (`CacheEntities.kt`) so cache round-trips it
  (serialize map as a JSON string column; migrate the Room DB version).
- State/UI: expose on `ManagedSessionsUiState`; render the off-plan Codex label in the
  `ManagedSessionsScreen` spawn picker (same copy + a warning icon).
- Tests: JVM unit test for the org.json decode; Room migration test.

## Testing & the on-device gap (be honest)
- Backend: pgTAP (owner-run) + a local `execute_sql` probe on a branch if available.
- Helper: `pytest` (Python) + `swift test` (CLIPulseCore/HelperKit).
- iOS: `swift test` for CLIPulseCore decode; `xcodebuild build` iOS target. **Cannot** do a
  device/simulator GUI smoke on this headless Mac (see feedback_gui_computer_use_blocked_headless).
- Android: `./gradlew testDebugUnitTest` + `assembleRelease` build. **Cannot** run an emulator
  smoke here.
- So mobile ships on **build + unit-test + backend-probe** confidence; the visual picker check is
  an owner device-smoke item (documented, not blocking the PR).

## Ship plan (all owner-gated at the store step)
1. Land Slices 1-4 as reviewed PRs to `main` (CI green). Backend migration authored; **apply to
   prod owner-gated**.
2. Version bump (next minor, e.g. 1.36.0 / build 86 / android code 52 / helper 1.23.0) across
   platforms via the sync path.
3. Ship: iOS→ASC (build+upload+submit), Android→**Play + GitHub-release APK**, macOS DEVID+MAS
   for helper parity. Each store submission = **notify + confirm** (feedback_appstore_update),
   and mobile is untestable here so I'll flag that explicitly.

## Non-goals
- No new remote-terminal work (already exists). No R0 realtime cutover. No affirmative on-plan
  badge. No Claude version-floor banner on mobile. No change to `provider_quotas.plan_type`.

## Review outcomes (2026-07-01)
**Codex: GO-WITH-CHANGES** (adopted in full):
1. Backend: DROP the live 5-arg helper_heartbeat (+ defensively the old (uuid,uuid,...) overload) then CREATE with new param; reapply SECURITY DEFINER+search_path; GRANT execute anon,authenticated; update schema.sql + helper_rpc.sql (not just the migration).
2. **`p_provider_plan_status jsonb default NULL`** (NOT '{}') + `set provider_plan_status = coalesce(p_provider_plan_status, provider_plan_status)` — old callers omitting the arg no longer clobber; a failed compute preserves last-known.
3. Validate/normalize server-side: keep only known provider keys with values in ('on_plan','off_plan'); coalesce so a bad payload can't fail the NOT NULL column.
4. Clobber nuance: Python (.pkg, legacy config) vs app login-item usually differ by device_id, but edge cases exist — `default null` is the defense.
5. Swift heartbeat sources the map from the local UDS `hello` (reuse LocalSessionControlClient in CLIPulseCore — linked into CLIPulseHelper) instead of a new sandboxed auth.json parser. MAS login item (sandboxed) can't read auth.json anyway; hello is unauthenticated+gate-bypassed.
6. UX strictly target-device (no global warning, no plan_type, no green badge); DROP the optional detail-screen banner (would lie after auth changes unless snapshotted at start).
7. **No Android Room bump** — extend the existing `serializeDevice`/`parseDevice` JSON blob in DashboardRepository.kt.
8. Defensive decode both clients (object-only, keys→string on_plan/off_plan; iOS decodeIfPresent so old persisted DeviceRecord JSON doesn't fail).

**Gemini 3.1 Pro:** review stalled/no-return; its specialty (realtime RLS) doesn't apply to this ungated device-heartbeat feature. Proceeding on Codex's review; will fold in Gemini if it returns before PRs finalize.
