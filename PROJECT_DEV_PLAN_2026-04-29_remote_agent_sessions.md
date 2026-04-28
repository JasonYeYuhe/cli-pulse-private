# PROJECT DEV PLAN — Remote Agent Sessions / Remote Approvals (Phase 1 MVP)

**Status:** Phase 1 shipped (commit `bf74fa6` on private `main`, app v1.11.0/44).
Migrations v0.26-v0.31 applied to live Supabase (`gkjwsxotmwrgqsvfijzs`).
**Date archived:** 2026-04-29.
**Audience:** internal — successor agents (Codex Phase 2), reviewers, future me.

This is the post-mortem / handoff doc for the Remote Approvals MVP. It is
**private**; do not publish to `public/cli-pulse` or to the website.

## Problem

Users running Claude Code on their Mac wanted to approve / deny tool
calls from their phone or another Mac instead of always tabbing back to
the Mac terminal. Phase 1 needed to deliver an end-to-end Approve / Deny
loop for **Claude PermissionRequest hooks** with strict privacy posture
(no transcripts uploaded, default OFF, server-side gate) without
expanding scope into PTY-managed sessions or full remote desktop.

## What shipped (single commit `bf74fa6`)

1. **Backend migrations v0.26-v0.31** (Supabase, applied to live):
   - `v0.26` — 5 tables (`remote_sessions`, `remote_session_events`,
     `remote_session_commands`, `remote_permission_requests`,
     `remote_permission_decisions`) + 6 helper RPCs (device_id+helper_secret
     auth) + 3 app RPCs (auth.uid + RLS).
   - `v0.27` — `user_settings.remote_control_enabled boolean default false`
     + `_remote_authenticate_helper_gated()` + every helper RPC and the
     two app write RPCs re-emitted to enforce the gate.
   - `v0.28` — nightly retention cron at 03:47 UTC (events 7d / commands
     30d / requests 30d / sessions idle 60d / pending grace 60min).
   - `v0.29` — drop legacy `_remote_authenticate_helper` + gate
     `remote_app_list_pending_approvals` (cross-device race close).
   - `v0.30` — `remote_helper_register_session` ownership check on
     conflict (no silent overwrite of foreign user/device sessions).
   - `v0.31` — REVOKE EXECUTE on internal helpers + RLS policies use
     `(select auth.uid())` for query-plan caching + 4 missing FK indexes.
2. **Helper Python**: new `remote-approval-hook --provider claude`
   subcommand on `cli_pulse_helper.py`; `helper/remote_hook.py` with
   defensive top-level wrapper (NEVER leaves stdout empty);
   `helper/provider_adapters/{base,claude,codex,shell}.py` — full
   ClaudeAdapter (risk classifier, secret redaction inc. JWT, allow-shape
   per docs = behavior-only); Codex/shell are Phase-2 stubs;
   `helper/remote_agent.py` skeleton for Phase-2 PTY work; 43 pytest.
3. **Swift CLIPulseCore (shared)**: `RemoteSession*`, `RemotePermission*`
   Codable models; `APIClient.remoteListPendingApprovals` /
   `remoteDecidePermission` / `remoteSendCommand`; `AppState` with
   `remoteControlEnabled` + `remoteControlSaving` flag; atomic
   `setRemoteControlEnabled(_:)` (latest-intent-wins semantics — sync
   prologue, optimistic flip, PATCH, revert-on-failure, never let
   refreshYieldScore overwrite mid-flight).
4. **Mac UI**: `AdvancedSection` Privacy toggle + consent dialog;
   `MenuBarView` footer pending pill + `RemoteApprovalsSheet`
   (Disabled / Empty / List states); high-risk Approve disabled.
5. **iOS UI**: `iOSSettingsTab` Privacy toggle + consent + count badge;
   `iOSOverviewTab` banner; `iOSRemoteApprovalsView` with
   pull-to-refresh.
6. **App version bump**: 1.10.8/43 → 1.11.0/44 across iOS, macOS,
   Watch, Widgets, Helper, and Android (versionCode 21→22).

## Privacy / security posture (the bar Phase 2 must not lower)

- **Default OFF.** New users opt-out. Server-side gate enforced on every
  helper RPC and both app write RPCs. Toggling off in the UI severs the
  helper end of the channel — old or rogue helpers that don't refresh
  user_settings still get rejected.
- **Never uploaded:** provider API keys, OAuth tokens, cookies, full
  transcripts, full session log files, full project paths.
- **cwd:** only `basename` (last path component) + HMAC of full path
  (HMAC key = per-user secret on the Mac).
- **Tool-input redaction:** sk-ant / AIza / ghp / GitHub PAT / AWS /
  Bearer / JWT (eyJ three-segment) / long hex. Tracked deferred:
  sensitive-filename blocklist (`.env`, `id_rsa`, `*.pem`,
  `credentials.json`).
- **High-risk fail-closed:** rm -rf / sudo / curl / dd / mkfs / kextload
  / ssh / scp / chmod 777 — never round-trip; local prompt only. UI
  Approve button disabled even if a request did make it through.
- **Always-Allow three-layer defence:** server downgrade for Codex,
  hook ignores returned scope, adapter never emits `permissionUpdates`.
- **Hook output verified against** https://code.claude.com/docs/en/hooks
  (verified 2026-04-28). PermissionRequest only supports
  `behavior: "allow" | "deny"` — fallback uses deny + message (no "ask",
  which is PreToolUse-only).
- **Retention cron** prunes per-table data nightly (03:47 UTC, 20 min
  after the v0.22 retention job to avoid lock contention).

## Review history (5 iterations)

1. **Iter 1**: Schema design + helper hook + Claude adapter draft.
2. **Iter 2**: SQL fixes — `remote_helper_create_permission_request`
   silent-null on stale session_id, `remote_app_decide_permission` rejects
   expired requests; `_hmac_path` accepts bytes|str; full hex HMAC.
3. **Iter 3 (Gemini 3.1 Pro review)**: 9 findings.
   - **P0** Drop legacy `_remote_authenticate_helper` (footgun) → v0.29
   - **P0** Codex stub raise → empty stdout → top-level catch + raw
     deny fallback in `run_hook`
   - **P1** Optimistic decide-restore wipes new pending → single-row
     restore
   - **P1** JWT redaction hole → eyJ three-segment regex
   - **P2** `list_pending_approvals` RLS-only is leaky cross-device →
     v0.29 also gates the read RPC
   - **P2** Refresh await race → post-await guard
   - **P1** search_path public-position — deferred (codebase-wide
     convention; separate hardening task)
   - **P3** Sensitive-filename blocklist — deferred Phase 2
4. **Iter 4 (Codex review)**:
   - **P1** Atomic toggle → introduce `setRemoteControlEnabled(_:)`
     entry point + revert-on-failure
   - **P2** `remote_helper_register_session` foreign-session UPDATE → v0.30
     ownership check on conflict
   - **P2** PermissionRequest fallback shape verified against docs (no
     "ask" → use deny+message)
   - **P3** ci_check allowlist self-audit — done
5. **Iter 5 (Codex review)**:
   - **P1** Toggle race under overlapping requests → `remoteControlSaving`
     flag + sync prologue before Task launch + `refreshYieldScore` skips
     overwrite while saving
   - **P2** Claude allow shape — drop `message` from allow output (docs
     say message is "For deny only")
6. **Post-deploy advisor** (Supabase security + performance):
   - REVOKE EXECUTE on internal helpers — v0.31
   - RLS `(select auth.uid())` initplan optimization — v0.31
   - 4 unindexed FKs → indexes — v0.31

## Known carried-forward / deferred

- **search_path includes `public`** — codebase-wide convention since
  v0.17 (30+ functions). Single-table fix would be inconsistent. Tracked
  as a separate codebase-wide hardening task.
- **Sensitive filename blocklist** — Phase 2 (`.env`, `id_rsa`, `*.pem`).
- **Notarized build / App Store push** — not in this PR. Per memory
  (`feedback_appstore_update.md`): notify user, don't act autonomously.
  Version is bumped (1.11.0/44) but DMG / .ipa / TestFlight build is
  the user's call.
- **Public docs / website update** — none. By design (private feature
  internal docs only). If we want to advertise Remote Approvals on
  cli-pulse.com, that's a separate distribution-only PR on `public`.

## Phase 2 backlog (priority order, my read)

1. **PTY-managed session** — schema and command queue already exist
   (`remote_session_commands` / `remote_session_events`). Helper-side
   PTY runner needs `os.openpty()` + `subprocess.Popen` + `EventBatcher`
   wiring (skeleton in `helper/remote_agent.py`). This unlocks "send
   prompt remotely" / "stop / interrupt remote session". Highest
   product value — turns the feature from "approve only" into "drive a
   session from anywhere."
2. **iOS push notifications** — currently refresh-based polling.
   Approval prompts that fire mid-meeting take ~120s to surface.
   Replacing the Overview banner with a real APNs notification needs
   APNs cert + Supabase edge function + push_token sync (the helper
   already collects `push_token` per device). Big UX win.
3. **Codex full adapter** — Phase 2 stub raises NotImplementedError;
   wrapping is defensive. Real impl needs the `codex_hooks` feature
   flag enabled in the user's Codex install + Codex hook output spec
   (allow / deny only — Always Allow not exposed by Codex). Schema
   already supports `provider = 'codex'` everywhere.
4. **Sensitive filename blocklist** — `.env` / `id_rsa` / `*.pem` /
   `credentials.json` / `~/.aws/credentials` redaction in summary AND
   payload. Comment placeholder in `claude.py` `_REDACT_PATTERNS`.
5. **Always-Allow surface** — Claude supports `permissionUpdates`. We
   intentionally don't expose it remotely (wider blast radius).
   Decision deferred — would need explicit "create allowlist rule" UI
   with a much louder consent path.
6. **Codebase-wide search_path hardening** — separate task across all
   30+ SECURITY DEFINER functions, not just remote_*.
7. **Public docs / marketing page** — once Phase 2 lands, add a section
   to cli-pulse.com explaining Remote Control. Distribution-only PR.

## Files of record

| Concern                   | File                                                       |
| ------------------------- | ---------------------------------------------------------- |
| Schema + RPCs             | `backend/supabase/migrate_v0.26_remote_sessions.sql`       |
| Server gate               | `backend/supabase/migrate_v0.27_remote_control_gate.sql`   |
| Retention cron            | `backend/supabase/migrate_v0.28_remote_retention.sql`      |
| Drop legacy + read gate   | `backend/supabase/migrate_v0.29_remote_gate_tightening.sql`|
| register_session ownership| `backend/supabase/migrate_v0.30_register_session_ownership.sql` |
| Advisor follow-ups        | `backend/supabase/migrate_v0.31_remote_advisor_followups.sql`|
| Hook entry                | `helper/remote_hook.py`                                    |
| Claude adapter            | `helper/provider_adapters/claude.py`                       |
| Phase 2 PTY skeleton      | `helper/remote_agent.py`                                   |
| Tests                     | `helper/test_remote_hook.py`                               |
| Swift state               | `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift` + `DataRefreshManager.swift` |
| Mac UI                    | `CLI Pulse Bar/CLI Pulse Bar/RemoteApprovalsSheet.swift` + `AdvancedSection.swift` + `MenuBarView.swift` |
| iOS UI                    | `CLI Pulse Bar/CLI Pulse Bar iOS/iOSRemoteApprovalsView.swift` + `iOSSettingsTab.swift` + `iOSOverviewTab.swift` |
| Hook setup (private)      | `helper/REMOTE_APPROVAL_SETUP.md`                          |

## Validation snapshot (final, post-deploy)

| Check                                  | Result                          |
| -------------------------------------- | ------------------------------- |
| `pytest helper/test_remote_hook.py`    | 16 passed                       |
| `pytest helper/test_system_collector.py` | 27 passed                     |
| `swift test --package-path CLIPulseCore` | 489 passed, 1 skipped         |
| `xcodebuild build` (Mac)               | BUILD SUCCEEDED                 |
| `xcodebuild build` (iOS Simulator)     | BUILD SUCCEEDED                 |
| `xcodebuild build` (Watch Simulator)   | BUILD SUCCEEDED                 |
| `xcodebuild build` (Widgets)           | BUILD SUCCEEDED                 |
| `ci_check_rpc_contract.py`             | OK                              |
| `ci_check_search_path.py`              | OK (12 new SECURITY DEFINER pinned) |
| `ci_check_user_id_cascade.py`          | OK (24 user_id tables cascade)  |
| `ci_check_alert_types.py`              | OK                              |
| `ci_check_date_windows.py`             | OK                              |
| Supabase live: 5 tables                | RLS enabled on all 5            |
| Supabase live: 6 helper + 3 app RPCs   | All present, gated              |
| Supabase live: cron                    | `remote_retention_cleanup_nightly` active, 47 3 * * * |
| Supabase advisors                      | 0 ERROR, all WARNs in v0.31 / codebase-wide convention buckets |
