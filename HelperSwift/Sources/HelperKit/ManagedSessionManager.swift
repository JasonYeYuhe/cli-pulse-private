import Foundation
import Darwin

/// Glue layer between `PtyTransport` (subprocess + PTY) and the
/// in-memory state (`ApprovalRegistry` + `EventBroker`). Owns the
/// drain loop that reads PTY output and publishes `output_delta`
/// events. Every public method is thread-safe.
///
/// Swift port of the relevant chunk of
/// `helper/remote_agent.py:RemoteAgentManager`. Iter 3 covers the
/// session lifecycle that the macOS app's Sessions tab depends on:
/// start / list / stop / send_input. Iter 4+ will fold in
/// hook ingress / approval-driven events.
public final class ManagedSessionManager: @unchecked Sendable {

    public struct Config: Sendable {
        /// How often the drain loop polls the PTY for output.
        /// 50 ms is fast enough that interactive Claude output
        /// feels instant in the macOS app's preview, slow enough
        /// that an idle session doesn't burn cycles.
        public var drainIntervalMs: UInt32 = 50
        /// Per-read max from the PTY master fd. 4 KB matches the
        /// Python implementation; sized to fit a typical Supabase
        /// event row's redacted body.
        public var drainChunkBytes: Int = 4096

        public init() {}
    }

    public struct Summary: Sendable, Equatable {
        public let sessionId: String
        public let provider: String
        public let clientLabel: String?
        public let pid: pid_t
        public let spawnedAtMono: TimeInterval
        public var status: String   // "running" / "stopped" / "errored"
    }

    private let config: Config
    private let transport: PtyTransport
    private let registry: ApprovalRegistry?
    private let broker: EventBroker?
    private let lock = NSLock()
    private var sessions: [String: ManagedSessionRecord] = [:]
    private var stopFlag = AtomicBool()

    private final class ManagedSessionRecord: @unchecked Sendable {
        let sessionId: String
        let provider: String
        let clientLabel: String?
        let handle: PtyTransport.Handle
        let spawnedAtMono: TimeInterval
        var status: String = "running"
        var drainThread: Thread?
        init(
            sessionId: String,
            provider: String,
            clientLabel: String?,
            handle: PtyTransport.Handle,
            spawnedAtMono: TimeInterval
        ) {
            self.sessionId = sessionId
            self.provider = provider
            self.clientLabel = clientLabel
            self.handle = handle
            self.spawnedAtMono = spawnedAtMono
        }
    }

    public init(
        transport: PtyTransport = PtyTransport(),
        registry: ApprovalRegistry? = nil,
        broker: EventBroker? = nil,
        config: Config = Config()
    ) {
        self.config = config
        self.transport = transport
        self.registry = registry
        self.broker = broker
    }

    /// Stop every running session + their drain loops. Called by
    /// the daemon's shutdown path.
    public func shutdown() {
        stopFlag.set(true)
        let snapshot: [ManagedSessionRecord]
        lock.lock()
        snapshot = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        for rec in snapshot {
            transport.terminate(rec.handle)
            transport.close(rec.handle)
            registry?.unregisterSession(rec.sessionId)
        }
    }

    // MARK: - lifecycle

    public enum ManagerError: Error, Equatable {
        case unsupportedProvider(String)
        case spawnFailed(String)
        case sessionNotFound(String)
        case writeFailed(String)
    }

    /// Spawn a managed Claude session. `provider` decides the argv
    /// (currently Claude only — Codex / shell follow in iter 7).
    /// Publishes `session_started` to the broker on success and
    /// kicks off the drain loop.
    @discardableResult
    public func startSession(
        provider: String,
        clientLabel: String?,
        cwd: String? = nil,
        extraEnv: [String: String] = [:]
    ) throws -> Summary {
        let argv: [String]
        switch provider.lowercased() {
        case "claude":
            // Same default as the Python helper: just `claude` in
            // PATH. The user's shell rc sourced into the LaunchAgent
            // env (via ProgramArguments wrapper TBD) is responsible
            // for finding the right binary.
            argv = ["claude"]
        default:
            throw ManagerError.unsupportedProvider(provider)
        }

        let sessionId = UUID().uuidString.lowercased()

        // Pre-register with the approval registry so the spawned
        // child's hook subprocess sees the capability token in env.
        let capToken = registry?.registerSession(sessionId, claudePid: nil)

        var env = extraEnv
        if let capToken {
            env["CLI_PULSE_LOCAL_HOOK_TOKEN"] = capToken
            env["CLI_PULSE_LOCAL_SESSION_ID"] = sessionId
            env["CLI_PULSE_LOCAL_HELPER_SOCK"] = AuthToken.containerPath()
                .appendingPathComponent("clipulse-helper.sock").path
        }

        let handle: PtyTransport.Handle
        do {
            handle = try transport.start(
                sessionId: sessionId, argv: argv, env: env, cwd: cwd
            )
        } catch {
            // Roll back the registry register so we don't keep a
            // ghost cap token for a session that never spawned.
            registry?.unregisterSession(sessionId)
            throw ManagerError.spawnFailed("\(error)")
        }
        registry?.updateSessionPid(sessionId, claudePid: Int(handle.pid))

        let record = ManagedSessionRecord(
            sessionId: sessionId,
            provider: provider,
            clientLabel: clientLabel,
            handle: handle,
            spawnedAtMono: ProcessInfo.processInfo.systemUptime
        )

        lock.lock()
        sessions[sessionId] = record
        lock.unlock()

        broker?.publish([
            "event": "session_started",
            "session_id": sessionId,
            "provider": provider,
            "client_label": clientLabel ?? NSNull(),
        ])

        // Kick off the drain loop on its own Thread.
        let drain = Thread { [weak self] in
            self?.drainLoop(record: record)
        }
        drain.name = "cli-pulse-drain-\(sessionId)"
        record.drainThread = drain
        drain.start()

        return Summary(
            sessionId: sessionId,
            provider: provider,
            clientLabel: clientLabel,
            pid: handle.pid,
            spawnedAtMono: record.spawnedAtMono,
            status: "running"
        )
    }

    public func listSessions() -> [Summary] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.map { rec in
            Summary(
                sessionId: rec.sessionId,
                provider: rec.provider,
                clientLabel: rec.clientLabel,
                pid: rec.handle.pid,
                spawnedAtMono: rec.spawnedAtMono,
                status: rec.status
            )
        }
    }

    @discardableResult
    public func stopSession(_ sessionId: String) -> Bool {
        lock.lock()
        let rec = sessions.removeValue(forKey: sessionId)
        lock.unlock()
        guard let rec else { return false }
        transport.terminate(rec.handle)
        // Drain loop notices the close and exits; the close()
        // call happens there so we don't double-close.
        registry?.unregisterSession(sessionId)
        broker?.publish([
            "event": "session_stopped",
            "session_id": sessionId,
        ])
        return true
    }

    /// Write to the PTY master, normalising the trailing
    /// terminator to `\r` (matches the Python helper —
    /// Claude Code's TUI is a raw-mode app with bracketed-paste
    /// enabled; sending `\n` is treated as "more text being
    /// pasted" rather than as Enter, so we coerce to CR).
    @discardableResult
    public func sendInput(sessionId: String, payload: String) throws -> Bool {
        lock.lock()
        let rec = sessions[sessionId]
        lock.unlock()
        guard let rec else { return false }
        var body = Data(payload.utf8)
        if body.last == 0x0a {                              // LF
            // Replace trailing \n with \r.
            body[body.count - 1] = 0x0d
            // If preceding byte is \r (so original was \r\n),
            // strip the \r so we don't end up with \r\r.
            if body.count >= 2 && body[body.count - 2] == 0x0d {
                body.removeLast(1)
            }
        } else if body.last != 0x0d {
            body.append(0x0d)
        }
        let n: Int
        do {
            n = try transport.writeStdin(rec.handle, body)
        } catch {
            throw ManagerError.writeFailed("\(error)")
        }
        if n == 0 {
            return false   // child gone
        }
        return true
    }

    // MARK: - drain loop

    private func drainLoop(record: ManagedSessionRecord) {
        let intervalNs = UInt32(config.drainIntervalMs * 1000)
        while !stopFlag.get() {
            // Has the session been removed from the map (stop
            // called)? Drain a final chunk + exit.
            lock.lock()
            let stillManaged = sessions[record.sessionId] === record
            lock.unlock()
            if !stillManaged {
                break
            }
            do {
                let chunk = try transport.readStdout(record.handle, maxBytes: config.drainChunkBytes)
                if !chunk.isEmpty {
                    let text = String(data: chunk, encoding: .utf8) ?? String(decoding: chunk, as: UTF8.self)
                    broker?.publish([
                        "event": "output_delta",
                        "session_id": record.sessionId,
                        "payload": text,
                        "ts": Date().timeIntervalSince1970,
                    ])
                }
            } catch {
                // Drain errors typically mean the child went away
                // mid-read; let the next isAlive check confirm.
            }
            if !transport.isAlive(record.handle) {
                lock.lock()
                if sessions[record.sessionId] === record {
                    record.status = "stopped"
                    sessions.removeValue(forKey: record.sessionId)
                }
                lock.unlock()
                broker?.publish([
                    "event": "session_stopped",
                    "session_id": record.sessionId,
                ])
                registry?.unregisterSession(record.sessionId)
                break
            }
            usleep(intervalNs)
        }
        transport.close(record.handle)
    }
}
