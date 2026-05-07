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
            if !sessionManager.ownsSession(sessionId) {
                outcome = (false, "session not running on this helper")
            } else {
                _ = sessionManager.stopSession(sessionId)
                await postStatus(sessionId: sessionId, status: "stopped")
                sessions.removeValue(forKey: sessionId)
                outcome = (true, "")
            }
        case "interrupt":
            if !sessionManager.ownsSession(sessionId) {
                outcome = (false, "session not running on this helper")
            } else {
                _ = sessionManager.interruptSession(sessionId)
                outcome = (true, "")
            }
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
        var provider = "claude"
        var cwdHmac: String?
        var clientLabel: String?
        if !payload.isEmpty,
           let data = payload.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let p = obj["provider"] as? String { provider = p }
            if let h = obj["cwd_hmac"] as? String, !h.isEmpty { cwdHmac = h }
            if let lbl = obj["client_label"] as? String, !lbl.isEmpty { clientLabel = lbl }
        } else if !payload.isEmpty {
            return (false, "invalid start payload")
        }
        if provider != "claude" {
            return (false, "provider \"\(provider)\" not supported in iter 1")
        }

        // Pre-set the env var so remote_hook can bind permission
        // requests back to this session. extraEnv merges via the
        // manager into PtyTransport.start.
        let extraEnv = ["CLI_PULSE_REMOTE_SESSION_ID": sessionId]
        let summary: ManagedSessionManager.Summary
        do {
            summary = try sessionManager.startSession(
                provider: provider,
                clientLabel: clientLabel,
                cwd: nil,
                extraEnv: extraEnv,
                forcedSessionId: sessionId
            )
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
            ok = try sessionManager.sendInput(sessionId: sessionId, payload: payload)
        } catch {
            return (false, "child exited")
        }
        return ok ? (true, "") : (false, "child exited")
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

    // MARK: - broker event handling

    private func handleBrokerEvent(_ event: [String: Any]) async {
        guard let kind = event["event"] as? String else { return }
        guard let sessionId = event["session_id"] as? String else { return }
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
