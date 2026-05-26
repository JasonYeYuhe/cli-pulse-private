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
    /// Phase 4D iter10 (Codex P1③.A): hook is no longer installed
    /// globally in `~/.claude/settings.json`. Instead the helper
    /// injects an ephemeral settings JSON at spawn time via
    /// `claude --settings <json>`, so:
    ///
    ///   - Managed sessions get the hook → structured approvals.
    ///   - Terminal-launched Claude (NOT spawned by the helper)
    ///     never sees the hook → behaves exactly as if CLI Pulse
    ///     weren't installed. No global "approve all" / "deny all"
    ///     hijack.
    ///
    /// This callable resolves the helper's own absolute path so
    /// the injected hook's `command` points at the right binary.
    /// Daemon main wires `os.path.abspath(sys.argv[0])`-equivalent
    /// here. Returning nil disables hook injection (managed
    /// sessions still spawn but no structured approvals — used by
    /// unit tests that don't need approvals wired).
    private let getHelperArgv0: @Sendable () -> String?
    /// v1.15 multi-CLI: the registry resolves provider → spawner.
    /// Default standard registry wires Claude with the inline-settings
    /// hook injection so structured approvals continue to fire for
    /// managed Claude sessions — same byte-for-byte behaviour as
    /// pre-v1.15 Phase 4D.
    private let providerRegistry: ProviderSpawnerRegistry
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
        /// v1.24 Phase 2c slice 1: fixed-capacity tail buffer for
        /// `get_tail_snapshot` (Gemini HIGH from in-app-terminal plan).
        /// When an iOS WKWebView returns from background, the client
        /// fetches the last N bytes of this buffer instead of replaying
        /// the full event stream. 64 KB ≈ several screens of terminal
        /// output; bytes are stored verbatim and redacted at read time.
        let tailBuffer = TerminalRingBuffer(capacity: 65536)
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
        config: Config = Config(),
        getHelperArgv0: @escaping @Sendable () -> String? = { nil },
        providerRegistry: ProviderSpawnerRegistry? = nil
    ) {
        self.config = config
        self.transport = transport
        self.registry = registry
        self.broker = broker
        self.getHelperArgv0 = getHelperArgv0
        // v1.15: default registry wires Claude with inline-settings
        // injection (same hook semantics as Phase 4D iter10) +
        // Codex/Gemini spawners. Tests can pass a custom registry
        // (e.g. all spawners stubbed) via the explicit param.
        self.providerRegistry = providerRegistry ?? ProviderSpawnerRegistry.standard(
            buildClaudeInlineSettings: { helperPath in
                Self.buildInlineSettingsForManagedSession(helperPath: helperPath)
            }
        )
    }

    /// Public access for `LocalSessionServer.handleHello` so the UDS
    /// `provider_availability` field reflects the same registry the
    /// manager actually consults at spawn time.
    public func availableProviders() -> [String] {
        providerRegistry.availableProviderNames()
    }

    /// Build the inline JSON Claude Code's `--settings` flag
    /// accepts, populated with our PermissionRequest hook entry
    /// pointing at `helperPath`. Returns nil only if JSON
    /// serialisation fails (which shouldn't happen for the
    /// statically-shaped dict below). Public so unit tests can
    /// pin the exact wire shape.
    public static func buildInlineSettingsForManagedSession(helperPath: String) -> String? {
        let hookCommand = ClaudeSettingsInstaller.recommendedHookCommand(
            helperPath: helperPath
        )
        let inlineSettings: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    ClaudeSettingsInstaller.canonicalHookEntry(command: hookCommand),
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: inlineSettings,
            options: []
        ) else { return nil }
        return String(data: data, encoding: .utf8)
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
    ///
    /// `forcedSessionId` (Phase 4E Slice 3): when non-nil, use the
    /// caller-supplied UUID instead of a freshly-generated one.
    /// Required for the Supabase-driven `start` command — the
    /// macOS app already created the `remote_sessions` row with
    /// that id and the helper's spawn must bind to the same row
    /// so subsequent `prompt`/`stop`/`interrupt` commands resolve.
    @discardableResult
    public func startSession(
        provider: String,
        clientLabel: String?,
        cwd: String? = nil,
        extraEnv: [String: String] = [:],
        forcedSessionId: String? = nil
    ) throws -> Summary {
        // v1.15 multi-CLI dispatch: resolve provider → spawner via
        // the registry. Pre-v1.15 this was a hardcoded
        // `switch provider { case "claude": ... default: throw }`
        // which immediately rejected codex/gemini even though the
        // SQL allowlist + iOS picker were already plumbing those
        // through. Registry lookup keeps Claude's inline-settings
        // hook injection intact (the standard registry wires
        // ClaudeSpawner with `buildInlineSettingsForManagedSession`).
        guard let spawner = providerRegistry.spawner(for: provider) else {
            throw ManagerError.unsupportedProvider(provider)
        }
        let argv = spawner.argv(
            extraEnv: extraEnv,
            helperArgv0: getHelperArgv0()
        )

        let sessionId = forcedSessionId?.lowercased() ?? UUID().uuidString.lowercased()

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

    /// Phase 4E Slice 3: send SIGINT to the session's process
    /// group. Used by `RemoteAgentCloud.tick()` for the
    /// `kind=interrupt` command. Returns true if the session was
    /// owned + the signal dispatched, false when the helper
    /// doesn't own the id (caller marks the queued command
    /// `failed`).
    @discardableResult
    public func interruptSession(_ sessionId: String) -> Bool {
        lock.lock()
        let rec = sessions[sessionId]
        lock.unlock()
        guard let rec else { return false }
        transport.interrupt(rec.handle)
        return true
    }

    /// Returns true iff this manager currently owns a session
    /// with the given id. Phase 4E Slice 3 — RemoteAgentCloud
    /// uses this for the fail-closed posture on `stop` /
    /// `interrupt` for unknown sessions (PR #18 lesson: marking
    /// `delivered` on no-ops obscured stale-row bugs).
    public func ownsSession(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[sessionId] != nil
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

    /// Raw byte write to the PTY master with NO payload transformation.
    /// v1.24 Phase 2a (Codex MEDIUM M3) — for the in-app terminal path
    /// where the JS xterm.js viewport sends individual keystrokes and
    /// control bytes (e.g. `0x03` Ctrl-C, `0x04` Ctrl-D, arrow ESC
    /// sequences). The legacy `sendInput` CR-appends, which would
    /// corrupt these bytes (turning Ctrl-C into `0x03\r`).
    @discardableResult
    public func sendInputRaw(sessionId: String, bytes: Data) throws -> Bool {
        lock.lock()
        let rec = sessions[sessionId]
        lock.unlock()
        guard let rec else { return false }
        guard !bytes.isEmpty else { return true }
        let n: Int
        do {
            n = try transport.writeStdin(rec.handle, bytes)
        } catch {
            throw ManagerError.writeFailed("\(error)")
        }
        return n > 0
    }

    /// Forward a window-size update to the underlying PTY for the
    /// in-app terminal viewport (v1.24 Phase 2b). The kernel side
    /// effect sends SIGWINCH to the child so ratatui / ncurses CLIs
    /// re-flow their layout. Returns false if `sessionId` isn't owned
    /// or the underlying ioctl failed.
    @discardableResult
    public func resize(sessionId: String, cols: UInt16, rows: UInt16) -> Bool {
        lock.lock()
        let rec = sessions[sessionId]
        lock.unlock()
        guard let rec else { return false }
        do {
            try transport.setWinsize(rec.handle, cols: cols, rows: rows)
            return true
        } catch {
            return false
        }
    }

    /// Return up to `maxBytes` of the most recent stdout for the
    /// session, with `Redactor.redact` applied (v1.24 Phase 2c slice 1,
    /// Gemini HIGH). Powers the iOS WKWebView's foreground-recovery
    /// path — when the WebView resumes after a network blip, fetch the
    /// last N bytes and `term.write()` it directly, skipping full
    /// event replay (which would risk WebKit OOM on backlog burst).
    ///
    /// Returns `nil` if the session isn't owned. Empty `Data` if
    /// there's nothing buffered yet (brand-new session). UTF-8 decode
    /// is lossy on chunk boundaries — acceptable for a best-effort
    /// "catch-up snapshot." Redaction matches the `EventUploader` /
    /// `RemoteAgentCloud.swift:456` path so secrets never leak through
    /// this RPC.
    public func getTailSnapshot(sessionId: String, maxBytes: Int) -> Data? {
        let cappedMax = max(0, min(maxBytes, 65536))
        lock.lock()
        let rec = sessions[sessionId]
        lock.unlock()
        guard let rec else { return nil }
        let raw = rec.tailBuffer.tail(maxBytes: cappedMax)
        if raw.isEmpty { return Data() }
        // Decode → redact → re-encode. Lossy UTF-8 is the right
        // failure mode for terminal content: a half-finished codepoint
        // at the leading boundary becomes a Unicode replacement, which
        // xterm.js renders as ▯ — a visible-but-harmless artifact.
        let text = String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
        let redacted = Redactor.redact(text)
        return Data(redacted.utf8)
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
                    // v1.24 Phase 2c: feed the tail buffer for
                    // get_tail_snapshot foreground-recovery. Stored
                    // verbatim; redaction happens at read time.
                    record.tailBuffer.append(chunk)
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
                // Phase 4E Slice 3: capture exit code so
                // RemoteAgentCloud can decide stopped vs errored
                // status. `waitChild(timeoutSec: 0)` is a poll —
                // returns nil if reaping isn't possible (already
                // reaped / errno=ECHILD).
                let exitStatus = transport.waitChild(record.handle, timeoutSec: 0)
                let exitCode: Int32? = exitStatus.map { (status: Int32) -> Int32 in
                    // POSIX wstatus → exit code if normal exit.
                    if (status & 0x7f) == 0 {
                        return (status >> 8) & 0xff
                    }
                    return -1   // signaled / dumped
                }
                lock.lock()
                if sessions[record.sessionId] === record {
                    record.status = (exitCode == 0) ? "stopped" : "errored"
                    sessions.removeValue(forKey: record.sessionId)
                }
                lock.unlock()
                var stoppedEvent: [String: Any] = [
                    "event": "session_stopped",
                    "session_id": record.sessionId,
                ]
                if let exitCode {
                    stoppedEvent["exit_code"] = Int(exitCode)
                }
                broker?.publish(stoppedEvent)
                registry?.unregisterSession(record.sessionId)
                break
            }
            usleep(intervalNs)
        }
        transport.close(record.handle)
    }
}
