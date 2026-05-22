// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Deepgram/{DeepgramUsageFetcher,
// DeepgramSettingsReader}.swift (https://github.com/steipete/CodexBar).
// The projects→usage/breakdown walk, the Codable response models, and
// the cross-project aggregation are ported; the fetch path is
// reimplemented on URLSession with the concurrency/latency safeguards
// below.
//
// CodexBar-parity Phase C-7 — add the (absent) Deepgram provider as a
// `.statusOnly` collector. Deepgram exposes NO quota/credits
// denominator — only absolute usage counts (requests / audio hours /
// tokens / TTS chars) — so there is no gauge; the counts render via
// status_text.
//
// Divergences from upstream (sandbox + shared-refresh safety; the
// owner chose full auto-discovery, so Gemini C-7 R1's required
// safeguards are applied):
//   * `URLSession` instead of CodexBar's `ProviderHTTPClient`; no
//     CodexBarLog.
//   * Gemini C-7 R1 CRITICAL: all collectors run in ONE shared
//     `DataRefreshManager.runCollectors` TaskGroup, so the N+1
//     projects→usage walk MUST NOT serialize-block it. Per-project
//     usage requests run CONCURRENTLY (internal `withThrowingTaskGroup`),
//     the project fan-out is CAPPED (maxProjects), and the WHOLE fetch
//     is wrapped in a strict absolute timeout so a slow account can
//     never stall the global refresh.
//   * `DEEPGRAM_PROJECT_ID` pins a single project ⇒ one fast call (no
//     list walk).
//   * Time-bounds: CodexBar's default sends none and works; we match
//     (boundless = current-period breakdown).
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

#if os(macOS)
import Foundation

/// Reports Deepgram usage counts via api-key auth (status-only — no
/// quota denominator).
///
/// Auth: `Authorization: Token <key>` (`config.apiKey` or
/// `DEEPGRAM_API_KEY`). Pinned `DEEPGRAM_PROJECT_ID` ⇒ one usage call;
/// otherwise `GET /v1/projects` then a capped, concurrent per-project
/// `GET /v1/projects/{id}/usage/breakdown`, aggregated. The whole fetch
/// is bounded by an absolute timeout to protect the shared refresh loop.
public struct DeepgramCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.deepgram

    static let baseURL = "https://api.deepgram.com/v1"
    static let apiKeyEnv = "DEEPGRAM_API_KEY"
    static let projectIDEnv = "DEEPGRAM_PROJECT_ID"
    static let maxProjects = 5
    static let perRequestTimeout: TimeInterval = 12
    static let absoluteTimeoutSeconds: Double = 12

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = resolveToken(config: config) else {
            throw CollectorError.missingCredentials("Deepgram: no API key (set DEEPGRAM_API_KEY)")
        }
        let pinnedProject = Self.resolveProjectID()

        // Gemini C-7 R1 CRITICAL: bound the entire network walk by a
        // strict absolute timeout so the shared collector TaskGroup is
        // never stalled by a slow/large account.
        return try await Self.withAbsoluteTimeout(Self.absoluteTimeoutSeconds) {
            if let pinnedProject {
                let agg = try await Self.fetchProjectUsage(projectID: pinnedProject, token: token)
                return Self.buildResult(aggregate: agg, projectName: nil, projectCount: 1)
            }

            let projects = try await Self.fetchProjects(token: token)
            guard !projects.isEmpty else {
                throw CollectorError.parseFailed("Deepgram: no projects for this API key")
            }
            let capped = Array(projects.prefix(Self.maxProjects))

            // Concurrent per-project usage fetch (NOT serialized).
            let aggregates = try await withThrowingTaskGroup(of: UsageAggregate.self) { group in
                for project in capped {
                    group.addTask {
                        try await Self.fetchProjectUsage(projectID: project.projectID, token: token)
                    }
                }
                var acc: [UsageAggregate] = []
                for try await a in group { acc.append(a) }
                return acc
            }

            let combined = Self.combine(aggregates)
            let name = capped.count == 1 ? capped.first?.name : nil
            return Self.buildResult(aggregate: combined, projectName: name, projectCount: capped.count)
        }
    }

    // MARK: - Credentials

    private func resolveToken(config: ProviderConfig) -> String? {
        if let k = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        if let k = ProcessInfo.processInfo.environment[Self.apiKeyEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        return nil
    }

    static func resolveProjectID() -> String? {
        guard let v = ProcessInfo.processInfo.environment[projectIDEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return nil
        }
        return v
    }

    // MARK: - Absolute-timeout wrapper (Gemini C-7 R1 CRITICAL)

    /// Run `op` but throw if it exceeds `seconds` — protects the shared
    /// refresh TaskGroup from a slow N+1 walk. A real error from `op`
    /// (e.g. 401) propagates as-is; only the timeout path synthesizes
    /// `httpError(status: 0)` (the codebase's network-failure convention).
    static func withAbsoluteTimeout<T: Sendable>(
        _ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw CollectorError.httpError(status: 0, provider: "Deepgram (timeout)")
            }
            guard let first = try await group.next() else {
                throw CollectorError.httpError(status: 0, provider: "Deepgram")
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Models

    struct Project: Sendable, Equatable {
        let projectID: String
        let name: String?
    }

    struct UsageAggregate: Sendable, Equatable {
        var requests = 0
        var hours = 0.0
        var totalHours = 0.0
        var agentHours = 0.0
        var tokensIn = 0
        var tokensOut = 0
        var ttsCharacters = 0
    }

    private struct ProjectsResponse: Decodable {
        let projects: [ProjectDTO]
        struct ProjectDTO: Decodable {
            let projectID: String
            let name: String?
            enum CodingKeys: String, CodingKey {
                case projectID = "project_id"
                case name
            }
        }
    }

    private struct UsageResponse: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let hours: Double?
            let totalHours: Double?
            let agentHours: Double?
            let tokensIn: Int?
            let tokensOut: Int?
            let ttsCharacters: Int?
            let requests: Int?
            enum CodingKeys: String, CodingKey {
                case hours
                case totalHours = "total_hours"
                case agentHours = "agent_hours"
                case tokensIn = "tokens_in"
                case tokensOut = "tokens_out"
                case ttsCharacters = "tts_characters"
                case requests
            }
        }
    }

    // MARK: - Parsing (testable statics)

    static func parseProjects(_ data: Data) throws -> [Project] {
        do {
            return try JSONDecoder().decode(ProjectsResponse.self, from: data).projects
                .map { Project(projectID: $0.projectID, name: $0.name) }
        } catch {
            throw CollectorError.parseFailed("Deepgram: projects — \(error.localizedDescription)")
        }
    }

    static func parseUsageAggregate(_ data: Data) throws -> UsageAggregate {
        do {
            let r = try JSONDecoder().decode(UsageResponse.self, from: data)
            return UsageAggregate(
                requests: r.results.reduce(0) { $0 + ($1.requests ?? 0) },
                hours: r.results.reduce(0) { $0 + ($1.hours ?? 0) },
                totalHours: r.results.reduce(0) { $0 + ($1.totalHours ?? 0) },
                agentHours: r.results.reduce(0) { $0 + ($1.agentHours ?? 0) },
                tokensIn: r.results.reduce(0) { $0 + ($1.tokensIn ?? 0) },
                tokensOut: r.results.reduce(0) { $0 + ($1.tokensOut ?? 0) },
                ttsCharacters: r.results.reduce(0) { $0 + ($1.ttsCharacters ?? 0) })
        } catch {
            throw CollectorError.parseFailed("Deepgram: usage — \(error.localizedDescription)")
        }
    }

    static func combine(_ parts: [UsageAggregate]) -> UsageAggregate {
        parts.reduce(into: UsageAggregate()) { acc, p in
            acc.requests += p.requests
            acc.hours += p.hours
            acc.totalHours += p.totalHours
            acc.agentHours += p.agentHours
            acc.tokensIn += p.tokensIn
            acc.tokensOut += p.tokensOut
            acc.ttsCharacters += p.ttsCharacters
        }
    }

    // MARK: - Networking

    private static func fetchProjects(token: String) async throws -> [Project] {
        guard let url = URL(string: "\(baseURL)/projects") else {
            throw CollectorError.invalidURL("deepgram projects")
        }
        let data = try await get(url: url, token: token)
        return try parseProjects(data)
    }

    static func fetchProjectUsage(projectID: String, token: String) async throws -> UsageAggregate {
        let path = "\(baseURL)/projects/\(projectID)/usage/breakdown"
        guard let url = URL(string: path) else {
            throw CollectorError.invalidURL("deepgram usage breakdown")
        }
        let data = try await get(url: url, token: token)
        return try parseUsageAggregate(data)
    }

    private static func get(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = perRequestTimeout
        // Deepgram uses the custom "Token" auth scheme (NOT Bearer).
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CollectorError.httpError(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Deepgram")
        }
        return data
    }

    // MARK: - Result building (.statusOnly — no gauge)

    static func formatStatusText(_ a: UsageAggregate) -> String {
        var parts: [String] = ["\(compactInt(a.requests)) requests"]
        if a.hours > 0 { parts.append("\(compactDecimal(a.hours)) audio hrs") }
        else if a.totalHours > 0 { parts.append("\(compactDecimal(a.totalHours)) billable hrs") }
        let totalTokens = a.tokensIn + a.tokensOut
        if totalTokens > 0 { parts.append("\(compactInt(totalTokens)) tokens") }
        else if a.ttsCharacters > 0 { parts.append("\(compactInt(a.ttsCharacters)) TTS chars") }
        return parts.joined(separator: " · ")
    }

    static func buildResult(
        aggregate: UsageAggregate, projectName: String?, projectCount: Int) -> CollectorResult
    {
        let planType: String
        if projectCount > 1 {
            planType = "\(projectCount) projects"
        } else if let name = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            planType = name
        } else {
            planType = "API key"
        }
        let usage = ProviderUsage(
            provider: ProviderKind.deepgram.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: nil,
            plan_type: planType,
            reset_time: nil,
            tiers: [],
            status_text: formatStatusText(aggregate),
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Deepgram", category: "cloud",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .statusOnly)
    }

    static func compactInt(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func compactDecimal(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = value == value.rounded() ? 0 : 1
        f.maximumFractionDigits = 1
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}
#endif
