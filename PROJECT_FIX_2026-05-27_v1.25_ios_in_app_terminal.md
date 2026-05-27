# PROJECT FIX — v1.25.0 iOS Interactive Remote Terminal (Phase 4)

**Date:** 2026-05-26 → 2026-05-27 JST
**Train:** v1.25.0 (Apple build 66, Android code 34)
**Status:** All 8 PRs merged to `main`. Ship channels (ASC / DEVID / Play) + backend migration v0.50 still owner-gated.

---

## Goal

Build on the v1.24 in-app terminal MVP (Mac Bar host) to deliver the iOS user-facing headline of the v1.25 train: tap a managed Mac session on your phone, see its terminal in real time, type into it. The plan §Phase 4 lays the full architecture; this train delivers it end-to-end.

Plan: `~/.claude/plans/v1.24-in-app-terminal-plan.md` (single plan covers v1.24 + v1.25).

## Architecture pipeline (helper → iOS)

```
PtyTransport (Mac helper)
  → TerminalBroadcastPublisher (v1.24 #80, redact-at-write actor)
  → SupabaseRealtimeBroadcastSink (v1.25 #85)   ─┐
  → Supabase Realtime broadcast endpoint        │ Phase 2c
  → RemoteSessionEventStream (v1.25 #87, WS)    ─┘
  → RemoteTerminalViewRepresentable Coordinator (v1.25 #88)
  → RemoteTerminalView (v1.25 #88, UIView)
  → TerminalOutputCoalescer (v1.24 #81, 16 ms window)
  → window.pushChunk('<base64>') JS bridge
  → JS-side rAF batcher
  → xterm.js term.write()
```

Reverse (iOS → helper):

```
User taps / types in xterm.js
  → term.onData → JS bridge
  → didReceiveStdin delegate (v1.25 #89)
  → DataRefreshManager.sendRemoteSessionInputRaw
  → APIClient.remoteSendCommand(kind: .input_raw, payload: base64)
  → Postgres remote_session_commands queue
  → helper remote_helper_pull_commands (1 s tick)
  → RemoteAgentCloud.dispatch case "input_raw"
  → ManagedSessionManager.sendInputRaw (v1.24 #78 — no CR-append, byte-verbatim)
  → PTY master fd → child stdin
```

## Slices shipped (8 PRs)

| # | PR | Phase | Item |
|---|---|---|---|
| 1 | [#85](https://github.com/JasonYeYuhe/cli-pulse-private/pull/85) | 2c-3 | `SupabaseRealtimeBroadcastSink` — helper-side broadcast POST |
| 2 | [#86](https://github.com/JasonYeYuhe/cli-pulse-private/pull/86) | 2c-4 | daemon wires sink behind `remote_realtime_enabled` kill switch (default ON) |
| 3 | [#87](https://github.com/JasonYeYuhe/cli-pulse-private/pull/87) | 2c-4b | `RemoteSessionEventStream` — Phoenix vsn-2.0.0 WS subscriber |
| 4 | [#88](https://github.com/JasonYeYuhe/cli-pulse-private/pull/88) | 4-1 | iOS `RemoteTerminalView` (UIView WKWebView host) + SwiftUI representable (read-only) |
| 5 | [#89](https://github.com/JasonYeYuhe/cli-pulse-private/pull/89) | 4-2 | Interactive: `input_raw` + `resize` command kinds + migration v0.50 |
| 6 | [#90](https://github.com/JasonYeYuhe/cli-pulse-private/pull/90) | 4-3 | `RemoteTerminalKeyBar` soft-keyboard bar (`Esc / Ctrl-C / ↑↓←→ / PgUp/Dn`) |
| 7 | [#91](https://github.com/JasonYeYuhe/cli-pulse-private/pull/91) | 4-4 | scenePhase lifecycle + jittered exponential backoff reconnect |
| 8 | [#92](https://github.com/JasonYeYuhe/cli-pulse-private/pull/92) | chore | 1.24.0 → 1.25.0 / Apple build 65→66 / Android code 33→34 |

## Test totals

- **HelperSwift:** 392 tests, 0 failures (13 new in this train: input_raw / resize parsers + dispatch).
- **CLIPulseCore:** 1523 tests on macOS host, 0 failures. 29+ additional iOS-guarded tests (RemoteTerminalView parseBridgeMessage / KeyBar wire bytes / Reconnect backoff curve) compile-checked by iOS scheme CI build.
- **CI gating:** All `Build CLI Pulse {Bar,iOS,Watch,Widgets}` + `Build CLIPulseHelper` + `CLIPulseCore unit tests` + `HelperSwift Package tests` + `Verify MAS archive` + `Signed-app reproducible build` + `Version drift gate` SUCCESS on every PR.

## Owner-gated next steps (not auto-applied)

1. **Apply backend migration `backend/supabase/migrate_v0.50_remote_input_raw.sql`** via Supabase Studio. Loosens `remote_session_commands.kind` check + `remote_app_send_command` allowed-list to accept `'input_raw'` and `'resize'`. Helper + iOS code is INERT until applied (helper-side dispatch fail-safe via default branch).
2. **Manual end-to-end test** on paired iOS + Mac after migration applies:
   - Open iOS Sessions detail → toggle "Show live terminal" → confirm xterm.js renders helper stdout
   - Type `ls\n` → confirm output renders
   - Tap Ctrl-C while running `sleep 100` → confirm abort
   - Rotate phone → confirm xterm.js re-flows
   - Background app for 30 s → foreground → confirm resubscribe within ~1 s (no replay; gap is expected)
   - Toggle airplane mode for 5 s → re-enable → confirm jittered backoff reconnect picks up
3. **ASC upload of build 66** → submit iOS + macOS per `feedback_asc_release_workflow`.
4. **Mac DEVID DMG** sign + notarize + upload to `cli-pulse-distrib`.
5. **Android Play AAB** of versionCode 34 (no new feature this train; Phase 5 deferred to v1.26).

## Architectural lessons codified this train

- **iOS-guarded tests are invisible to `swift test` on macOS host** but compile-check on the iOS scheme CI build. Sufficient pattern for parser / wire-byte constants; instance-instantiating WKWebView tests still SIGABRT (matches v1.24 `feedback_filtered_swift_test_blind_spot` precedent).
- **CLIPulseCore vs HelperKit module boundary.** HelperKit is Mac-helper-only (Darwin PTY APIs). Anything iOS needs (RemoteSessionEventStream, RemoteTerminalView) belongs in CLIPulseCore which targets macOS+iOS+watchOS.
- **Backend migration owner-gating pattern.** Write the .sql in-tree (helper + iOS code is inert until applied; default-branch dispatch makes legacy helpers safe). User reviews .sql in the PR, applies post-merge via Supabase Studio.
- **GitHub Actions trigger anomalies happen.** Repo-wide CI freeze 2026-05-26 PM (5.5 h zero runs across all workflows). Manual `workflow_dispatch` + empty-commit push retriggered. Future incidents: only Swift CI has `workflow_dispatch`; other workflows need an empty-commit nudge.
- **iCloud dup-file spawning** under ~/Documents (per `feedback_icloud_dup_artifacts`) hit twice mid-session — sweep `* 2.swift` / `* 2.sql` before commit.
- **Phoenix vsn-2.0.0 wire shape (5-tuple array frames).** Topic prefix `realtime:`; heartbeat ≤25 s on `phoenix` topic. Broadcast payload nesting: `{event, type:"broadcast", payload:{session_id, data_b64}}`. Defensive flat-payload decode keeps us safe if Phoenix upgrades.

## What v1.25 explicitly does NOT ship

- **fetchTailSnapshot foreground recovery** (plan §4e). Needs new cloud RPC `remote_helper_get_tail_snapshot` + Mac helper command-type expansion. Backend-migration work. iOS UX without it: "reconnected, no replay" — acceptable for MVP, less so once Android joins. Defer to v1.26.
- **500-line scrollback cap on iOS** (currently inherits Mac's 5000). Lightweight follow-up: `window.TERMINAL_CONFIG` JS-side hook + native pre-load set. Defer to v1.26 micro-PR.
- **Helper-restart "reconnect via session_id" guarantee** (Codex M6). The Realtime path self-heals via the slice-4 backoff; the dedicated UDS helper-restart path is Mac-only and orthogonal. Out of scope.
- **Phase 5: Android Kotlin WebView terminal mirror.** Android app has no remote-control plumbing today; "mirror" would require porting session list / startSession / sendInput / approvals / etc. first — multi-week effort, dedicated v1.26 train.
- **Phase 6: Tauri desktop terminal.** Per plan, v1.26.
