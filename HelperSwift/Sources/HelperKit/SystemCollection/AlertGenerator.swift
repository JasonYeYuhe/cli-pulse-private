import Foundation

/// One alert row uploaded to Supabase `ingest_alerts`. Mirrors
/// `helper/system_collector.py::CollectedAlert`. Snake_case wire shape
/// matches the Supabase table schema and what the macOS app's Alerts
/// tab reads.
public struct CollectedAlert: Codable, Sendable, Equatable {
    public let alertId: String
    public let type: String
    public let severity: String          // "Warning", "Info", "Critical"
    public let title: String
    public let message: String
    public let createdAt: String         // ISO-8601 UTC
    public let relatedProjectId: String?
    public let relatedProjectName: String?
    public let relatedSessionId: String?
    public let relatedSessionName: String?
    public let relatedProvider: String?
    public let relatedDeviceName: String?

    private enum CodingKeys: String, CodingKey {
        case alertId = "alert_id"
        case type
        case severity
        case title
        case message
        case createdAt = "created_at"
        case relatedProjectId = "related_project_id"
        case relatedProjectName = "related_project_name"
        case relatedSessionId = "related_session_id"
        case relatedSessionName = "related_session_name"
        case relatedProvider = "related_provider"
        case relatedDeviceName = "related_device_name"
    }

    public init(
        alertId: String,
        type: String,
        severity: String,
        title: String,
        message: String,
        createdAt: String,
        relatedProjectId: String? = nil,
        relatedProjectName: String? = nil,
        relatedSessionId: String? = nil,
        relatedSessionName: String? = nil,
        relatedProvider: String? = nil,
        relatedDeviceName: String? = nil
    ) {
        self.alertId = alertId
        self.type = type
        self.severity = severity
        self.title = title
        self.message = message
        self.createdAt = createdAt
        self.relatedProjectId = relatedProjectId
        self.relatedProjectName = relatedProjectName
        self.relatedSessionId = relatedSessionId
        self.relatedSessionName = relatedSessionName
        self.relatedProvider = relatedProvider
        self.relatedDeviceName = relatedDeviceName
    }
}

/// Generates `CollectedAlert` rows from session + device data.
/// Mirrors `helper/system_collector.py::collect_alerts` 1:1:
///
///   - Device CPU spike: `device.cpu_usage >= 85` → "Usage Spike" warn
///   - Per-session CPU spike: `session.cpu_usage >= 80` → "Usage Spike" warn
///   - Per-session too-long: `session.requests >= 400` → "Session Too Long" info
///   - Cap at 6 alerts total
///
/// Thresholds are pinned in unit tests so future tweaks can't silently
/// reintroduce alert flapping (per `feedback_gemini_review_patterns.md`
/// item #3 — pin threshold values, not just behaviour).
public struct AlertGenerator: Sendable {

    public static let deviceCpuSpikeThreshold: Int = 85
    public static let sessionCpuSpikeThreshold: Double = 80.0
    public static let sessionTooLongRequestsThreshold: Int = 400
    public static let maxAlertsPerCollection: Int = 6

    public init() {}

    /// `now` is parameterized so tests can pin a fixed timestamp.
    public func generate(
        sessions: [CollectedSession],
        device: DeviceSnapshot,
        now: Date = Date()
    ) -> [CollectedAlert] {
        var alerts: [CollectedAlert] = []
        let formatter = SessionDetector.makeISOFormatter()
        let nowISO = formatter.string(from: now)
        let nowEpochInt = Int(now.timeIntervalSince1970)

        // Device-level CPU spike. NOTE: alert_id mirrors Python's
        // `cpu-spike-{int(now.timestamp())}` — INTENTIONAL parity with
        // helper/system_collector.py:323. A sustained spike across
        // multiple collection cycles will produce multiple alert
        // rows (one per cycle, distinct timestamp). Server-side
        // dedup in the Supabase Alerts panel handles this. If we
        // want true single-row-per-spike semantics in the future,
        // both Python and Swift need to switch to a stable id like
        // "device-cpu-spike" — that's a cross-platform schema change,
        // tracked separately. (Phase 4E Slice 2b Gemini P1 noted +
        // accepted as parity-with-Python.)
        if device.cpuUsage >= Self.deviceCpuSpikeThreshold {
            alerts.append(CollectedAlert(
                alertId: "cpu-spike-\(nowEpochInt)",
                type: "Usage Spike",
                severity: "Warning",
                title: "Device CPU usage is elevated",
                message: "helper sampled CPU usage at \(device.cpuUsage)%.",
                createdAt: nowISO
            ))
        }

        // Per-session alerts.
        for session in sessions {
            if let cpu = session.cpuUsage, cpu >= Self.sessionCpuSpikeThreshold {
                alerts.append(makeSessionAlert(
                    session: session,
                    nowISO: nowISO,
                    suffix: "session-spike",
                    type: "Usage Spike",
                    severity: "Warning",
                    title: "\(session.name ?? "(session)") is consuming high CPU",
                    message: String(format: "Process CPU is %.1f%% for %@.", cpu, session.provider as NSString)
                ))
            }
            if let requests = session.requests, requests >= Self.sessionTooLongRequestsThreshold {
                alerts.append(makeSessionAlert(
                    session: session,
                    nowISO: nowISO,
                    suffix: "session-long",
                    type: "Session Too Long",
                    severity: "Info",
                    title: "\(session.name ?? "(session)") has been running for a long time",
                    message: "Long-running local agent session detected by helper."
                ))
            }
        }

        return Array(alerts.prefix(Self.maxAlertsPerCollection))
    }

    private func makeSessionAlert(
        session: CollectedSession,
        nowISO: String,
        suffix: String,
        type: String,
        severity: String,
        title: String,
        message: String
    ) -> CollectedAlert {
        return CollectedAlert(
            alertId: "\(suffix)-\(session.sessionId)",
            type: type,
            severity: severity,
            title: title,
            message: message,
            createdAt: nowISO,
            relatedProjectId: session.project.map { Self.projectId($0) },
            relatedProjectName: session.project,
            relatedSessionId: session.sessionId,
            relatedSessionName: session.name,
            relatedProvider: session.provider
        )
    }

    /// Mirrors Python `_project_id`: lowercase + non-alphanumerics
    /// to dashes, strip leading/trailing dashes. Empty result falls
    /// back to "local-workspace".
    static func projectId(_ value: String) -> String {
        let lowered = value.lowercased()
        var out = ""
        var lastWasDash = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else {
                if !lastWasDash {
                    out.append("-")
                    lastWasDash = true
                }
            }
        }
        // Strip trailing dash.
        if out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "local-workspace" : out
    }
}
