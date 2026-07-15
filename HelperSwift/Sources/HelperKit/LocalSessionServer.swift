import Foundation

/// Swift port of `helper/local_session_server.py:LocalSessionServer`.
///
/// Iter 1 of the Swift port covers the bare minimum surface that
/// lets a Swift client speak the protocol end-to-end: framing,
/// auth-token enforcement, hello / ping. iter 2+ ports
/// start_session / list_sessions / stop_session / send_input,
/// approvals, streaming, hook ingress.
///
/// The Python implementation uses one accept thread + one
/// connection thread per peer. We follow the same model in Swift
/// to keep the code shape recognisable across the port:
///
///   - One `accept` Thread that loops on `accept(2)` and hands
///     each connection off to a per-connection Thread.
///   - One per-connection Thread that calls `Framing.readFrame`
///     in a loop until EOF / error.
///
/// Foundation's higher-level networking APIs (NWConnection,
/// URLSession) don't expose AF_UNIX cleanly, so we go straight
/// to BSD sockets via libc here.
public final class LocalSessionServer: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var socketPath: URL
        public var subscribeIdleTimeoutSeconds: Double
        public var maxPayload: Int

        public init(
            socketPath: URL,
            subscribeIdleTimeoutSeconds: Double = 30.0,
            maxPayload: Int = Framing.maxPayload
        ) {
            self.socketPath = socketPath
            self.subscribeIdleTimeoutSeconds = subscribeIdleTimeoutSeconds
            self.maxPayload = maxPayload
        }
    }

    /// Callbacks the daemon supplies to plumb the helper's
    /// in-memory state into the protocol surface. One callable per
    /// concept rather than one big delegate object — matches the
    /// Python LocalSessionServer constructor signature so a
    /// reviewer reading both can pair them up.
    public struct Hooks: Sendable {
        public var getAuthToken: @Sendable () -> String
        public var isLocalControlEnabled: @Sendable () -> Bool
        public var setLocalControlEnabled: @Sendable (Bool) -> Void
        /// Returns `nil` when the helper hasn't recorded an argv0
        /// yet — the install_claude_hook method surfaces
        /// `notImplemented` in that case so the macOS app can
        /// fall back to "Copy command".
        public var getHelperArgv0: @Sendable () -> String?
        /// Iter 3: managed session lifecycle. The daemon supplies
        /// a `ManagedSessionManager`; the server forwards
        /// start/list/stop/send_input to it.
        public var sessionManager: ManagedSessionManager?
        /// Iter 3: list of read-only Claude sessions detected on
        /// the same Mac (psutil-equivalent process scan). Iter 7
        /// wires this in; iter 3 stub returns empty.
        public var listDetectedSessions: @Sendable () -> [[String: Any]]
        /// Iter 4: approval registry for hook ingress + the
        /// `approve_action` / `get_pending_approvals` methods.
        /// Optional so iter 1-3 unit tests can omit it.
        public var approvalRegistry: ApprovalRegistry?
        /// Iter 6: event broker that drives `subscribe_events`.
        /// When nil, the server returns notImplemented for that
        /// method.
        public var eventBroker: EventBroker?
        /// #18c: override the ~/.claude/settings.json path the install/uninstall
        /// verbs write. `nil` (default) → the real path. A HELPER-side seam only
        /// (tests + never the app) — the anti-tamper guarantee is unchanged: the
        /// socket peer still can't pass a path.
        public var claudeSettingsPathOverride: @Sendable () -> URL?
        /// M2p2: same seam for the codex verbs' ~/.codex/hooks.json target.
        /// Helper-side only; the socket peer can never pass a path.
        public var codexSettingsPathOverride: @Sendable () -> URL?

        public init(
            getAuthToken: @escaping @Sendable () -> String,
            isLocalControlEnabled: @escaping @Sendable () -> Bool = { true },
            setLocalControlEnabled: @escaping @Sendable (Bool) -> Void = { _ in },
            getHelperArgv0: @escaping @Sendable () -> String? = { nil },
            sessionManager: ManagedSessionManager? = nil,
            listDetectedSessions: @escaping @Sendable () -> [[String: Any]] = { [] },
            approvalRegistry: ApprovalRegistry? = nil,
            eventBroker: EventBroker? = nil,
            claudeSettingsPathOverride: @escaping @Sendable () -> URL? = { nil },
            codexSettingsPathOverride: @escaping @Sendable () -> URL? = { nil }
        ) {
            self.getAuthToken = getAuthToken
            self.isLocalControlEnabled = isLocalControlEnabled
            self.setLocalControlEnabled = setLocalControlEnabled
            self.getHelperArgv0 = getHelperArgv0
            self.sessionManager = sessionManager
            self.listDetectedSessions = listDetectedSessions
            self.approvalRegistry = approvalRegistry
            self.eventBroker = eventBroker
            self.claudeSettingsPathOverride = claudeSettingsPathOverride
            self.codexSettingsPathOverride = codexSettingsPathOverride
        }
    }

    private let config: Configuration
    private let hooks: Hooks
    private var listenFD: Int32 = -1
    /// Inode of the socket file this server actually bound (captured right
    /// after bind). stop() only unlinks the path if it STILL refers to this
    /// inode — so an exiting instance never deletes a NEWER instance's socket
    /// (the update/restart overlap race that left a live helper with no socket
    /// file → app reported "not running").
    private var boundSocketInode: ino_t?
    private var acceptThread: Thread?
    private let stopFlag = AtomicBool()
    private let connsLock = NSLock()
    private var conns: [Int32] = []

    public init(config: Configuration, hooks: Hooks) {
        self.config = config
        self.hooks = hooks
    }

    // MARK: - lifecycle

    public func start() throws {
        // Stale-socket recovery: a leftover file from a crashed previous helper
        // must be unlinked before bind. But DON'T blindly unlink — an
        // overlapping LIVE helper (two instances briefly coexisting during an
        // update/restart) may own this socket. Connect-probe first: if a server
        // answers, refuse to bind and let the live instance keep serving rather
        // than yanking its socket out from under it (which left the process
        // running but the path gone → app reported "not running"). Only a
        // stale/dead socket is unlinked.
        let path = config.socketPath.path
        if FileManager.default.fileExists(atPath: path) {
            if Self.isSocketAlive(atPath: path) {
                throw ServerError.alreadyRunning(path)
            }
            try? FileManager.default.removeItem(atPath: path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw ServerError.socketCreate(errnoMsg()) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = (path as NSString).fileSystemRepresentation
        let pathLen = strlen(pathBytes)
        if pathLen >= MemoryLayout.size(ofValue: addr.sun_path) {
            Darwin.close(fd)
            throw ServerError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            memcpy(rawPtr.baseAddress!, pathBytes, pathLen)
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            let msg = errnoMsg()
            Darwin.close(fd)
            throw ServerError.bind(msg)
        }
        // Restrict socket to user via mode 0600.
        chmod(pathBytes, 0o600)
        // Record the bound socket's inode so stop() only removes OUR socket,
        // never a newer instance's that rebound the same path. Guarded by
        // connsLock: stop() runs on the SIGTERM/SIGINT DispatchSource's global
        // queue, so boundSocketInode is touched from two threads.
        var bound = stat()
        if stat(pathBytes, &bound) == 0 {
            connsLock.lock()
            boundSocketInode = bound.st_ino
            connsLock.unlock()
        }

        if Darwin.listen(fd, 8) != 0 {
            let msg = errnoMsg()
            Darwin.close(fd)
            throw ServerError.listen(msg)
        }

        listenFD = fd
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "cli-pulse-uds-accept"
        acceptThread = thread
        thread.start()
    }

    public func stop() {
        guard listenFD >= 0 else { return }
        stopFlag.set(true)
        // Wake the accept loop by closing the listen fd —
        // accept() returns EBADF and the loop exits.
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        listenFD = -1
        connsLock.lock()
        let toClose = conns
        conns.removeAll()
        connsLock.unlock()
        for fd in toClose {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        // Best-effort socket file cleanup so the next start() can bind cleanly.
        // Only remove the file if it's STILL our socket (inode match): during an
        // update/restart overlap a newer instance may have already rebound the
        // path, and we must not delete ITS socket.
        connsLock.lock()
        let mine = boundSocketInode
        boundSocketInode = nil
        connsLock.unlock()
        if let mine {
            var cur = stat()
            let p = (config.socketPath.path as NSString).fileSystemRepresentation
            if stat(p, &cur) == 0, cur.st_ino == mine {
                try? FileManager.default.removeItem(at: config.socketPath)
            }
        }
    }

    // MARK: - accept loop

    private func acceptLoop() {
        while !stopFlag.get() {
            var peer = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connFD = withUnsafeMutablePointer(to: &peer) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(listenFD, saPtr, &len)
                }
            }
            if connFD < 0 {
                if stopFlag.get() { return }
                if errno == EINTR { continue }
                // Other errors: typically EBADF when stop()
                // closes the listener. Just exit the loop.
                return
            }
            connsLock.lock()
            conns.append(connFD)
            connsLock.unlock()
            let connThread = Thread { [weak self] in
                self?.serveConnection(fd: connFD)
            }
            connThread.name = "cli-pulse-uds-conn"
            connThread.start()
        }
    }

    // MARK: - connection serving

    private func serveConnection(fd: Int32) {
        defer {
            connsLock.lock()
            conns.removeAll { $0 == fd }
            connsLock.unlock()
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        while !stopFlag.get() {
            let body: Data?
            do {
                body = try Framing.readFrame(from: fd)
            } catch {
                // Framing error → typed error frame, then close.
                let resp = framingErrorToResponse(error: error)
                try? sendResponse(fd: fd, response: resp)
                return
            }
            guard let payload = body else { return }   // clean EOF
            // Inspect the request first so we can branch on
            // subscribe_events (which takes over the connection).
            let raw: Any
            do {
                raw = try JSONSerialization.jsonObject(with: payload, options: [])
            } catch {
                let r = WireResponse.err(id: "", code: .badRequest, message: "invalid JSON")
                try? sendResponse(fd: fd, response: r)
                return
            }
            guard let dict = raw as? [String: Any],
                  let request = try? WireRequest.decode(from: dict) else {
                let r = WireResponse.err(id: "", code: .badRequest, message: "request decode failed")
                try? sendResponse(fd: fd, response: r)
                return
            }
            if request.method == SupportedMethod.subscribeEvents.rawValue {
                runStreamingLoop(fd: fd, request: request)
                return
            }
            let resp = dispatch(request: request, peerFD: fd)
            do {
                try sendResponse(fd: fd, response: resp)
            } catch {
                return
            }
        }
    }

    /// Drive a `subscribe_events` connection. Writes the initial
    /// snapshot ack frame, then frame-encodes each event published
    /// to the broker subscription until the peer closes or the
    /// server stops. Connection is cleaned up by the outer
    /// `serveConnection` defer block.
    private func runStreamingLoop(fd: Int32, request: WireRequest) {
        // Auth check — same as the non-streaming dispatch path.
        if let token = request.authToken {
            if !AuthToken.compare(expected: hooks.getAuthToken(), supplied: token) {
                let r = WireResponse.err(id: request.id, code: .unauthenticated, message: "invalid auth_token")
                try? sendResponse(fd: fd, response: r)
                return
            }
        } else {
            let r = WireResponse.err(id: request.id, code: .unauthenticated, message: "auth_token required")
            try? sendResponse(fd: fd, response: r)
            return
        }
        if !hooks.isLocalControlEnabled() {
            let r = WireResponse.err(id: request.id, code: .localControlOff, message: "local_control_enabled is false")
            try? sendResponse(fd: fd, response: r)
            return
        }
        guard let broker = hooks.eventBroker else {
            let r = WireResponse.err(id: request.id, code: .notImplemented, message: "event broker not configured")
            try? sendResponse(fd: fd, response: r)
            return
        }
        let sessionFilter = request.params["session_id"] as? String

        // Build the initial snapshot frame — gives the macOS
        // app a deterministic catch-up state without a second
        // round-trip.
        let managed: [[String: Any]] = hooks.sessionManager?.listSessions().map { s in
            return [
                "session_id": s.sessionId,
                "provider": s.provider,
                "client_label": s.clientLabel ?? NSNull(),
                "spawned_at_monotonic": s.spawnedAtMono,
                "status": s.status,
            ]
        } ?? []
        let initialPending = (hooks.approvalRegistry?.listPending(sessionId: sessionFilter) ?? [])
            .map { $0.toDictSafe() }
        var initial: [String: Any] = [
            "subscribed": true,
            "session_id": sessionFilter ?? NSNull(),
            "managed_sessions": managed,
            "pending_approvals": initialPending,
        ]

        // Subscribe BEFORE writing the ack so we don't miss any
        // event published in the gap between the two writes.
        // Concurrent publishes are buffered into the subscription's
        // internal queue.
        let queue = StreamQueue()
        let subscription = broker.subscribe(sessionFilter: sessionFilter) { event in
            queue.put(event)
        }
        _ = initial    // (initial used below, separate so the
        // subscribe site comes before)
        defer { broker.unsubscribe(subscription) }

        let ackResponse = WireResponse.ok(id: request.id, result: initial)
        do {
            try sendResponse(fd: fd, response: ackResponse)
        } catch {
            return
        }

        // Background reader: detects peer EOF without coupling to
        // the queue.get() blocking call on the publish thread.
        let closeFlag = AtomicBool()
        let reader = Thread { [closeFlag] in
            let bufSize = 4096
            var buf = [UInt8](repeating: 0, count: bufSize)
            while !closeFlag.get() {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    return Darwin.read(fd, ptr.baseAddress, bufSize)
                }
                if n <= 0 {
                    closeFlag.set(true)
                    return
                }
                // Spurious bytes from a misbehaving client; ignore.
            }
        }
        reader.name = "cli-pulse-uds-stream-eof"
        reader.start()

        // Drain the queue + write each frame. Idle timeout
        // matches Python (30s) — without one the queue.get
        // blocks forever even if the peer goes away.
        let idleTimeout = config.subscribeIdleTimeoutSeconds
        while !stopFlag.get() && !closeFlag.get() {
            guard let event = queue.poll(timeout: idleTimeout) else {
                continue
            }
            // Frame-encode the event dict and write.
            do {
                let data = try JSONSerialization.data(withJSONObject: event)
                try Framing.writeFrame(to: fd, body: data)
            } catch {
                // Write error usually = peer disconnect; stop.
                return
            }
        }
    }

    private func handleFrame(payload: Data, peerFD: Int32 = -1) -> WireResponse {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: payload, options: [])
        } catch {
            return .err(id: "", code: .badRequest, message: "invalid JSON: \(error.localizedDescription)")
        }
        guard let dict = raw as? [String: Any] else {
            return .err(id: "", code: .badRequest, message: "request root must be a JSON object")
        }
        let request: WireRequest
        do {
            request = try WireRequest.decode(from: dict)
        } catch WireDecodeError.missingMethod {
            return .err(id: "", code: .badRequest, message: "'method' required")
        } catch {
            return .err(id: "", code: .badRequest, message: "request decode failed")
        }
        return dispatch(request: request, peerFD: peerFD)
    }

    private func dispatch(request: WireRequest, peerFD: Int32 = -1) -> WireResponse {
        guard let method = SupportedMethod(rawValue: request.method) else {
            return .err(id: request.id, code: .unknownMethod, message: "method not supported: \(request.method)")
        }
        // Auth-table enforcement matches the Python `_dispatch`.
        if method.isHookAuth {
            // Hook-side ingress: app token is rejected here.
            if request.authToken != nil {
                return .err(id: request.id, code: .badRequest, message: "hook methods do not accept the app auth_token; use session_token + session_id")
            }
            return handleHookIngress(method: method, request: request, peerFD: peerFD)
        }
        if !method.bypassesAuth {
            // App methods reject the per-session token.
            if request.sessionToken != nil {
                return .err(id: request.id, code: .badRequest, message: "app methods do not accept session_token; use auth_token")
            }
            guard let supplied = request.authToken else {
                return .err(id: request.id, code: .unauthenticated, message: "auth_token required")
            }
            let expected = hooks.getAuthToken()
            if !AuthToken.compare(expected: expected, supplied: supplied) {
                return .err(id: request.id, code: .unauthenticated, message: "invalid auth_token")
            }
        }
        if !method.bypassesGate && !hooks.isLocalControlEnabled() {
            return .err(id: request.id, code: .localControlOff, message: "local_control_enabled is false")
        }
        return handleAuthenticated(method: method, request: request)
    }

    private func handleAuthenticated(method: SupportedMethod, request: WireRequest) -> WireResponse {
        switch method {
        case .hello:
            // v1.15: include the list of providers whose CLI binary
            // the helper can actually spawn on this host. The macOS
            // / iOS spawn picker uses this to gray out unavailable
            // providers in the dropdown so users don't try to start
            // a Codex session on a Mac that doesn't have Codex
            // installed. Falls back to a defensive empty list when
            // the manager doesn't expose a registry (e.g. tests
            // configuring `LocalSessionServer` without a session
            // manager hook).
            let providerAvailability: [String]
            let providerPlanStatus: [String: String]
            if let mgr = hooks.sessionManager {
                providerAvailability = mgr.availableProviders()
                providerPlanStatus = mgr.providerPlanStatus()
            } else {
                providerAvailability = []
                providerPlanStatus = [:]
            }
            return .ok(id: request.id, result: [
                "protocol_version": kProtocolVersion,
                // v1.34 R1d: advertise our semantic version so the app can gate
                // managed Claude sessions on the SOCKET OWNER being >= the
                // OAuth-injection floor (1.20.0). Mirrors the Python helper's
                // `helper_version` (local_session_server.py). Without this the
                // app couldn't distinguish this injection-capable Swift helper
                // from a pre-injection one (both reported no version).
                "helper_version": kHelperVersion,
                "supported_methods": SupportedMethod.allCases.map(\.rawValue),
                "helper_pid": Int(getpid()),
                "capabilities": [
                    "send_input": true,
                    "subscribe_events": true,
                    "approvals": true,
                ],
                "provider_availability": providerAvailability,
                // Per-provider plan-auth status ("on_plan"/"off_plan") so the picker can
                // warn before silently launching an off-plan (billed) managed session
                // (e.g. Codex with an api-key login). Omits "unknown" providers.
                "provider_plan_status": providerPlanStatus,
            ])
        case .ping:
            return .ok(id: request.id, result: ["pong": true])
        case .getLocalControlStatus:
            return .ok(id: request.id, result: [
                "local_control_enabled": hooks.isLocalControlEnabled(),
                "protocol_version": kProtocolVersion,
            ])
        case .setLocalControlEnabled:
            guard let enabled = request.params["enabled"] as? Bool else {
                return .err(id: request.id, code: .badRequest, message: "'enabled' must be a boolean")
            }
            hooks.setLocalControlEnabled(enabled)
            return .ok(id: request.id, result: ["local_control_enabled": hooks.isLocalControlEnabled()])
        case .startSession:
            return handleStartSession(request: request)
        case .listSessions:
            return handleListSessions(request: request)
        case .stopSession:
            return handleStopSession(request: request)
        case .sendInput:
            return handleSendInput(request: request)
        case .sendInputRaw:
            return handleSendInputRaw(request: request)
        case .resize:
            return handleResize(request: request)
        case .getTailSnapshot:
            return handleGetTailSnapshot(request: request)
        case .getPendingApprovals:
            return handleGetPendingApprovals(request: request)
        case .approveAction:
            return handleApproveAction(request: request)
        case .installClaudeHook:
            return handleInstallClaudeHook(request: request)
        case .uninstallClaudeHook:
            return handleUninstallClaudeHook(request: request)
        case .installCodexHook:
            return handleInstallCodexHook(request: request)
        case .uninstallCodexHook:
            return handleUninstallCodexHook(request: request)
        case .listWrappedSessions:
            return handleListWrappedSessions(request: request)
        case .attachWrappedSession:
            return handleAttachWrappedSession(request: request)
        case .shellIntegrationStatus:
            return handleShellIntegration(request: request, action: .status)
        case .shellIntegrationInstall:
            return handleShellIntegration(request: request, action: .install)
        case .shellIntegrationUninstall:
            return handleShellIntegration(request: request, action: .uninstall)
        default:
            return .err(id: request.id, code: .notImplemented, message: "method \(request.method) lands in a later iter of the Swift port")
        }
    }

    // MARK: - iter3 method handlers

    private func handleStartSession(request: WireRequest) -> WireResponse {
        guard let mgr = hooks.sessionManager else {
            return .err(id: request.id, code: .notImplemented, message: "session manager not configured on this helper")
        }
        let provider = (request.params["provider"] as? String) ?? "claude"
        let clientLabel = request.params["client_label"] as? String
        let cwd = request.params["cwd"] as? String
        do {
            let summary = try mgr.startSession(provider: provider, clientLabel: clientLabel, cwd: cwd)
            return .ok(id: request.id, result: [
                "session_id": summary.sessionId,
                "ok": true,
            ])
        } catch ManagedSessionManager.ManagerError.unsupportedProvider(let p) {
            return .err(id: request.id, code: .badRequest, message: "unsupported provider: \(p)")
        } catch ManagedSessionManager.ManagerError.spawnFailed(let m) {
            return .err(id: request.id, code: .internalError, message: "spawn failed: \(m)")
        } catch {
            return .err(id: request.id, code: .internalError, message: "start_session: \(error)")
        }
    }

    private func handleListSessions(request: WireRequest) -> WireResponse {
        let managed: [[String: Any]] = hooks.sessionManager?.listSessions().map { s in
            return [
                "session_id": s.sessionId,
                "provider": s.provider,
                "client_label": s.clientLabel ?? NSNull(),
                "spawned_at_monotonic": s.spawnedAtMono,
                "status": s.status,
                "controllable": true,
                "source": "managed",
            ]
        } ?? []
        let detected = hooks.listDetectedSessions()
        return .ok(id: request.id, result: [
            "managed": managed,
            "detected": detected,
            "sessions": managed,   // legacy alias the macOS app still reads
        ])
    }

    private func handleStopSession(request: WireRequest) -> WireResponse {
        guard let sid = request.params["session_id"] as? String, !sid.isEmpty else {
            return .err(id: request.id, code: .badRequest, message: "'session_id' required")
        }
        guard let mgr = hooks.sessionManager else {
            return .err(id: request.id, code: .notImplemented, message: "session manager not configured")
        }
        let stopped = mgr.stopSession(sid)
        if !stopped {
            // Match Python: detected-only sessions return
            // not_controllable; missing managed sessions return
            // session_not_found.
            return .err(id: request.id, code: .sessionNotFound, message: "no managed session with id '\(sid)'")
        }
        return .ok(id: request.id, result: ["session_id": sid, "stopped": true])
    }

    private func handleSendInput(request: WireRequest) -> WireResponse {
        guard let sid = request.params["session_id"] as? String, !sid.isEmpty else {
            return .err(id: request.id, code: .badRequest, message: "'session_id' must be a non-empty string")
        }
        guard let payload = request.params["payload"] as? String else {
            return .err(id: request.id, code: .badRequest, message: "'payload' must be a string")
        }
        guard let mgr = hooks.sessionManager else {
            return .err(id: request.id, code: .notImplemented, message: "session manager not configured")
        }
        do {
            let written = try mgr.sendInput(sessionId: sid, payload: payload)
            if !written {
                return .err(id: request.id, code: .sessionNotFound, message: "no managed session with id '\(sid)'")
            }
            return .ok(id: request.id, result: [
                "session_id": sid,
                "written": true,
            ])
        } catch {
            return .err(id: request.id, code: .internalError, message: "send_input failed: \(error)")
        }
    }

    /// v1.24 Phase 2b — raw byte input from the in-app terminal viewport
    /// (xterm.js `onData`). `payload_base64` is base64-encoded so we
    /// preserve all control bytes (0x03 Ctrl-C, 0x04 Ctrl-D, ESC
    /// sequences) without JSON-string-escape ambiguity.
    private func handleSendInputRaw(request: WireRequest) -> WireResponse {
        guard let sid = request.params["session_id"] as? String, !sid.isEmpty else {
            return .err(id: request.id, code: .badRequest, message: "'session_id' must be a non-empty string")
        }
        guard let b64 = request.params["payload_base64"] as? String else {
            return .err(id: request.id, code: .badRequest, message: "'payload_base64' must be a string")
        }
        guard let bytes = Data(base64Encoded: b64) else {
            return .err(id: request.id, code: .badRequest, message: "'payload_base64' is not valid base64")
        }
        guard let mgr = hooks.sessionManager else {
            return .err(id: request.id, code: .notImplemented, message: "session manager not configured")
        }
        do {
            let written = try mgr.sendInputRaw(sessionId: sid, bytes: bytes)
            if !written {
                return .err(id: request.id, code: .sessionNotFound, message: "no managed session with id '\(sid)'")
            }
            return .ok(id: request.id, result: [
                "session_id": sid,
                "written": true,
                "bytes": bytes.count,
            ])
        } catch {
            return .err(id: request.id, code: .internalError, message: "send_input_raw failed: \(error)")
        }
    }

    /// v1.24 Phase 2c slice 1 — return up to `max_bytes` (default
    /// 8192, capped at 65536) of the most-recent stdout, redacted.
    /// Powers the iOS WKWebView's foreground-recovery path.
    /// Result: `{ session_id, bytes_base64, bytes }`.
    private func handleGetTailSnapshot(request: WireRequest) -> WireResponse {
        guard let sid = request.params["session_id"] as? String, !sid.isEmpty else {
            return .err(id: request.id, code: .badRequest, message: "'session_id' must be a non-empty string")
        }
        let maxBytes = (request.params["max_bytes"] as? Int) ?? 8192
        guard maxBytes >= 0 else {
            return .err(id: request.id, code: .badRequest, message: "'max_bytes' must be non-negative")
        }
        guard let mgr = hooks.sessionManager else {
            return .err(id: request.id, code: .notImplemented, message: "session manager not configured")
        }
        guard let snap = mgr.getTailSnapshot(sessionId: sid, maxBytes: maxBytes) else {
            return .err(id: request.id, code: .sessionNotFound, message: "no managed session with id '\(sid)'")
        }
        return .ok(id: request.id, result: [
            "session_id": sid,
            "bytes_base64": snap.base64EncodedString(),
            "bytes": snap.count,
        ])
    }

    /// v1.24 Phase 2b — window-size update from the in-app terminal
    /// viewport (xterm.js `onResize` / FitAddon). Triggers SIGWINCH
    /// on the child via TIOCSWINSZ.
    private func handleResize(request: WireRequest) -> WireResponse {
        guard let sid = request.params["session_id"] as? String, !sid.isEmpty else {
            return .err(id: request.id, code: .badRequest, message: "'session_id' must be a non-empty string")
        }
        let colsRaw = request.params["cols"] as? Int ?? -1
        let rowsRaw = request.params["rows"] as? Int ?? -1
        guard colsRaw > 0, colsRaw <= 1000, rowsRaw > 0, rowsRaw <= 1000 else {
            return .err(id: request.id, code: .badRequest, message: "'cols' and 'rows' must be positive integers ≤ 1000")
        }
        guard let mgr = hooks.sessionManager else {
            return .err(id: request.id, code: .notImplemented, message: "session manager not configured")
        }
        let ok = mgr.resize(sessionId: sid, cols: UInt16(colsRaw), rows: UInt16(rowsRaw))
        if !ok {
            return .err(id: request.id, code: .sessionNotFound, message: "no managed session with id '\(sid)' (or resize ioctl failed)")
        }
        return .ok(id: request.id, result: [
            "session_id": sid,
            "cols": colsRaw,
            "rows": rowsRaw,
        ])
    }

    private func handleGetPendingApprovals(request: WireRequest) -> WireResponse {
        let sid = request.params["session_id"] as? String
        let pending = hooks.approvalRegistry?.listPending(sessionId: sid) ?? []
        return .ok(id: request.id, result: [
            "pending_approvals": pending.map { $0.toDictSafe() },
        ])
    }

    private func handleApproveAction(request: WireRequest) -> WireResponse {
        guard let sid = request.params["session_id"] as? String,
              let approvalId = request.params["approval_id"] as? String,
              let decision = request.params["decision"] as? String else {
            return .err(id: request.id, code: .badRequest, message: "'session_id', 'approval_id', 'decision' required")
        }
        let comment = request.params["comment"] as? String
        guard let registry = hooks.approvalRegistry else {
            return .err(id: request.id, code: .notImplemented, message: "approval registry not configured")
        }
        do {
            let resolved = try registry.decide(
                sessionId: sid, approvalId: approvalId,
                decision: decision, comment: comment
            )
            return .ok(id: request.id, result: resolved.toDictSafe())
        } catch ApprovalRegistry.RegistryError.approvalNotFound {
            return .err(id: request.id, code: .approvalNotFound, message: "approval not found")
        } catch ApprovalRegistry.RegistryError.approvalNotAllowed {
            return .err(id: request.id, code: .approvalNotAllowed, message: "approval id does not belong to this session")
        } catch ApprovalRegistry.RegistryError.approvalAlreadyResolved(let s) {
            return .err(id: request.id, code: .approvalAlreadyResolved, message: "already resolved (status=\(s))")
        } catch {
            return .err(id: request.id, code: .internalError, message: "approve_action: \(error)")
        }
    }

    private func handleInstallClaudeHook(request: WireRequest) -> WireResponse {
        // M1/#18c: RE-ACTIVATED (owner-approved). Managed sessions inject the
        // hook inline at spawn, but EXTERNAL (hand-launched) Claude can't be —
        // it needs the global ~/.claude/settings.json install to route its
        // approvals through CLI Pulse. This writes BOTH events (PermissionRequest
        // + PreToolUse) via ClaudeSettingsInstaller. Runs only from an explicit
        // app-authenticated + local-control-gated opt-in (the user's Install
        // toggle). The helper supplies its OWN argv[0] as the hook command — the
        // app must NOT pass a path (anti-tamper: a socket peer can't reroute the
        // hook at a third-party binary).
        guard let helperPath = hooks.getHelperArgv0() else {
            return .err(id: request.id, code: .notImplemented,
                        message: "helper did not record its own argv[0] — install_claude_hook unavailable")
        }
        do {
            let result = try ClaudeSettingsInstaller.install(
                helperPath: helperPath, settingsPath: hooks.claudeSettingsPathOverride())
            var events: [String: Any] = [:]
            for (event, action) in result.events { events[event] = action.rawValue }
            return .ok(id: request.id, result: [
                "settings_path": result.settingsPath,
                "action": result.action.rawValue,
                "previous_command": result.previousCommand ?? NSNull(),
                "new_command": result.newCommand,
                "events": events,
            ])
        } catch let err as ClaudeSettingsInstaller.InstallError {
            if case .malformedSettings(let msg) = err {
                return .err(id: request.id, code: .settingsMalformed, message: msg)
            }
            return .err(id: request.id, code: .internalError, message: "\(err)")
        } catch {
            return .err(id: request.id, code: .internalError, message: "\(error)")
        }
    }

    private func handleUninstallClaudeHook(request: WireRequest) -> WireResponse {
        // M1c/#18c: the reversible other half of the opt-in — remove the CLI
        // Pulse hooks (both events) from ~/.claude/settings.json, preserving the
        // user's own hooks. No helper path needed (removal is by marker). Same
        // app-auth + local-control gating as install.
        do {
            let result = try ClaudeSettingsInstaller.uninstall(
                settingsPath: hooks.claudeSettingsPathOverride())
            var events: [String: Any] = [:]
            for (event, removed) in result.events { events[event] = removed }
            return .ok(id: request.id, result: [
                "settings_path": result.settingsPath,
                "action": result.action,
                "removed": result.removed,
                "events": events,
            ])
        } catch let err as ClaudeSettingsInstaller.InstallError {
            if case .malformedSettings(let msg) = err {
                return .err(id: request.id, code: .settingsMalformed, message: msg)
            }
            return .err(id: request.id, code: .internalError, message: "\(err)")
        } catch {
            return .err(id: request.id, code: .internalError, message: "\(error)")
        }
    }

    private func handleInstallCodexHook(request: WireRequest) -> WireResponse {
        // M2p2 codex-Swift port: the Codex counterpart of install_claude_hook.
        // Same helper-owns-argv[0] anti-tamper, same idempotency/auto-heal, but
        // targets ~/.codex/hooks.json with the `--provider codex` marker (fully
        // independent of the claude install even co-resident in one file).
        // Codex requires a one-time `/hooks` TUI trust that CANNOT be automated;
        // the result carries requires_manual_trust/trust_command so the client
        // renders that step — matching the Python #357 payload.
        guard let helperPath = hooks.getHelperArgv0() else {
            return .err(id: request.id, code: .notImplemented,
                        message: "helper did not record its own argv[0] — install_codex_hook unavailable")
        }
        do {
            let result = try ClaudeSettingsInstaller.install(
                helperPath: helperPath, settingsPath: hooks.codexSettingsPathOverride(),
                provider: "codex")
            var events: [String: Any] = [:]
            for (event, action) in result.events { events[event] = action.rawValue }
            return .ok(id: request.id, result: [
                "settings_path": result.settingsPath,
                "action": result.action.rawValue,
                "previous_command": result.previousCommand ?? NSNull(),
                "new_command": result.newCommand,
                "events": events,
                "requires_manual_trust": result.requiresManualTrust,
                "trust_command": result.trustCommand ?? NSNull(),
            ])
        } catch let err as ClaudeSettingsInstaller.InstallError {
            if case .malformedSettings(let msg) = err {
                return .err(id: request.id, code: .settingsMalformed, message: msg)
            }
            return .err(id: request.id, code: .internalError, message: "\(err)")
        } catch {
            return .err(id: request.id, code: .internalError, message: "\(error)")
        }
    }

    private func handleUninstallCodexHook(request: WireRequest) -> WireResponse {
        // M2p2: reversible other half — remove the CLI Pulse hooks from
        // ~/.codex/hooks.json by the codex marker, preserving the user's own
        // hooks AND any co-resident claude entries. Same gating as claude.
        do {
            let result = try ClaudeSettingsInstaller.uninstall(
                settingsPath: hooks.codexSettingsPathOverride(), provider: "codex")
            var events: [String: Any] = [:]
            for (event, removed) in result.events { events[event] = removed }
            return .ok(id: request.id, result: [
                "settings_path": result.settingsPath,
                "action": result.action,
                "removed": result.removed,
                "events": events,
            ])
        } catch let err as ClaudeSettingsInstaller.InstallError {
            if case .malformedSettings(let msg) = err {
                return .err(id: request.id, code: .settingsMalformed, message: msg)
            }
            return .err(id: request.id, code: .internalError, message: "\(err)")
        } catch {
            return .err(id: request.id, code: .internalError, message: "\(error)")
        }
    }

    // MARK: - M4.4a: wrapped-session attach + shell integration

    private func handleListWrappedSessions(request: WireRequest) -> WireResponse {
        guard let mgr = hooks.sessionManager else {
            return .err(id: request.id, code: .notImplemented, message: "session manager not configured")
        }
        return .ok(id: request.id, result: ["sessions": mgr.listWrappedSessions()])
    }

    private func handleAttachWrappedSession(request: WireRequest) -> WireResponse {
        guard let mgr = hooks.sessionManager else {
            return .err(id: request.id, code: .notImplemented, message: "session manager not configured")
        }
        guard let sessionId = request.params["session_id"] as? String, !sessionId.isEmpty else {
            return .err(id: request.id, code: .badRequest, message: "'session_id' must be a non-empty string")
        }
        guard let tmuxName = request.params["tmux_session_name"] as? String, !tmuxName.isEmpty else {
            return .err(id: request.id, code: .badRequest, message: "'tmux_session_name' must be a non-empty string")
        }
        // Strict validation matching Python (review: codex): a SUPPLIED provider
        // must be a non-empty string (not silently coerced to "claude"); a
        // SUPPLIED client_label must be a string or null (not silently dropped).
        var provider = "claude"
        if let raw = request.params["provider"] {
            guard let p = raw as? String, !p.isEmpty else {
                return .err(id: request.id, code: .badRequest, message: "'provider' must be a non-empty string")
            }
            provider = p
        }
        var clientLabel: String? = nil
        if let raw = request.params["client_label"], !(raw is NSNull) {
            guard let label = raw as? String else {
                return .err(id: request.id, code: .badRequest, message: "'client_label' must be a string or null")
            }
            clientLabel = label
        }
        let attached = mgr.attachWrappedSession(
            sessionId: sessionId, tmuxSessionName: tmuxName,
            provider: provider, clientLabel: clientLabel)
        if !attached {
            return .err(id: request.id, code: .attachFailed,
                        message: "could not attach wrapped session \(tmuxName)")
        }
        return .ok(id: request.id, result: ["attached": true, "session_id": sessionId])
    }

    private enum ShellIntegrationAction { case status, install, uninstall }

    private func handleShellIntegration(request: WireRequest, action: ShellIntegrationAction) -> WireResponse {
        // The install/uninstall paths write to the user's shell rc — a STANDING
        // change — so they're app-auth + local-control gated (dispatch gate),
        // never automatic. status is read-only.
        func statusDict(_ st: ShellIntegration.Status) -> [String: Any] {
            [
                "installed": st.installed,
                "init_present": st.initPresent,
                "tmux_bin": st.tmuxBin ?? NSNull(),
                "rc_files_with_block": st.rcFilesWithBlock,
                "sock": st.sock,
            ]
        }
        do {
            let st: ShellIntegration.Status
            switch action {
            case .status: st = ShellIntegration.status()
            case .install: st = try ShellIntegration.install()
            case .uninstall: st = try ShellIntegration.uninstall()
            }
            return .ok(id: request.id, result: statusDict(st))
        } catch {
            return .err(id: request.id, code: .internalError, message: "\(error)")
        }
    }

    // MARK: - iter4 hook ingress

    private func handleHookIngress(
        method: SupportedMethod,
        request: WireRequest,
        peerFD: Int32
    ) -> WireResponse {
        guard let registry = hooks.approvalRegistry else {
            return .err(id: request.id, code: .notImplemented, message: "approval registry not configured")
        }
        guard let sessionId = request.sessionId, !sessionId.isEmpty else {
            return .err(id: request.id, code: .badRequest, message: "'session_id' required for hook methods")
        }
        guard let sessionToken = request.sessionToken, !sessionToken.isEmpty else {
            return .err(id: request.id, code: .badRequest, message: "'session_token' required for hook methods")
        }
        do {
            try registry.authenticateHook(
                sessionId: sessionId,
                capabilityToken: sessionToken,
                peerFD: peerFD < 0 ? nil : peerFD
            )
        } catch ApprovalRegistry.RegistryError.sessionNotFound {
            return .err(id: request.id, code: .sessionNotFound, message: "session not found")
        } catch ApprovalRegistry.RegistryError.capabilityInvalid {
            return .err(id: request.id, code: .approvalCapabilityInvalid, message: "capability token mismatch")
        } catch ApprovalRegistry.RegistryError.descentMismatch {
            return .err(id: request.id, code: .approvalNotAllowed, message: "peer is not a descendant of the recorded Claude pid")
        } catch {
            return .err(id: request.id, code: .internalError, message: "authenticate_hook: \(error)")
        }

        switch method {
        case .hookCreateApproval:
            return handleHookCreateApproval(registry: registry, sessionId: sessionId, request: request)
        case .hookWaitDecision:
            return handleHookWaitDecision(registry: registry, sessionId: sessionId, request: request)
        default:
            return .err(id: request.id, code: .notImplemented, message: "method \(request.method) not implemented")
        }
    }

    private func handleHookCreateApproval(
        registry: ApprovalRegistry,
        sessionId: String,
        request: WireRequest
    ) -> WireResponse {
        let kind = (request.params["type"] as? String) ?? "PermissionRequest"
        let title = (request.params["title"] as? String) ?? "Permission request"
        let summary = (request.params["summary"] as? String) ?? ""
        let toolMetadata = (request.params["tool_metadata"] as? [String: Any]) ?? [:]
        let ttl = request.params["ttl_seconds"] as? Double
        do {
            let row = try registry.createPending(
                sessionId: sessionId,
                kind: kind,
                title: title,
                summary: summary,
                toolMetadata: toolMetadata,
                ttlSeconds: ttl
            )
            return .ok(id: request.id, result: row.toDictSafe())
        } catch ApprovalRegistry.RegistryError.sessionNotFound {
            return .err(id: request.id, code: .sessionNotFound, message: "session not found")
        } catch ApprovalRegistry.RegistryError.approvalLimitReached {
            return .err(id: request.id, code: .approvalLimitReached, message: "approval limit reached")
        } catch {
            return .err(id: request.id, code: .internalError, message: "hook_create_approval: \(error)")
        }
    }

    private func handleHookWaitDecision(
        registry: ApprovalRegistry,
        sessionId: String,
        request: WireRequest
    ) -> WireResponse {
        guard let approvalId = request.params["approval_id"] as? String,
              !approvalId.isEmpty else {
            return .err(id: request.id, code: .badRequest, message: "'approval_id' required")
        }
        let timeout = (request.params["timeout_s"] as? Double) ?? 60.0
        do {
            let resolved = try registry.waitForDecision(
                sessionId: sessionId,
                approvalId: approvalId,
                timeout: timeout
            )
            return .ok(id: request.id, result: resolved.toDictSafe())
        } catch ApprovalRegistry.RegistryError.approvalNotFound {
            return .err(id: request.id, code: .approvalNotFound, message: "approval not found")
        } catch ApprovalRegistry.RegistryError.approvalNotAllowed {
            return .err(id: request.id, code: .approvalNotAllowed, message: "approval id does not belong to this session")
        } catch ApprovalRegistry.RegistryError.waitTimeout {
            return .err(id: request.id, code: .approvalExpired, message: "wait timed out before decision")
        } catch {
            return .err(id: request.id, code: .internalError, message: "hook_wait_decision: \(error)")
        }
    }

    private func sendResponse(fd: Int32, response: WireResponse) throws {
        let dict = response.encode()
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        try Framing.writeFrame(to: fd, body: data)
    }

    private func framingErrorToResponse(error: Error) -> WireResponse {
        if let fe = error as? Framing.FrameError {
            switch fe {
            case .frameTooLarge(let claimed):
                return .err(id: "", code: .frameTooLarge, message: "frame size \(claimed) exceeds cap \(Framing.maxPayload)")
            case .frameTruncated:
                return .err(id: "", code: .frameTruncated, message: "stream closed mid-body")
            case .ioError(let s):
                return .err(id: "", code: .internalError, message: "framing IO error: \(s)")
            }
        }
        return .err(id: "", code: .internalError, message: "framing error: \(error)")
    }

    /// Connect-probe a UNIX socket path: true if a server is actively
    /// listening (a live helper), false for a stale/dead socket file. Used by
    /// start() to avoid unlinking an overlapping live instance's socket.
    private static func isSocketAlive(atPath path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = (path as NSString).fileSystemRepresentation
        let len = strlen(bytes)
        if len >= MemoryLayout.size(ofValue: addr.sun_path) { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            memcpy(raw.baseAddress!, bytes, len)
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }

    public enum ServerError: Error, Equatable {
        case socketCreate(String)
        case pathTooLong(String)
        case bind(String)
        case listen(String)
        case alreadyRunning(String)
    }
}

// MARK: - utilities

private func errnoMsg() -> String {
    return String(cString: strerror(errno))
}

/// Minimal atomic bool for stop flag — `OSAtomicTestAndSet`-free
/// version using NSLock. NSLock is fine here; the operation is
/// rare (stop() once per server lifetime).
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool = false
    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ v: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = v
    }
}

/// Bounded thread-safe FIFO that drives the streaming subscription's
/// drain loop. Mirrors `queue.Queue.get(timeout=...)` semantics from
/// the Python helper. Dropping the bound matches Python's "evict-
/// oldest" overflow policy — events lost in overflow are signalled
/// via a separate error frame the dispatcher sends.
final class StreamQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var buffer: [[String: Any]] = []
    private let cap: Int
    private(set) var dropped: Int = 0

    init(cap: Int = 4096) { self.cap = cap }

    func put(_ event: [String: Any]) {
        cond.lock()
        if buffer.count >= cap {
            // Drop the oldest item to make room — bounded queue
            // protects against a slow subscriber blocking the
            // publish thread.
            buffer.removeFirst()
            dropped += 1
        }
        buffer.append(event)
        cond.signal()
        cond.unlock()
    }

    /// Block up to `timeout` seconds for the next event. Returns
    /// nil on timeout. The streaming loop polls with a short
    /// timeout so it can periodically check the close flag.
    func poll(timeout: TimeInterval) -> [String: Any]? {
        cond.lock()
        defer { cond.unlock() }
        if buffer.isEmpty {
            let deadline = Date().addingTimeInterval(timeout)
            // wait(until:) returns false on timeout.
            if !cond.wait(until: deadline) { return nil }
        }
        if buffer.isEmpty { return nil }
        return buffer.removeFirst()
    }
}
