# PROJECT FIX — Remote Session Input (iter 1)

**Date:** 2026-05-03
**Branch:** `remote-session-input-iter1`
**Status:** Implementation complete on private branch. Backend migration is a **placeholder** — slot assignment and live apply are deferred until Jason coordinates with the cli-pulse-desktop track.
**Audience:** internal — successor agents (Codex review iter 2), reviewers, future me.

This archive covers the iter-1 cut of the new "Sessions Input" feature for the macOS + iOS apps: the user can now spawn a Claude Code session from the app and drive it (send prompts, approve permissions inline, stop) over the existing v0.26 Remote-Sessions schema.

## What this iteration ships

### Backend — `backend/supabase/migrate_pending_remote_session_input.sql`

Placeholder filename (no `v0.3X` slot, **not applied to live Supabase**). Adds:

1. Widens `remote_session_commands.kind` CHECK to include `'start'` (existing values `'prompt' | 'stop' | 'interrupt'` retained). `remote_app_send_command` keeps its narrower runtime-only validation; `'start'` only enters via the new RPC below.
2. `remote_app_request_session_start(p_device_id, p_provider, p_cwd_basename, p_cwd_hmac, p_client_label) -> {session_id, command_id}` — RLS-safe, gated by `_remote_control_enabled_for_caller()`. Validates that `p_device_id` belongs to the caller. Atomically inserts a `remote_sessions(status='pending')` row plus a `remote_session_commands(kind='start')` row whose payload is a snake_case JSON object with `provider`, `cwd_basename`, `cwd_hmac`, `client_label`. iter 1 only accepts `provider='claude'`.
3. `remote_app_list_sessions() -> jsonb` — returns the caller's `pending|running` sessions joined with `devices.name` so the UI can label which Mac each session is on. Returns `[]` when Remote Control is disabled.
4. `REVOKE ALL ... FROM public, anon` + `GRANT EXECUTE ... TO authenticated` on both new RPCs (matches the v0.31 hardening posture).

Manual verification SQL is at the bottom of the migration file. The `placeholder` filename ensures `ci_check_rpc_contract.py` parses it (it scans every `*.sql`) but it cannot be replayed by mistake — the file isn't in any v0.X numeric slot, so `_sql_replay_order` puts it last.

### Helper — `helper/transports/` (new package)

Pluggable PTY backend so the Tauri 2 desktop track can plug in `ConPtyTransport` later without touching `RemoteAgentManager`.

- [helper/transports/__init__.py](helper/transports/__init__.py) — public exports + `default_transport()` factory; only loads `posix_pty` lazily.
- [helper/transports/base.py](helper/transports/base.py) — `SessionTransport` ABC + opaque `SessionHandle` + `TransportError`. The protocol is platform-neutral: no `pty.*`, `termios`, `fcntl`, or signal numbers cross the boundary.
- [helper/transports/posix_pty.py](helper/transports/posix_pty.py) — `PosixPtyTransport`. Uses `os.openpty()` + `subprocess.Popen(start_new_session=True)` so SIGINT to the child's pgid doesn't kill the helper. Non-blocking master fd via `fcntl(F_SETFL, O_NONBLOCK)`. `read_stdout` uses a 0-timeout `select()` and treats EIO/EBADF as EOF.
- [helper/transports/conpty.py](helper/transports/conpty.py) — `ConPtyTransport` stub. Constructor raises `NotImplementedError("Windows ConPTY transport — implemented in cli-pulse-desktop track")`. Module docstring documents the Win32 contract (`CreatePseudoConsole` / `ResizePseudoConsole` / `ClosePseudoConsole` / `pywinpty.PtyProcess`) so the desktop track can wire against the same abstraction.

### Helper — `helper/remote_agent.py` (rewritten)

Phase-1 stub replaced with a real implementation:

- `RemoteAgentManager(helper_config, rpc_caller, transport=None)` — `transport` is dependency-injected; default factory returns `PosixPtyTransport` on non-Windows.
- `spawn_session(params)` → `transport.start(...)` with env merged including `CLI_PULSE_REMOTE_SESSION_ID=<session_uuid>` (the binding for inline approve), then UPSERT-registers the session via `remote_helper_register_session` so the app sees `status='running'`.
- `write_to_session(session_id, payload)` writes UTF-8 + auto-newline up to the 8192-char column cap.
- `stop_session` / `interrupt_session` → `transport.terminate` / `interrupt`.
- `tick(max_commands=10)` is the per-cycle entry: pulls commands via `remote_helper_pull_commands`, dispatches by `kind` (`start | prompt | stop | interrupt`), drains stdout into per-session in-memory buffers (capped at 64 KB; **not uploaded** in iter 1), and posts `status='stopped'` / `status='errored'` events when children exit. Server-side gate-off failures are swallowed at debug level so toggling Remote Control off mid-session doesn't crash the daemon.
- `shutdown()` terminates all sessions, idempotent, signal-handler-safe.

Argv resolution: `CLAUDE_ARGV = ["claude"]` — relies on POSIX `execvp` PATH search. iter 1 only spawns Claude; codex/shell still raise from their adapter stubs.

### Helper — `helper/cli_pulse_helper.py`

Daemon loop wires in the manager:

- Constructed once at start, before the main loop.
- Lazily imported so a future Windows desktop call doesn't crash on `import pty`.
- `manager.tick()` runs once per second from inside the existing 1-second sleep granularity, so a typed prompt reaches the spawned `claude` within ~1s of being enqueued (vs. the 60s heartbeat cadence).
- `manager.shutdown()` runs in a `finally` so SIGTERM / SIGHUP / KeyboardInterrupt drain any live PTYs before the daemon exits.
- A `ConfigError` on init means the helper isn't paired yet — daemon continues without the manager and the next `heartbeat()` will surface the pairing error normally.

### Helper — `helper/remote_hook.py`

- New `REMOTE_SESSION_ID_ENV = "CLI_PULSE_REMOTE_SESSION_ID"` constant + `_resolve_managed_session_id(raw)` helper. Order of precedence: env var (UUID-validated) → raw hook input session_id → None. Falls through gracefully when the env var is missing or malformed.
- The single call site in `_run_hook_inner` now calls `_resolve_managed_session_id` instead of `_coerce_uuid` directly.
- Belt-and-braces: even if a stray env var points to a session not owned by `(user_id, device_id)`, the SQL gate (`remote_helper_create_permission_request` v0.27 / v0.30) zeroes out a mismatched `p_session_id` rather than raising, so the request still creates (just unbound). Hand-opened Terminal Claude flows that have the env var unintentionally set fall through to the standard pending-approvals sheet.

### Swift — `CLIPulseCore`

- `Models.swift` — `RemoteSession` gains `device_name: String?` (matches the new RPC join) and `Hashable` conformance (needed for SwiftUI `NavigationLink(value:)` / `navigationDestination(for:)` on iOS). Adds `isManaged: Bool` convenience that filters terminal-state rows.
- `APIClient.swift`:
  - `remoteListSessions() -> [RemoteSession]` → wraps `remote_app_list_sessions`.
  - `remoteRequestSessionStart(deviceId:cwdBasename:cwdHmac:clientLabel:) -> (sessionId, commandId)` → wraps `remote_app_request_session_start`. Provider is hard-pinned to `"claude"` for iter 1.
  - `remoteSendCommand` doc clarifies that `.start` is rejected — must go through the start RPC for atomicity with the session row.
- `AppState.swift` — three new `@Published` properties (`remoteSessions`, `remoteSessionsLastRefresh`, `remoteSessionsError`).
- `DataRefreshManager.swift` (extension `AppState`) — adds:
  - `refreshRemoteSessions()` — gated on `remoteControlEnabled`, pre/post `await` re-checks (mirrors `refreshRemoteApprovals` discipline).
  - `requestRemoteClaudeSessionStart(deviceId:...)` returns the new `sessionId` so the UI can immediately select.
  - `sendRemoteSessionPrompt(sessionId:text:)` — trims, no-ops on empty, calls `remoteSendCommand(.prompt)`.
  - `stopRemoteSession(sessionId:)` — wraps `.stop`.
  - `setRemoteControlEnabled` toggle-OFF success branch also clears managed-session cache.
- `AuthManager.swift` — logout reset clears `remoteSessions` / `remoteSessionsLastRefresh` / `remoteSessionsError`.

### Swift — Mac UI (`CLI Pulse Bar/SessionsTab.swift`)

Rewrote `SessionsTab` to split into a **Managed Claude sessions** section (top) and the existing **Sessions** analytics list (bottom, view-only). New affordances:

- "Open managed Claude session" toolbar button (only when Remote Control is enabled). Picks the most recently online Mac with helper installed; disabled (with help text) when no eligible device exists. Calls `requestRemoteClaudeSessionStart` and auto-selects the new row.
- Each managed row toggles a per-row inline command bar.
- Command bar: `TextField` + `Send` button (Enter shortcut), `Approve pending` button (`⌘↩` shortcut, disabled for high-risk requests, reads from `state.remotePendingApprovals.first { $0.session_id == session.id }`), `Stop` button (destructive).
- `.task` polling loop refreshes every 3s while RC on, 10s when off (to honor a flip without wasted bandwidth).
- Analytics rows now carry an explicit "Analytics sessions are read-only — they reflect locally detected CLI activity." footnote so users don't expect to type into them.

### Swift — iOS UI (`CLI Pulse Bar iOS/iOSSessionsTab.swift`)

Same split + new `ManagedSessionDetailView` for the inputtable surface:

- iPhone: managed sessions section above analytics, NavigationLink into detail.
- iPad: combined `List` with two sections, taps swap the detail pane.
- "New" toolbar button → spawn → auto-select.
- Detail view: header card (status + device), `pendingApprovalCard` when a matching request exists (Approve / Deny + high-risk caveat), multiline `TextEditor` for prompt + Send button + Stop button.
- Same `.task` polling discipline as macOS (3s on / 10s off).

## Architectural decisions committed to in code

1. **Concept B only.** All input flows bind to `RemoteSession` (PTY-managed). Existing `SessionRecord` analytics rows remain read-only and now carry an explicit footnote so users don't expect them to be inputtable.
2. **`'start'` joins the existing `remote_session_commands` queue, not a parallel table.** Reuses the proven pending → delivered → failed/expired status machinery. `remote_app_send_command` keeps its narrower CHECK so end users can't enqueue a start through the wrong RPC.
3. **`remote_app_request_session_start` does both inserts atomically** so the app sees a `pending` row instantly. Helper UPSERTs to `running` via `remote_helper_register_session` (v0.30 ownership-checked) once the PTY is alive.
4. **PTY abstraction is `SessionTransport` ABC + opaque `SessionHandle`** with `PosixPtyTransport` concrete + `ConPtyTransport` stub raising `NotImplementedError`. `RemoteAgentManager` accepts the transport via DI and never imports `pty`/`termios`/`fcntl`.
5. **Manager runs in the daemon's existing 1s inner sleep loop**, not as a separate thread. SIGTERM-aware via the existing `stopping` flag; `shutdown()` runs in a `finally`.
6. **iter 1 does NOT upload stdout/stderr.** The `EventBatcher` and read-drain plumbing exist but only `status='stopped' / 'errored'` events are posted. Tail-streaming UI is iter 2+, with the redaction posture from `claude.py._redact` to be reused on the upload path.
7. **`CLI_PULSE_REMOTE_SESSION_ID` env var** is the binding mechanism: the helper sets it on the spawned child; `remote_hook.py` prefers it over Claude's hook session_id (UUID-validated). The SQL gate handles mismatches gracefully (zeros out, doesn't raise).
8. **Polling cadence:** Sessions UI polls only while visible AND `remoteControlEnabled` (3s); 10s idle cadence when off so a flip is honored without wasted bandwidth. `refreshAll` does NOT call `refreshRemoteSessions` — the call lives only in the SessionsTab `.task`.

## Privacy / security posture (Phase 1 invariants preserved)

- ✅ Default OFF: every new RPC checks `_remote_control_enabled_for_caller()`.
- ✅ No transcripts, no API keys, no cookies, no full session log files: stdout buffer is in-memory only, never uploaded in iter 1.
- ✅ cwd_basename ≤ 255 chars, cwd_hmac unchanged, no full path traversal.
- ✅ Free-text prompt payload ≤ 8192 chars (existing column CHECK).
- ✅ Event row ≤ 4 KB (existing column CHECK) — only status events posted in iter 1.
- ✅ High-risk fail-closed: prompt payloads flow into Claude verbatim; Claude's own permission prompt fires when it tries to run a tool, and that prompt round-trips through the existing hook → remote-approval surface (no new bypass).
- ✅ Always-Allow stays out of scope: no `permissionUpdates`, no scope changes.
- ✅ PermissionRequest output: `behavior: "allow" | "deny"` only — env-var binding only changes `session_id`, not the response shape.
- ✅ Logout clears the new state.
- ⚠️ **Shell provider is deferred** and MUST add a high-risk filter on the prompt payload before it ships (the kickoff prompt's high-risk shortcut block doesn't apply to free-text input today because only Claude is supported in iter 1).

## What's deferred to iter 2+

- Codex / shell provider PTY adapters.
- Live event-tail streaming UI (the data path is wired up to status events; stdout/stderr upload + redaction is the open work).
- Watch / Android / Tauri desktop targets.
- Backend migration **slot assignment** + **live apply**. Per memory `feedback_cli_pulse_autonomy.md` and the cross-track coordination note, schema slot `v0.3X` is reserved by Jason after coordinating with the cli-pulse-desktop v0.4.4 backlog.
- App Store / TestFlight submission.
- L10n: new UI strings ("Managed Claude sessions", "Open managed Claude session", "Send a prompt", "Approve pending", etc.) are inline English literals; full localization is a separate beat.

## Files of record

| Concern | File |
|---|---|
| Backend migration (placeholder) | `backend/supabase/migrate_pending_remote_session_input.sql` |
| Transport abstraction | `helper/transports/__init__.py`, `helper/transports/base.py` |
| POSIX PTY | `helper/transports/posix_pty.py` |
| Windows ConPTY stub | `helper/transports/conpty.py` |
| Manager (rewrite) | `helper/remote_agent.py` |
| Daemon wiring | `helper/cli_pulse_helper.py` |
| Hook env-var binding | `helper/remote_hook.py` |
| Swift models | `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Models.swift` |
| Swift API surface | `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/APIClient.swift` |
| Swift state | `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift`, `DataRefreshManager.swift`, `AuthManager.swift` |
| Mac UI | `CLI Pulse Bar/CLI Pulse Bar/SessionsTab.swift` |
| iOS UI | `CLI Pulse Bar/CLI Pulse Bar iOS/iOSSessionsTab.swift` |
| Tests | `helper/test_remote_agent.py` (new), `helper/test_remote_hook.py` (env-var cases) |
| Archive | `PROJECT_FIX_2026-05-03_remote_session_input_iter1.md` (this file) |

## Validation snapshot

| Check | Result |
|---|---|
| `pytest helper/test_remote_hook.py` | 21 passed (16 prior + 5 env-var) |
| `pytest helper/test_remote_agent.py` | 12 passed (PosixPty + ConPty stub + 9 manager dispatch) |
| `pytest helper/test_system_collector.py` | 33 passed |
| `swift test --package-path CLIPulseCore` | All suites passed |
| `xcodebuild build` (macOS) | **BUILD SUCCEEDED** |
| `xcodebuild build` (iOS Simulator, scheme "CLI Pulse iOS") | **BUILD SUCCEEDED** *(see note below)* |
| `ci_check_rpc_contract.py` | OK (new RPCs picked up via APIClient call sites) |
| `ci_check_search_path.py` | OK (no new `SECURITY DEFINER` warnings) |
| `ci_check_user_id_cascade.py` | OK |

> **Scheme name correction:** the Codex kickoff prompt referred to the iOS scheme as `"CLI Pulse Bar iOS"` but the actual scheme in the .xcodeproj is `"CLI Pulse iOS"`. The verify command should be:
> ```bash
> xcodebuild -project "CLI Pulse Bar/CLI Pulse Bar.xcodeproj" -scheme "CLI Pulse iOS" -destination 'generic/platform=iOS Simulator' build
> ```

## Codex review pass — fixes layered on top (commit `24659d6`)

After the initial `40e6526` landed, Codex flagged two P1 blockers + one
nit; all three are fixed on the same branch in commit `24659d6`:

1. **Active approvals refresh in the Sessions UI** — the `.task` loops
   on macOS `SessionsTab` and iOS `iOSSessionsTab` only polled
   `refreshRemoteSessions`. Inline approve reads
   `state.remotePendingApprovals`, so a pending Claude permission
   request bound to the selected managed session could miss the 10s
   hook window. Both loops now refresh sessions AND approvals
   concurrently via `async let` on the same 3s/10s gated cadence.
   `ManagedSessionDetailView` (iOS) gets its own `.task` because
   SwiftUI may pause the parent task while a destination view is on
   screen via `NavigationLink`.
2. **Errored sessions stuck on pending/running** —
   `RemoteAgentManager._post_status` had been concatenating a detail
   string into the status payload (`f"errored: {detail}"`), so the SQL
   gate in `remote_helper_post_event` (which only transitions
   `remote_sessions.status` when `p_payload IN ('stopped','errored')`)
   never fired. `_post_status` now takes only the bare status string
   and refuses anything else; detail goes to the local helper log.
   Five new tests in `helper/test_remote_agent.py` pin the exact
   payload posture for spawn-failure / non-zero-exit / child-gone /
   stop-success / unknown-status paths.
3. **macOS Send button double-send** — Send button kept a
   `.keyboardShortcut(.return, modifiers: [])` alongside
   `TextField.onSubmit`, which on macOS routes Return to BOTH and
   double-sent the prompt. Removed the explicit shortcut; Enter is now
   exclusively the TextField's submit, and ⌘↩ on the Approve button
   keeps its distinct command-modifier shortcut.

## Final polish (commit on top of `24659d6`)

A second Codex pass on `24659d6` flagged stale-render risk in the iOS
detail view + a `.refreshable` consistency gap. Polish layered on top:

- **iOS `ManagedSessionDetailView` reads `currentSession`** — the view
  captured `session: RemoteSession` at navigation time and used it
  directly for the navigation title, header label/status/device, and
  `statusColor`. While the new detail-view `.task` refreshes
  `state.remoteSessions`, the captured value never updated, so the UI
  could keep showing `pending` after the helper had flipped the row to
  `running`. Added a private computed `currentSession` that prefers
  `state.remoteSessions.first(where: { $0.id == session.id })` and
  falls back to the captured snapshot. Every render-time read
  (navigation title, header fields, status color) now routes through
  `currentSession`. Command calls (`stopRemoteSession`,
  `sendRemoteSessionPrompt`) also use `currentSession.id` for symmetry
  — the id is stable across the snapshot vs. live row by construction.
- **iOS `.refreshable` handlers also call `refreshRemoteApprovals`** —
  pull-to-refresh on iPad and iPhone now fans out to dashboard /
  sessions / approvals side-by-side, matching the `.task` polling
  shape so the contract is obvious. Belt-and-braces: `refreshAll`
  already schedules a `refreshRemoteApprovals` Task internally, but
  the explicit call avoids the implicit dependency.

No backend schema change beyond the original placeholder migration.
Helper tests all still pass. The separate `claude-oauth-nested-parse-fix`
branch is untouched. No public-repo writes.

### Deferred items (preserved from earlier passes)

- **Stdout/stderr upload** — iter 1 buffers reads in-memory only; the
  `EventBatcher` is wired but `remote_helper_post_event` is never
  called for `kind='stdout' | 'stderr'`. iter 2 will plumb this
  through the `claude.py._redact` patterns.
- **`kind='info'` detail events** — spawn-failure detail, exit codes,
  and "child gone" reasons currently go to the local helper log only.
  iter 2 may post redacted `info` events so the UI can surface
  "Failed to spawn: claude not found" without a status-string regression.
- **Real schema slot** — the migration file remains at the placeholder
  filename `migrate_pending_remote_session_input.sql`. A `v0.3X` slot
  + live apply waits on Jason's coordination with the
  cli-pulse-desktop v0.4.4 + OpenRouter bigint migration queue.
- **No public-repo writes** — entirely on private `origin`. No release
  tags, no website changes, no GitHub Releases artifact movement.

## Open questions for review (iter-2 prompt input)

1. **Migration slot timing.** The placeholder migration is committed but not yet replayed. The desktop track's v0.4.4 backlog needs to land first or Jason needs to assign a slot to this iter — confirm cadence.
2. **Stdout/stderr upload.** iter 1 buffers reads but doesn't upload. iter 2 should plumb `EventBatcher` → `remote_helper_post_event` with the `claude.py._redact` patterns reused. Open question: should the upload be opt-in per-session (a "stream live output" toggle) or always-on while the session is selected in the UI?
3. **Argv resolution.** `CLAUDE_ARGV = ["claude"]` relies on PATH. Users with non-standard installs (e.g. `~/.claude/local/claude` from the Anthropic dev install) would need a `CLI_PULSE_CLAUDE_BIN` override. iter 2 candidate.
4. **Multi-Mac selection.** "Open managed Claude session" picks the most recently online Mac. If a user has two Macs paired, they may want to choose. iter 2 candidate (probably a small Picker in the toolbar).
5. **Free-text high-risk filter.** Only relevant when `shell` provider lands; document on the shell adapter PR rather than here.
6. **L10n.** New UI strings are inline literals — should they go through `L10n.sessions.*` like the existing keys?
