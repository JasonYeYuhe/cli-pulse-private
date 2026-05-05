import Foundation

/// Phase 3 Iter 1 — Local Transport Foundation.
///
/// The macOS Sessions UI used to drive a single Supabase-backed surface
/// for every managed-session action (start / list / stop / send input).
/// That worked, but every keystroke against a session running on the
/// SAME Mac as the app paid a 1-3 s round-trip through Supabase. Phase 3
/// adds a same-machine Unix domain socket fast path. iOS / iPad / Watch
/// and cross-device Mac control keep using the existing remote path.
///
/// `SessionControlClient` is the small protocol that lets the Sessions
/// UI talk to either transport without branching on `if isSelfDevice`
/// in three places. Two conformers ship in iter 1:
///
///   * `RemoteSessionControlClient` — wraps the existing APIClient
///     session-control methods (`remoteListSessions`,
///     `remoteRequestSessionStart`, `remoteSendCommand`). Rename + thin
///     adapter only — no behaviour change.
///   * `LocalSessionControlClient` (macOS only) — talks to the helper
///     UDS server inside the app group container. Implements
///     `start_session`, `list_sessions`, `stop_session`. `sendInput`
///     is intentionally NOT in iter 1; the protocol exposes
///     `capabilities.sendInput` so the UI can disable the input field
///     when local is selected.
///
/// iter 2A will add `sendInput` and a streaming `subscribeEvents`
/// surface; iter 2B will add `approvals`. The `capabilities` payload
/// returned by `hello` is how the UI decides what to enable per
/// transport, NOT a hard-coded version check — a future helper that
/// gains `sendInput` support will surface it through `capabilities`
/// without an app update.
public protocol SessionControlClient: Sendable {
    /// Probe the transport. Returns the negotiated protocol version,
    /// the methods the server supports, and the capability flags the
    /// UI uses to decide what to render.
    ///
    /// For the local transport this is also the "is the helper
    /// running?" check — `helperNotRunning` falls out as a typed
    /// error if the socket isn't there.
    func hello() async throws -> SessionControlHello

    /// Spawn a new managed Claude session. iter 1 only supports
    /// `provider == "claude"`; codex / shell / etc. are out of scope.
    func startClaudeSession(
        clientLabel: String?,
        cwdBasename: String?,
        cwdHmac: String?
    ) async throws -> SessionControlStartResult

    /// List the sessions visible through this transport.
    /// Local lists in-memory helper state; remote lists Supabase rows.
    func listSessions() async throws -> [SessionControlSummary]

    /// Stop a managed session by id.
    func stopSession(sessionId: String) async throws
}

/// Reply payload for `hello`.
public struct SessionControlHello: Sendable, Equatable {
    public let protocolVersion: Int
    public let supportedMethods: Set<String>
    public let capabilities: SessionControlCapabilities

    public init(
        protocolVersion: Int,
        supportedMethods: Set<String>,
        capabilities: SessionControlCapabilities
    ) {
        self.protocolVersion = protocolVersion
        self.supportedMethods = supportedMethods
        self.capabilities = capabilities
    }
}

/// Capability flags the UI consults BEFORE rendering a feature.
/// iter 1 hard-codes everything except `startStopList` to false on
/// the local client; the remote client mirrors today's Supabase
/// surface (the existing input + approvals UX continues to work).
public struct SessionControlCapabilities: Sendable, Equatable {
    public let sendInput: Bool
    public let subscribeEvents: Bool
    public let approvals: Bool

    public init(sendInput: Bool, subscribeEvents: Bool, approvals: Bool) {
        self.sendInput = sendInput
        self.subscribeEvents = subscribeEvents
        self.approvals = approvals
    }

    /// What the iter-1 LocalSessionControlClient advertises after a
    /// successful hello — start/list/stop only.
    public static let iter1Local = SessionControlCapabilities(
        sendInput: false,
        subscribeEvents: false,
        approvals: false
    )

    /// What the RemoteSessionControlClient advertises today — the
    /// Supabase path supports the full surface that shipped in
    /// PR #10 + PR #11.
    public static let supabaseFull = SessionControlCapabilities(
        sendInput: true,
        subscribeEvents: true,
        approvals: true
    )
}

/// Result of a successful `startClaudeSession`. The remote transport
/// also returns a server-issued command id (so the UI can poll
/// completion); the local transport leaves it nil because the helper
/// dispatches the spawn synchronously through the executor and the
/// UDS reply already implies success.
public struct SessionControlStartResult: Sendable, Equatable {
    public let sessionId: String
    public let commandId: String?

    public init(sessionId: String, commandId: String? = nil) {
        self.sessionId = sessionId
        self.commandId = commandId
    }
}

/// Minimal session row returned by `listSessions`. Both transports
/// converge on the same shape; the macOS UI never has to know which
/// transport produced it.
public struct SessionControlSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let provider: String
    public let clientLabel: String?
    public let status: String

    public init(id: String, provider: String, clientLabel: String?, status: String) {
        self.id = id
        self.provider = provider
        self.clientLabel = clientLabel
        self.status = status
    }
}

/// Typed error surface for the SessionControlClient protocol.
///
/// Local transport maps the wire-level `error.code` strings from
/// `helper/local_session_server.py` to these cases; remote transport
/// maps APIClient HTTPError + transport failures. Equality and
/// Sendable conformance let XCTest assert on specific cases.
public enum SessionControlError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The helper UDS socket is missing or refusing connections.
    /// Only the local transport surfaces this; the remote transport
    /// would never report it (Supabase is always reachable when the
    /// device has internet).
    case helperNotRunning

    /// Bad / missing / mismatched auth_token (local) or 401 (remote).
    case unauthenticated

    /// Local hello negotiated an unsupported protocol version.
    case versionMismatch

    /// The method exists on the wire surface but isn't implemented
    /// in this iteration (e.g. local sendInput in iter 1).
    case notImplemented

    /// `local_control_enabled` is false on the helper; the user must
    /// flip the toggle in the macOS app's Settings → Privacy surface.
    case localControlOff

    /// The transport did not reply within the configured deadline.
    case timeout

    /// The connection dropped mid-call.
    case disconnected

    /// The reply envelope was syntactically invalid (bad JSON,
    /// missing required field). Detail string is for logs / debug;
    /// the UI should show a generic "couldn't reach helper" message.
    case invalidResponse(String)

    /// Server-side exception during dispatch. Detail string is the
    /// short form (no stack trace, no PII).
    case internalError(String)

    public var description: String {
        switch self {
        case .helperNotRunning:    return "helper not running"
        case .unauthenticated:     return "unauthenticated"
        case .versionMismatch:     return "version mismatch"
        case .notImplemented:      return "not implemented"
        case .localControlOff:     return "local control disabled"
        case .timeout:             return "timeout"
        case .disconnected:        return "disconnected"
        case .invalidResponse(let m): return "invalid response: \(m)"
        case .internalError(let m):   return "internal error: \(m)"
        }
    }
}

/// Stable mapping from helper UDS wire-level `error.code` strings to
/// `SessionControlError` cases. Public so the LocalSessionControlClient
/// AND XCTest can share one source of truth.
public enum SessionControlErrorMapping {
    public static func error(forWireCode code: String, message: String) -> SessionControlError {
        switch code {
        case "unauthenticated":   return .unauthenticated
        case "version_mismatch":  return .versionMismatch
        case "not_implemented":   return .notImplemented
        case "local_control_off": return .localControlOff
        case "internal":          return .internalError(message)
        case "bad_request":       return .invalidResponse(message)
        case "unknown_method":    return .notImplemented
        case "frame_too_large":   return .invalidResponse(message)
        case "frame_truncated":   return .disconnected
        default:                  return .internalError("\(code): \(message)")
        }
    }
}
