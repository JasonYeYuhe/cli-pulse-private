# PROJECT DEV PLAN — Remote Approvals Push Notifications (iOS)

**Status:** code committed locally on `codex/remote-approvals-push`, **not pushed**, migration **not applied** to live Supabase.
**Date:** 2026-04-29.
**Audience:** internal — successor agents, reviewers, the user.

This is the design + handoff doc for adding APNs push notifications to the
Phase 1 Remote Approvals feature so users don't have to keep an app open
to catch the 10s Claude PermissionRequest hook window.

## Same-account auto-match conclusion (verified)

Phase 1 schema **already** supports "iOS app and Mac app, signed into the
same Supabase account, automatically share the same user's pending
approvals" with no additional pairing. The audit:

| RPC | Scope query | iOS needs device_id? |
|-----|-------------|---------------------|
| `remote_app_list_pending_approvals` | `where user_id = auth.uid()` | No |
| `remote_app_decide_permission` | `where id = p_request_id and user_id = auth.uid()` | No |
| `remote_app_send_command` | `select device_id from remote_sessions where id = p_session_id and user_id = auth.uid()` | No (looked up via session_id) |
| `remote_helper_create_permission_request` (helper-side) | `device_id + helper_secret → user_id`, writes both | Helper provides own |

**iOS never needs `helper_secret` and never needs to know any specific
`device_id`.** Mac helper writes its own `device_id` because that's
what the helper RPC contract requires for auth.

**No schema changes were needed for auto-match.** This file is purely
about adding the push notification layer on top.

The single visibility gap fixed in v0.32: `list_pending_approvals` now
joins `devices.name` so multi-Mac users can tell which Mac fired which
request (UI shows it as secondary text on each row).

## Architecture (committed in this branch)

```
helper hook fires
    ↓ remote_helper_create_permission_request RPC (gated on remote_control_enabled)
remote_permission_requests INSERT (status='pending')
    ↓ AFTER INSERT trigger: remote_request_after_insert_push
        ├── re-check user_settings.remote_control_enabled    [defense layer 2]
        ├── skip if no app_push_tokens for this user
        ├── insert app_push_jobs row
        └── net.http_post → /functions/v1/send-approval-push  [immediate]
            ↓ edge function send-approval-push
                ├── re-check remote_control_enabled         [defense layer 3]
                ├── load app_push_tokens for user
                ├── load APNs vault secrets (team_id, key_id, p8 PEM, topic)
                ├── build APNs JWT (ES256 token-based auth)
                ├── build PAYLOAD (no sensitive content; see payload.ts)
                ├── POST https://api.push.apple.com/3/device/<token>
                ├── 2xx → set notified_at on remote_permission_requests
                ├── 410 BadDeviceToken → delete from app_push_tokens
                └── other → record generic error string, leave for cron retry
                          ↓ Apple Push Notification Service
                              ↓ user's iOS device (banner)
                                  ↓ tap → app foreground
                                      ↓ iOSAppDelegate routes to settings tab
                                          ↓ refreshRemoteApprovals fires immediately

(parallel) pg_cron `app_push_jobs_drain` every 30s:
    Pass 1: reconcile dispatched jobs against net._http_response
    Pass 2: re-dispatch jobs the trigger failed to fire (rare)
```

## Privacy / security posture

This work does not lower the Phase 1 bar. New invariants:

- **Push payload contains zero sensitive content.** Full list of banned
  substrings enforced by `assertPayloadIsClean` (deno-tested):
  `tool_name`, `tool_input`, `summary`, `command`, `provider`, `cwd`,
  `cwd_basename`, `cwd_hmac`, `session_id`, `user_id`, `device_id`,
  `device_name`, `helper_secret`, `«REDACTED»`. Only `request_id` (a
  UUID) crosses the wire as routing metadata.
- **`request_id` shape-validated** — only `[0-9a-fA-F-]{1,64}`. Defends
  against an attacker who somehow gets a non-UUID into the column from
  exfiltrating data via the routing field.
- **APNs tokens are device-globally unique.** `app_push_tokens.token`
  has `UNIQUE` constraint and `register_app_push_token` does
  `ON CONFLICT(token) DO UPDATE SET user_id = auth.uid()` — when a
  different user signs into the same iPhone, the token row transfers to
  the new user atomically. Old user's pending requests stop pushing to
  that device. Tested by inspection of the `INSERT ... ON CONFLICT` clause.
- **`unregister_app_push_token` is identity-locked.** Server-side
  `delete from app_push_tokens where token = p_token and user_id = auth.uid()`
  — calling user can only delete tokens they own. Non-owned tokens are
  silently no-op (don't leak "this token belongs to user X").
- **Three-layer Remote Control gate.** Helper RPC (Phase 1), trigger
  function (this PR), edge function (this PR). Toggle off → no enqueue,
  no APNs.
- **No edge logs of payload content.** Only `request_id`, HTTP status
  code, and generic error tokens (`network`, `410`, `http_400`, etc.).
- **`devices.push_token` / `push_platform` continues to be dead.** v0.10
  added these columns; nothing populates or reads them. We use a
  separate `app_push_tokens` table because helper devices and app
  installs are different entity types (one user → many helpers, one
  user → many iPhones). Cleanup of the dead columns is a separate PR.

## Why `unique(token)` instead of `unique(user_id, platform, token)`

Because APNs tokens are bound to the physical iPhone, not the user.
The same token can be issued to user A first, then user B if A logs
out and B logs in on the same iPhone. If we keyed by
`(user_id, platform, token)`, both rows would coexist; user A's
pending requests would push to user B's iPhone after the switch.
The `unique(token)` invariant + `ON CONFLICT(token) DO UPDATE` makes
ownership transfer atomic and prevents that leak.

## Why device-level Remote Control is deferred

Current model: `user_settings.remote_control_enabled` (single boolean
per user). Multi-Mac users get all-or-nothing.

Risks of all-or-nothing are bounded in practice:
- Helper hook must be wired into each Mac's `~/.claude/settings.json`
  individually. A Mac without the hook never fires a request.
- Helper auth is per-device (`helper_secret`). A stolen Mac that hasn't
  been re-paired can't impersonate.

Backlog: add `devices.remote_control_enabled boolean` defaulting to
NULL. Semantics:
- NULL = inherit user-level (current behavior; no migration breakage)
- TRUE = explicitly on for this Mac
- FALSE = explicitly off for this Mac (override)

Combined gate: `user_setting = true AND (device.remote_control_enabled IS DISTINCT FROM false)`.
The trigger here naturally inherits the upgraded gate when this lands —
no rework. Tracked separately so this push PR stays scoped.

## Files changed

### New
- `backend/supabase/migrate_v0.32_remote_approvals_push.sql` — schema + RPCs + trigger + cron worker + list_pending join
- `backend/supabase/functions/send-approval-push/payload.ts` — pure payload builder + privacy assertion helper
- `backend/supabase/functions/send-approval-push/payload_test.ts` — 9 deno tests pinning privacy contract
- `backend/supabase/functions/send-approval-push/index.ts` — edge function entry (APNs JWT + dispatch)
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/PushTokenSync.swift` — pure helpers (token hex, length checks, platform identifier)
- `CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/PushTokenSyncTests.swift` — 10 tests (8 helper, 2 model decode)
- `CLI Pulse Bar/CLI Pulse Bar iOS/iOSAppDelegate.swift` — UIApplicationDelegateAdaptor + UNUserNotificationCenterDelegate

### Modified
- `backend/supabase/ci_check_rpc_contract.py` — internal helper allowlist
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Models.swift` — `RemotePermissionRequest.device_name` optional
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/APIClient.swift` — `registerAppPushToken` / `unregisterAppPushToken`
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift` — `@Published registeredPushToken`
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift` — `requestNotificationPermission` now also calls `registerForRemoteNotifications` (iOS only); new `syncPushToken` / `unregisterPushTokenOnLogout`
- `CLI Pulse Bar/CLI Pulse Bar iOS/CLIPulseApp_iOS.swift` — `@UIApplicationDelegateAdaptor(iOSAppDelegate.self)`
- `CLI Pulse Bar/CLI Pulse Bar/RemoteApprovalsSheet.swift` — render device_name
- `CLI Pulse Bar/CLI Pulse Bar iOS/iOSRemoteApprovalsView.swift` — render device_name
- `CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj` — add iOSAppDelegate.swift to iOS target

## Validation results

| Check | Result |
|-------|--------|
| `pytest helper/test_remote_hook + test_system_collector + test_permissions_diagnose` | **69 passed** |
| `swift test --package-path CLIPulseCore` | **508 passed**, 1 skipped (489 + 9 entry-state + 10 push helpers) |
| `deno test backend/supabase/functions/send-approval-push/payload_test.ts` | **9 passed** |
| `ci_check_rpc_contract` | OK |
| `ci_check_search_path` | OK (4 new SECURITY DEFINER functions all pinned) |
| `ci_check_user_id_cascade` | OK (21 user_id tables cascade — was 19, now +app_push_tokens, +app_push_jobs) |
| `ci_check_alert_types` | OK |
| `ci_check_date_windows` | OK |
| xcodebuild Mac | BUILD SUCCEEDED |
| xcodebuild iOS Simulator | BUILD SUCCEEDED |
| xcodebuild Watch Simulator | BUILD SUCCEEDED |
| xcodebuild Widgets | BUILD SUCCEEDED |
| `git diff --check` | OK |

## Live APNs smoke (NOT performed in this PR — requires manual Apple Developer setup)

This commit is deployment-ready code; live APNs verification needs
out-of-band Apple Developer + Supabase Vault configuration.

### Step 1 — Apple Developer

1. Sign in at <https://developer.apple.com/account/resources/authkeys/list>
2. Create a new Auth Key with "Apple Push Notifications service (APNs)"
   capability. Save the `.p8` file (only downloadable once).
3. Note `Team ID` (10-char alphanumeric, top-right of developer portal)
   and `Key ID` (10-char alphanumeric, in the auth-keys list).
4. Confirm iOS app's Bundle Identifier (`yyh.CLI-Pulse-iOS` or whatever
   `Bundle.main.bundleIdentifier` reports). This is the APNs `topic`.

### Step 2 — Xcode iOS target capabilities

Open the iOS target → Signing & Capabilities → "+ Capability" → Push
Notifications. Xcode auto-adds `aps-environment` to a generated
entitlements file when this is signed with a development cert. We
intentionally did NOT modify `CLI_Pulse_iOS.entitlements` in this PR
to avoid breaking Release / TestFlight signing — the user adds the
capability through Xcode's UI and it gets handled per-config.

### Step 3 — Supabase Vault secrets

```sql
-- One-time, run as the project owner (or via Supabase Dashboard SQL editor)
select vault.create_secret('THE_TEAM_ID',                    'apns_team_id', 'Apple Developer Team ID');
select vault.create_secret('THE_KEY_ID',                     'apns_key_id', 'APNs Auth Key ID');
select vault.create_secret(
  '-----BEGIN PRIVATE KEY-----' || E'\n' ||
  '...contents of AuthKey_<KeyID>.p8 file...' || E'\n' ||
  '-----END PRIVATE KEY-----',
  'apns_p8_pem', 'APNs Auth Key PEM');
select vault.create_secret('yyh.CLI-Pulse-iOS',              'apns_topic_ios', 'Default APNs topic when bundle_id is missing');
-- Optional: 'apns_host' = 'api.sandbox.push.apple.com' for development env
```

### Step 4 — Deploy edge function

```bash
supabase functions deploy send-approval-push --project-ref gkjwsxotmwrgqsvfijzs
```

(or via the Supabase Dashboard upload flow).

### Step 5 — Apply migration

```sql
-- Either via Dashboard SQL editor or psql:
\i backend/supabase/migrate_v0.32_remote_approvals_push.sql
```

### Step 6 — End-to-end smoke

1. Build + install the iOS app on a real iPhone (push doesn't work in
   Simulator). Sign in with the same Supabase account that's running
   on the Mac.
2. Toggle Remote Control on in iOS → Settings → Privacy.
3. Confirm `select * from app_push_tokens where user_id = '<your-uid>'`
   has one row.
4. On Mac, with the helper running and the hook wired in
   `~/.claude/settings.json`, run a Claude Code command that triggers a
   PermissionRequest (e.g. a Bash command without an Always-Allow rule).
5. Within ~2 seconds the iPhone should show "CLI Pulse approval needed"
   banner.
6. Tap the banner → app opens to Settings tab → "Pending Approvals"
   link has a count badge → tap → see the request → Approve.
7. Mac's Claude Code receives the allow decision before the 10s hook
   timeout.

### Step 7 — Confirm privacy

```sql
-- Should show notified_at populated, and notification_last_error null
-- Should NOT show any tool_name/cwd/summary in any logged column
select
  id, status, notification_queued_at, notified_at,
  notification_attempts, notification_last_error
from remote_permission_requests
order by created_at desc limit 5;

-- Edge function logs: only request_id / status / generic error tokens
-- View at: Supabase Dashboard → Edge Functions → send-approval-push → Logs
```

If any of `tool_name`, `cwd`, `summary`, `command`, etc. appears in
edge logs, we have a regression — the deno tests should have caught it
but verify in production once.

## Phase 2+ backlog (NOT this PR)

| Item | Why not now |
|------|-------------|
| Mac native push (NSApplicationDelegateAdaptor + APNs) | iOS first; Mac plumbs the same edge function with `platform='macos'` later |
| Notification action buttons (Approve / Deny inline) | UNNotificationCategory + UNNotificationAction wiring; out of scope for "pure visibility" goal |
| Localised payload (title-loc-key / loc-key) | English-only fine for MVP; CLIPulseCore L10n already exists for an extension |
| Notification merging when multiple pending land in <10s | APNs already collapses by `thread-id`; banner count via badge value is a follow-up |
| `devices.remote_control_enabled` per-device override | Backlog (separate PR; trigger + RPC gate auto-inherits new gate) |
| `devices.push_token` / `push_platform` dead column cleanup | Trivial DROP; separate PR |
| `decided_by_device_id` column re-purpose | Currently always NULL; keep optional for now |

## Decision log

- **app_push_tokens separate table, NOT extending `devices`**: helper
  device != app install. One user can pair 1+ Macs as helpers AND have
  1+ iPhones with the app — different cardinalities, different auth
  models. Separate table keeps each clean.
- **Immediate-first dispatch**: cron alone is insufficient (30s ≫ 10s
  hook timeout). pg_net call from trigger fires within ~1s of helper
  RPC commit. Cron is retry/backfill only.
- **No `aps-environment` in checked-in entitlements**: Release vs Debug
  needs different values; managing per-config in pbxproj is messy.
  User enables Push capability via Xcode UI which generates the right
  entitlement per signing cert.
- **No live APNs verification in this PR**: requires real Apple
  Developer .p8 + Supabase Vault config + real iPhone. Code is
  validation-tested + deployment-ready; live smoke is the next step
  the user runs manually.
