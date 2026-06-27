import XCTest
@testable import CLIPulseCore

/// Pins the provider service-status engine: indicator normalization, severity/
/// incident logic, the tolerant Statuspage v2 parser (real Claude + OpenAI
/// fixtures, incl. both fractional and non-fractional `updated_at`), and the
/// provider→endpoint catalog. Pure — no network.
final class ServiceStatusTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Indicator normalization

    func testIndicatorFromStatuspageRaw() {
        XCTAssertEqual(ServiceStatusIndicator(statuspageIndicator: "none"), .operational)
        XCTAssertEqual(ServiceStatusIndicator(statuspageIndicator: "minor"), .minor)
        XCTAssertEqual(ServiceStatusIndicator(statuspageIndicator: "major"), .major)
        XCTAssertEqual(ServiceStatusIndicator(statuspageIndicator: "critical"), .critical)
        XCTAssertEqual(ServiceStatusIndicator(statuspageIndicator: "maintenance"), .maintenance)
        // case-insensitive + whitespace tolerant
        XCTAssertEqual(ServiceStatusIndicator(statuspageIndicator: "  NONE "), .operational)
        XCTAssertEqual(ServiceStatusIndicator(statuspageIndicator: "Major"), .major)
        // unrecognized
        XCTAssertEqual(ServiceStatusIndicator(statuspageIndicator: "weird"), .unknown)
        XCTAssertEqual(ServiceStatusIndicator(statuspageIndicator: ""), .unknown)
    }

    // MARK: - Severity / incident classification

    func testSeverityOrdering() {
        XCTAssertGreaterThan(ServiceStatusIndicator.critical.severity, ServiceStatusIndicator.major.severity)
        XCTAssertGreaterThan(ServiceStatusIndicator.major.severity, ServiceStatusIndicator.minor.severity)
        XCTAssertGreaterThan(ServiceStatusIndicator.minor.severity, ServiceStatusIndicator.maintenance.severity)
        XCTAssertGreaterThan(ServiceStatusIndicator.maintenance.severity, ServiceStatusIndicator.operational.severity)
        // unknown never wins a "most severe" reduction
        XCTAssertLessThan(ServiceStatusIndicator.unknown.severity, ServiceStatusIndicator.operational.severity)
    }

    func testOperationalAndIncidentFlags() {
        XCTAssertTrue(ServiceStatusIndicator.operational.isOperational)
        XCTAssertFalse(ServiceStatusIndicator.operational.isIncident)

        for incident in [ServiceStatusIndicator.minor, .major, .critical] {
            XCTAssertTrue(incident.isIncident, "\(incident) should be an incident")
            XCTAssertFalse(incident.isOperational)
        }
        // maintenance + unknown are neither operational nor incidents
        for neutral in [ServiceStatusIndicator.maintenance, .unknown] {
            XCTAssertFalse(neutral.isOperational, "\(neutral) is not operational")
            XCTAssertFalse(neutral.isIncident, "\(neutral) is not an incident")
        }
    }

    func testShouldSurface() {
        // silent when all is well or unknowable
        XCTAssertFalse(ServiceStatusIndicator.operational.shouldSurface)
        XCTAssertFalse(ServiceStatusIndicator.unknown.shouldSurface)
        // surfaced for maintenance + every real incident level
        for surfaced in [ServiceStatusIndicator.maintenance, .minor, .major, .critical] {
            XCTAssertTrue(surfaced.shouldSurface, "\(surfaced) should surface a badge")
        }
    }

    func testMostSevereReduction() {
        let worst = [ServiceStatusIndicator.operational, .minor, .critical, .unknown]
            .max(by: { $0.severity < $1.severity })
        XCTAssertEqual(worst, .critical)
    }

    // MARK: - Parser (real-world fixtures)

    func testParsesOpenAIOperationalNonFractionalTimestamp() {
        // OpenAI's `updated_at` has NO fractional seconds.
        let json = """
        {"page":{"id":"01JM","name":"OpenAI","url":"https://status.openai.com/","updated_at":"2026-04-27T15:52:49Z"},"status":{"description":"All Systems Operational","indicator":"none"}}
        """
        let snap = ServiceStatusParser.parseStatuspageStatus(data(json), provider: .codex)
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.provider, .codex)
        XCTAssertEqual(snap?.indicator, .operational)
        XCTAssertEqual(snap?.description, "All Systems Operational")
        XCTAssertNotNil(snap?.updatedAt, "non-fractional ISO8601 must parse")
        XCTAssertEqual(snap?.pageURL, URL(string: "https://status.openai.com/"))
    }

    func testParsesClaudeOperationalFractionalTimestamp() {
        // Claude's `updated_at` HAS fractional seconds — must also parse.
        let json = """
        {"page":{"id":"tymt","name":"Claude","url":"https://status.claude.com","time_zone":"Etc/UTC","updated_at":"2026-06-03T13:34:10.032Z"},"status":{"indicator":"none","description":"All Systems Operational"}}
        """
        let snap = ServiceStatusParser.parseStatuspageStatus(data(json), provider: .claude)
        XCTAssertEqual(snap?.indicator, .operational)
        XCTAssertNotNil(snap?.updatedAt, "fractional-seconds ISO8601 must parse")
        XCTAssertEqual(snap?.pageURL, URL(string: "https://status.claude.com"))
    }

    func testParsesExpandedProviderRealResponse() {
        // Verbatim shape captured live from status.moonshot.cn (2026-06-28) — note
        // the `+08:00` numeric offset (not `Z`) that some of the new providers use.
        // The required fields (indicator/description) must parse to a usable
        // snapshot; an offset timestamp that the parser can't read degrades
        // gracefully to nil (never a crash / never a failed parse).
        let json = """
        {"page":{"id":"x","name":"Moonshot AI","url":"https://status.moonshot.cn","updated_at":"2026-06-27T23:14:37.403+08:00"},"status":{"indicator":"none","description":"All Systems Operational"}}
        """
        let snap = ServiceStatusParser.parseStatuspageStatus(data(json), provider: .moonshot)
        XCTAssertNotNil(snap, "a real new-provider response must parse")
        XCTAssertEqual(snap?.indicator, .operational)
        XCTAssertEqual(snap?.description, "All Systems Operational")
        XCTAssertEqual(snap?.pageURL, URL(string: "https://status.moonshot.cn"))
    }

    func testParsesDegradedIndicators() {
        for (raw, expected) in [("minor", ServiceStatusIndicator.minor),
                                ("major", .major),
                                ("critical", .critical),
                                ("maintenance", .maintenance)] {
            let json = """
            {"status":{"indicator":"\(raw)","description":"Something"}}
            """
            let snap = ServiceStatusParser.parseStatuspageStatus(data(json), provider: .cursor)
            XCTAssertEqual(snap?.indicator, expected, "indicator \(raw)")
        }
    }

    func testParserDegradesGracefullyOnMissingOptionalFields() {
        // No `page` object → no updatedAt / pageURL, but still parses.
        let json = """
        {"status":{"indicator":"major"}}
        """
        let snap = ServiceStatusParser.parseStatuspageStatus(data(json), provider: .copilot)
        XCTAssertEqual(snap?.indicator, .major)
        XCTAssertEqual(snap?.description, "", "missing description degrades to empty string")
        XCTAssertNil(snap?.updatedAt)
        XCTAssertNil(snap?.pageURL)
    }

    func testParserReturnsNilOnStructuralFailures() {
        XCTAssertNil(ServiceStatusParser.parseStatuspageStatus(data("not json"), provider: .claude))
        XCTAssertNil(ServiceStatusParser.parseStatuspageStatus(data(""), provider: .claude))
        XCTAssertNil(ServiceStatusParser.parseStatuspageStatus(data("[1,2,3]"), provider: .claude))
        // missing `status` object
        XCTAssertNil(ServiceStatusParser.parseStatuspageStatus(data("""
        {"page":{"name":"X"}}
        """), provider: .claude))
        // `status` present but no `indicator`
        XCTAssertNil(ServiceStatusParser.parseStatuspageStatus(data("""
        {"status":{"description":"x"}}
        """), provider: .claude))
    }

    func testParserToleratesUnparseableTimestamp() {
        let json = """
        {"page":{"updated_at":"not-a-date"},"status":{"indicator":"none","description":"ok"}}
        """
        let snap = ServiceStatusParser.parseStatuspageStatus(data(json), provider: .claude)
        XCTAssertEqual(snap?.indicator, .operational)
        XCTAssertNil(snap?.updatedAt, "bad timestamp → nil, not a failed parse")
    }

    // MARK: - Catalog

    func testCatalogEndpointsForKnownProviders() {
        XCTAssertEqual(ServiceStatusCatalog.statusEndpoint(for: .claude),
                       URL(string: "https://status.claude.com/api/v2/status.json"))
        XCTAssertEqual(ServiceStatusCatalog.statusEndpoint(for: .codex),
                       URL(string: "https://status.openai.com/api/v2/status.json"))
        XCTAssertEqual(ServiceStatusCatalog.statusEndpoint(for: .openaiAdmin),
                       URL(string: "https://status.openai.com/api/v2/status.json"))
        XCTAssertEqual(ServiceStatusCatalog.statusEndpoint(for: .cursor),
                       URL(string: "https://status.cursor.com/api/v2/status.json"))
        XCTAssertEqual(ServiceStatusCatalog.statusEndpoint(for: .copilot),
                       URL(string: "https://www.githubstatus.com/api/v2/status.json"))
        XCTAssertEqual(ServiceStatusCatalog.statusPageURL(for: .claude),
                       URL(string: "https://status.claude.com"))
    }

    func testCatalogEndpointsForExpandedProviders() {
        // Hosts live-verified 2026-06-28 to serve a valid Atlassian Statuspage v2
        // `/api/v2/status.json` (status.indicator + description + page.updated_at),
        // so the existing parser handles them unchanged. Pinned so a typo can't
        // silently break a badge.
        let expected: [ProviderKind: String] = [
            .elevenLabs: "status.elevenlabs.io",
            .groq: "groqstatus.com",
            .warp: "status.warp.dev",
            .moonshot: "status.moonshot.cn",
            .deepgram: "status.deepgram.com",
            .windsurf: "status.codeium.com",
            .augment: "status.augmentcode.com",
        ]
        for (provider, host) in expected {
            XCTAssertEqual(ServiceStatusCatalog.statusEndpoint(for: provider),
                           URL(string: "https://\(host)/api/v2/status.json"),
                           "endpoint for \(provider)")
            XCTAssertTrue(ServiceStatusCatalog.hasStatusPage(for: provider))
        }
    }

    func testCatalogReturnsNilForUnmappedProviders() {
        XCTAssertNil(ServiceStatusCatalog.statusEndpoint(for: .gemini))
        XCTAssertNil(ServiceStatusCatalog.statusEndpoint(for: .ollama))
        XCTAssertFalse(ServiceStatusCatalog.hasStatusPage(for: .gemini))
        XCTAssertTrue(ServiceStatusCatalog.hasStatusPage(for: .claude))
    }

    func testSupportedProvidersAllResolveToEndpoints() {
        XCTAssertFalse(ServiceStatusCatalog.supportedProviders.isEmpty)
        for provider in ServiceStatusCatalog.supportedProviders {
            XCTAssertNotNil(
                ServiceStatusCatalog.statusEndpoint(for: provider),
                "supported provider \(provider) must resolve to an endpoint"
            )
            XCTAssertTrue(ServiceStatusCatalog.hasStatusPage(for: provider))
        }
    }
}
