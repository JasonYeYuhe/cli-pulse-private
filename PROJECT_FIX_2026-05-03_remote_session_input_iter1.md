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

  > Caveat caught by Codex on the next pass: the iPad `.refreshable`
  > and iPhone `.refreshable` lived at different indentation depths
  > in the View hierarchy, so the `replace_all: true` Edit only matched
  > one. The follow-up commit (see "Final polish — terminal-state UX"
  > below) fixed the iPhone body too.

No backend schema change beyond the original placeholder migration.
Helper tests all still pass. The separate `claude-oauth-nested-parse-fix`
branch is untouched. No public-repo writes.

## Final polish — terminal-state UX (commit on top of `e3ef028`)

A third Codex review pass against `e3ef028` flagged two follow-ups:

1. **Missed iPhone `.refreshable`** — the prior `replace_all: true` Edit
   silently matched only the iPad block because the iPad and iPhone
   bodies live at different indentation levels in the view hierarchy
   (8 vs 12 spaces). iPhone's pull-to-refresh now mirrors iPad's
   `refreshAll() + refreshRemoteSessions() + refreshRemoteApprovals()`
   trio.

2. **Terminal-state detail view** — `remote_app_list_sessions()` filters
   to `status IN ('pending', 'running')` (deliberate: the active list
   is "what you can drive right now"). Once the helper posts a
   `'stopped'` / `'errored'` status event the row falls out of the
   list, and the detail view's `currentSession` falls back to the
   navigation-captured snapshot — which was probably `running` at
   navigation time. The user would otherwise keep seeing `running`
   forever on a session that's gone.

   Fixed without touching SQL: the iOS detail view tracks a
   `@State hasRefreshedAtLeastOnce` flag (set inside the `.task`
   AFTER the first `refreshRemoteSessions()` await completes) and
   exposes a computed `sessionEnded`:

   ```
   sessionEnded =
       hasRefreshedAtLeastOnce
       AND state.remoteControlEnabled
       AND !state.remoteSessions.contains { $0.id == session.id }
   ```

   Two false-positive guards baked in deliberately:

   - **`hasRefreshedAtLeastOnce`** prevents a freshly-navigated detail
     view from briefly flickering to "ended" before the first refresh
     response lands.
   - **`state.remoteControlEnabled`** prevents marking the session as
     ended when the user has just disabled Remote Control. RC-off
     legitimately empties the active list (the `refreshRemoteSessions`
     no-op path clears the cache); the session might still be running
     on the helper, we just can't see it. In that case we keep
     rendering the snapshot's last known status instead of
     manufacturing an "ended" lie.

   Transient `remoteListSessions` failures are already safe: the
   `refreshRemoteSessions` catch arm only sets `remoteSessionsError`
   and leaves the prior `remoteSessions` snapshot intact, so the id
   stays in the list across one-off network errors.

   When `sessionEnded` is true:
   - Header status pill renders `"ended"` in `.secondary` colour
     instead of the snapshot's stale `"running"`.
   - A neutral `endedNotice` card replaces the pending-approval card
     ("Session ended — no longer active. Open a new managed session
     from the Sessions tab to keep working.").
   - `TextEditor` is `.disabled(true)` and rendered at 50% opacity so
     the user immediately sees the input is dead.
   - Send + Stop buttons are `.disabled(true)`.
   - Pending approvals are deliberately hidden (the helper has already
     terminated the child; approving would be a no-op the user can't
     undo).

No backend schema change. No state on the iPad path was needed because
it shares `ManagedSessionDetailView`. macOS `SessionsTab` has the
analogous risk in its `commandBar(for:)`, but the Mac inline command
bar already disappears when the user deselects the row, so the
detail-view "stale snapshot" pattern doesn't apply there in iter 1
(the command bar reads `state.remoteSessions` for the row directly via
`state.remoteSessions.first { $0.id == session.id }` lookup against
the live ForEach, which removes the row on terminal status). If a
future macOS revision starts retaining a selected-session reference
across refreshes the same fix should be ported.

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

## Phase 2 — live managed-session output tail (commit on top of `278f626`)

iter 1 plumbed input (prompt / stop / interrupt / inline approve). Phase
2 closes the loop with privacy-first output streaming so the user can
actually watch what `claude` is doing on the helper-side PTY.

### Wire format additions

The placeholder migration `migrate_pending_remote_session_input.sql`
gains one new app-side RPC. **No real `v0.3X` slot assigned. Not
applied to live Supabase.**

```sql
remote_app_list_session_events(
  p_session_id uuid,
  p_after_id   bigint default 0,    -- pagination by bigserial id
  p_limit      integer default 200  -- clamped server-side to [1, 500]
) returns jsonb
```

Pagination is by the `bigserial id` column, NOT by `seq` — `seq` has
no UNIQUE constraint and a per-session counter resets on helper
restart, so it's an ordering hint at best. `id` is server-authoritative
monotonic insert order, exactly what a "give me everything past
watermark X" pull needs.

Gated identically to the rest of Remote Control: returns `[]` when
RC is off, returns `[]` when the session doesn't belong to the
caller (silent rather than raising — keeps the failure shape
indistinguishable from "no events yet" so a probing caller can't
infer ownership).

### Helper changes

- **New `helper/redaction.py` module**: factored out of
  `claude.py._REDACT_PATTERNS` so the iter-2 stdout uploader and the
  iter-1 hook share one secret-pattern source of truth. Added module
  docstring explicitly listing patterns (sk-ant / AIza / ghp /
  github_pat / AWS / Bearer / JWT three-segment / long hex). The
  marker is a constant `REDACTION_MARKER = "«REDACTED»"`. Pure,
  dependency-free, importable from any helper-side context.
  `claude.py` now `from redaction import redact as _redact` instead
  of declaring locals — existing 16+ hook tests still pass unchanged.

- **`RemoteAgentManager` event uploader**:
  - Per-session `EventBatcher` (existing class, now actually used)
    targeting ~3.5 KB chunks with a 0.5 s idle flush so interactive
    output (a few words at a time) doesn't sit half a second behind
    the user's expectations.
  - Per-session monotonic `event_seq` counter on `_ManagedSession`.
    Resets to 0 on every spawn. Phase-2 P0 — the iter-1 monotonic-ms
    seq scheme risked int32 wrap on long-uptime hosts (`time.monotonic
    () * 1000` exceeds 2^31 after ~24.8 days) and double-collisions
    on high-frequency stdout. Per-session counter dodges both. Helper
    restart can reset to 0 and theoretically collide with stale rows
    for a deleted session that shared the same id, but the schema
    has no UNIQUE on `(session_id, seq)` and the app pages by `id`,
    so collisions are harmless.
  - New `_post_event(session_id, kind, payload)` is the single
    poster everything goes through; uses `_next_seq` for ordering;
    swallows `Exception` at DEBUG level so the gate-off path doesn't
    spam logs (the gate-off RPC failure is the most common reason).
  - `_post_status` keeps its iter-1 contract — payload MUST be
    exactly `'stopped'` or `'errored'`. Refuses anything else with
    a WARN log so a typo can't silently produce a stuck session.
  - `_post_info(session_id, detail)` redacts via `redact()` and
    truncates to 1 KB before posting `kind='info'`. No-ops on empty
    detail so callers can invoke unconditionally.
  - `_post_stdout_chunk(session_id, text)` redacts and truncates to
    4 KB (a hair under the SQL `length(payload) <= 4096` CHECK to
    leave headroom). Does NOT re-buffer un-redacted bytes for retry
    on upload failure — events are 7-day retention by design and
    re-stashing into `stdout_buffer` would amplify a long upload
    outage into unbounded memory growth.
  - `_drain_running_sessions_stdout`:
    - Decodes PTY bytes with `errors="replace"` so a multi-byte
      UTF-8 character straddling the 4 KB read boundary doesn't
      corrupt.
    - Feeds into the per-session batcher.
    - Flushes when the batcher returns a payload OR when it's been
      idle past `max_idle_s`.
    - Posts the flushed payload as a redacted `kind='stdout'` event.
  - `_observe_exits` final-flushes the batcher so the last lines of
    output reach the app BEFORE the lifecycle event lands.
  - Spawn failure path now posts BOTH `status='errored'` AND a
    redacted `kind='info'` carrying the failure reason (`spawn
    failed: <redacted error>`).
  - Non-zero-exit path now also posts a redacted `kind='info'`
    carrying `exit_code=N` (or `child gone` when `wait()` returns
    None).

- **`stop_session` ordering fix**: the iter-1 implementation popped
  the session entry before posting `_post_status`. With the new
  per-session seq counter, that meant the `'stopped'` event landed
  with seq=0 (the missing-session fallback) instead of the next
  dense value. Reordered to post BEFORE the pop so the counter is
  still alive at the call.

- **PTY stdout/stderr merging is unchanged**: `PosixPtyTransport`
  wires `stdout=stderr=slave_fd` so the kernel can't distinguish
  the streams. iter 2 emits `kind='stdout'` for the merged stream;
  splitting stderr would require abandoning the merged PTY for some
  streams (and giving up TUI behaviour for `claude`). Iter-3 work.

### Swift side

- **`APIClient.remoteListSessionEvents(sessionId:afterId:limit:)`** —
  wraps the new RPC, clamps server-side to `[1, 500]`, returns
  `[RemoteSessionEvent]`.
- **`AppState.remoteSessionEvents: [String: [RemoteSessionEvent]]`** —
  per-session ring buffer keyed by `RemoteSession.id`. Capped at
  `AppState.remoteSessionEventsCap = 200` rows, drops oldest on
  overflow. Cleared on RC-toggle-off and on logout (matching the
  iter-1 cache-clearing posture for sessions / approvals).
- **`refreshRemoteSessionEvents(sessionId:)`** — pagination by
  max-id (reads the largest event id we've already stored locally,
  passes as `afterId`); re-checks the gate after the await; drops
  the request silently on RC-flip; non-fatal on transient errors.
- **`clearRemoteSessionEventsCache(sessionId:)`** — called by the
  "Show output" toggle when the user collapses the panel, so the
  next reveal pulls fresh rather than from the previous run's tail.

### UI

- **macOS `SessionsTab`**: command bar gains a "Show output" /
  "Hide output" toggle. Default OFF. When ON, renders a compact
  140-pt-tall scrollable monospace panel with kind-coloured rows
  (`stdout` primary, `stderr` orange, `status='errored'` red,
  `info` blue). Auto-scrolls to the newest event via `ScrollViewReader
  + .onChange(of: events.last?.id)`. The `.task` polling loop only
  fetches events when both `showOutput == true` AND a session is
  selected. Switching selection resets `showOutput = false` so the
  user has to opt in again for the new session.

- **iOS `ManagedSessionDetailView`**: same toggle (rendered as a
  Toggle next to a "Show live output" label) + a 220-pt scrollable
  panel. Preserves the iter-1 ended-state behaviour from `278f626`:
  Send/Stop stay disabled when `sessionEnded`, the ended notice
  card still renders, the Show-output toggle still works (event
  rows for terminal sessions remain readable until the 7-day
  retention cron prunes them).

- Both surfaces show a footer line "Secrets redacted before upload."
  so the user can SEE the privacy posture without reading the docs.

### Tests

- **9 new helper tests** in `test_remote_agent.py`:
  `test_stdout_drain_posts_redacted_event`,
  `test_stdout_chunking_flushes_on_idle_when_no_new_reads`,
  `test_stdout_post_failure_is_non_fatal`,
  `test_stdout_post_does_not_collide_with_status_payload_exactness`,
  `test_info_event_redacts_and_is_size_bounded`,
  `test_info_event_skipped_when_detail_empty`,
  `test_spawn_failure_emits_status_and_redacted_info_pair`,
  `test_observe_exits_emits_info_with_exit_code`,
  `test_per_session_event_seq_counter_starts_at_one`.

- **5 new Swift tests** in `RemoteSessionEventTests.swift` (new
  file): wire-shape decode for `stdout` / `status='errored'` /
  `info` rows, `Identifiable` keys off `id`, full Codable
  round-trip, bigint id (4.8B value past Int32) decodes into
  Swift's 64-bit `Int`.

### Privacy / security posture preserved

- Default OFF — `_remote_control_enabled_for_caller()` gates the
  new listing RPC.
- Show-output is a per-detail user-explicit opt-in for *rendering*;
  upload itself runs while RC is on regardless. Aligns with the
  retention cron (7-day prune).
- Every helper upload path (`stdout`, `info`) runs `redact()`
  before the wire — secrets stay on-device.
- Status payload remains exactly `'stopped'` / `'errored'`. Detail
  goes via `kind='info'` so iter-1's SQL gate fix doesn't regress.
- 4 KB stdout / 1 KB info row caps; 200-event ring buffer per
  session app-side; 64 KB local stdout buffer (safety net only,
  not actually used by the new uploader path).

### Deferred items (preserved)

- **Stderr / stdout split** — PTY merges them; iter-3 work would
  need a non-PTY pipe.
- **Real schema slot** — `migrate_pending_remote_session_input.sql`
  still has no `v0.3X` slot. Live apply waits on Jason's
  coordination with cli-pulse-desktop v0.4.4 + OpenRouter bigint
  migration queue.
- **No public-repo writes** — entirely on private `origin`.
- **Codex / shell providers, multi-Mac picker, L10n, Watch /
  Android, public release, App Store** — all still out of scope.

## Open questions for review (iter-2 prompt input)

1. **Migration slot timing.** The placeholder migration is committed but not yet replayed. The desktop track's v0.4.4 backlog needs to land first or Jason needs to assign a slot to this iter — confirm cadence.
2. **Stdout/stderr upload.** iter 1 buffers reads but doesn't upload. iter 2 should plumb `EventBatcher` → `remote_helper_post_event` with the `claude.py._redact` patterns reused. Open question: should the upload be opt-in per-session (a "stream live output" toggle) or always-on while the session is selected in the UI?
3. **Argv resolution.** `CLAUDE_ARGV = ["claude"]` relies on PATH. Users with non-standard installs (e.g. `~/.claude/local/claude` from the Anthropic dev install) would need a `CLI_PULSE_CLAUDE_BIN` override. iter 2 candidate.
4. **Multi-Mac selection.** "Open managed Claude session" picks the most recently online Mac. If a user has two Macs paired, they may want to choose. iter 2 candidate (probably a small Picker in the toolbar).
5. **Free-text high-risk filter.** Only relevant when `shell` provider lands; document on the shell adapter PR rather than here.
6. **L10n.** New UI strings are inline literals — should they go through `L10n.sessions.*` like the existing keys?
