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
    /// M4.4a: the transport that owns a record's handle — the per-session
    /// override (an attached tmux `TmuxTransport`) if set, else the shared
    /// `PtyTransport` (spawned sessions). Every handle-scoped I/O call routes
    /// through this so attached + spawned sessions share the same drain / input
    /// / reap loops. Mirrors Python `_sess_transport`.
    private func sessTransport(_ rec: ManagedSessionRecord) -> any SessionTransport {
        rec.transportOverride ?? transport
    }
    private let registry: ApprovalRegistry?
    private let broker: EventBroker?
    /// v1.24 Phase 2c slice 2: optional terminal Broadcast publisher.
    /// When non-nil, each stdout chunk is also handed off to the
    /// publisher (which redacts + ships to the configured sink).
    /// Default `nil` = no Broadcast traffic, matching v1.24.0's
    /// "ship the seam, light it up later" plan §2d feature-flag
    /// posture. Real sinks (e.g. Supabase Realtime POST) are passed
    /// in by the daemon wire-up.
    private let broadcastPublisher: TerminalBroadcastPublisher?
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
    /// Resolves the Claude subscription OAuth access token injected into managed
    /// `claude` sessions so they run on the user's plan (e.g. Max) instead of
    /// "Claude API" pay-per-token. Returns nil → no injection (claude's own
    /// ambient auth, unchanged behaviour). Overridable so tests don't read the
    /// real credentials file / hit the network.
    private let claudeTokenResolver: @Sendable () -> String?
    private let lock = NSLock()
    private var sessions: [String: ManagedSessionRecord] = [:]
    private var stopFlag = AtomicBool()

    private final class ManagedSessionRecord: @unchecked Sendable {
        let sessionId: String
        let provider: String
        let clientLabel: String?
        let handle: SessionHandle
        /// M4.4a: per-session transport override. `nil` ⇒ the manager's shared
        /// `PtyTransport` (spawned sessions). An ATTACHED tmux-wrapped session
        /// carries its own `TmuxTransport` here so every handle-scoped I/O call
        /// routes to the right transport (`_sessTransport`). Mirrors Python
        /// `_ManagedSession.transport`.
        let transportOverride: (any SessionTransport)?
        let spawnedAtMono: TimeInterval
        /// R0 (S2): the session's `realtime_private` from the cloud start
        /// payload — `false` = positively public, `true` = private, `nil` =
        /// UNKNOWN (a local/UDS session, or a pre-v0.61 payload without the
        /// flag). Governs the fail-closed public-broadcast gate below.
        let realtimePrivate: Bool?
        // Mutable fields below are governed by `ManagedSessionManager.lock`.
        // `status` is read/written only under that lock. `drainThread` is
        // assigned once before the record is published into `sessions` and
        // never mutated afterward (see startSession), so post-publication
        // it is effectively immutable.
        var status: String = "running"
        var drainThread: Thread?
        /// v1.24 Phase 2c slice 1: fixed-capacity tail buffer for
        /// `get_tail_snapshot` (Gemini HIGH from in-app-terminal plan).
        /// When an iOS WKWebView returns from background, the client
        /// fetches the last N bytes of this buffer instead of replaying
        /// the full event stream. 64 KB ≈ several screens of terminal
        /// output; bytes are stored verbatim and redacted at read time.
        let tailBuffer = TerminalRingBuffer(capacity: 65536)

        /// R0 fail-closed: mirror to the PUBLIC `term:` sink ONLY when the
        /// session is POSITIVELY known public. Private OR unknown => mute, so a
        /// private session's output can never leak on the public channel and
        /// "public" is never *inferred* from a missing flag (Codex fail-closed
        /// invariant).
        var allowsPublicBroadcast: Bool {
            ManagedSessionManager.allowsPublicBroadcast(realtimePrivate: realtimePrivate)
        }

        init(
            sessionId: String,
            provider: String,
            clientLabel: String?,
            handle: SessionHandle,
            transportOverride: (any SessionTransport)? = nil,
            spawnedAtMono: TimeInterval,
            realtimePrivate: Bool?
        ) {
            self.sessionId = sessionId
            self.provider = provider
            self.clientLabel = clientLabel
            self.handle = handle
            self.transportOverride = transportOverride
            self.spawnedAtMono = spawnedAtMono
            self.realtimePrivate = realtimePrivate
        }
    }

    /// R0 (S2) fail-closed public-broadcast gate (pure, unit-testable). Returns
    /// true ONLY for a session POSITIVELY known public (`realtime_private ==
    /// false`). A `nil` (unknown — local session / pre-v0.61 payload) or `true`
    /// (private) => false, so a private session's redacted output is NEVER
    /// POSTed to the public `term:<sid>` topic. The Swift helper does not run
    /// Route B-lite (no minted producer token), so a private session simply
    /// gets no realtime mirror — the phone degrades to event-polling.
    static func allowsPublicBroadcast(realtimePrivate: Bool?) -> Bool {
        realtimePrivate == false
    }

    public init(
        transport: PtyTransport = PtyTransport(),
        registry: ApprovalRegistry? = nil,
        broker: EventBroker? = nil,
        config: Config = Config(),
        getHelperArgv0: @escaping @Sendable () -> String? = { nil },
        providerRegistry: ProviderSpawnerRegistry? = nil,
        broadcastPublisher: TerminalBroadcastPublisher? = nil,
        claudeTokenResolver: @escaping @Sendable () -> String? = { ClaudeOAuthInjector.resolveAccessToken() }
    ) {
        self.config = config
        self.transport = transport
        self.registry = registry
        self.broker = broker
        self.broadcastPublisher = broadcastPublisher
        self.getHelperArgv0 = getHelperArgv0
        self.claudeTokenResolver = claudeTokenResolver
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

    /// Per-provider plan-auth status ("on_plan"/"off_plan") for the hello reply's
    /// `provider_plan_status`, so the picker can warn before silently launching an
    /// off-plan (billed) managed session. Keyed off the same getpwuid home used at spawn.
    public func providerPlanStatus() -> [String: String] {
        providerRegistry.planAuthStatuses(resolvedHome: HelperEnvironment.resolvedUserHome())
    }

    /// Derive the spawn env from a provider's `envPatch`: overlay `set` onto `env` and
    /// return the keys to `remove` (which PtyTransport deletes AFTER merging the parent
    /// env). Extracted as a pure static so the manager's patch-derivation glue — not just
    /// the spawner's patch in isolation — is unit-tested (e.g. that a Codex spawn forwards
    /// the OPENAI_API_KEY removal to the transport). See ManagedEnvSeamTests.
    static func applyProviderEnvPatch(
        _ spawner: ProviderSpawner,
        env: [String: String],
        extraEnv: [String: String],
        resolvedHome: String?
    ) -> (env: [String: String], remove: Set<String>) {
        var env = env
        let patch = spawner.envPatch(extraEnv: extraEnv, resolvedHome: resolvedHome)
        for (k, v) in patch.set { env[k] = v }
        return (env, patch.remove)
    }

    /// Build the inline JSON Claude Code's `--settings` flag
    /// accepts, populated with our hook entry pointing at
    /// `helperPath`. Returns nil only if JSON serialisation fails
    /// (which shouldn't happen for the statically-shaped dict
    /// below). Public so unit tests can pin the exact wire shape.
    ///
    /// M1 (review: codex): registers our hook under BOTH events —
    /// PreToolUse (fires for EVERY tool call) as well as
    /// PermissionRequest (which a broad allowlist suppresses).
    /// Without PreToolUse, a managed session whose allowlist
    /// pre-approves a tool would run it WITHOUT CLI Pulse approval.
    /// Same both-events shape the global `ClaudeSettingsInstaller`
    /// install writes.
    public static func buildInlineSettingsForManagedSession(helperPath: String) -> String? {
        let hookCommand = ClaudeSettingsInstaller.recommendedHookCommand(
            helperPath: helperPath
        )
        let entry = ClaudeSettingsInstaller.canonicalHookEntry(command: hookCommand)
        let inlineSettings: [String: Any] = [
            "hooks": [
                "PermissionRequest": [entry],
                "PreToolUse": [entry],
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
            let t = sessTransport(rec)
            t.terminate(rec.handle)
            t.close(rec.handle)
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
        forcedSessionId: String? = nil,
        realtimePrivate: Bool? = nil
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

        // v1.35: per-provider env patch (set + REMOVE). Lets a spawner pin a config
        // dir (Codex `CODEX_HOME`) and DELETE an inherited var (scrub `OPENAI_API_KEY`
        // so managed Codex can't silently fall back to the pay-per-token API). The
        // `set` overlays here; `remove` is applied by PtyTransport AFTER it merges the
        // parent (launchd) env — a dict merge alone can't delete an inherited key.
        let resolvedHome = HelperEnvironment.resolvedUserHome()
        let patched = Self.applyProviderEnvPatch(
            spawner, env: env, extraEnv: extraEnv, resolvedHome: resolvedHome)
        env = patched.env

        // Run managed `claude` on the user's subscription (e.g. Max) instead of
        // "Claude API": inject the OAuth access token over an inherited fd
        // (leak-safe — not in the env / tool subprocs / `ps eww`). Best-effort;
        // a nil result leaves claude's own ambient auth untouched.
        var inheritedFD: (envVar: String, data: Data)? = nil
        if provider.lowercased() == "claude",
           let token = claudeTokenResolver(), !token.isEmpty {
            inheritedFD = (ClaudeOAuthInjector.fdEnvVar, Data(token.utf8))
        }

        let handle: PtyTransport.Handle
        do {
            handle = try transport.start(
                sessionId: sessionId, argv: argv, env: env, cwd: cwd,
                inheritedFD: inheritedFD, envRemove: patched.remove
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
            spawnedAtMono: ProcessInfo.processInfo.systemUptime,
            realtimePrivate: realtimePrivate
        )

        // Build the drain thread and stash its handle on the record
        // BEFORE the record is published into `sessions`. Once it's in
        // the dict the record is shared with listSessions / stopSession /
        // the drain loop, and from that point every mutable field
        // (`status`) is touched only under `lock`. Initializing
        // `drainThread` pre-publication keeps the record fully formed
        // before it becomes visible, so there's no unlocked write to an
        // already-shared object.
        let drain = Thread { [weak self] in
            self?.drainLoop(record: record)
        }
        drain.name = "cli-pulse-drain-\(sessionId)"
        record.drainThread = drain

        lock.lock()
        sessions[sessionId] = record
        lock.unlock()

        broker?.publish([
            "event": "session_started",
            "session_id": sessionId,
            "provider": provider,
            "client_label": clientLabel ?? NSNull(),
        ])

        // Start AFTER publication: a fast-exiting child's drain loop must
        // find the record in `sessions` (=== identity check) when it
        // flips status to stopped/errored, else the status write is lost.
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
        sessTransport(rec).terminate(rec.handle)
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
        sessTransport(rec).interrupt(rec.handle)
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
            n = try sessTransport(rec).writeStdin(rec.handle, body)
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
            n = try sessTransport(rec).writeStdin(rec.handle, bytes)
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
            try sessTransport(rec).setWinsize(rec.handle, cols: cols, rows: rows)
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

    /// v1.26 Phase B2: publish a tail-snapshot over the Realtime
    /// broadcast channel as event `tail_snapshot_result`. Reads
    /// from the ring buffer via `getTailSnapshot` (already redacted)
    /// and hands off to the `TerminalBroadcastPublisher` (Phase 2c
    /// slice 2), which re-runs redaction (idempotent) and POSTs.
    ///
    /// Returns `true` when a publish was attempted (publisher present
    /// AND session owned), `false` otherwise. The publisher itself
    /// is fire-and-forget — a `true` return doesn't guarantee
    /// delivery. iOS times out at 2 s if no broadcast arrives.
    @discardableResult
    public func publishTailSnapshot(sessionId: String, maxBytes: Int) async -> Bool {
        guard let publisher = broadcastPublisher else { return false }
        // R0 (S2) fail-closed: never publish a private/unknown session's snapshot
        // on the public `term:` channel (a gone session → nil → also muted).
        lock.lock()
        let allowPublic = sessions[sessionId]?.allowsPublicBroadcast ?? false
        lock.unlock()
        guard allowPublic else { return false }
        guard let snapshot = getTailSnapshot(sessionId: sessionId, maxBytes: maxBytes) else {
            return false
        }
        // Empty snapshot for a brand-new session: don't publish.
        // The iOS side will time out at 2 s and drain its (also
        // empty) buffer — same UX as the v1.25 baseline.
        if snapshot.isEmpty { return false }
        await publisher.submit(
            sessionId: sessionId,
            channel: "tail_snapshot_result",
            chunk: snapshot)
        return true
    }

    // MARK: - drain loop

    private func drainLoop(record: ManagedSessionRecord) {
        let intervalNs = UInt32(config.drainIntervalMs * 1000)
        // M4.4a: resolve the record's transport ONCE — an attached tmux session
        // reads/reaps through its TmuxTransport, a spawned one through the PTY.
        let t = sessTransport(record)
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
                let chunk = try t.readStdout(record.handle, maxBytes: config.drainChunkBytes)
                if !chunk.isEmpty {
                    // v1.24 Phase 2c slice 1: feed the tail buffer
                    // for get_tail_snapshot foreground-recovery.
                    // Stored verbatim; redaction at read time.
                    record.tailBuffer.append(chunk)
                    // v1.24 Phase 2c slice 2: also hand off to the
                    // terminal Broadcast publisher when configured.
                    // Publisher redacts + ships to sink; this call
                    // is fire-and-forget (actor handles its own
                    // queue/drop policy).
                    //
                    // R0 (S2) fail-closed: the publisher POSTs to the PUBLIC
                    // `term:<sid>` topic, so mirror there ONLY for a session
                    // positively known public. A private or unknown-privacy
                    // session gets NO broadcast — its output never leaks on the
                    // public channel (the Swift helper has no `pterm:` producer;
                    // the phone falls back to polling).
                    if record.allowsPublicBroadcast, let publisher = broadcastPublisher {
                        let sid = record.sessionId
                        let payload = chunk
                        Task { await publisher.submit(sessionId: sid, chunk: payload) }
                    }
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
            if !t.isAlive(record.handle) {
                // Phase 4E Slice 3: capture exit code so
                // RemoteAgentCloud can decide stopped vs errored
                // status. `waitChild(timeoutSec: 0)` is a poll —
                // returns nil if reaping isn't possible (already
                // reaped / errno=ECHILD).
                let exitStatus = t.waitChild(record.handle, timeoutSec: 0)
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
        t.close(record.handle)
    }
}
