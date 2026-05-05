#if os(macOS)
import Foundation
import Network
import os

private let localSessionLog = Logger(
    subsystem: "com.cli-pulse.bar", category: "local-session-client"
)

/// Reply payload from `LocalSessionControlClient.getLocalControlStatus`.
/// macOS-only because the local UDS surface is macOS-only — iOS / iPad
/// / Watch always go through the Supabase remote path.
public struct LocalControlStatus: Sendable, Equatable {
    public let localControlEnabled: Bool
    public let protocolVersion: Int

    public init(localControlEnabled: Bool, protocolVersion: Int) {
        self.localControlEnabled = localControlEnabled
        self.protocolVersion = protocolVersion
    }
}

/// macOS-only `SessionControlClient` that talks to the helper's UDS
/// server inside the app group container.
///
/// Wire format: 4-byte big-endian length prefix + UTF-8 JSON body.
/// Mirrors `helper/local_session_server.py` symmetrically; the
/// envelope shapes and error codes are documented there.
///
/// Connection model: each method opens a fresh NWConnection, performs
/// one request/reply, and tears it down. iter 1 doesn't need
/// connection pooling (every operation is a one-shot from the user's
/// perspective). When iter 2A introduces a streaming `subscribe_events`
/// surface, that path will hold a connection open for the lifetime of
/// the subscription — but iter 1 does NOT need that.
public final class LocalSessionControlClient: SessionControlClient {
    public static let appGroupID = "group.yyh.CLI-Pulse"
    public static let socketFilename = "clipulse-helper.sock"
    public static let authTokenFilename = "helper-auth-token"
    public static let protocolVersion = 1
    public static let maxPayload: UInt32 = 1 << 20    // 1 MiB

    private let socketPath: String
    private let tokenPath: String
    private let connectTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.cli-pulse.local-session-client")

    public init(
        socketPath: String? = nil,
        tokenPath: String? = nil,
        connectTimeout: TimeInterval = 3,
        requestTimeout: TimeInterval = 5
    ) {
        if let socketPath, let tokenPath {
            self.socketPath = socketPath
            self.tokenPath = tokenPath
        } else {
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: Self.appGroupID
            )
            let base = containerURL?.path ?? NSHomeDirectory()
            self.socketPath = socketPath ?? (base as NSString)
                .appendingPathComponent(Self.socketFilename)
            self.tokenPath = tokenPath ?? (base as NSString)
                .appendingPathComponent(Self.authTokenFilename)
        }
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
    }

    /// Diagnostic snapshot of the paths this client resolved + their
    /// on-disk state. Surfaced in the UI via a debug-only "Diagnose"
    /// button so we can ground "the helper says it's listening but
    /// the app sees ENOENT" in concrete data instead of guessing
    /// at firmlink/sandbox path translations.
    public struct Diagnostics: Sendable, Equatable {
        public let resolvedSocketPath: String
        public let socketExists: Bool
        public let resolvedTokenPath: String
        public let tokenExists: Bool
        public let tokenReadable: Bool
        public let appGroupContainerPath: String?
        public let nsHomeDirectory: String

        public init(resolvedSocketPath: String, socketExists: Bool,
                    resolvedTokenPath: String, tokenExists: Bool,
                    tokenReadable: Bool, appGroupContainerPath: String?,
                    nsHomeDirectory: String) {
            self.resolvedSocketPath = resolvedSocketPath
            self.socketExists = socketExists
            self.resolvedTokenPath = resolvedTokenPath
            self.tokenExists = tokenExists
            self.tokenReadable = tokenReadable
            self.appGroupContainerPath = appGroupContainerPath
            self.nsHomeDirectory = nsHomeDirectory
        }
    }

    public func diagnostics() -> Diagnostics {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        )
        let socketExists = FileManager.default.fileExists(atPath: socketPath)
        let tokenExists = FileManager.default.fileExists(atPath: tokenPath)
        let tokenReadable: Bool
        if tokenExists {
            tokenReadable = (try? String(contentsOfFile: tokenPath))
                .map { !$0.isEmpty } ?? false
        } else {
            tokenReadable = false
        }
        return Diagnostics(
            resolvedSocketPath: socketPath,
            socketExists: socketExists,
            resolvedTokenPath: tokenPath,
            tokenExists: tokenExists,
            tokenReadable: tokenReadable,
            appGroupContainerPath: containerURL?.path,
            nsHomeDirectory: NSHomeDirectory()
        )
    }

    // MARK: - SessionControlClient

    public func hello() async throws -> SessionControlHello {
        let result = try await send(
            method: "hello",
            params: ["client_protocol_version": Self.protocolVersion],
            requireAuth: false
        )
        guard let version = result["protocol_version"] as? Int,
              let methods = result["supported_methods"] as? [String],
              let capsRaw = result["capabilities"] as? [String: Any]
        else {
            throw SessionControlError.invalidResponse("hello reply missing fields")
        }
        let caps = SessionControlCapabilities(
            sendInput: (capsRaw["send_input"] as? Bool) ?? false,
            subscribeEvents: (capsRaw["subscribe_events"] as? Bool) ?? false,
            approvals: (capsRaw["approvals"] as? Bool) ?? false
        )
        return SessionControlHello(
            protocolVersion: version,
            supportedMethods: Set(methods),
            capabilities: caps
        )
    }

    public func startClaudeSession(
        clientLabel: String?,
        cwdBasename: String?,
        cwdHmac: String?
    ) async throws -> SessionControlStartResult {
        var params: [String: Any] = ["provider": "claude"]
        if let clientLabel { params["client_label"] = clientLabel }
        if let cwdBasename { params["cwd_basename"] = cwdBasename }
        if let cwdHmac { params["cwd_hmac"] = cwdHmac }
        let result = try await send(method: "start_session", params: params)
        guard let sid = result["session_id"] as? String, !sid.isEmpty else {
            throw SessionControlError.invalidResponse("start_session: missing session_id")
        }
        return SessionControlStartResult(sessionId: sid, commandId: nil)
    }

    public func listSessions() async throws -> [SessionControlSummary] {
        let result = try await send(method: "list_sessions", params: [:])
        // iter 2A reply shape:
        //   { "managed": [...], "detected": [...], "sessions": [...legacy...] }
        // Older helper revisions only return `sessions`. Read both
        // and merge so the caller sees a single uniform list with
        // `controllable` + `source` set per row.
        let managedRaw = (result["managed"] as? [[String: Any]])
            ?? (result["sessions"] as? [[String: Any]])
            ?? []
        let detectedRaw = (result["detected"] as? [[String: Any]]) ?? []
        var rows: [SessionControlSummary] = []
        for row in managedRaw {
            guard let id = row["session_id"] as? String else { continue }
            rows.append(.init(
                id: id,
                provider: (row["provider"] as? String) ?? "claude",
                clientLabel: row["client_label"] as? String,
                status: (row["status"] as? String) ?? "running",
                controllable: (row["controllable"] as? Bool) ?? true,
                source: .managed
            ))
        }
        for row in detectedRaw {
            guard let id = row["session_id"] as? String else { continue }
            rows.append(.init(
                id: id,
                provider: (row["provider"] as? String) ?? "claude",
                clientLabel: row["client_label"] as? String,
                status: (row["status"] as? String) ?? "running",
                controllable: false,
                source: .detected
            ))
        }
        return rows
    }

    public func stopSession(sessionId: String) async throws {
        _ = try await send(
            method: "stop_session",
            params: ["session_id": sessionId]
        )
    }

    public func sendInput(sessionId: String, payload: String) async throws {
        _ = try await send(
            method: "send_input",
            params: ["session_id": sessionId, "payload": payload]
        )
    }

    /// Read the helper's persisted `local_control_enabled` value.
    /// Used on app launch to hydrate `AppState.localControlEnabled`
    /// without keeping a duplicate local copy that can drift.
    public func getLocalControlStatus() async throws -> LocalControlStatus {
        let result = try await send(method: "get_local_control_status", params: [:])
        guard let enabled = result["local_control_enabled"] as? Bool else {
            throw SessionControlError.invalidResponse(
                "get_local_control_status: missing local_control_enabled"
            )
        }
        return LocalControlStatus(
            localControlEnabled: enabled,
            protocolVersion: (result["protocol_version"] as? Int) ?? 0
        )
    }

    /// Flip the helper's `local_control_enabled` toggle. NOT part of
    /// the protocol — exposed as a concrete-class method because only
    /// the local transport has this concept (the remote transport's
    /// gate lives server-side under a different toggle entirely).
    @discardableResult
    public func setLocalControlEnabled(_ enabled: Bool) async throws -> Bool {
        let result = try await send(
            method: "set_local_control_enabled",
            params: ["enabled": enabled]
        )
        return (result["enabled"] as? Bool) ?? enabled
    }

    // MARK: - Wire core

    private func send(
        method: String,
        params: [String: Any],
        requireAuth: Bool = true
    ) async throws -> [String: Any] {
        // Build envelope. Auth token re-read each call so a manual
        // helper restart (which rotates the token) takes effect
        // without an app restart.
        var envelope: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        if requireAuth {
            guard let token = readToken(), !token.isEmpty else {
                throw SessionControlError.unauthenticated
            }
            envelope["auth_token"] = token
        }
        let body = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        )
        let conn = try await connect()
        defer { conn.cancel() }
        try await sendFrame(conn, body: body)
        let reply = try await receiveFrame(conn)
        return try parseReply(reply)
    }

    private func parseReply(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionControlError.invalidResponse("reply not a JSON object")
        }
        if let okFlag = obj["ok"] as? Bool, !okFlag {
            let err = obj["error"] as? [String: Any] ?? [:]
            let code = (err["code"] as? String) ?? "internal"
            let message = (err["message"] as? String) ?? "(no message)"
            throw SessionControlErrorMapping.error(forWireCode: code, message: message)
        }
        guard let result = obj["result"] as? [String: Any] else {
            throw SessionControlError.invalidResponse("reply missing 'result' on ok=true")
        }
        return result
    }

    private func readToken() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tokenPath)),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - NWConnection helpers

    private func connect() async throws -> NWConnection {
        // Pre-flight diagnostic — surface the kind of path mismatch
        // that would make the unsandboxed helper write to one inode
        // and the sandboxed app try to connect to another. Logged
        // every attempt at debug level so the noise stays bounded
        // and the cause is grepable in Xcode log without a custom
        // build flag.
        let socketExists = FileManager.default.fileExists(atPath: socketPath)
        localSessionLog.debug(
            "uds.connect attempt path=\(self.socketPath, privacy: .public) socketExists=\(socketExists, privacy: .public)"
        )
        let endpoint = NWEndpoint.unix(path: socketPath)
        let connection = NWConnection(to: endpoint, using: .tcp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success:                cont.resume()
                case .failure(let err):       cont.resume(throwing: err)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let err):
                    // POSIXErrorCode .ENOENT → file missing → helper not running.
                    // POSIXErrorCode .ECONNREFUSED → socket exists but no listener.
                    if let posix = (err as NSError).userInfo[NSUnderlyingErrorKey] as? POSIXError {
                        if posix.code == .ENOENT || posix.code == .ECONNREFUSED {
                            resumeOnce(.failure(SessionControlError.helperNotRunning))
                            return
                        }
                    }
                    let nsErr = err as NSError
                    if nsErr.domain == NSPOSIXErrorDomain {
                        if nsErr.code == Int(POSIXErrorCode.ENOENT.rawValue)
                            || nsErr.code == Int(POSIXErrorCode.ECONNREFUSED.rawValue) {
                            resumeOnce(.failure(SessionControlError.helperNotRunning))
                            return
                        }
                    }
                    resumeOnce(.failure(SessionControlError.disconnected))
                case .cancelled:
                    resumeOnce(.failure(SessionControlError.disconnected))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            // Soft connect timeout. The continuation guard means a late
            // .ready after the timeout doesn't double-resume.
            queue.asyncAfter(deadline: .now() + connectTimeout) {
                resumeOnce(.failure(SessionControlError.timeout))
            }
        }
        return connection
    }

    private func sendFrame(_ conn: NWConnection, body: Data) async throws {
        if body.count > Int(Self.maxPayload) {
            throw SessionControlError.invalidResponse("outbound frame > 1 MiB")
        }
        var header = Data(count: 4)
        let length = UInt32(body.count).bigEndian
        header.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: length, as: UInt32.self)
        }
        let frame = header + body
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { err in
                if let err {
                    if (err as NSError).domain == NSPOSIXErrorDomain {
                        cont.resume(throwing: SessionControlError.disconnected)
                    } else {
                        cont.resume(throwing: SessionControlError.disconnected)
                    }
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receiveFrame(_ conn: NWConnection) async throws -> Data {
        let header = try await receiveExact(conn, count: 4)
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        if length > Self.maxPayload {
            throw SessionControlError.invalidResponse("inbound frame > 1 MiB (\(length))")
        }
        if length == 0 { return Data() }
        return try await receiveExact(conn, count: Int(length))
    }

    private func receiveExact(_ conn: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var resumed = false
            let resumeOnce: (Result<Data, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let payload): cont.resume(returning: payload)
                case .failure(let err):     cont.resume(throwing: err)
                }
            }
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, err in
                if let err {
                    let nsErr = err as NSError
                    if nsErr.domain == NSPOSIXErrorDomain {
                        resumeOnce(.failure(SessionControlError.disconnected))
                    } else {
                        resumeOnce(.failure(SessionControlError.disconnected))
                    }
                    return
                }
                guard let data, data.count == count else {
                    resumeOnce(.failure(SessionControlError.disconnected))
                    return
                }
                resumeOnce(.success(data))
            }
            queue.asyncAfter(deadline: .now() + requestTimeout) {
                resumeOnce(.failure(SessionControlError.timeout))
            }
        }
    }
}
#endif
