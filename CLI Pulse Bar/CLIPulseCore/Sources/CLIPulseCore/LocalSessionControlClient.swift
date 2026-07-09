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

/// Machine controls M1: result of `LocalSessionControlClient.killProcess`.
/// A refusal throws rather than returning this; a returned value means the
/// process was signalled. `escalated` is true when SIGTERM didn't take
/// within the grace window and the helper had to send SIGKILL.
public struct KillProcessResult: Sendable, Equatable {
    public let terminated: Bool
    public let escalated: Bool

    public init(terminated: Bool, escalated: Bool) {
        self.terminated = terminated
        self.escalated = escalated
    }
}

/// Phase 3 Iter 2B: structured local approval row. Backed by the
/// helper's `ApprovalRegistry` and surfaced to the UI through both
/// `subscribe_events` (push) and `get_pending_approvals` (snapshot).
///
/// **Security state.** This row drives the inline Approve / Reject
/// controls in the macOS Sessions tab. It is created exclusively by
/// `hook_create_approval` on the helper's UDS surface (which requires
/// the per-session capability token); PTY output text NEVER produces
/// one. The macOS UI MUST gate the Approve / Reject buttons on the
/// presence of a `PendingApproval` for the row's session — never on a
/// regex / string match against `output_delta` payloads.
public struct PendingApproval: Sendable, Equatable, Codable, Identifiable {
    public let approvalId: String
    public let sessionId: String
    public let type: String
    public let title: String
    public let summary: String
    public let toolMetadata: [String: String]   // simplified: stringified scalars
    public let status: String                   // pending | approved | rejected | expired | cancelled
    public let createdAt: Date
    public let expiresAt: Date?

    public var id: String { approvalId }

    public init(
        approvalId: String,
        sessionId: String,
        type: String,
        title: String,
        summary: String,
        toolMetadata: [String: String],
        status: String,
        createdAt: Date,
        expiresAt: Date?
    ) {
        self.approvalId = approvalId
        self.sessionId = sessionId
        self.type = type
        self.title = title
        self.summary = summary
        self.toolMetadata = toolMetadata
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// Decode from the helper's wire-level dict (`PendingApproval.to_dict_safe`).
    /// Returns nil on missing required fields rather than throwing — the
    /// caller treats the row as unparseable and falls through to a
    /// snapshot refresh.
    public static func decode(from raw: [String: Any]) -> PendingApproval? {
        guard
            let approvalId = raw["approval_id"] as? String,
            let sessionId = raw["session_id"] as? String,
            let status = raw["status"] as? String,
            let createdAtRaw = raw["created_at"] as? Double
        else { return nil }
        let type = (raw["type"] as? String) ?? "PermissionRequest"
        let title = (raw["title"] as? String) ?? type
        let summary = (raw["summary"] as? String) ?? ""
        var meta: [String: String] = [:]
        if let m = raw["tool_metadata"] as? [String: Any] {
            for (k, v) in m {
                if let sv = v as? String {
                    meta[k] = sv
                } else if let nv = v as? NSNumber {
                    meta[k] = nv.stringValue
                } else if let bv = v as? Bool {
                    meta[k] = bv ? "true" : "false"
                }
            }
        }
        let expiresAt: Date? = (raw["expires_at"] as? Double).map {
            Date(timeIntervalSince1970: $0)
        }
        return PendingApproval(
            approvalId: approvalId,
            sessionId: sessionId,
            type: type,
            title: title,
            summary: summary,
            toolMetadata: meta,
            status: status,
            createdAt: Date(timeIntervalSince1970: createdAtRaw),
            expiresAt: expiresAt
        )
    }
}

/// Decision the user picked. Mirrors the helper's `decide` argument.
public enum ApprovalDecision: String, Sendable, Equatable, Codable {
    case approve
    case reject
}

/// Phase 4 helper-bundling: result of `LocalSessionControlClient.
/// installClaudeHook()`. Mirrors the dict the Python helper's
/// `permissions_diagnose.install_claude_hook` returns. The macOS UI
/// surfaces these so the user knows whether anything actually changed
/// (e.g. `action == "noop"` means the hook was already correctly
/// wired and the user clicked "Install" redundantly).
public struct InstallClaudeHookResult: Sendable, Equatable {
    /// One of `"created" | "added" | "noop" | "replaced"`. Drives
    /// the post-install copy in the SessionsTab banner ("Hook
    /// installed", "Hook updated to point at this app", etc.).
    public let action: String
    /// The hook command that was previously in `~/.claude/settings.json`,
    /// if any. `nil` for fresh installs. Used for diff-style copy
    /// when the user renames their helper checkout.
    public let previousCommand: String?
    /// The hook command that's now in place. Always non-nil after a
    /// successful call.
    public let newCommand: String
    /// Absolute path of the file the helper wrote to. Lets the UI
    /// link to it via Finder for users who want to inspect the
    /// settings post-install.
    public let settingsPath: String

    public init(
        action: String,
        previousCommand: String?,
        newCommand: String,
        settingsPath: String
    ) {
        self.action = action
        self.previousCommand = previousCommand
        self.newCommand = newCommand
        self.settingsPath = settingsPath
    }
}

/// Wire-level event coming off the helper's `subscribe_events` stream.
/// Decoded by `LocalSessionControlClient.subscribeEvents`. The macOS
/// app's per-row task drains the stream and updates AppState.
///
/// Unknown event types decode as `.other(name, raw)` so a future
/// helper that adds a new event kind doesn't crash old apps.
public enum LocalSessionEvent: Sendable, Equatable {
    /// Initial snapshot frame the helper sends as the streaming ack
    /// before any live event. Lets the app catch up without a second
    /// round-trip.
    case subscribed(sessionId: String?, managedSessions: [SessionControlSummary], pendingApprovals: [PendingApproval])
    case sessionStarted(sessionId: String, provider: String, clientLabel: String?)
    case outputDelta(sessionId: String, payload: String, ts: TimeInterval)
    /// v1.30.x Phase 1b: raw (un-stripped, still redacted) terminal output —
    /// only delivered to subscribers that opted in with `raw: true` (the in-app
    /// xterm.js terminal). ANSI escapes preserved so the TUI renders.
    case outputRaw(sessionId: String, payload: String, ts: TimeInterval)
    case sessionStatus(sessionId: String, status: String)
    case sessionStopped(sessionId: String, exitCode: Int?)
    case approvalRequested(approval: PendingApproval)
    case approvalResolved(sessionId: String, approvalId: String, decision: String, status: String)
    case heartbeat(ts: TimeInterval)
    case error(code: String, message: String)
    case other(name: String, raw: [String: Any])

    public static func == (lhs: LocalSessionEvent, rhs: LocalSessionEvent) -> Bool {
        switch (lhs, rhs) {
        case (.subscribed(let a, let b, let c), .subscribed(let d, let e, let f)):
            return a == d && b == e && c == f
        case (.sessionStarted(let a, let b, let c), .sessionStarted(let d, let e, let f)):
            return a == d && b == e && c == f
        case (.outputDelta(let a, let b, _), .outputDelta(let d, let e, _)):
            return a == d && b == e
        case (.outputRaw(let a, let b, _), .outputRaw(let d, let e, _)):
            return a == d && b == e
        case (.sessionStatus(let a, let b), .sessionStatus(let c, let d)):
            return a == c && b == d
        case (.sessionStopped(let a, let b), .sessionStopped(let c, let d)):
            return a == c && b == d
        case (.approvalRequested(let a), .approvalRequested(let b)):
            return a == b
        case (.approvalResolved(let a, let b, let c, let d),
              .approvalResolved(let e, let f, let g, let h)):
            return a == e && b == f && c == g && d == h
        case (.heartbeat, .heartbeat):
            return true
        case (.error(let a, let b), .error(let c, let d)):
            return a == c && b == d
        case (.other(let a, _), .other(let b, _)):
            return a == b
        default:
            return false
        }
    }

    /// Decode from a helper-side event dict. Returns nil for the
    /// initial-ack ok envelope shape (which is decoded separately
    /// by the streaming consumer because it's wrapped in {"ok": true,
    /// "result": {...}} rather than being a bare event).
    public static func decode(from raw: [String: Any]) -> LocalSessionEvent? {
        let name = (raw["event"] as? String) ?? ""
        let ts = (raw["ts"] as? Double) ?? Date().timeIntervalSince1970
        let sessionId = (raw["session_id"] as? String) ?? ""
        switch name {
        case "session_started":
            return .sessionStarted(
                sessionId: sessionId,
                provider: (raw["provider"] as? String) ?? "claude",
                clientLabel: raw["client_label"] as? String
            )
        case "output_delta":
            return .outputDelta(
                sessionId: sessionId,
                payload: (raw["payload"] as? String) ?? "",
                ts: ts
            )
        case "output_raw":
            return .outputRaw(
                sessionId: sessionId,
                payload: (raw["payload"] as? String) ?? "",
                ts: ts
            )
        case "session_status":
            return .sessionStatus(
                sessionId: sessionId,
                status: (raw["status"] as? String) ?? ""
            )
        case "session_stopped":
            return .sessionStopped(
                sessionId: sessionId,
                exitCode: raw["exit_code"] as? Int
            )
        case "approval_requested":
            guard let inner = raw["approval"] as? [String: Any],
                  let approval = PendingApproval.decode(from: inner) else {
                return .other(name: name, raw: raw)
            }
            return .approvalRequested(approval: approval)
        case "approval_resolved":
            return .approvalResolved(
                sessionId: sessionId,
                approvalId: (raw["approval_id"] as? String) ?? "",
                decision: (raw["decision"] as? String) ?? "",
                status: (raw["status"] as? String) ?? ""
            )
        case "heartbeat":
            return .heartbeat(ts: ts)
        case "error":
            return .error(
                code: (raw["code"] as? String) ?? "",
                message: (raw["message"] as? String) ?? ""
            )
        case "":
            return nil
        default:
            return .other(name: name, raw: raw)
        }
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
public final class LocalSessionControlClient: SessionControlClient, MachineControlRelaying {
    public static let appGroupID = "group.yyh.CLI-Pulse"
    public static let socketFilename = "clipulse-helper.sock"
    public static let authTokenFilename = "helper-auth-token"

    /// Group-container base path shared by the app's UDS client and the
    /// installer's liveness probe. Prefer the sandbox-provisioned container;
    /// when that's nil, fall back to the REAL-home `Library/Group Containers`
    /// path the (unsandboxed) helper binds in — NOT `NSHomeDirectory()`, which
    /// under the App Sandbox is the app's PRIVATE container
    /// (`~/Library/Containers/yyh.CLI-Pulse/Data`), a path the helper never
    /// creates → permanent ENOENT → "helper running but app reports not
    /// detected". `passwdHomeDirectory()` (thread-safe `getpwuid_r`) bypasses
    /// the sandbox home redirect, matching the helper's
    /// `AuthToken.containerPath()` and the existing `HelperInstaller.helperDir`
    /// resolution.
    public static func groupContainerBasePath() -> String {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            return url.path
        }
        let realHome: String = passwdHomeDirectory()
            ?? NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        return (realHome as NSString)
            .appendingPathComponent("Library/Group Containers/\(appGroupID)")
    }
    public static let protocolVersion = 1

    /// v1.34 R1d: the minimum helper version that injects the user's Claude
    /// subscription (Max/Pro) OAuth token into managed `claude` sessions. A
    /// socket-owner helper BELOW this floor spawns `claude` on the Claude API
    /// instead. The injection landed in the Python helper at 1.20.0 and in the
    /// Swift helper at 1.21.0 (`kHelperVersion`), both on this version line, so
    /// a single floor comparison covers whichever helper owns the socket.
    public static let oauthInjectionHelperFloor = "1.20.0"

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
            let base = Self.groupContainerBasePath()
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
        // v1.15: optional `provider_availability` field. Older helpers
        // omit it entirely; treat that as "no advertised list" so the
        // UI falls back to the legacy implicit Claude default rather
        // than blanking out every Menu item on a not-yet-upgraded
        // helper.
        let providerAvailability =
            (result["provider_availability"] as? [String]) ?? []
        // v1.16: optional `helper_version` field. Empty string for
        // older helpers; HelperInstaller treats "" as "predates 1.16,
        // could be 1.15 nohup or older".
        let helperVersion = (result["helper_version"] as? String) ?? ""
        // v1.30.2 (RC-1): optional `paired` flag. Absent on older helpers →
        // nil (unknown). false ⇒ installed + running but not yet paired.
        let paired = result["paired"] as? Bool
        // Optional `provider_plan_status` (on_plan/off_plan per provider). Absent on older
        // helpers → empty → no warning (the picker treats a missing entry as unknown).
        let providerPlanStatus =
            (result["provider_plan_status"] as? [String: String]) ?? [:]
        return SessionControlHello(
            protocolVersion: version,
            supportedMethods: Set(methods),
            capabilities: caps,
            providerAvailability: providerAvailability,
            helperVersion: helperVersion,
            paired: paired,
            providerPlanStatus: providerPlanStatus
        )
    }

    /// `SessionControlClient` protocol conformance (4-param). Forwards to the
    /// v-next P1-1 cwd-aware overload with `cwd: nil` (inherit). Kept as a
    /// distinct method (rather than a defaulted param) so the 4-param protocol
    /// requirement is satisfied exactly and existing callers stay unchanged.
    public func startManagedSession(
        provider: String,
        clientLabel: String?,
        cwdBasename: String?,
        cwdHmac: String?
    ) async throws -> SessionControlStartResult {
        try await startManagedSession(
            provider: provider, clientLabel: clientLabel,
            cwdBasename: cwdBasename, cwdHmac: cwdHmac, cwd: nil)
    }

    public func startManagedSession(
        provider: String,
        clientLabel: String?,
        cwdBasename: String?,
        cwdHmac: String?,
        cwd: String?
    ) async throws -> SessionControlStartResult {
        var params: [String: Any] = ["provider": provider]
        if let clientLabel { params["client_label"] = clientLabel }
        if let cwdBasename { params["cwd_basename"] = cwdBasename }
        if let cwdHmac { params["cwd_hmac"] = cwdHmac }
        // v-next P1-1: the real absolute working directory the helper spawns
        // the child in. Local UDS only (same-Mac); the helper validates it
        // (absolute + existing dir). Omitted ⇒ helper inherits its own dir.
        if let cwd { params["cwd"] = cwd }
        let result = try await send(method: "start_session", params: params)
        guard let sid = result["session_id"] as? String, !sid.isEmpty else {
            throw SessionControlError.invalidResponse("start_session: missing session_id")
        }
        // v1.15 codex review (round 2): the helper's
        // `_local_start_claude_session_impl` returns
        //   { "session_id": <uuid>, "ok": <bool> }
        // where `ok=false` indicates the spawn itself failed (e.g. the
        // requested provider's binary was not on PATH). Pre-fix the
        // Swift caller only checked `session_id`, treated the call as
        // success, and the optimistic-append path in
        // `LocalSessionControlState` registered a phantom "running"
        // session that never existed. Surface the failure as a typed
        // error so the caller can show it AND skip the optimistic
        // append.
        if let ok = result["ok"] as? Bool, !ok {
            throw SessionControlError.spawnFailed(
                detail: "helper reported start_session ok=false (provider \(provider))"
            )
        }
        return SessionControlStartResult(sessionId: sid, commandId: nil)
    }

    public func listSessions() async throws -> [SessionControlSummary] {
        // v1.16 hotfix: list_sessions on the helper scans running
        // Claude/Codex/Gemini processes for the `detected` rows; on
        // a busy Mac that walk can take 1-3 s. Default 5 s
        // requestTimeout caught the slow tail and surfaced as
        // "local list_sessions failed: timeout" → empty
        // localManagedSessions → fast-path subscribe never fires →
        // user sees "No output yet…" indefinitely. 15 s override
        // here only; other RPCs keep the tighter default so a real
        // helper hang surfaces quickly.
        let result = try await send(method: "list_sessions", params: [:], timeoutOverride: 15)
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

    /// System Monitor S4: read-only machine-health snapshot from the helper
    /// (per-process CPU/mem, battery health, native temps/fans/power). The helper
    /// gathers everything the sandbox can't; the app just renders what it returns.
    public func getMachineSnapshot() async throws -> MachineSnapshot {
        let result = try await send(method: "get_machine_snapshot", params: [:])
        return MachineSnapshot(dict: result)
    }

    // MARK: - v1.41 machine-mobile relay (Track B, MachineControlRelaying)

    /// Drain the fan/LPM commands the helper pulled from the cloud queue for the
    /// RemoteMachineExecutor. Read-only; the executor acks each via
    /// `completeMachineCommand`. A `.notImplemented` throw ⇒ helper too old — the
    /// executor treats that as "skip this tick" (mirrors get_machine_snapshot).
    public func pullMachineCommands() async throws -> [RemoteMachineCommand] {
        let result = try await send(method: "pull_machine_commands", params: [:])
        let rows = (result["commands"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let kind = row["kind"] as? String else { return nil }
            let payload = row["payload"] as? [String: Any] ?? [:]
            return RemoteMachineCommand(
                id: id,
                kind: kind,
                rpm: (payload["rpm"] as? NSNumber)?.intValue,
                ttlSeconds: (payload["ttl_seconds"] as? NSNumber)?.intValue,
                on: payload["on"] as? Bool,
                lid: payload["prevent_lid_sleep"] as? Bool
            )
        }
    }

    /// Forward the executor's typed completion (done/failed + optional error code
    /// like daemon_unavailable / clamped) to the cloud via the helper.
    public func completeMachineCommand(id: String, status: String, error: String?) async throws {
        var params: [String: Any] = ["command_id": id, "status": status]
        if let error, !error.isEmpty {
            params["result"] = ["error": error]
        }
        _ = try await send(method: "complete_machine_command", params: params)
    }

    /// Report the executor's live control state so the helper folds it into the
    /// next heartbeat (the phone renders ONLY controls the Mac will honor). Must
    /// be called ~every 2 s — the helper treats a report as "alive" for 15 s.
    public func reportMachineControlState(_ state: RemoteMachineControlState) async throws {
        var s: [String: Any] = [
            "remote_fan": state.remoteFan,
            "remote_lpm": state.remoteLPM,
            "boost_active": state.boostActive,
            "keep_awake": state.keepAwake,
            "keep_awake_active": state.keepAwakeActive,
            "keep_awake_lid_active": state.keepAwakeLidActive,
        ]
        if let rpm = state.boostTargetRPM { s["boost_target_rpm"] = rpm }
        _ = try await send(method: "report_machine_control_state", params: ["state": s])
    }

    /// Machine controls M1: ask the (unsandboxed) helper to terminate a
    /// SAME-UID process by pid (SIGTERM → ~2s grace → SIGKILL). The helper's
    /// `machine_actions` guard refuses pid ≤ 1, protected system processes,
    /// the helper itself, another user's / root's processes, and a flood; a
    /// refusal throws a typed `SessionControlError` (`.processNotFound` /
    /// `.processProtected` / `.processNotPermitted` / `.rateLimited`). On
    /// success it returns whether SIGKILL was needed. NO root — same-UID only.
    public func killProcess(pid: Int) async throws -> KillProcessResult {
        let result = try await send(method: "kill_process", params: ["pid": pid])
        return KillProcessResult(
            terminated: (result["terminated"] as? Bool) ?? false,
            escalated: (result["escalated"] as? Bool) ?? false
        )
    }

    /// Machine controls v1.38.1: pause a SAME-UID process (`SIGSTOP`). Immediate
    /// (no escalation), reversible with `resumeProcess`. Same guard as
    /// `killProcess` — a refusal throws the same typed `SessionControlError`
    /// (`.processNotFound` / `.processProtected` / `.processNotPermitted` /
    /// `.rateLimited`). Both suspend and resume ride ONE wire verb
    /// (`signal_process` + an `action` param). NO root — same-UID only.
    public func suspendProcess(pid: Int) async throws {
        _ = try await send(method: "signal_process",
                           params: ["pid": pid, "action": "suspend"])
    }

    /// Machine controls v1.38.1: resume a paused SAME-UID process (`SIGCONT`).
    /// Benign + immediate (no confirm on the app side). Same refusal surface as
    /// `suspendProcess`.
    public func resumeProcess(pid: Int) async throws {
        _ = try await send(method: "signal_process",
                           params: ["pid": pid, "action": "resume"])
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

    // MARK: - v1.24 Phase 2+3: in-app terminal RPC wrappers

    /// Raw byte input — preserves control bytes (0x03 Ctrl-C, 0x04
    /// Ctrl-D, ESC sequences) without the CR-append `sendInput`
    /// applies. Used by `TerminalView` in the in-app terminal path.
    /// Payload travels base64-encoded so JSON-string-escape can't
    /// corrupt arbitrary byte values.
    public func sendInputRaw(sessionId: String, bytes: Data) async throws {
        _ = try await send(
            method: "send_input_raw",
            params: [
                "session_id": sessionId,
                "payload_base64": bytes.base64EncodedString(),
            ]
        )
    }

    /// Window-size update. Triggers `ioctl(TIOCSWINSZ)` on the
    /// child's master PTY → SIGWINCH → ratatui / ncurses CLIs
    /// re-flow their viewport. Cols/rows clamped to (0, 1000] on
    /// the helper side; this client validates the same range so we
    /// don't waste a round-trip on obvious garbage.
    public func resize(sessionId: String, cols: Int, rows: Int) async throws {
        guard cols > 0, cols <= 1000, rows > 0, rows <= 1000 else {
            throw SessionControlError.invalidResponse(
                "resize: cols/rows must be positive integers ≤ 1000 (got \(cols)×\(rows))"
            )
        }
        _ = try await send(
            method: "resize",
            params: ["session_id": sessionId, "cols": cols, "rows": rows]
        )
    }

    /// Foreground-recovery snapshot — returns up to `maxBytes`
    /// (default 8192, capped at 65 536 on the helper) of the most
    /// recent stdout, redacted. Powers the iOS WKWebView's
    /// background→foreground recovery; the Mac TerminalView calls
    /// this when an existing session is being attached to a fresh
    /// view (e.g. window re-opened).
    public func getTailSnapshot(sessionId: String, maxBytes: Int = 8192) async throws -> Data {
        let result = try await send(
            method: "get_tail_snapshot",
            params: ["session_id": sessionId, "max_bytes": maxBytes]
        )
        guard let b64 = result["bytes_base64"] as? String else {
            throw SessionControlError.invalidResponse("get_tail_snapshot: missing bytes_base64")
        }
        return Data(base64Encoded: b64) ?? Data()
    }

    // MARK: - Iter 2B: streaming + approvals

    /// Open a long-lived `subscribe_events` stream. The returned
    /// AsyncThrowingStream yields one `LocalSessionEvent` per event
    /// frame the helper sends. The first non-snapshot value is
    /// `.subscribed(...)` carrying the initial snapshot.
    ///
    /// Cancellation: cancelling the consuming Task tears the
    /// connection down via `onTermination`. The helper's broker
    /// detects the EOF and unsubscribes.
    ///
    /// Failure modes that throw on the stream:
    ///   - SessionControlError.helperNotRunning if the socket isn't
    ///     reachable
    ///   - SessionControlError.unauthenticated if the auth token
    ///     file is missing / the helper rejects it
    ///   - SessionControlError.localControlOff if the gate is off
    ///   - SessionControlError.disconnected on a mid-stream
    ///     transport failure
    /// - Parameter raw: v1.30.x Phase 1b — when true, opt into the raw
    ///   (un-stripped, still redacted) `output_raw` stream instead of the
    ///   redacted+stripped `output_delta`. The in-app xterm.js terminal sets
    ///   this so the TUI renders; the SessionsTab preview leaves it false.
    public func subscribeEvents(sessionId: String? = nil, raw: Bool = false) -> AsyncThrowingStream<LocalSessionEvent, Error> {
        AsyncThrowingStream { continuation in
            // Box for the connection so the outer onTermination (set
            // BEFORE the inner Task runs) can still reach it. The
            // inner Task assigns into this box once `connect()`
            // returns; before that, onTermination just cancels the
            // task and connect() will throw `.timeout` to unwind.
            let connBox = _ConnectionBox()
            let task = Task { [self] in
                do {
                    var params: [String: Any] = [:]
                    if let sessionId { params["session_id"] = sessionId }
                    if raw { params["raw"] = true }
                    guard let token = readToken(), !token.isEmpty else {
                        throw SessionControlError.unauthenticated
                    }
                    let envelope: [String: Any] = [
                        "id": UUID().uuidString,
                        "method": "subscribe_events",
                        "auth_token": token,
                        "params": params,
                    ]
                    let body = try JSONSerialization.data(
                        withJSONObject: envelope, options: [.sortedKeys]
                    )
                    let conn = try await connect()
                    connBox.connection = conn
                    // If the consumer already cancelled while we were
                    // connecting, drop the connection now and bail.
                    if Task.isCancelled {
                        conn.cancel()
                        continuation.finish()
                        return
                    }
                    try await sendFrame(conn, body: body)
                    // First frame is the ack envelope. The ack is the
                    // helper's snapshot reply built synchronously from
                    // the registry + broker, so a watchdog timeout on
                    // it IS still the right behaviour (a missing ack
                    // means the helper hung). The streaming receives
                    // below run with `timeout: nil` precisely because
                    // a missing event is normal during idle.
                    let ackBytes = try await receiveFrame(conn, timeout: requestTimeout)
                    let ackResult = try parseReply(ackBytes)
                    let initialSessions = (ackResult["managed_sessions"] as? [[String: Any]]) ?? []
                    let initialApprovals = (ackResult["pending_approvals"] as? [[String: Any]]) ?? []
                    var sessionRows: [SessionControlSummary] = []
                    for row in initialSessions {
                        guard let id = row["session_id"] as? String else { continue }
                        sessionRows.append(.init(
                            id: id,
                            provider: (row["provider"] as? String) ?? "claude",
                            clientLabel: row["client_label"] as? String,
                            status: (row["status"] as? String) ?? "running",
                            controllable: (row["controllable"] as? Bool) ?? true,
                            source: .managed
                        ))
                    }
                    let approvals = initialApprovals.compactMap { PendingApproval.decode(from: $0) }
                    continuation.yield(.subscribed(
                        sessionId: sessionId,
                        managedSessions: sessionRows,
                        pendingApprovals: approvals
                    ))
                    // Streaming loop. Each frame is a bare event dict
                    // (NOT wrapped in {"ok":..., "result":...}).
                    //
                    // `timeout: nil` is load-bearing here. With a
                    // watchdog, an idle period longer than the
                    // watchdog throws `.timeout`, the loop continues,
                    // a second `receive` is scheduled, and the OLD
                    // receive callback (still pending on the
                    // NWConnection) eats the next frame's bytes
                    // before the new receive sees them. Codex caught
                    // this on PR #18 (heartbeat=15s, requestTimeout=5s
                    // → frames lost on every idle gap). Keeping
                    // exactly one outstanding receive at a time means
                    // the kernel/Network framework hands bytes to the
                    // single live continuation.
                    while !Task.isCancelled {
                        let frameBytes: Data
                        do {
                            frameBytes = try await receiveFrame(conn, timeout: nil)
                        } catch let err as SessionControlError where err == .disconnected {
                            // Connection torn down (cancellation or
                            // helper shutdown). Exit cleanly.
                            throw err
                        }
                        guard let raw = try? JSONSerialization.jsonObject(with: frameBytes) as? [String: Any] else {
                            throw SessionControlError.invalidResponse("event frame not a JSON object")
                        }
                        guard let event = LocalSessionEvent.decode(from: raw) else {
                            continue
                        }
                        continuation.yield(event)
                        if case .error = event {
                            break
                        }
                    }
                    conn.cancel()
                    continuation.finish()
                } catch {
                    connBox.connection?.cancel()
                    continuation.finish(throwing: error)
                }
            }
            // Single onTermination handler that yanks BOTH the
            // connection (so the pending receive resolves with an
            // error and the inner Task unblocks) AND the Task
            // itself. Previously two assignments existed and the
            // second overwrote the first, so cancellation only
            // cancelled the Task — which doesn't auto-resolve a
            // continuation suspended on receive — and the stream
            // hung until the helper independently disconnected.
            continuation.onTermination = { @Sendable [task, connBox] _ in
                connBox.connection?.cancel()
                task.cancel()
            }
        }
    }

    /// Decide a structured pending approval. Throws typed errors per
    /// `SessionControlErrorMapping` — the macOS UI maps each to a
    /// row-specific user message (e.g. `approvalAlreadyResolved`
    /// → "Already approved on another device").
    public func approveAction(
        sessionId: String,
        approvalId: String,
        decision: ApprovalDecision,
        comment: String? = nil
    ) async throws {
        var params: [String: Any] = [
            "session_id": sessionId,
            "approval_id": approvalId,
            "decision": decision.rawValue,
        ]
        if let comment, !comment.isEmpty {
            params["comment"] = comment
        }
        _ = try await send(method: "approve_action", params: params)
    }

    /// Phase 4 helper-bundling: ask the (unsandboxed) helper to
    /// idempotently install the Claude PermissionRequest hook into
    /// `~/.claude/settings.json`. Sandboxed macOS app can't write
    /// that path itself; this wraps the new `install_claude_hook`
    /// UDS method which delegates to the same
    /// `permissions_diagnose.install_claude_hook` function the CLI
    /// subcommand uses.
    ///
    /// The helper supplies its OWN argv[0] as the hook command's
    /// `helper_path` — the app deliberately does NOT pass arbitrary
    /// paths so a malicious socket peer can't reroute the hook
    /// command at a third-party Python script.
    ///
    /// Returns the same status fields the CLI prints
    /// (`action`, `previous_command`, `new_command`, `settings_path`)
    /// for the UI to surface.
    public func installClaudeHook() async throws -> InstallClaudeHookResult {
        let result = try await send(method: "install_claude_hook", params: [:])
        guard
            let action = result["action"] as? String,
            let newCommand = result["new_command"] as? String,
            let settingsPath = result["settings_path"] as? String
        else {
            throw SessionControlError.invalidResponse(
                "install_claude_hook: missing action / new_command / settings_path"
            )
        }
        return InstallClaudeHookResult(
            action: action,
            previousCommand: result["previous_command"] as? String,
            newCommand: newCommand,
            settingsPath: settingsPath
        )
    }

    /// Snapshot of pending approvals — used by the macOS UI on row
    /// expand and as the recovery path when a stream disconnects.
    /// `sessionId == nil` returns every session's pending rows.
    public func getPendingApprovals(sessionId: String? = nil) async throws -> [PendingApproval] {
        var params: [String: Any] = [:]
        if let sessionId { params["session_id"] = sessionId }
        let result = try await send(method: "get_pending_approvals", params: params)
        let raw = (result["pending_approvals"] as? [[String: Any]]) ?? []
        return raw.compactMap { PendingApproval.decode(from: $0) }
    }

    // MARK: - Existing Iter 2A surface

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
        requireAuth: Bool = true,
        timeoutOverride: TimeInterval? = nil
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
        // One-shot RPC: missing reply IS a timeout-class error,
        // so apply the configured requestTimeout watchdog. Per-call
        // override exists for slow RPCs (`list_sessions` scans
        // running CLI processes; can take 1-3 s on a busy Mac).
        let timeout = timeoutOverride ?? requestTimeout
        let reply = try await receiveFrame(conn, timeout: timeout)
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
        // Do NOT hard-fail on a false `socketExists`. FileManager.fileExists
        // is an unreliable gate for a UNIX-domain socket the (unsandboxed)
        // helper created in the shared group container — a running,
        // connectable helper would otherwise be reported "not running" purely
        // because the stat returned false (the "helper is visible in Activity
        // Monitor but the app doesn't detect it" reports). Still attempt the
        // connection; a genuinely-missing socket fails fast via the bounded
        // timeout below plus the ENOENT/ECONNREFUSED mapping in the state
        // handler. We SHORTEN the timeout when the socket looks absent so a
        // truly-missing path can't stall into overlapping attempts at the
        // ~3 s poll cadence (the v1.16 anti-hang intent — and the connect runs
        // on a background queue awaited via continuation, so it never blocks
        // the main actor), while a present-but-unstatable socket still
        // connects.
        let effectiveConnectTimeout = socketExists ? connectTimeout : Swift.min(connectTimeout, 1.5)
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
            queue.asyncAfter(deadline: .now() + effectiveConnectTimeout) {
                // Only act if the connection hasn't already resolved. If it
                // became .ready, the caller now owns it for a possibly
                // long-lived stream (subscribe_events) — cancelling here would
                // kill that active connection mid-stream. `resumed` and the
                // stateUpdateHandler both run on `queue` (serial), so this
                // check is race-free. On a genuine connect timeout (never
                // ready) we cancel to tear down the stuck .preparing
                // NWConnection instead of leaking it.
                guard !resumed else { return }
                connection.cancel()
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

    /// Receive one length-prefixed frame.
    ///
    /// `timeout` semantics:
    ///   * `.some(seconds)` — schedule an `asyncAfter` watchdog that
    ///     resumes the continuation with `.timeout` if no bytes
    ///     arrive in time. Used by request/reply RPCs, the
    ///     `subscribe_events` initial ack, and any other call where
    ///     a missing reply is itself a hard error.
    ///   * `nil` — NO watchdog. Used by streaming-loop event reads:
    ///     the helper heartbeats every 15s but a 5s `requestTimeout`
    ///     would fire repeatedly during normal idle, leaving the
    ///     pre-existing `conn.receive(...)` callback dangling. When
    ///     the next frame eventually arrives the OLD callback fires
    ///     first, sees `resumed == true`, and silently swallows
    ///     the bytes — the loop's brand-new `receive` call sees
    ///     nothing. Codex caught this on PR #18; with `timeout=nil`
    ///     there is exactly one outstanding receive and bytes are
    ///     never lost.
    ///
    /// Cancellation flow without a timeout watchdog: `subscribeEvents`
    /// hooks `continuation.onTermination` to call `conn.cancel()`,
    /// which transitions NWConnection to .cancelled and fires the
    /// pending receive callback with an error → the continuation
    /// resumes via `.failure(.disconnected)` → the loop exits.
    private func receiveFrame(
        _ conn: NWConnection,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let resolvedTimeout: TimeInterval? = timeout
        let header = try await receiveExact(conn, count: 4, timeout: resolvedTimeout)
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        if length > Self.maxPayload {
            throw SessionControlError.invalidResponse("inbound frame > 1 MiB (\(length))")
        }
        if length == 0 { return Data() }
        return try await receiveExact(conn, count: Int(length), timeout: resolvedTimeout)
    }

    /// Mutable reference holder so a `@Sendable` cancellation
    /// closure outside the inner Task can see the `NWConnection`
    /// the inner Task assigns once `connect()` resolves. NWConnection
    /// is itself a class so the box only needs to wrap a single
    /// optional. `@unchecked Sendable` is sound here because the
    /// only writer is the inner Task and the only reader is the
    /// onTermination closure, both of which serialise via the
    /// AsyncThrowingStream's continuation contract.
    private final class _ConnectionBox: @unchecked Sendable {
        var connection: NWConnection?
    }

    private func receiveExact(
        _ conn: NWConnection,
        count: Int,
        timeout: TimeInterval?
    ) async throws -> Data {
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
            if let timeout {
                queue.asyncAfter(deadline: .now() + timeout) {
                    resumeOnce(.failure(SessionControlError.timeout))
                }
            }
        }
    }
}

// MARK: - Machine health snapshot (System Monitor S4)

/// Decoded `get_machine_snapshot` reply. The helper gathers everything (the
/// sandbox can't); nil fields mean "not readable on this device". `capability`
/// is the honest per-device map the UI renders off (no battery card for a Mac
/// mini, no fan gauge for a fanless Air, no temps/fans/power without the S3
/// native binary).
public struct MachineSnapshot: Sendable {
    public struct Battery: Sendable {
        public let hasBattery: Bool
        public let chargePct: Int?
        public let state: String?
        public let cycleCount: Int?
        public let healthPct: Double?
        public let designCapacity: Int?
        public let currentCapacity: Int?
        public let batteryTempC: Double?
        public let adapterWatts: Double?
        public let thermalState: Int?
    }
    public struct ProcessInfo: Sendable, Identifiable {
        public let pid: Int
        public let name: String
        public let cpuPercent: Double
        public let rssMB: Double
        /// Owner UID. Machine controls M1 offers "End Process" ONLY when this
        /// equals the current user (a root/other-user pid can't be killed
        /// without the future root helper). -1 when the helper couldn't read it.
        public let uid: Int
        /// Process state (v1.38.1): "running" | "stopped" | "other". Chooses
        /// Suspend vs Resume and drives the "Paused" badge. Defaults to
        /// "running" when the helper omits it (an OLD ≤1.25.0 helper has no
        /// state column) so the affordance degrades to Suspend, never a
        /// stuck/blank control.
        public let state: String
        public var id: Int { pid }
        /// v1.38.1: a same-UID paused process the user can Resume.
        public var isStopped: Bool { state == "stopped" }
        /// v1.38.1: a running process the user can Suspend (excludes zombies /
        /// "other" so a defunct row offers neither Suspend nor Resume).
        public var isRunning: Bool { state == "running" }
    }

    public let cpuPercent: Int
    public let memoryPercent: Int
    public let memoryUsedBytes: Int
    public let memoryTotalBytes: Int
    public let battery: Battery
    public let topProcesses: [ProcessInfo]
    public let capability: [String: Bool]
    // Native sensors (nil when unavailable / no S3 binary).
    public let cpuTempC: Double?
    public let gpuTempC: Double?
    public let cpuPowerW: Double?
    public let gpuPowerW: Double?
    public let anePowerW: Double?
    public let systemPowerW: Double?
    public let fanRpm: Int?
    public let fanMaxRpm: Int?

    /// v1.39 extra system-monitor metrics. All Optional — nil against an older
    /// helper (≤1.26.0) that doesn't send the `system` block.
    public let uptimeSeconds: Int?
    public let loadAvg: [Double]?          // [1m, 5m, 15m]
    public let memoryPressure: String?     // "nominal" | "warn" | "critical"
    public let swapUsedBytes: Int?
    public let swapTotalBytes: Int?
    public let diskFreeBytes: Int?
    public let diskTotalBytes: Int?

    public func can(_ key: String) -> Bool { capability[key] == true }

    init(dict: [String: Any]) {
        func i(_ v: Any?) -> Int? {
            if let n = v as? NSNumber { return n.intValue }
            if let d = v as? Double { return Int(d) }
            if let x = v as? Int { return x }
            return nil
        }
        func d(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let x = v as? Double { return x }
            if let x = v as? Int { return Double(x) }
            return nil
        }
        cpuPercent = i(dict["cpu_percent"]) ?? 0
        memoryPercent = i(dict["memory_percent"]) ?? 0
        memoryUsedBytes = i(dict["memory_used_bytes"]) ?? 0
        memoryTotalBytes = i(dict["memory_total_bytes"]) ?? 0

        let b = dict["battery"] as? [String: Any] ?? [:]
        battery = Battery(
            hasBattery: (b["has_battery"] as? Bool) ?? false,
            chargePct: i(b["charge_pct"]),
            state: b["state"] as? String,
            cycleCount: i(b["cycle_count"]),
            healthPct: d(b["health_pct"]),
            designCapacity: i(b["design_capacity"]),
            currentCapacity: i(b["current_capacity"]),
            batteryTempC: d(b["battery_temp_c"]),
            adapterWatts: d(b["adapter_watts"]),
            thermalState: i(b["thermal_state"])
        )

        topProcesses = (dict["top_processes"] as? [[String: Any]] ?? []).compactMap { row in
            guard let pid = i(row["pid"]), let name = row["name"] as? String else { return nil }
            return ProcessInfo(pid: pid, name: name,
                               cpuPercent: d(row["cpu_percent"]) ?? 0,
                               rssMB: d(row["rss_mb"]) ?? 0,
                               uid: i(row["uid"]) ?? -1,
                               // v1.38.1: default "running" tolerates an OLD helper
                               // (≤1.25.0 sends no state) — degrades to Suspend.
                               state: (row["state"] as? String) ?? "running")
        }

        if let capRaw = dict["capability"] as? [String: Any] {
            capability = capRaw.compactMapValues { $0 as? Bool }
        } else {
            capability = [:]
        }

        let s = dict["sensors"] as? [String: Any] ?? [:]
        cpuTempC = d(s["cpu_temp_c"])
        gpuTempC = d(s["gpu_temp_c"])
        cpuPowerW = d(s["cpu_power_w"])
        gpuPowerW = d(s["gpu_power_w"])
        anePowerW = d(s["ane_power_w"])
        systemPowerW = d(s["system_power_w"])
        fanRpm = i(s["fan_rpm"])
        fanMaxRpm = i(s["fan_max_rpm"])

        let sys = dict["system"] as? [String: Any] ?? [:]
        uptimeSeconds = i(sys["uptime_seconds"])
        loadAvg = (sys["load_avg"] as? [Any])?.compactMap { d($0) }
        memoryPressure = sys["memory_pressure"] as? String
        swapUsedBytes = i(sys["swap_used_bytes"])
        swapTotalBytes = i(sys["swap_total_bytes"])
        diskFreeBytes = i(sys["disk_free_bytes"])
        diskTotalBytes = i(sys["disk_total_bytes"])
    }
}
#endif
