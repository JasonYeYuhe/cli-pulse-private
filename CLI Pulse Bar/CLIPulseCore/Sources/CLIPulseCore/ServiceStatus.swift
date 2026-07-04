// Provider service-status (incident/health) engine.
//
// Original CLI Pulse feature (NOT vendored): surfaces whether an AI provider
// is itself having an outage, so a user can tell a provider incident apart
// from their own rate limit / quota exhaustion. Most providers publish an
// Atlassian Statuspage v2 `status.json` document:
//
//   { "page":   { "name": "Claude", "url": "...", "updated_at": "2026-..Z" },
//     "status": { "indicator": "none", "description": "All Systems Operational" } }
//
// `indicator` ∈ none | minor | major | critical | maintenance. This file is
// the pure core (indicator model + tolerant parser + provider→endpoint
// catalog + a thin async fetcher); the UI consumer lands separately. Pure
// Foundation so it lives in CLIPulseCore (shared macOS + iOS + watchOS) and
// is fully unit-testable without a network.

import Foundation

// MARK: - Indicator

/// Severity of a provider's published service status, normalized from the
/// Atlassian Statuspage v2 `status.indicator` string.
public enum ServiceStatusIndicator: String, Codable, CaseIterable, Sendable {
    case operational   // statuspage "none"
    case maintenance   // statuspage "maintenance"
    case minor         // statuspage "minor"
    case major         // statuspage "major"
    case critical      // statuspage "critical"
    case unknown       // unrecognized / missing

    /// Normalize a raw Statuspage v2 `status.indicator` value.
    public init(statuspageIndicator raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none": self = .operational
        case "maintenance": self = .maintenance
        case "minor": self = .minor
        case "major": self = .major
        case "critical": self = .critical
        default: self = .unknown
        }
    }

    /// Normalize a raw Statuspage v2 *component* `status` value. Components use a
    /// wider vocabulary than the top-level `status.indicator`
    /// (`operational`/`degraded_performance`/`partial_outage`/`major_outage`/
    /// `under_maintenance`); collapse it onto the same severity ladder.
    public init(statuspageComponentStatus raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "operational": self = .operational
        case "degraded_performance": self = .minor
        case "partial_outage": self = .major
        case "major_outage", "full_outage": self = .critical
        case "under_maintenance": self = .maintenance
        default: self = .unknown
        }
    }

    /// Higher = worse. `unknown` sorts below `operational` so it never wins a
    /// "most severe across providers" reduction. Used for ordering/aggregation.
    public var severity: Int {
        switch self {
        case .unknown: return -1
        case .operational: return 0
        case .maintenance: return 1
        case .minor: return 2
        case .major: return 3
        case .critical: return 4
        }
    }

    /// All systems normal.
    public var isOperational: Bool { self == .operational }

    /// A real degradation worth surfacing a badge for (minor/major/critical).
    /// `maintenance` and `unknown` are intentionally excluded — neither is an
    /// unexpected outage.
    public var isIncident: Bool { severity >= ServiceStatusIndicator.minor.severity }

    /// Whether the UI should surface a status badge at all: a real incident OR
    /// planned maintenance. `operational` and `unknown` stay silent — no badge
    /// clutter when all is well or when there is nothing meaningful to report.
    public var shouldSurface: Bool {
        switch self {
        case .maintenance, .minor, .major, .critical: return true
        case .operational, .unknown: return false
        }
    }
}

// MARK: - Snapshot

/// A point-in-time read of one provider's published service status.
public struct ServiceStatusSnapshot: Equatable, Sendable {
    public let provider: ProviderKind
    public let indicator: ServiceStatusIndicator
    /// Human description from the status page, e.g. "All Systems Operational".
    public let description: String
    /// `page.updated_at` from the status document, if present/parseable.
    public let updatedAt: Date?
    /// `page.url` (the human status page), if present/parseable.
    public let pageURL: URL?

    public init(
        provider: ProviderKind,
        indicator: ServiceStatusIndicator,
        description: String,
        updatedAt: Date?,
        pageURL: URL?
    ) {
        self.provider = provider
        self.indicator = indicator
        self.description = description
        self.updatedAt = updatedAt
        self.pageURL = pageURL
    }
}

// MARK: - Component

/// One row in a provider's status page — a service component (e.g. "claude.ai",
/// "Claude API") or a component GROUP (with children). Mirrors the Statuspage v2
/// `components` array. `statusRaw` is the raw Statuspage status (kept so the UI
/// can localize the exact wording, e.g. "Degraded Performance"); `indicator` is
/// the normalized severity used for the colored dot. For a group, both reflect
/// the WORST child (Statuspage doesn't always propagate child degradation to the
/// group's own status).
public struct ServiceStatusComponent: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let indicator: ServiceStatusIndicator
    public let statusRaw: String
    public let children: [ServiceStatusComponent]

    public init(
        id: String,
        name: String,
        indicator: ServiceStatusIndicator,
        statusRaw: String,
        children: [ServiceStatusComponent] = []
    ) {
        self.id = id
        self.name = name
        self.indicator = indicator
        self.statusRaw = statusRaw
        self.children = children
    }

    public var isGroup: Bool { !children.isEmpty }
}

// MARK: - Parser

public enum ServiceStatusParser {
    /// Tolerantly parse an Atlassian Statuspage v2 `status.json` body for
    /// `provider`. Returns nil only when the body isn't a JSON object with a
    /// `status.indicator` string; a missing description/updated_at/url degrades
    /// to ""/nil rather than failing the whole parse.
    public static func parseStatuspageStatus(
        _ data: Data,
        provider: ProviderKind
    ) -> ServiceStatusSnapshot? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status = root["status"] as? [String: Any],
            let indicatorRaw = status["indicator"] as? String
        else { return nil }

        let page = root["page"] as? [String: Any]
        return ServiceStatusSnapshot(
            provider: provider,
            indicator: ServiceStatusIndicator(statuspageIndicator: indicatorRaw),
            description: (status["description"] as? String) ?? "",
            updatedAt: (page?["updated_at"] as? String).flatMap(sharedISO8601Parse),
            pageURL: (page?["url"] as? String).flatMap { URL(string: $0) }
        )
    }

    /// Parse the `components` array of a Statuspage v2 `summary.json` (or
    /// `components.json`) body into a nested top-level→children tree, in
    /// Statuspage `position` order. Component GROUPs (`group: true` / referenced
    /// by a child's `group_id`) carry their children and take the WORST child's
    /// severity + status wording. Tolerant: a body with no `components` array, or
    /// entries missing id/name/status, yields [] / skips the entry rather than
    /// throwing.
    public static func parseStatuspageComponents(_ data: Data) -> [ServiceStatusComponent] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawComponents = root["components"] as? [[String: Any]]
        else { return [] }

        struct RawComponent {
            let id: String
            let name: String
            let status: String
            let groupID: String?
            let position: Int
        }
        let raws: [RawComponent] = rawComponents.compactMap { c in
            guard
                let id = c["id"] as? String,
                let name = c["name"] as? String,
                let status = c["status"] as? String
            else { return nil }
            return RawComponent(
                id: id, name: name, status: status,
                groupID: c["group_id"] as? String,
                position: (c["position"] as? Int) ?? 0
            )
        }

        let childrenByGroup = Dictionary(grouping: raws.filter { $0.groupID != nil }) { $0.groupID! }
        let topLevel = raws.filter { $0.groupID == nil }.sorted { $0.position < $1.position }

        return topLevel.map { parent -> ServiceStatusComponent in
            let kids = (childrenByGroup[parent.id] ?? [])
                .sorted { $0.position < $1.position }
                .map { child in
                    ServiceStatusComponent(
                        id: child.id, name: child.name,
                        indicator: ServiceStatusIndicator(statuspageComponentStatus: child.status),
                        statusRaw: child.status
                    )
                }
            // A group takes the worst child's severity + wording; a leaf takes its
            // own. (Statuspage's own group `status` can lag a degraded child.)
            let worstChild = kids.max { $0.indicator.severity < $1.indicator.severity }
            let indicator = worstChild?.indicator ?? ServiceStatusIndicator(statuspageComponentStatus: parent.status)
            let statusRaw = worstChild?.statusRaw ?? parent.status
            return ServiceStatusComponent(
                id: parent.id, name: parent.name,
                indicator: indicator, statusRaw: statusRaw, children: kids
            )
        }
    }
}

// MARK: - Catalog

/// Maps providers to their public Atlassian Statuspage. Deliberately a
/// non-exhaustive switch (`default: nil`) so adding a new `ProviderKind` case
/// never forces a change here — providers without a known status page simply
/// surface no badge.
public enum ServiceStatusCatalog {
    /// The status-page host for `provider`, or nil if none is known/standard.
    public static func statusPageHost(for provider: ProviderKind) -> String? {
        switch provider {
        case .claude: return "status.claude.com"
        case .codex, .openaiAdmin: return "status.openai.com"
        case .cursor: return "status.cursor.com"
        case .copilot: return "www.githubstatus.com"
        // Live-verified 2026-06-28: each host returns a valid Atlassian
        // Statuspage v2 `/api/v2/status.json` (status.indicator + description +
        // page.updated_at), so the existing parser handles them unchanged.
        case .elevenLabs: return "status.elevenlabs.io"
        case .groq: return "groqstatus.com"
        case .warp: return "status.warp.dev"
        case .moonshot: return "status.moonshot.cn"
        case .deepgram: return "status.deepgram.com"
        case .windsurf: return "status.codeium.com"
        case .augment: return "status.augmentcode.com"
        default: return nil
        }
    }

    /// The human-facing status page URL for `provider`, if known.
    public static func statusPageURL(for provider: ProviderKind) -> URL? {
        statusPageHost(for: provider).flatMap { URL(string: "https://\($0)") }
    }

    /// The machine-readable Statuspage v2 `status.json` endpoint, if known.
    public static func statusEndpoint(for provider: ProviderKind) -> URL? {
        statusPageHost(for: provider).flatMap {
            URL(string: "https://\($0)/api/v2/status.json")
        }
    }

    /// The Statuspage v2 `summary.json` endpoint (overall status + the full
    /// `components` list in one GET), if known.
    public static func summaryEndpoint(for provider: ProviderKind) -> URL? {
        statusPageHost(for: provider).flatMap {
            URL(string: "https://\($0)/api/v2/summary.json")
        }
    }

    /// Whether `provider` has a known service-status source.
    public static func hasStatusPage(for provider: ProviderKind) -> Bool {
        statusPageHost(for: provider) != nil
    }

    /// Providers with a known status page, in display order.
    public static let supportedProviders: [ProviderKind] =
        [.claude, .codex, .cursor, .copilot, .openaiAdmin,
         .elevenLabs, .groq, .warp, .moonshot, .deepgram, .windsurf, .augment]
}

// MARK: - Fetcher

/// Thin async fetcher: GET the provider's `status.json` and parse it. Returns
/// nil on no-known-page, network/HTTP failure, or unparseable body — callers
/// treat nil as "no status to show" (graceful, no UI change). The parsing core
/// is unit-tested; this network wrapper is intentionally minimal.
public struct ServiceStatusFetcher: Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
    }

    public func fetch(_ provider: ProviderKind) async -> ServiceStatusSnapshot? {
        guard let url = ServiceStatusCatalog.statusEndpoint(for: provider) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else { return nil }
        return ServiceStatusParser.parseStatuspageStatus(data, provider: provider)
    }

    /// GET the provider's `summary.json` and return its component list (in
    /// Statuspage order, groups nested).
    ///
    /// Returns `nil` on FAILURE (no-known-page, network/HTTP error, task
    /// cancellation) so the caller can distinguish a retryable failure from an
    /// empty page and NOT latch a permanent "no data". Returns `[]` only for a
    /// genuine 200 body with no `components`. (A cancelled request surfaces as
    /// `URLError(.cancelled)`, swallowed by `try?` → `nil` here; the SwiftUI
    /// caller additionally re-checks `Task.isCancelled` before committing state.)
    public func fetchComponents(_ provider: ProviderKind) async -> [ServiceStatusComponent]? {
        guard let url = ServiceStatusCatalog.summaryEndpoint(for: provider) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else { return nil }
        return ServiceStatusParser.parseStatuspageComponents(data)
    }
}
