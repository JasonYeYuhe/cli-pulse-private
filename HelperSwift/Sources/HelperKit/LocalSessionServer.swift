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

        public init(
            getAuthToken: @escaping @Sendable () -> String,
            isLocalControlEnabled: @escaping @Sendable () -> Bool = { true },
            setLocalControlEnabled: @escaping @Sendable (Bool) -> Void = { _ in },
            getHelperArgv0: @escaping @Sendable () -> String? = { nil },
            sessionManager: ManagedSessionManager? = nil,
            listDetectedSessions: @escaping @Sendable () -> [[String: Any]] = { [] },
            approvalRegistry: ApprovalRegistry? = nil
        ) {
            self.getAuthToken = getAuthToken
            self.isLocalControlEnabled = isLocalControlEnabled
            self.setLocalControlEnabled = setLocalControlEnabled
            self.getHelperArgv0 = getHelperArgv0
            self.sessionManager = sessionManager
            self.listDetectedSessions = listDetectedSessions
            self.approvalRegistry = approvalRegistry
        }
    }

    private let config: Configuration
    private let hooks: Hooks
    private var listenFD: Int32 = -1
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
        // Stale-socket recovery: if a leftover file from a crashed
        // previous helper sits at the path, unlink it (matches
        // `prepare_socket_path` in the Python implementation).
        let path = config.socketPath.path
        if FileManager.default.fileExists(atPath: path) {
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
        // Best-effort socket file cleanup so the next start() can
        // bind cleanly. POSIX leaves the inode behind.
        try? FileManager.default.removeItem(at: config.socketPath)
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
            // Pass the connection fd into the dispatcher so hook-
            // ingress methods can perform descent verification
            // (peer pid via getsockopt requires the connected
            // socket).
            let resp = handleFrame(payload: payload, peerFD: fd)
            do {
                try sendResponse(fd: fd, response: resp)
            } catch {
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
            return .ok(id: request.id, result: [
                "protocol_version": kProtocolVersion,
                "supported_methods": SupportedMethod.allCases.map(\.rawValue),
                "helper_pid": Int(getpid()),
                "capabilities": [
                    "send_input": true,
                    "subscribe_events": true,
                    "approvals": true,
                ],
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
        case .getPendingApprovals:
            return handleGetPendingApprovals(request: request)
        case .approveAction:
            return handleApproveAction(request: request)
        case .installClaudeHook:
            return handleInstallClaudeHook(request: request)
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
        guard let argv0 = hooks.getHelperArgv0() else {
            return .err(id: request.id, code: .notImplemented,
                        message: "helper did not record its own argv[0] — install_claude_hook unavailable")
        }
        do {
            let result = try ClaudeSettingsInstaller.install(helperPath: argv0)
            var dict: [String: Any] = [
                "settings_path": result.settingsPath,
                "action": result.action.rawValue,
                "new_command": result.newCommand,
            ]
            if let prev = result.previousCommand {
                dict["previous_command"] = prev
            } else {
                dict["previous_command"] = NSNull()
            }
            return .ok(id: request.id, result: dict)
        } catch ClaudeSettingsInstaller.InstallError.malformedSettings(let msg) {
            return .err(id: request.id, code: .settingsMalformed, message: msg)
        } catch {
            return .err(id: request.id, code: .internalError, message: "install_claude_hook: \(error)")
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

    public enum ServerError: Error, Equatable {
        case socketCreate(String)
        case pathTooLong(String)
        case bind(String)
        case listen(String)
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
