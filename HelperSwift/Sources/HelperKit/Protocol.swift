import Foundation

/// UDS protocol definitions — Swift port of the constants in
/// `helper/local_session_server.py`.
///
/// Wire compatibility note: the JSON shapes here MUST match the
/// Python implementation exactly. The macOS app's
/// `LocalSessionControlClient` decodes against these envelopes;
/// any drift breaks every existing client.

/// Protocol version pinned at 1 by iter1; iter2A bumped feature
/// surface but kept the version. Ports advertise this in `hello`.
public let kProtocolVersion: Int = 1

/// Semantic version of THIS (Swift) helper, advertised in the `hello`
/// reply as `helper_version` so the macOS app can compare the SOCKET
/// OWNER against the Claude-OAuth-injection floor (1.20.0).
///
/// Why this matters: the bundled Swift helper and the separately-
/// `.pkg`-installed Python helper bind the SAME UDS socket
/// (`clipulse-helper.sock`) and neither evicts a live peer — so on a Mac
/// with a stale pre-1.20.0 `.pkg` helper already bound at login, this
/// (newer) bundled helper cedes and the app talks to the OLD one, which
/// spawns `claude` on the Claude API instead of the user's Max plan.
/// Until this constant existed the Swift helper sent NO version, so the
/// app couldn't tell the bundled (injection-capable) helper from an
/// ancient one. Kept on the SAME version line as the Python helper
/// (`helper/system_collector.py:HELPER_VERSION`) so the app's single
/// floor comparison works for whichever helper owns the socket.
public let kHelperVersion: String = "1.23.0"

/// Methods this revision of the helper advertises in `hello`. Must
/// match `helper/local_session_server.py:SUPPORTED_METHODS`
/// element-for-element so the macOS app's capability negotiation
/// produces the same result.
public enum SupportedMethod: String, CaseIterable, Sendable {
    case hello
    case ping
    case getLocalControlStatus = "get_local_control_status"
    case setLocalControlEnabled = "set_local_control_enabled"
    case startSession = "start_session"
    case listSessions = "list_sessions"
    case stopSession = "stop_session"
    case sendInput = "send_input"
    // v1.24 Phase 2b — in-app terminal: raw byte input (no CR-append)
    // and window-size updates for the WKWebView xterm.js viewport.
    case sendInputRaw = "send_input_raw"
    case resize
    // v1.24 Phase 2c slice 1 — foreground-recovery snapshot.
    case getTailSnapshot = "get_tail_snapshot"
    // Phase 3 Iter 2B
    case subscribeEvents = "subscribe_events"
    case approveAction = "approve_action"
    case getPendingApprovals = "get_pending_approvals"
    case hookCreateApproval = "hook_create_approval"
    case hookWaitDecision = "hook_wait_decision"
    // Phase 4 (one-click install)
    case installClaudeHook = "install_claude_hook"
    // M1c/#18c: reversible other half of the opt-in — remove the CLI Pulse hooks
    // (both events) from ~/.claude/settings.json, preserving the user's hooks.
    case uninstallClaudeHook = "uninstall_claude_hook"
    // M2p2 codex-Swift port: install/remove the SAME hook into ~/.codex/hooks.json
    // (Claude-compatible format), scoped to the `--provider codex` marker so the
    // two providers never touch each other. App-auth + local-control gated exactly
    // like the claude verbs (the gate-var defaults below already do this). Codex
    // additionally needs a one-time `/hooks` TUI trust the result payload
    // surfaces via requires_manual_trust/trust_command.
    case installCodexHook = "install_codex_hook"
    case uninstallCodexHook = "uninstall_codex_hook"

    /// Methods that use the per-session capability token (set by
    /// the managed-session env vars) instead of the global app
    /// auth token. Mirrors Python's `HOOK_AUTH_METHODS`.
    public var isHookAuth: Bool {
        switch self {
        case .hookCreateApproval, .hookWaitDecision: return true
        default: return false
        }
    }

    /// Methods that bypass the auth-token requirement entirely.
    /// `hello` is the only one — clients use it for protocol +
    /// capability negotiation BEFORE they have any reason to
    /// authenticate. Pings used to bypass too but no longer do
    /// (Codex review fix in PR #18: a free liveness probe was a
    /// pointless info leak; clients always have the token by the
    /// time they're calling ping).
    public var bypassesAuth: Bool {
        return self == .hello
    }

    /// Methods that bypass the `local_control_enabled` gate. The
    /// handshake / introspection methods + the toggle itself all
    /// pass; the session-control + hook methods do not.
    public var bypassesGate: Bool {
        switch self {
        case .hello, .ping, .getLocalControlStatus, .setLocalControlEnabled:
            return true
        default:
            return false
        }
    }
}

/// Typed error codes matching `helper/local_session_server.py`'s
/// `_RequestError` `code` field. The macOS app's
/// `SessionControlErrorMapping` decodes against these strings;
/// keep wire-stable.
public enum WireErrorCode: String, Sendable {
    case badRequest = "bad_request"
    case unauthenticated
    case unknownMethod = "unknown_method"
    case localControlOff = "local_control_off"
    case sessionNotFound = "session_not_found"
    case notControllable = "not_controllable"
    case notImplemented = "not_implemented"
    case settingsMalformed = "settings_malformed"
    case internalError = "internal_error"
    // Iter 2B approval surface — match
    // `helper/local_approvals.py:ApprovalError`.
    case approvalNotFound = "approval_not_found"
    case approvalExpired = "approval_expired"
    case approvalAlreadyResolved = "approval_already_resolved"
    case approvalNotAllowed = "approval_not_allowed"
    case approvalCapabilityInvalid = "approval_capability_invalid"
    case approvalLimitReached = "approval_limit_reached"
    // Framing surface
    case frameTooLarge = "frame_too_large"
    case frameTruncated = "frame_truncated"
}

/// Request envelope — JSON top-level keys: `id`, `method`,
/// `auth_token`, `params`. Hook-side ingress uses `session_token`
/// + `session_id` instead of `auth_token` (mutually exclusive
/// auth tables; the dispatcher rejects either token presented
/// against the wrong method).
///
/// Not `Sendable` because `params: [String: Any]` cannot be
/// statically proven thread-safe. The connection-handling code
/// keeps each request scoped to a single Thread so this isn't
/// a real concurrency hazard, but Swift 6's strict-concurrency
/// checker can't prove that automatically.
public struct WireRequest {
    public let id: String
    public let method: String
    public let authToken: String?
    public let sessionToken: String?
    public let sessionId: String?
    public let params: [String: Any]

    public init(
        id: String,
        method: String,
        authToken: String? = nil,
        sessionToken: String? = nil,
        sessionId: String? = nil,
        params: [String: Any] = [:]
    ) {
        self.id = id
        self.method = method
        self.authToken = authToken
        self.sessionToken = sessionToken
        self.sessionId = sessionId
        self.params = params
    }

    /// Decode a JSON-decoded dict into a typed request envelope.
    /// Wire-format-tolerant: `id` may arrive as int or string;
    /// missing fields default to nil. Throws on missing `method`.
    public static func decode(from raw: [String: Any]) throws -> WireRequest {
        let id: String
        if let s = raw["id"] as? String { id = s }
        else if let n = raw["id"] as? Int { id = String(n) }
        else { id = "" }
        guard let method = raw["method"] as? String, !method.isEmpty else {
            throw WireDecodeError.missingMethod
        }
        let authToken = raw["auth_token"] as? String
        let sessionToken = raw["session_token"] as? String
        let sessionId = raw["session_id"] as? String
        let params = (raw["params"] as? [String: Any]) ?? [:]
        return WireRequest(
            id: id,
            method: method,
            authToken: authToken,
            sessionToken: sessionToken,
            sessionId: sessionId,
            params: params
        )
    }
}

public enum WireDecodeError: Error, Equatable {
    case missingMethod
    case malformedJSON
    case nonObjectRoot
}

/// Response envelope. Mirrors Python's `_ok` / `_err` helpers.
/// Not `Sendable` for the same reason as `WireRequest` —
/// `[String: Any]` payloads cross-thread are scoped to one
/// connection-handling Thread per request.
public struct WireResponse {
    public let id: String
    public let ok: Bool
    public let result: [String: Any]?
    public let errorCode: WireErrorCode?
    public let errorMessage: String?

    public static func ok(id: String, result: [String: Any]) -> WireResponse {
        WireResponse(id: id, ok: true, result: result, errorCode: nil, errorMessage: nil)
    }

    public static func err(id: String, code: WireErrorCode, message: String) -> WireResponse {
        WireResponse(id: id, ok: false, result: nil, errorCode: code, errorMessage: message)
    }

    /// Encode as JSON-serialisable dict. The framing layer
    /// converts to bytes via `JSONSerialization.data`.
    public func encode() -> [String: Any] {
        var out: [String: Any] = ["id": id, "ok": ok]
        if ok, let r = result {
            out["result"] = r
        } else if let code = errorCode {
            out["error"] = [
                "code": code.rawValue,
                "message": errorMessage ?? "",
            ]
        }
        return out
    }
}
