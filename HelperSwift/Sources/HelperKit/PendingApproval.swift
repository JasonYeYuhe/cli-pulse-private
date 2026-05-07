import Foundation

/// Wire-stable representation of one outstanding hook approval.
/// Mirrors the dict produced by `helper/local_approvals.py:
/// PendingApproval.to_dict_safe`. The macOS app's
/// `LocalSessionControlClient.PendingApproval` decodes against
/// these JSON keys; any drift breaks the existing client.
public struct PendingApproval: Equatable {

    public enum Status: String, Sendable, Equatable {
        case pending
        case approved
        case rejected
        case expired
        case cancelled
    }

    public let approvalId: String
    public let sessionId: String
    public let kind: String         // serialised as `type`
    public let title: String
    public let summary: String
    public let toolMetadata: [String: Any]
    public var status: Status
    public let createdAtWall: TimeInterval
    public let createdAtMono: TimeInterval
    public var expiresAtWall: TimeInterval?
    public var decidedDecision: String?
    public var decidedComment: String?
    public var decidedAtWall: TimeInterval?

    public init(
        approvalId: String,
        sessionId: String,
        kind: String,
        title: String,
        summary: String,
        toolMetadata: [String: Any],
        status: Status = .pending,
        createdAtWall: TimeInterval = Date().timeIntervalSince1970,
        createdAtMono: TimeInterval = ProcessInfo.processInfo.systemUptime,
        expiresAtWall: TimeInterval? = nil,
        decidedDecision: String? = nil,
        decidedComment: String? = nil,
        decidedAtWall: TimeInterval? = nil
    ) {
        self.approvalId = approvalId
        self.sessionId = sessionId
        self.kind = kind
        self.title = title
        self.summary = summary
        self.toolMetadata = toolMetadata
        self.status = status
        self.createdAtWall = createdAtWall
        self.createdAtMono = createdAtMono
        self.expiresAtWall = expiresAtWall
        self.decidedDecision = decidedDecision
        self.decidedComment = decidedComment
        self.decidedAtWall = decidedAtWall
    }

    /// Wire-format dict — what the macOS app sees. Excludes any
    /// internal fields (e.g. condition variables in the Python
    /// version). See `local_approvals.py:to_dict_safe` for the
    /// reference shape.
    public func toDictSafe() -> [String: Any] {
        var d: [String: Any] = [
            "approval_id": approvalId,
            "session_id": sessionId,
            "type": kind,
            "title": title,
            "summary": summary,
            "tool_metadata": toolMetadata,
            "status": status.rawValue,
            "created_at": createdAtWall,
        ]
        if let exp = expiresAtWall { d["expires_at"] = exp }
        if let dec = decidedDecision {
            d["decision"] = dec
            d["decided_at"] = decidedAtWall ?? 0.0
            if let c = decidedComment { d["comment"] = c }
        }
        return d
    }

    public static func == (lhs: PendingApproval, rhs: PendingApproval) -> Bool {
        // `toolMetadata` is `[String: Any]` so we compare the
        // serialisable subset only — covers tests that pin status
        // changes without caring about metadata identity.
        return lhs.approvalId == rhs.approvalId
            && lhs.sessionId == rhs.sessionId
            && lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.summary == rhs.summary
            && lhs.status == rhs.status
            && lhs.createdAtWall == rhs.createdAtWall
            && lhs.expiresAtWall == rhs.expiresAtWall
            && lhs.decidedDecision == rhs.decidedDecision
            && lhs.decidedComment == rhs.decidedComment
            && lhs.decidedAtWall == rhs.decidedAtWall
    }
}
