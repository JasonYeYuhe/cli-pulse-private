import Foundation
import Security

/// Result of authenticating an incoming XPC peer against our code-signing
/// requirement. `reject` carries a non-sensitive reason for the log.
public enum PeerAuthDecision: Equatable {
    case accept
    case reject(reason: String)

    public var isAccept: Bool { if case .accept = self { return true }; return false }
}

/// The single security gate of the root helper: authenticate that an incoming
/// XPC connection is the genuine CLI Pulse app / user-helper, and reject every
/// other local process. A root daemon reachable by ANY local process is a full
/// local-root escalation, so this must be correct and race-free.
///
/// **Why audit_token, not PID.** The obvious `LOCAL_PEERPID`/`SecCodeCopyGuest
/// WithAttributes(kSecGuestAttributePid:)` path is TOCTOU-vulnerable: a PID can
/// be reused between the check and the command. XPC exposes a per-message
/// `audit_token` (an opaque kernel token that pins the exact sending process);
/// building the `SecCode` from that token is the only race-free way to
/// authenticate a caller. The daemon retrieves the token and hands the raw
/// bytes here.
///
/// This type is split so the SECURITY DECISION is unit-testable: the impure
/// `SecCodeCheckValidity` call is injected, and the requirement string is a pure
/// function. The token→SecCode step lives in `secCode(fromAuditToken:)` (thin
/// wrapper over `SecCodeCopyGuestWithAttributes`).
public struct PeerAuthenticator {
    public let teamID: String
    public let allowedIdentifiers: [String]
    private let checkValidity: (SecCode, SecRequirement) -> OSStatus

    /// - Parameters:
    ///   - teamID: Apple Developer Team ID (the leaf cert `subject.OU`). For CLI
    ///     Pulse: `KHMK6Q3L3K`.
    ///   - allowedIdentifiers: bundle identifiers permitted to call the daemon —
    ///     the app and the unsandboxed user-helper. A caller must be BOTH
    ///     Apple-anchored + our Team-ID AND one of these identifiers.
    ///   - checkValidity: injected `SecCodeCheckValidity`-equivalent (tests pass a
    ///     stub; production uses the real Security API).
    public init(teamID: String,
                allowedIdentifiers: [String],
                checkValidity: @escaping (SecCode, SecRequirement) -> OSStatus = { code, req in
                    SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), req)
                }) {
        self.teamID = teamID
        self.allowedIdentifiers = allowedIdentifiers
        self.checkValidity = checkValidity
    }

    /// The designated-requirement string a caller must satisfy: signed by Apple,
    /// leaf cert OU == our Team ID, AND one of our bundle identifiers. Pure +
    /// unit-tested so the exact clause can't silently drift.
    public static func requirementString(teamID: String, identifiers: [String]) -> String {
        let idClause = identifiers.isEmpty
            ? "identifier \"\"" // empty set → un-satisfiable (fail closed)
            : identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (\(idClause))"
    }

    /// Build the compiled `SecRequirement`, or nil if the string doesn't compile.
    public func requirement() -> SecRequirement? {
        var req: SecRequirement?
        let s = Self.requirementString(teamID: teamID, identifiers: allowedIdentifiers)
        guard SecRequirementCreateWithString(s as CFString, SecCSFlags(rawValue: 0), &req) == errSecSuccess else {
            return nil
        }
        return req
    }

    /// The DECISION: given a peer's `SecCode` (built from its audit token),
    /// accept iff it satisfies our requirement. Fails closed on every error path
    /// (nil code, requirement build failure, non-success status).
    public func decide(peerCode: SecCode?) -> PeerAuthDecision {
        guard let peerCode else { return .reject(reason: "no SecCode for peer (audit-token lookup failed)") }
        guard allowedIdentifiers.contains(where: { !$0.isEmpty }) else {
            return .reject(reason: "no allowed identifiers configured (fail closed)")
        }
        guard let req = requirement() else { return .reject(reason: "requirement failed to compile") }
        let status = checkValidity(peerCode, req)
        if status == errSecSuccess { return .accept }
        return .reject(reason: "code-signature check failed (OSStatus \(status))")
    }

    /// Build a `SecCode` from a raw `audit_token_t` (as `Data`). Thin wrapper over
    /// `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit:)` — the race-free
    /// path. Returns nil if the token can't be resolved to a code object.
    public static func secCode(fromAuditToken tokenData: Data) -> SecCode? {
        let attrs: [CFString: Any] = [kSecGuestAttributeAudit: tokenData]
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary,
                                                    SecCSFlags(rawValue: 0), &code)
        return status == errSecSuccess ? code : nil
    }
}
