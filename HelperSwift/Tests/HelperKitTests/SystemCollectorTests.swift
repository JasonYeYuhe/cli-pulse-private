import XCTest
@testable import HelperKit
import Foundation

/// Tests for the Phase 4E Slice 2d façade + ClaudeSnapshotWriter.

final class ClaudeSnapshotWriterTests: XCTestCase {

    func testBuildDict_canonicalShape() {
        let snapshot = ProviderQuotaSnapshot(
            quota: 100, remaining: 70, planType: "Pro",
            resetTime: "2026-05-07T05:00:00Z",
            tiers: [
                ProviderQuotaTier(name: "5h Window", quota: 100, remaining: 70,
                                  resetTime: "2026-05-07T05:00:00Z"),
                ProviderQuotaTier(name: "Weekly", quota: 100, remaining: 50,
                                  resetTime: "2026-05-13T00:00:00Z"),
            ],
            provenance: .anthropicOAuth,
            fetchedAt: "2026-05-07T01:23:45Z"
        )
        let dict = ClaudeSnapshotWriter.buildDict(
            from: snapshot,
            rateLimitTier: "pro",
            source: "oauth",
            fetchedAt: "2026-05-07T01:23:45Z"
        )

        XCTAssertEqual(dict["session_used"] as? Int, 30,
                       "5h Window remaining=70 → used=30")
        XCTAssertEqual(dict["weekly_used"] as? Int, 50,
                       "Weekly remaining=50 → used=50")
        XCTAssertEqual(dict["session_reset"] as? String, "2026-05-07T05:00:00Z")
        XCTAssertEqual(dict["weekly_reset"] as? String, "2026-05-13T00:00:00Z")
        XCTAssertEqual(dict["rate_limit_tier"] as? String, "pro")
        XCTAssertEqual(dict["source"] as? String, "oauth")
        XCTAssertEqual(dict["fetched_at"] as? String, "2026-05-07T01:23:45Z")
        XCTAssertNotNil(dict["account_email"] as? NSNull)
        XCTAssertEqual((dict["extra_tiers"] as? [Any])?.count, 0,
                       "no Designs/Daily Routines tiers in this snapshot")
    }

    func testBuildDict_extraTiersWired() {
        let snapshot = ProviderQuotaSnapshot(
            quota: 100, remaining: 70, planType: "Pro", resetTime: nil,
            tiers: [
                ProviderQuotaTier(name: "5h Window", quota: 100, remaining: 70, resetTime: nil),
                ProviderQuotaTier(name: "Designs", quota: 100, remaining: 80,
                                  resetTime: "2026-05-08T00:00:00Z"),
                ProviderQuotaTier(name: "Daily Routines", quota: 100, remaining: 60, resetTime: nil),
            ],
            provenance: .anthropicOAuth,
            fetchedAt: "2026-05-07T01:23:45Z"
        )
        let dict = ClaudeSnapshotWriter.buildDict(
            from: snapshot, rateLimitTier: nil,
            source: "oauth", fetchedAt: "2026-05-07T01:23:45Z"
        )
        let extras = dict["extra_tiers"] as? [[String: Any]] ?? []
        XCTAssertEqual(extras.count, 2)
        XCTAssertEqual(extras[0]["name"] as? String, "Designs")
        XCTAssertEqual(extras[0]["used"] as? Int, 20,
                       "Designs remaining=80 → used=20")
        XCTAssertEqual(extras[1]["name"] as? String, "Daily Routines")
    }

    func testBuildDict_extraUsageDollarConversion() {
        // Extra Usage tier expressed in 100,000-unit credits — quota
        // becomes the user's monthly limit in dollars.
        let snapshot = ProviderQuotaSnapshot(
            quota: 100, remaining: 100, planType: "Max 5x", resetTime: nil,
            tiers: [
                ProviderQuotaTier(name: "Extra Usage", quota: 5_000_000, remaining: 3_750_000,
                                  resetTime: nil),
            ],
            provenance: .anthropicOAuth,
            fetchedAt: "2026-05-07T01:23:45Z"
        )
        let dict = ClaudeSnapshotWriter.buildDict(
            from: snapshot, rateLimitTier: "max_5x",
            source: "oauth", fetchedAt: "2026-05-07T01:23:45Z"
        )
        let extra = dict["extra_usage"] as? [String: Any]
        XCTAssertNotNil(extra)
        XCTAssertEqual(extra?["is_enabled"] as? Bool, true)
        XCTAssertEqual(extra?["monthly_limit"] as? Double, 50.0,
                       "5_000_000 / 100_000 = $50")
        XCTAssertEqual(extra?["used_credits"] as? Double, 12.5,
                       "(5_000_000 - 3_750_000) / 100_000 = $12.50")
        XCTAssertEqual(extra?["currency"] as? String, "USD")
    }

    func testSourceLabel_mapsAllProvenanceVariants() {
        XCTAssertEqual(ClaudeSnapshotWriter.sourceLabel(from: .anthropicOAuth), "oauth")
        XCTAssertEqual(ClaudeSnapshotWriter.sourceLabel(from: .anthropicWebCookie), "web")
        XCTAssertEqual(ClaudeSnapshotWriter.sourceLabel(from: .anthropicCLILegacy), "cli")
        XCTAssertEqual(ClaudeSnapshotWriter.sourceLabel(from: .openAIWham), "unknown")
        XCTAssertEqual(ClaudeSnapshotWriter.sourceLabel(from: .googleCloudCode), "unknown")
        XCTAssertEqual(
            ClaudeSnapshotWriter.sourceLabel(from: .unavailable(reason: "x")),
            "unavailable"
        )
    }

    func testWrite_invokesFileHookForBothPaths() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString)")
        let groupContainer = tmp.appendingPathComponent("group/claude_snapshot.json")
        let legacy = tmp.appendingPathComponent("legacy/claude_snapshot.json")

        actor WriteCapture {
            var paths: [String] = []
            func capture(_ url: URL, _ data: Data) {
                paths.append(url.path)
            }
        }
        let capture = WriteCapture()

        let writer = ClaudeSnapshotWriter(
            groupContainerPath: groupContainer,
            legacyPath: legacy,
            fileWrite: { url, data in
                Task { await capture.capture(url, data) }
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let snapshot = ProviderQuotaSnapshot(
            quota: 100, remaining: 70, planType: "Pro", resetTime: nil,
            tiers: [], provenance: .anthropicOAuth,
            fetchedAt: "2026-05-07T01:23:45Z"
        )
        writer.write(snapshot: snapshot, rateLimitTier: "pro")

        // Block until both writes have been recorded (max 1 s).
        let expectation = XCTestExpectation(description: "both paths written")
        Task {
            for _ in 0..<100 {
                if await capture.paths.count == 2 {
                    expectation.fulfill()
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        wait(for: [expectation], timeout: 2.0)
    }
}

// MARK: - SystemCollector facade

final class SystemCollectorFacadeTests: XCTestCase {

    /// Build a facade with mocked-out collectors so collect_all is
    /// deterministic without the host's `ps` / `vm_stat` / Keychain.
    private func makeFacade(
        sessionsPS: String,
        vmStat: String = ""
    ) -> SystemCollector {
        let device = DeviceSnapshotCollector(hooks: .init(
            loadAverage1m: { 1.0 },
            cpuCount: { 4 },
            vmStatOutput: { vmStat }
        ))
        let session = SessionDetector(
            userSecret: Data("k".utf8),
            hooks: SessionDetector.TestHooks(
                psOutput: { sessionsPS },
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                fileExists: { _ in false }
            )
        )
        // Quota fetchers all default to "no creds available" via
        // their hook defaults (file loaders return nil, etc.); they
        // produce .unavailable provenance.
        let claudeFetcher = ClaudeQuotaFetcher(
            keychain: KeychainReader(
                clock: { 0 },
                fetch: { _ in .nonZeroExit(code: 44, stdout: "") }
            ),
            backoff: OAuthBackoff(),
            http: { _ in nil },
            now: { Date() }
        )
        let codexFetcher = CodexQuotaFetcher(
            authFilePath: URL(fileURLWithPath: "/dev/null"),
            http: { _ in nil },
            fileLoader: { _ in nil },
            now: { Date() }
        )
        let geminiFetcher = GeminiQuotaFetcher(
            primaryCredsPath: URL(fileURLWithPath: "/dev/null/p"),
            fallbackCredsPath: URL(fileURLWithPath: "/dev/null/f"),
            http: { _ in nil },
            fileLoader: { _ in nil },
            now: { Date() }
        )
        return SystemCollector(
            userSecret: Data("k".utf8),
            deviceCollector: device,
            sessionDetector: session,
            claudeFetcher: claudeFetcher,
            codexFetcher: codexFetcher,
            geminiFetcher: geminiFetcher,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    func testCollectAll_assemblesAllComponents() async {
        let ps = "12345  3.5  1.2 00:42 /usr/local/bin/codex --model gpt-5"
        let vmStat = """
        Pages free:     50.
        Pages active:   100.
        Pages inactive: 50.
        Pages speculative: 10.
        Pages wired down: 100.
        Pages occupied by compressor: 50.
        """
        let facade = makeFacade(sessionsPS: ps, vmStat: vmStat)
        let result = await facade.collectAll()

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].provider, "Codex")
        XCTAssertEqual(result.device.cpuUsage, 25)  // 1.0 / 4 * 100
        // memory: active=100+100+50=250, total=(50+10)+250+50=360, ratio=250/360 ≈ 0.69 → 69
        XCTAssertEqual(result.device.memoryUsage, 69)
        // Codex provider triggers Codex fetcher; no Claude/Gemini fetchers.
        XCTAssertEqual(Set(result.providerQuotas.keys), Set(["Codex"]))
        // Quota provenance is unavailable (mock fetchers have no creds).
        if case .unavailable = result.providerQuotas["Codex"]?.provenance {
            // good
        } else {
            XCTFail("expected Codex provenance to be unavailable")
        }
    }

    func testCollectAll_returnsResultEvenWithNoSessions() async {
        let facade = makeFacade(sessionsPS: "")
        let result = await facade.collectAll()
        XCTAssertEqual(result.sessions, [])
        XCTAssertEqual(result.providerQuotas, [:])
    }

    func testCollectionResultEncodesSnakeCase() throws {
        let result = SystemCollector.CollectionResult(
            device: DeviceSnapshot(cpuUsage: 10, memoryUsage: 30),
            sessions: [],
            alerts: [],
            providerQuotas: [:],
            helperVersion: "swift-test",
            collectionErrors: [],
            collectedAt: "2026-05-07T01:23:45Z"
        )
        let data = try JSONEncoder().encode(result)
        let json = String(data: data, encoding: .utf8) ?? ""
        for needle in [
            "\"helper_version\":",
            "\"collection_errors\":",
            "\"provider_quotas\":",
            "\"collected_at\":",
        ] {
            XCTAssertTrue(json.contains(needle),
                          "missing snake_case key `\(needle)`")
        }
    }
}
