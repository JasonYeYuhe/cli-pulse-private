import Foundation

/// Cloud-sync layer over Phase 4D's `ManagedSessionManager`.
///
/// Polls Supabase for queued commands via
/// `remote_helper_pull_commands` and dispatches them into the
/// existing manager. Coalesces stdout from the broker into ≤4 KB
/// rows via per-session `EventBatcher`, queues them through
/// `EventUploader` (bounded 256/session, drop-oldest). On session
/// exit, posts the bare-string `kind='status'` event ('stopped' or
/// 'errored') the SQL gate keys on, plus a redacted `kind='info'`
/// carrying the exit code so the UI can render "exited code=N".
///
/// Swift port of `helper/remote_agent.py:RemoteAgentManager.tick`
/// + the cloud-sync slice of its public API. The local UDS path
/// stays in `LocalSessionServer` (Phase 4D); this actor is the
/// remote counterpart.
public actor RemoteAgentCloud {

    public struct TickResult: Sendable, Equatable {
        public let commandsProcessed: Int
        public let sessionsExited: Int
        public let eventsPosted: Int
    }

    /// Per-session bookkeeping. The actor owns the batcher so we
    /// don't have to wrap it in another sync primitive.
    private final class SessionState {
        let sessionId: String
        let provider: String
        let clientLabel: String?
        var lastStatusPosted: String   // 'running' | 'stopped' | 'errored'
        var lastExitCode: Int?         // nil if not yet observed
        var batcher: EventBatcher
        var pid: Int32?

        init(
            sessionId: String,
            provider: String,
            clientLabel: String?,
            batcher: EventBatcher = EventBatcher()
        ) {
            self.sessionId = sessionId
            self.provider = provider
            self.clientLabel = clientLabel
            self.lastStatusPosted = "running"
            self.batcher = batcher
        }
    }

    private let helperConfig: @Sendable () -> HelperConfigStore.CloudConfig
    private let rpcCaller: any RPCCallable
    private let sessionManager: ManagedSessionManager
    private let broker: EventBroker?
    private let uploader: EventUploader
    private let nowProvider: @Sendable () -> TimeInterval

    /// Per-session state owned by this actor. Sessions enter on
    /// `start` (from pull_commands) or via `registerExistingSession`
    /// for tests/local-only scenarios.
    private var sessions: [String: SessionState] = [:]

    /// M4.4d: per-session opt-in sequence numbers + their source counter. See
    /// `nextShareSeq`. Entries are tiny and bounded by the number of wrapped
    /// sessions the user ever toggled this run, so they're not pruned.
    private var shareSeq: [String: Int] = [:]
    private var shareSeqCounter = 0

    /// Subscription to the broker for output_delta + lifecycle
    /// events. Held so we can unsubscribe on shutdown — even
    /// though EventBroker doesn't support weak refs, dropping it
    /// here is what ends the lifecycle.
    private var subscription: EventBroker.Subscription?

    /// Optional logger callback for tests / Sentry integration.
    private let onLog: (@Sendable (String) -> Void)?

    public init(
        helperConfig: @escaping @Sendable () -> HelperConfigStore.CloudConfig,
        rpcCaller: any RPCCallable,
        sessionManager: ManagedSessionManager,
        uploader: EventUploader,
        broker: EventBroker? = nil,
        onLog: (@Sendable (String) -> Void)? = nil,
        nowProvider: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.helperConfig = helperConfig
        self.rpcCaller = rpcCaller
        self.sessionManager = sessionManager
        self.uploader = uploader
        self.broker = broker
        self.onLog = onLog
        self.nowProvider = nowProvider
    }

    // MARK: - public lifecycle

    /// Subscribe to the broker so output_delta from
    /// ManagedSessionManager's drain loop coalesces into our
    /// per-session batcher. Idempotent — called by tests + by the
    /// daemon main on first tick().
    public func startObservingBroker() {
        guard subscription == nil, let broker else { return }
        // Capture self weakly via task hop — actors can't be
        // captured directly into @Sendable closures.
        subscription = broker.subscribe(sessionFilter: nil) { [weak self] event in
            guard let self else { return }
            // Hop onto the actor to mutate state.
            Task { await self.handleBrokerEvent(event) }
        }
    }

    /// Stop observing + queue-flush. Safe to call multiple times.
    public func shutdown() async {
        if let subscription, let broker {
            broker.unsubscribe(subscription)
        }
        subscription = nil
        // Drain anything still buffered in batchers.
        for (sid, state) in sessions {
            if let chunk = state.batcher.drain() {
                let redacted = Redactor.redact(chunk)
                if !redacted.isEmpty {
                    await uploader.ingest(sessionId: sid, kind: .stdout, payload: redacted)
                }
            }
        }
        sessions.removeAll()
    }

    /// One daemon cycle. Pulls commands, dispatches them, observes
    /// child exits via the manager's session list, idle-flushes
    /// stdout batchers, then drives one pass of the upload pump.
    @discardableResult
    public func tick(maxCommands: Int = 10) async -> TickResult {
        if subscription == nil { startObservingBroker() }

        let processed = await pollAndDispatchCommands(maxCommands: maxCommands)
        await flushIdleBatchers()
        let exited = await observeExits()
        let posted = await uploader.pumpOnce()
        return TickResult(
            commandsProcessed: processed,
            sessionsExited: exited,
            eventsPosted: posted
        )
    }

    // MARK: - command polling

    private func pollAndDispatchCommands(maxCommands: Int) async -> Int {
        let cfg = helperConfig()
        guard cfg.isPaired else { return 0 }
        let result: Any
        do {
            result = try await rpcCaller.call(
                "remote_helper_pull_commands",
                params: [
                    "p_device_id": cfg.deviceId,
                    "p_helper_secret": cfg.helperSecret,
                    "p_max": maxCommands,
                ]
            )
        } catch {
            // Includes the gate-off path: when the user disables
            // Remote Control, the RPC raises 'Device not found
            // or unauthorized'. Daemon must keep running so a
            // re-enable resumes dispatch.
            log("pull_commands skipped: \(error)")
            return 0
        }
        guard let list = result as? [Any] else { return 0 }
        var processed = 0
        for raw in list {
            guard let cmd = raw as? [String: Any] else { continue }
            await dispatchOne(cmd)
            processed += 1
        }
        return processed
    }

    private func dispatchOne(_ cmd: [String: Any]) async {
        guard let cmdId = cmd["id"] as? String else { return }
        let kind = (cmd["kind"] as? String) ?? ""
        let sessionId = (cmd["session_id"] as? String) ?? ""
        let payload = (cmd["payload"] as? String) ?? ""

        log("dispatch kind=\(kind) session=\(sessionId) cmd=\(cmdId) payload_chars=\(payload.count)")

        // M4.4a defense-in-depth (review: codex): an attached wrapped session the
        // user has NOT opted in was never uploaded, so the cloud has no
        // legitimate way to command it — reject any inbound command for it. A
        // SHARED one (M4.4d) falls through to the per-kind policies below, which
        // re-check ATOMICALLY under the manager's lock; this check is the cheap
        // outer gate, not the authority.
        //
        // Querying live manager state is reliable HERE (unlike the broker path):
        // a command targets a live session, so the record is present.
        if !sessionId.isEmpty,
           sessionManager.isAttached(sessionId),
           !sessionManager.isCloudShared(sessionId) {
            log("dispatch rejected: \(sessionId) is a local-only attached session")
            await completeCommand(cmdId: cmdId, ok: false, error: "attached session is local-only")
            return
        }

        let outcome: (Bool, String)
        switch kind {
        case "start":
            outcome = await handleStart(sessionId: sessionId, payload: payload)
        case "prompt":
            outcome = handlePrompt(sessionId: sessionId, payload: payload)
        case "stop":
            // PR #18 lesson: fail-closed on unknown session
            // rather than silently `delivered`. The macOS app
            // distinguishes stale-row no-ops from real
            // successful stops via this status.
            // `.refuseAttached` closes the TOCTOU (review: codex) — even if a
            // local attach registered this id after the top-of-dispatch check,
            // stopSession refuses it ATOMICALLY.
            //
            // M4.4d: an attached session is refused even when the user opted it
            // into the cloud. Attach is NON-OWNING, so terminate() no-ops the
            // kill: a cloud stop would DETACH us while the user's real claude
            // kept running, and still report `stopped` to the phone. Sharing
            // grants the phone read + input, never the power to end a session
            // the user started themselves.
            if !sessionManager.ownsSession(sessionId) {
                outcome = (false, "session not running on this helper")
            } else if !sessionManager.stopSession(sessionId, attachedPolicy: .refuseAttached) {
                outcome = (false, "an attached external session cannot be stopped from the phone")
            } else {
                await postStatus(sessionId: sessionId, status: "stopped")
                sessions.removeValue(forKey: sessionId)
                outcome = (true, "")
            }
        case "interrupt":
            if !sessionManager.ownsSession(sessionId) {
                outcome = (false, "session not running on this helper")
            } else if !sessionManager.interruptSession(sessionId, attachedPolicy: .requireCloudShared) {
                outcome = (false, "session is local-only or already gone")
            } else {
                outcome = (true, "")
            }
        case "input_raw":
            // v1.25 Phase 4 slice 2: payload is base64-encoded raw
            // bytes from xterm.js's `onData`. Decode and write
            // VERBATIM to the PTY master (no CR-append) so 0x03
            // Ctrl-C / 0x04 Ctrl-D / arrow ESC sequences land in
            // the child process intact. Inert until v0.50
            // migration applies (server rejects the kind), so
            // legacy helpers stay safe.
            outcome = handleInputRaw(sessionId: sessionId, payload: payload)
        case "resize":
            // v1.25 Phase 4 slice 2: payload is "<cols>x<rows>"
            // (e.g. "80x24"). Forward to PTY via
            // `setWinsize(TIOCSWINSZ)` so ratatui / ncurses CLIs
            // reflow on phone rotation / soft-keyboard show.
            outcome = handleResize(sessionId: sessionId, payload: payload)
        case "tail_snapshot":
            // v1.26 Phase B2: foreground-recovery. Payload is a
            // decimal maxBytes (defaults to 8192 if empty /
            // unparseable). Snapshot is read from
            // ManagedSessionManager's per-session TerminalRingBuffer
            // (already redacted via Redactor), then PUBLISHED over
            // the same Realtime broadcast channel as live stdout
            // chunks — event kind `tail_snapshot_result`. Inert
            // until v0.51 migration applies (server rejects the
            // kind), so legacy helpers stay safe.
            outcome = await handleTailSnapshot(sessionId: sessionId, payload: payload)
        default:
            outcome = (false, "unknown command kind: \"\(kind)\"")
        }

        await completeCommand(cmdId: cmdId, ok: outcome.0, error: outcome.1)
    }

    private func handleStart(sessionId: String, payload: String) async -> (Bool, String) {
        // Validate session_id is a UUID.
        if UUID(uuidString: sessionId) == nil {
            return (false, "invalid session_id")
        }
        guard let parsed = Self.decodeStartPayload(payload) else {
            return (false, "invalid start payload")
        }
        let provider = parsed.provider
        let cwdHmac = parsed.cwdHmac
        let clientLabel = parsed.clientLabel
        // R0 (S2): authoritative privacy source for the fail-closed broadcast
        // gate — nil (absent) stays UNKNOWN → muted downstream.
        let realtimePrivate = parsed.realtimePrivate
        // No cloud-layer provider allowlist: ManagedSessionManager
        // validates the provider against the ProviderSpawnerRegistry
        // (Claude / Codex / Gemini) and throws .unsupportedProvider for
        // anything unknown — caught below. The old `provider != "claude"`
        // gate here silently blocked Codex/Gemini remote sessions that
        // the local LocalSessionServer path already supported (2026-05-29
        // audit). Delegating keeps the two paths consistent.

        // Pre-set the env var so remote_hook can bind permission
        // requests back to this session. extraEnv merges via the
        // manager into PtyTransport.start.
        let extraEnv = ["CLI_PULSE_REMOTE_SESSION_ID": sessionId]
        let summary: ManagedSessionManager.Summary
        do {
            // `startSession` for `claude` may do a SYNCHRONOUS OAuth-token refresh
            // (rare — only on ~8h expiry, ≤ a few seconds). handleStart runs on
            // the Swift Concurrency cooperative pool, so run the blocking call on
            // a dedicated global-queue thread and await it, rather than parking a
            // cooperative thread (Gemini 3.5 Flash review). The LOCAL UDS path
            // already runs on a dedicated per-connection Thread, so it's unaffected.
            let mgr = sessionManager
            summary = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<ManagedSessionManager.Summary, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        cont.resume(returning: try mgr.startSession(
                            provider: provider,
                            clientLabel: clientLabel,
                            cwd: nil,
                            extraEnv: extraEnv,
                            forcedSessionId: sessionId,
                            realtimePrivate: realtimePrivate
                        ))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } catch let err as ManagedSessionManager.ManagerError {
            // Status payload MUST be exactly 'errored' for the
            // SQL gate. Detail goes via redacted info event.
            let detail = describe(err)
            await postStatus(sessionId: sessionId, status: "errored")
            await postInfo(sessionId: sessionId, detail: "spawn failed: \(detail)")
            return (false, "spawn failed")
        } catch {
            await postStatus(sessionId: sessionId, status: "errored")
            await postInfo(sessionId: sessionId, detail: "spawn failed: \(error)")
            return (false, "spawn failed")
        }

        // Track in our local session map so observeExits() can
        // detect the transition from running → not in manager's
        // list. The session_id we use here matches the manager
        // (forcedSessionId).
        let state = SessionState(
            sessionId: summary.sessionId,
            provider: provider,
            clientLabel: clientLabel
        )
        state.pid = Int32(summary.pid)
        sessions[summary.sessionId] = state

        // Best-effort register the session row; spawn already
        // succeeded, so this is just a UI hint to flip the row's
        // status to 'running' before the next status event.
        let cfg = helperConfig()
        var registerParams: [String: Any] = [
            "p_device_id": cfg.deviceId,
            "p_helper_secret": cfg.helperSecret,
            "p_session_id": summary.sessionId,
            "p_provider": provider,
            "p_cwd_basename": "",
        ]
        if let cwdHmac {
            registerParams["p_cwd_hmac"] = cwdHmac
        } else {
            registerParams["p_cwd_hmac"] = NSNull()
        }
        if let clientLabel {
            registerParams["p_client_label"] = clientLabel
        } else {
            registerParams["p_client_label"] = NSNull()
        }
        do {
            _ = try await rpcCaller.call(
                "remote_helper_register_session", params: registerParams
            )
        } catch {
            log("register_session(\(summary.sessionId)) after spawn failed: \(error)")
        }
        return (true, "")
    }

    private func handlePrompt(sessionId: String, payload: String) -> (Bool, String) {
        if sessionId.isEmpty {
            return (false, "prompt requires session_id")
        }
        if !sessionManager.ownsSession(sessionId) {
            return (false, "session not running on this helper")
        }
        let ok: Bool
        do {
            ok = try sessionManager.sendInput(sessionId: sessionId, payload: payload, attachedPolicy: .requireCloudShared)
        } catch {
            return (false, "child exited")
        }
        return ok ? (true, "") : (false, "child exited")
    }

    /// v1.25 Phase 4 slice 2: write raw xterm.js keystroke bytes
    /// verbatim to the PTY. `payload` is base64; an empty / malformed
    /// payload is rejected up-front so the queue marks it failed
    /// instead of silently dropping. Exposed `internal` (file-private
    /// in practice since this file is the only consumer) so the
    /// payload-parse logic is unit-testable via
    /// `decodeInputRawPayload(_:)`.
    private func handleInputRaw(sessionId: String, payload: String) -> (Bool, String) {
        if sessionId.isEmpty {
            return (false, "input_raw requires session_id")
        }
        if !sessionManager.ownsSession(sessionId) {
            return (false, "session not running on this helper")
        }
        guard let bytes = Self.decodeInputRawPayload(payload) else {
            return (false, "input_raw payload must be non-empty base64")
        }
        let ok: Bool
        do {
            ok = try sessionManager.sendInputRaw(sessionId: sessionId, bytes: bytes, attachedPolicy: .requireCloudShared)
        } catch {
            return (false, "child exited")
        }
        return ok ? (true, "") : (false, "child exited")
    }

    /// Parsed fields of a cloud `start` command payload.
    struct StartPayload: Equatable {
        let provider: String
        let cwdHmac: String?
        let clientLabel: String?
        /// R0 (S2/S5): `realtime_private` from the backend start payload
        /// (migrate_v0.61). `nil` when the key is ABSENT — an old backend or a
        /// truncated payload — which the broadcast gate treats as UNKNOWN and
        /// fail-closed mutes. NEVER default a missing flag to `false` (that
        /// would infer "public" and re-open the leak).
        let realtimePrivate: Bool?
    }

    /// Pure parser for the `start` command payload (S5 added `realtime_private`).
    /// Returns nil ONLY for a non-empty payload that isn't valid JSON (the
    /// caller rejects it); an EMPTY payload yields defaults (provider=claude,
    /// privacy unknown). Static so unit tests pin the wire shape without a live
    /// RPC caller / session manager.
    static func decodeStartPayload(_ payload: String) -> StartPayload? {
        if payload.isEmpty {
            return StartPayload(provider: "claude", cwdHmac: nil, clientLabel: nil, realtimePrivate: nil)
        }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let provider = (obj["provider"] as? String) ?? "claude"
        let cwdHmac = (obj["cwd_hmac"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let clientLabel = (obj["client_label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Bool ONLY — a non-bool (string "true", number) is treated as absent →
        // unknown → fail-closed, never coerced to public.
        let realtimePrivate = obj["realtime_private"] as? Bool
        return StartPayload(
            provider: provider, cwdHmac: cwdHmac,
            clientLabel: clientLabel, realtimePrivate: realtimePrivate)
    }

    /// Pure parser. Returns nil for empty / non-base64 payloads.
    /// Public so unit tests can pin the wire shape without
    /// instantiating `RemoteAgentCloud` (which needs a live RPC
    /// caller + session manager).
    static func decodeInputRawPayload(_ payload: String) -> Data? {
        if payload.isEmpty { return nil }
        guard let data = Data(base64Encoded: payload), !data.isEmpty else {
            return nil
        }
        return data
    }

    /// v1.25 Phase 4 slice 2: forward window-size update to the PTY.
    /// Payload is "<cols>x<rows>" (e.g. "80x24"). Both dimensions
    /// must be positive and fit in UInt16 — xterm.js can produce
    /// huge values when the viewport is mid-animation; clamp at
    /// 32767 (UInt16 max) so the ioctl doesn't reject.
    private func handleResize(sessionId: String, payload: String) -> (Bool, String) {
        if sessionId.isEmpty {
            return (false, "resize requires session_id")
        }
        if !sessionManager.ownsSession(sessionId) {
            return (false, "session not running on this helper")
        }
        guard let (cols, rows) = Self.decodeResizePayload(payload) else {
            return (false, "resize payload must be '<cols>x<rows>' (1..32767 each)")
        }
        let ok = sessionManager.resize(sessionId: sessionId, cols: cols, rows: rows, attachedPolicy: .requireCloudShared)
        return ok ? (true, "") : (false, "resize failed (ioctl)")
    }

    /// Pure parser for the resize payload. Returns nil for any
    /// non-conforming shape (missing 'x', non-numeric, zero, or
    /// >32767). Public so unit tests can pin it.
    static func decodeResizePayload(_ payload: String) -> (cols: UInt16, rows: UInt16)? {
        let parts = payload.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard let cols = Int(parts[0]),
              let rows = Int(parts[1]),
              cols > 0, rows > 0,
              cols <= 32767, rows <= 32767
        else { return nil }
        return (UInt16(cols), UInt16(rows))
    }

    /// v1.26 Phase B2: read the most-recent N bytes of the session's
    /// PTY ring buffer (already redacted via Redactor) and publish them
    /// via the Realtime broadcast channel as event `tail_snapshot_result`.
    /// The iOS side `Coordinator.resume()` uses this to "catch up"
    /// after a background→foreground cycle without paying for a full
    /// event-log replay. Returns success even when the snapshot is
    /// empty (brand-new session) — the iOS side handles the empty
    /// case the same as a missed broadcast (it just drains its
    /// pendingSnapshotBuffer with no prefix).
    private func handleTailSnapshot(sessionId: String, payload: String) async -> (Bool, String) {
        if sessionId.isEmpty {
            return (false, "tail_snapshot requires session_id")
        }
        if !sessionManager.ownsSession(sessionId) {
            return (false, "session not running on this helper")
        }
        let maxBytes = Self.decodeTailSnapshotPayload(payload)
        // `publishTailSnapshot` self-locks via TerminalRingBuffer
        // (v1.26 A0 hotfix), redacts via Redactor (idempotent —
        // safe re-run inside the publisher), and POSTs over the
        // existing term:<sid> Realtime channel as event
        // `tail_snapshot_result`. Returns false when there's
        // nothing to publish (empty buffer / no publisher
        // configured) — counted as a success here so the queue
        // marks the command delivered; iOS times out at 2 s and
        // proceeds without recovery, which is the cold-start UX.
        _ = await sessionManager.publishTailSnapshot(sessionId: sessionId, maxBytes: maxBytes)
        return (true, "")
    }

    /// Pure parser for the tail_snapshot payload. Accepts a decimal
    /// `maxBytes` (e.g. "8192"); clamps to [0, 65536] which matches
    /// the ring buffer's capacity. An empty / unparseable payload
    /// defaults to 8192 — the value the iOS side sends today.
    /// Public so unit tests can pin the wire shape.
    static func decodeTailSnapshotPayload(_ payload: String) -> Int {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 8192 }
        guard let n = Int(trimmed) else { return 8192 }
        return max(0, min(n, 65536))
    }

    private func completeCommand(cmdId: String, ok: Bool, error: String) async {
        let cfg = helperConfig()
        let params: [String: Any] = [
            "p_device_id": cfg.deviceId,
            "p_helper_secret": cfg.helperSecret,
            "p_command_id": cmdId,
            "p_status": ok ? "delivered" : "failed",
            "p_error": error.isEmpty ? NSNull() : error,
        ]
        do {
            _ = try await rpcCaller.call(
                "remote_helper_complete_command", params: params
            )
        } catch {
            log("complete_command(\(cmdId)) failed: \(error)")
        }
    }

    // MARK: - M4.4d: opting an attached external session into the cloud

    /// Opt an ATTACHED wrapped (external) session into the cloud plane so the
    /// phone can see and drive it. Explicit, per-session, and reversible — the
    /// design's hard requirement for anything that touches a session the user
    /// launched themselves (DEV_PLAN §4: "explicit opt-in + consent + one-click
    /// uninstall. Never silent").
    ///
    /// Ordering is load-bearing: mint the row FIRST, flip the opt-in only once
    /// it exists. The reverse would let the drain loop latch `local_only:false`
    /// onto frames whose `remote_helper_post_event` then raises 'Session not
    /// found for device' — and a failed event doesn't just drop, it stays at the
    /// head of the uploader's queue and stalls every later event behind it.
    ///
    /// The row is minted PRIVATE (`p_realtime_private = true`, v0.69). An
    /// external session must never be advertised on the public `term:<uuid>`
    /// topic, which bypasses RLS by design (v0.56) — anyone who learns the UUID
    /// could read the stream. The phone therefore joins the RLS-governed
    /// `pterm:` topic; since the Swift helper ships no `pterm:` producer
    /// (DEV_PLAN §2 gap 2), output reaches it through the durable event tail at
    /// ~3 s poll latency instead of a live stream. Private and correct, just not
    /// live — the honest trade until that gap closes.
    public func shareAttachedSession(sessionId: String) async -> (ok: Bool, error: String) {
        let cfg = helperConfig()
        guard cfg.isPaired else {
            return (false, "this Mac is not paired with your account")
        }
        guard let info = sessionManager.attachedSessionInfo(sessionId) else {
            return (false, "not an attached external session")
        }
        // Actor reentrancy guard (review: agy). `await`ing the RPC below is a
        // suspension point: an unshare — or a later share — can run to
        // completion in the gap and we'd resume and stomp it, silently
        // uploading against the user's LAST explicit choice. Claim a sequence
        // number now and refuse to apply if anything supersedes us.
        let mySeq = nextShareSeq(for: sessionId)

        do {
            _ = try await rpcCaller.call(
                "remote_helper_register_session",
                params: [
                    "p_device_id": cfg.deviceId,
                    "p_helper_secret": cfg.helperSecret,
                    "p_session_id": sessionId,
                    "p_provider": info.provider,
                    // No cwd: we didn't spawn this session, so we never learned
                    // its working directory. Sending a wrong one is worse than
                    // sending none — the phone renders it as the session's
                    // identity.
                    "p_cwd_basename": "",
                    "p_cwd_hmac": NSNull(),
                    "p_client_label": info.clientLabel ?? NSNull(),
                    "p_realtime_private": true,
                ]
            )
        } catch {
            log("share(\(sessionId)) register_session failed: \(error)")
            return (false, "could not register the session with the cloud: \(error)")
        }

        // Superseded while we were awaiting → the user has since said something
        // else about this session. Their later word wins; do NOT flip the flag.
        // The row we minted is harmless: no opt-in means nothing uploads to it,
        // and a concurrent unshare marks it stopped.
        guard shareSeq[sessionId] == mySeq else {
            log("share(\(sessionId)) superseded by a later opt-in change — not applying")
            return (false, "superseded by a later change")
        }

        guard sessionManager.setCloudShared(sessionId, true) != nil else {
            // The session ended between the info read and the flip. We've
            // already minted a 'running' row; mark it stopped so the phone
            // doesn't offer a dead session for the ~60 s until it goes stale.
            await postStatus(sessionId: sessionId, status: "stopped")
            return (false, "the session ended before it could be shared")
        }
        // Register our own per-session state directly rather than waiting for a
        // broker frame: share is a synchronous call, so there's no deferred-Task
        // ordering hazard here, and doing it now means the very next output_delta
        // has a batcher to land in.
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionState(
                sessionId: sessionId,
                provider: info.provider,
                clientLabel: info.clientLabel
            )
        }
        log("shared attached session \(sessionId) with the cloud (private)")
        return (true, "")
    }

    /// Revoke a previously granted opt-in. The REAL session keeps running — this
    /// ends the CLOUD's view of it, not the session.
    ///
    /// Flip the flag FIRST: from that instant the drain loop latches
    /// `local_only:true` and nothing further uploads, even if the steps after it
    /// fail. Revocation must never depend on the network.
    public func unshareAttachedSession(sessionId: String) async -> (ok: Bool, error: String) {
        // Claim the sequence FIRST so any share still awaiting its RPC resumes
        // into a superseded check and can't re-enable us (review: agy).
        _ = nextShareSeq(for: sessionId)
        guard sessionManager.setCloudShared(sessionId, false) != nil else {
            return (false, "not an attached external session")
        }
        // Drop the batcher WITHOUT flushing — whatever it holds is output the
        // user just revoked consent for. This MUST happen before the await
        // below (review: agy): `postStatus` suspends, and the uploader's tick
        // would otherwise flush the batcher we meant to discard.
        sessions.removeValue(forKey: sessionId)
        // Mark the row stopped so the session leaves the phone's list, which
        // filters on status in ('pending','running').
        await postStatus(sessionId: sessionId, status: "stopped")
        log("unshared attached session \(sessionId) — cloud view ended, session still running")
        return (true, "")
    }

    /// Monotonic per-session opt-in sequence. Bumped synchronously at the START
    /// of every share/unshare, so a call that suspends can tell on resume whether
    /// the user has since changed their mind. Actor-isolated, so the
    /// read-bump-write is atomic with respect to other calls.
    private func nextShareSeq(for sessionId: String) -> Int {
        shareSeqCounter += 1
        shareSeq[sessionId] = shareSeqCounter
        return shareSeqCounter
    }

    // MARK: - broker event handling

    private func handleBrokerEvent(_ event: [String: Any]) async {
        guard let kind = event["event"] as? String else { return }
        guard let sessionId = event["session_id"] as? String else { return }
        // M4.4a/M4.4d: an ATTACHED wrapped (external) session is LOCAL-ONLY
        // until the user explicitly opts it into the cloud — never mint a cloud
        // row nor upload its output/status (review: codex — the record's
        // `realtimePrivate` only mutes the PUBLIC Realtime sink, NOT this
        // cloud-upload path). The manager LATCHES `local_only` onto every frame,
        // so we reject from the FRAME ITSELF — NOT from live manager state. That
        // is what makes this ordering-independent: broker frames are handled on a
        // DEFERRED per-event Task (see `startObservingBroker`), so by the time
        // this runs the manager may already have removed the record; a state
        // query would then return false and let a delayed output_delta slip a row
        // in. The flag travels with the event and can't.
        //
        // Fail-closed on a MISSING flag would break every spawned session (whose
        // frames predate the key), so absent ⇒ false ⇒ upload. That's safe
        // because only the manager publishes here and it stamps the key on all
        // four attached-session frames; an attached frame can never arrive
        // without it.
        if (event["local_only"] as? Bool) == true { return }
        switch kind {
        case "session_started":
            // We register state on `start` dispatch; this branch
            // only fires for managers running their own
            // start path (e.g. local UDS). Mirror it so output_delta
            // for those still coalesces here too.
            if sessions[sessionId] == nil {
                let provider = (event["provider"] as? String) ?? "claude"
                let clientLabel = event["client_label"] as? String
                sessions[sessionId] = SessionState(
                    sessionId: sessionId,
                    provider: provider,
                    clientLabel: clientLabel
                )
            }
        case "output_delta":
            await handleOutputDelta(sessionId: sessionId, event: event)
        case "session_stopped":
            // Capture exit_code so observeExits() can post
            // 'errored' vs 'stopped' + the redacted info event.
            // Status posting itself happens in observeExits()
            // so we have a single owner.
            if let code = event["exit_code"] as? Int {
                if let state = sessions[sessionId] {
                    state.lastExitCode = code
                }
            }
        default:
            break
        }
    }

    private func handleOutputDelta(sessionId: String, event: [String: Any]) async {
        guard let payload = event["payload"] as? String, !payload.isEmpty else { return }
        let state: SessionState
        if let existing = sessions[sessionId] {
            state = existing
        } else {
            state = SessionState(sessionId: sessionId, provider: "claude", clientLabel: nil)
            sessions[sessionId] = state
        }
        if let chunk = state.batcher.add(payload) {
            await postStdoutChunk(sessionId: sessionId, chunk: chunk)
        }
    }

    private func flushIdleBatchers() async {
        for (sid, state) in sessions where state.batcher.due() {
            if let chunk = state.batcher.drain() {
                await postStdoutChunk(sessionId: sid, chunk: chunk)
            }
        }
    }

    // MARK: - observe exits

    private func observeExits() async -> Int {
        // Compare our tracked sessions to the manager's. Any session
        // we knew about that's no longer in the manager is "exited".
        let live = Set(sessionManager.listSessions().map(\.sessionId))
        var exited = 0
        for (sid, state) in sessions where !live.contains(sid) {
            // Force-flush whatever's still in the batcher BEFORE
            // posting status so the event ordering reads
            // naturally (last lines → exit code → status).
            if let chunk = state.batcher.drain() {
                await postStdoutChunk(sessionId: sid, chunk: chunk)
            }
            // Without an exit code from the broker we can't
            // distinguish 'stopped' (code 0) from 'errored'.
            // The drainLoop in ManagedSessionManager observes
            // the wstatus and publishes session_stopped with
            // exit_code; we read it from the most recent
            // recorded status, defaulting to 'stopped'.
            let status = (state.lastExitCode != nil && state.lastExitCode != 0) ? "errored" : "stopped"
            await postStatus(sessionId: sid, status: status)
            if let code = state.lastExitCode, code != 0 {
                await postInfo(sessionId: sid, detail: "exit_code=\(code)")
            }
            sessions.removeValue(forKey: sid)
            exited += 1
        }
        return exited
    }

    // MARK: - event posting helpers

    /// Post a 'status' lifecycle event. Payload MUST be exactly
    /// 'stopped' or 'errored' — the SQL gate refuses anything
    /// else. Mirrors Python `_post_status`.
    public func postStatus(sessionId: String, status: String) async {
        guard status == "stopped" || status == "errored" else {
            log("postStatus(\(sessionId)) refused unknown status \"\(status)\"")
            return
        }
        if let state = sessions[sessionId] {
            state.lastStatusPosted = status
        }
        await uploader.ingest(sessionId: sessionId, kind: .status, payload: status)
    }

    public func postInfo(sessionId: String, detail: String) async {
        if detail.isEmpty { return }
        let redacted = Redactor.redact(detail)
        if redacted.isEmpty { return }
        await uploader.ingest(sessionId: sessionId, kind: .info, payload: redacted)
    }

    public func postStdoutChunk(sessionId: String, chunk: String) async {
        if chunk.isEmpty { return }
        let redacted = Redactor.redact(chunk)
        if redacted.isEmpty { return }
        await uploader.ingest(sessionId: sessionId, kind: .stdout, payload: redacted)
    }

    // MARK: - test seam

    /// Test-only: register a session that the manager doesn't
    /// actually own (no real PTY). Used by SessionState
    /// observation tests to exercise the postStatus / batcher
    /// logic without spawning `cat`.
    public func registerTestSession(
        sessionId: String,
        provider: String = "claude",
        clientLabel: String? = nil
    ) {
        sessions[sessionId] = SessionState(
            sessionId: sessionId,
            provider: provider,
            clientLabel: clientLabel
        )
    }

    /// Test-only: feed a chunk into a session's batcher as if it
    /// came from the broker. Use to exercise idle-flush and
    /// overflow paths without wiring a real PtyTransport.
    public func injectStdoutChunk(sessionId: String, chunk: String) async {
        var state = sessions[sessionId]
        if state == nil {
            state = SessionState(sessionId: sessionId, provider: "claude", clientLabel: nil)
            sessions[sessionId] = state
        }
        if let payload = state?.batcher.add(chunk) {
            await postStdoutChunk(sessionId: sessionId, chunk: payload)
        }
    }

    /// Test-only: flush any batchers currently due. Mirrors
    /// `flushIdleBatchers` from the tick path.
    public func flushBatchersForTesting() async {
        await flushIdleBatchers()
    }

    /// Test-only: drive a single broker frame through the observer (so the
    /// attached-session cloud-skip can be asserted end-to-end).
    public func handleBrokerEventForTesting(_ event: [String: Any]) async {
        await handleBrokerEvent(event)
    }

    /// Test-only: drive one inbound cloud command through the dispatcher (so the
    /// attached-session command-reject can be asserted).
    public func dispatchOneForTesting(_ cmd: [String: Any]) async {
        await dispatchOne(cmd)
    }

    /// Test-only: number of cloud session states the observer is tracking (an
    /// attached session must NEVER create one).
    public var trackedSessionCountForTesting: Int { sessions.count }

    /// Test-only: simulate `session_stopped` broker frame so we
    /// can drive observeExits() without a real PtyTransport.
    public func recordExitForTesting(sessionId: String, exitCode: Int) {
        if let state = sessions[sessionId] {
            state.lastExitCode = exitCode
        }
    }

    /// Test-only: drive observeExits() directly. Mirrors what
    /// happens in tick() after the manager's listSessions
    /// reports the session is gone.
    @discardableResult
    public func observeExitsForTesting() async -> Int {
        return await observeExits()
    }

    // MARK: - private

    private func describe(_ err: ManagedSessionManager.ManagerError) -> String {
        switch err {
        case .unsupportedProvider(let p): return "unsupported provider: \(p)"
        case .spawnFailed(let s): return s
        case .sessionNotFound(let s): return "session not found: \(s)"
        case .writeFailed(let s): return "write failed: \(s)"
        }
    }

    private func log(_ msg: String) {
        onLog?(msg)
    }
}
