#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class ClaudeStrategyTests: XCTestCase {

    // MARK: - ClaudeSnapshot → CollectorResult

    func testResultBuilderFullSnapshot() {
        let snapshot = ClaudeSnapshot(
            sessionUsed: 45, weeklyUsed: 60, opusUsed: 75, sonnetUsed: 55,
            sessionReset: "2026-04-02T22:00:00Z", weeklyReset: "2026-04-09T00:00:00Z",
            rateLimitTier: "pro", sourceLabel: "oauth"
        )
        let result = ClaudeResultBuilder.build(from: snapshot)
        XCTAssertEqual(result.usage.provider, "Claude")
        XCTAssertEqual(result.usage.quota, 100)
        XCTAssertEqual(result.usage.remaining, 55) // 100 - 45
        XCTAssertEqual(result.usage.plan_type, "Pro")
        XCTAssertEqual(result.usage.tiers.count, 3) // 5h + weekly + sonnet only
        XCTAssertEqual(result.usage.tiers[0].name, "5h Window")
        XCTAssertEqual(result.usage.tiers[0].remaining, 55)
        XCTAssertEqual(result.usage.tiers[1].name, "Weekly")
        XCTAssertEqual(result.usage.tiers[1].remaining, 40)
        XCTAssertEqual(result.usage.tiers[2].name, "Sonnet only")
        XCTAssertEqual(result.usage.tiers[2].remaining, 45)
        XCTAssertEqual(result.dataKind, .quota)
    }

    // P3: Designs (`iguana_necktie`) and Daily Routines (`seven_day_omelette`)
    // append after the existing Sonnet/Opus row in the order
    // [5h, Weekly, Sonnet only, Designs, Daily Routines]. Sonnet/Opus
    // coalescing is unchanged — it still produces a single "Sonnet only"
    // bar regardless of which of the two carried the value.
    func testResultBuilderAppendsDesignsAndDailyRoutines() {
        let snapshot = ClaudeSnapshot(
            sessionUsed: 22,
            weeklyUsed: 18,
            sonnetUsed: 2,
            designsUsed: 25,
            dailyRoutinesUsed: 5,
            sessionReset: "2026-05-05T08:00:00Z",
            weeklyReset: "2026-05-05T12:00:01Z",
            designsReset: "2026-05-05T12:00:01Z",
            dailyRoutinesReset: nil,
            rateLimitTier: "max_20x",
            sourceLabel: "oauth"
        )
        let result = ClaudeResultBuilder.build(from: snapshot)
        XCTAssertEqual(result.usage.tiers.map(\.name),
                       ["5h Window", "Weekly", "Sonnet only", "Designs", "Daily Routines"])
        let byName = Dictionary(uniqueKeysWithValues: result.usage.tiers.map { ($0.name, $0) })
        XCTAssertEqual(byName["Designs"]?.remaining, 75)
        XCTAssertEqual(byName["Designs"]?.reset_time, "2026-05-05T12:00:01Z")
        XCTAssertEqual(byName["Daily Routines"]?.remaining, 95)
        XCTAssertNil(byName["Daily Routines"]?.reset_time)
    }

    // Regression guard: snapshots WITHOUT the new launch-window fields
    // must still produce exactly the legacy three-row layout. Locks the
    // additive contract so old helper builds keep rendering unchanged.
    func testResultBuilderLegacySnapshotKeepsThreeRows() {
        let snapshot = ClaudeSnapshot(
            sessionUsed: 45, weeklyUsed: 60, sonnetUsed: 55,
            sessionReset: "2026-04-02T22:00:00Z",
            weeklyReset: "2026-04-09T00:00:00Z",
            rateLimitTier: "pro", sourceLabel: "oauth"
        )
        let result = ClaudeResultBuilder.build(from: snapshot)
        XCTAssertEqual(result.usage.tiers.map(\.name),
                       ["5h Window", "Weekly", "Sonnet only"])
    }

    // hasAnyUsage must consider the launch windows so a Designs-only
    // payload still emits a real quota envelope (otherwise it would be
    // mis-classified as "unavailable" and the new bar would never show).
    func testHasAnyUsageIncludesLaunchWindows() {
        let onlyDesigns = ClaudeSnapshot(designsUsed: 25, sourceLabel: "oauth")
        XCTAssertTrue(onlyDesigns.hasAnyUsage)
        let onlyDailyRoutines = ClaudeSnapshot(dailyRoutinesUsed: 5, sourceLabel: "oauth")
        XCTAssertTrue(onlyDailyRoutines.hasAnyUsage)
    }

    func testResultBuilderMinimalSnapshot() {
        let snapshot = ClaudeSnapshot(sessionUsed: 10, sourceLabel: "cli-pty")
        let result = ClaudeResultBuilder.build(from: snapshot)
        XCTAssertEqual(result.usage.remaining, 90)
        XCTAssertEqual(result.usage.tiers.count, 1)
        XCTAssertEqual(result.usage.plan_type, "Unknown")
    }

    func testResultBuilderExtraUsage() {
        let extra = ClaudeExtraUsage(isEnabled: true, monthlyLimit: 5000.0, usedCredits: 1234.56, currency: "USD")
        let snapshot = ClaudeSnapshot(sessionUsed: 20, extraUsage: extra, sourceLabel: "oauth")
        let result = ClaudeResultBuilder.build(from: snapshot)
        XCTAssertEqual(result.usage.tiers.count, 1)
        XCTAssertEqual(result.usage.tiers.first?.name, "5h Window")
    }

    func testResultBuilderPlanTypes() {
        for (tier, expected) in [("max", "Max 5x"), ("default_claude_max_20x", "Max 20x"), ("max_5x", "Max 5x"), ("pro", "Pro"), ("team", "Team"), ("enterprise", "Enterprise"), (nil, "Unknown")] {
            let snapshot = ClaudeSnapshot(sessionUsed: 0, rateLimitTier: tier, sourceLabel: "test")
            let result = ClaudeResultBuilder.build(from: snapshot)
            XCTAssertEqual(result.usage.plan_type, expected, "tier '\(tier ?? "nil")' should map to '\(expected)'")
        }
    }

    func testResetFormattingRoundsUpLikeCodexBar() {
        let future = Date().addingTimeInterval((3 * 3600) + (34 * 60) + 5)
        let iso = ISO8601DateFormatter().string(from: future)
        XCTAssertEqual(RelativeTime.formatReset(iso), "in 3h 35m")
    }

    func testCanonicalWeeklyResetMatchesClaudeFriday11PM() throws {
        let formatter = ISO8601DateFormatter()
        let reference = try XCTUnwrap(formatter.date(from: "2026-04-02T08:34:00Z")) // Thu 5:34 PM JST

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        let reset = try XCTUnwrap(ClaudeHelperContract.canonicalWeeklyReset(after: reference, calendar: calendar))
        XCTAssertEqual(formatter.string(from: reset), "2026-04-03T14:00:00Z") // Fri 11:00 PM JST
    }

    func testNormalizeWeeklyResetPrefersCanonicalWhenSnapshotLooksBogus() {
        let formatter = ISO8601DateFormatter()
        let reference = formatter.date(from: "2026-04-02T08:34:00Z")!
        let normalized = ClaudeHelperContract.normalizeWeeklyReset(
            "2026-04-09T00:00:00Z",
            reference: reference
        )
        XCTAssertEqual(normalized, "2026-04-03T14:00:00Z")
    }

    func testNormalizeSessionResetDropsPastReset() {
        let formatter = ISO8601DateFormatter()
        let reference = formatter.date(from: "2026-04-02T08:38:58Z")!
        XCTAssertNil(
            ClaudeHelperContract.normalizeSessionReset(
                "2026-04-02T08:00:00Z",
                reference: reference
            )
        )
    }

    // MARK: - ClaudeCredentials

    func testParseCredentialsSnakeCase() {
        let json = """
        {"claude_ai_oauth":{"access_token":"sk-ant-oat01-test","rate_limit_tier":"pro"}}
        """.data(using: .utf8)!
        let creds = ClaudeCredentials.parseCredentialsJSON(json)
        XCTAssertEqual(creds?.accessToken, "sk-ant-oat01-test")
        XCTAssertEqual(creds?.rateLimitTier, "pro")
    }

    func testParseCredentialsCamelCase() {
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-cc","rateLimitTier":"max"}}
        """.data(using: .utf8)!
        let creds = ClaudeCredentials.parseCredentialsJSON(json)
        XCTAssertEqual(creds?.accessToken, "sk-ant-oat01-cc")
        XCTAssertEqual(creds?.rateLimitTier, "max")
    }

    func testParseCredentialsEmpty() {
        XCTAssertNil(ClaudeCredentials.parseCredentialsJSON("{}".data(using: .utf8)!))
    }

    func testStripANSI() {
        XCTAssertEqual(ClaudeCredentials.stripANSI("\u{001B}[32m42% left\u{001B}[0m"), "42% left")
    }

    // MARK: - ClaudeWebStrategy session key extraction

    func testExtractSessionKeyFromCookieHeader() {
        XCTAssertEqual(
            ClaudeWebStrategy.extractSessionKey(from: "sessionKey=abc123; other=xyz"),
            "abc123"
        )
        XCTAssertEqual(
            ClaudeWebStrategy.extractSessionKey(from: "sessionKey=abc123"),
            "abc123"
        )
        XCTAssertNil(ClaudeWebStrategy.extractSessionKey(from: "other=xyz"))
        XCTAssertNil(ClaudeWebStrategy.extractSessionKey(from: "sessionKey="))
    }

    // MARK: - ClaudeCLIPTYStrategy parsing

    func testPTYParseCLIOutput() throws {
        let text = """
        Settings: Usage

        Current session
        42% left
        Resets in 2 hours

        Current week (all models)
        75% left
        Resets Monday 12:00 AM

        Current week (Opus)
        60% left
        """
        let snapshot = try ClaudeCLIPTYStrategy.parseCLIOutput(text)
        XCTAssertEqual(snapshot.sessionPercentLeft, 42)
        XCTAssertEqual(snapshot.weeklyPercentLeft, 75)
        XCTAssertEqual(snapshot.opusPercentLeft, 60)
    }

    func testPTYPercentUsedFromLine() {
        XCTAssertEqual(ClaudeCLIPTYStrategy.percentUsedFromLine("42% left"), 58)
        XCTAssertEqual(ClaudeCLIPTYStrategy.percentUsedFromLine("75% used"), 75)
        XCTAssertEqual(ClaudeCLIPTYStrategy.percentUsedFromLine("30% remaining"), 70)
        XCTAssertNil(ClaudeCLIPTYStrategy.percentUsedFromLine("no percentage here"))
    }

    // MARK: - ClaudeOAuthStrategy parsing

    func testOAuthParseUsage() throws {
        let json = """
        {
            "five_hour": { "utilization": 45, "resets_at": "2026-04-02T22:00:00Z" },
            "seven_day": { "utilization": 60, "resets_at": "2026-04-09T00:00:00Z" },
            "seven_day_opus": { "utilization": 75 }
        }
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthStrategy.parseUsage(json)
        XCTAssertEqual(usage.fiveHour?.utilization, 45)
        XCTAssertEqual(usage.sevenDay?.utilization, 60)
        XCTAssertEqual(usage.sevenDayOpus?.utilization, 75)
        XCTAssertNil(usage.sevenDaySonnet)
    }

    func testOAuthParseUsageWithExtraUsage() throws {
        let json = """
        {
            "five_hour": { "utilization": 10 },
            "extra_usage": { "is_enabled": true, "monthly_limit": 5000.0, "used_credits": 1234.56, "currency": "USD" }
        }
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthStrategy.parseUsage(json)
        XCTAssertNotNil(usage.extraUsage)
        XCTAssertTrue(usage.extraUsage!.isEnabled)
        XCTAssertEqual(usage.extraUsage!.monthlyLimit!, 5000.0, accuracy: 0.01)
    }

    /// Regression: Anthropic's /api/oauth/usage returns `utilization` as a
    /// JSON number that Foundation decodes to `Double` (e.g. `9.0`).
    /// A bare `as? Int` cast on `NSNumber(Double)` returns nil — which, prior
    /// to the v1.10.4 fix, collapsed every window's utilization to the
    /// `?? 0` fallback, producing the "Quota data unavailable" symptom on
    /// macOS even though the endpoint was returning valid data.
    /// This test fails if the Int-coercion regresses.
    func testOAuthParseUsageDoubleUtilization() throws {
        let json = """
        {
            "five_hour":        { "utilization": 9.0,  "resets_at": "2026-04-23T09:00:01Z" },
            "seven_day":        { "utilization": 81.0, "resets_at": "2026-04-23T20:00:01Z" },
            "seven_day_opus":   null,
            "seven_day_sonnet": { "utilization": 66.0, "resets_at": "2026-04-23T20:00:01Z" },
            "extra_usage":      { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null, "currency": null }
        }
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthStrategy.parseUsage(json)
        XCTAssertEqual(usage.fiveHour?.utilization, 9, "Double 9.0 must coerce to Int 9, not 0")
        XCTAssertEqual(usage.sevenDay?.utilization, 81)
        XCTAssertNil(usage.sevenDayOpus, "null should decode as nil window")
        XCTAssertEqual(usage.sevenDaySonnet?.utilization, 66)
    }

    /// Edge cases for the `intFromJSON` helper: rounds halves, handles Int
    /// literals unchanged, returns nil for non-numbers.
    func testIntFromJSONHelper() {
        XCTAssertEqual(ClaudeOAuthStrategy.intFromJSON(9.0), 9)
        XCTAssertEqual(ClaudeOAuthStrategy.intFromJSON(9.4), 9)
        XCTAssertEqual(ClaudeOAuthStrategy.intFromJSON(9.6), 10)
        XCTAssertEqual(ClaudeOAuthStrategy.intFromJSON(9), 9)
        XCTAssertEqual(ClaudeOAuthStrategy.intFromJSON(0), 0)
        XCTAssertNil(ClaudeOAuthStrategy.intFromJSON(nil))
        XCTAssertNil(ClaudeOAuthStrategy.intFromJSON("9"))
    }

    // P3 — launch-window null semantics on the OAuth parser.
    // - `iguana_necktie: null` must parse as a window with utilization 0
    //   (enabled-but-unused bucket), NOT skipped.
    // - `seven_day_omelette: {"utilization": 5.0, "resets_at": null}` parses
    //   normally — utilization 5, no reset.
    // - `seven_day_opus: null` keeps the existing optional-window behavior
    //   and parses as nil (NOT a 0-bucket). This is the key invariant the
    //   launch-window split must not regress.
    func testOAuthParseLaunchWindowsAndOpusNullDistinct() throws {
        let json = """
        {
            "five_hour": { "utilization": 0.0, "resets_at": null },
            "seven_day": { "utilization": 18.0, "resets_at": "2026-05-05T12:00:01Z" },
            "seven_day_opus": null,
            "seven_day_sonnet": { "utilization": 2.0, "resets_at": "2026-05-05T12:00:00Z" },
            "iguana_necktie": null,
            "seven_day_omelette": { "utilization": 5.0, "resets_at": null }
        }
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthStrategy.parseUsage(json)
        XCTAssertNotNil(usage.iguanaNecktie)
        XCTAssertEqual(usage.iguanaNecktie?.utilization, 0)
        XCTAssertNil(usage.iguanaNecktie?.resetsAt)
        XCTAssertNotNil(usage.sevenDayOmelette)
        XCTAssertEqual(usage.sevenDayOmelette?.utilization, 5)
        XCTAssertNil(usage.sevenDayOmelette?.resetsAt)
        XCTAssertNil(usage.sevenDayOpus,
                     "Existing optional model windows must keep parseWindow's nil-on-null behavior")
    }

    // P3 — absent launch keys still skip. If the API hasn't started returning
    // the new buckets at all yet, neither field should fabricate a window.
    func testOAuthParseLaunchWindowsAbsentSkipped() throws {
        let json = """
        {
            "five_hour": { "utilization": 10.0, "resets_at": null }
        }
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthStrategy.parseUsage(json)
        XCTAssertNil(usage.iguanaNecktie)
        XCTAssertNil(usage.sevenDayOmelette)
    }

    // P3 — malformed utilization on a launch window collapses to 0 for that
    // window, not the whole parse. Mirrors the helper's `_coerce_util` rule.
    func testOAuthParseLaunchWindowMalformedUtilizationFallsBack() throws {
        let json = """
        {
            "five_hour": { "utilization": 5, "resets_at": null },
            "iguana_necktie": { "utilization": "garbage", "resets_at": null }
        }
        """.data(using: .utf8)!
        let usage = try ClaudeOAuthStrategy.parseUsage(json)
        XCTAssertEqual(usage.iguanaNecktie?.utilization, 0)
        XCTAssertEqual(usage.fiveHour?.utilization, 5,
                       "A single bad launch-window value must not poison sibling parses")
    }

    // MARK: - ClaudeSourceResolver

    func testResolverDefaultOrder() {
        // Verify default strategy order: OAuth → CLI PTY → Web (CodexBar app-runtime order)
        let strategies = ClaudeSourceResolver.defaultStrategies
        XCTAssertEqual(strategies.count, 3)
        XCTAssertEqual(strategies[0].sourceLabel, "oauth")
        XCTAssertEqual(strategies[1].sourceLabel, "cli-pty")
        XCTAssertEqual(strategies[2].sourceLabel, "web")
    }

    func testResolverAvailability() {
        let resolver = ClaudeSourceResolver()
        let config = ProviderConfig(kind: .claude)
        _ = resolver.isAvailable(config: config)
    }

    // MARK: - Helper contract

    func testHelperContractPaths() {
        let home = ClaudeCredentials.realHomeDir
        XCTAssertTrue(ClaudeHelperContract.snapshotPath.hasPrefix(home))
        XCTAssertTrue(ClaudeHelperContract.snapshotPath.hasSuffix("claude_snapshot.json"))
        XCTAssertTrue(ClaudeHelperContract.sessionKeyPath.hasSuffix("claude_session.json"))
    }

    func testHelperSnapshotRoundTrip() throws {
        // Save any existing production snapshot so we can restore it after the test.
        let prodPath = ClaudeHelperContract.snapshotPath
        let hadExisting = FileManager.default.fileExists(atPath: prodPath)
        let existingData = hadExisting ? FileManager.default.contents(atPath: prodPath) : nil

        let snapshot = ClaudeSnapshot(
            sessionUsed: 45, weeklyUsed: 60, opusUsed: 75,
            sessionReset: "2026-04-02T22:00:00Z", weeklyReset: "2026-04-09T00:00:00Z",
            rateLimitTier: "pro", accountEmail: "test@example.com",
            sourceLabel: "web"
        )
        try ClaudeHelperContract.writeSnapshot(snapshot)
        defer {
            // Restore the original snapshot if one existed; otherwise remove test artifact
            if let data = existingData {
                try? data.write(to: URL(fileURLWithPath: prodPath), options: .atomic)
            } else {
                try? FileManager.default.removeItem(atPath: prodPath)
            }
        }

        let read = ClaudeWebStrategy.readHelperSnapshot()
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.sessionUsed, 45)
        XCTAssertEqual(read?.weeklyUsed, 60)
        XCTAssertEqual(read?.opusUsed, 75)
        XCTAssertEqual(read?.rateLimitTier, "pro")
        XCTAssertEqual(read?.accountEmail, "test@example.com")
        XCTAssertEqual(read?.sourceLabel, "helper-web")
        // Legacy snapshots carry no extra_tiers — new launch-window fields
        // must round-trip as nil for back-compat.
        XCTAssertNil(read?.designsUsed)
        XCTAssertNil(read?.dailyRoutinesUsed)
        XCTAssertNil(read?.designsReset)
        XCTAssertNil(read?.dailyRoutinesReset)
    }

    // P3 — extra_tiers round-trip. A snapshot carrying Designs and Daily
    // Routines must serialize to disk and re-emerge with the same values
    // through ClaudeWebStrategy.readHelperSnapshot, including a null reset
    // for Daily Routines (mirrors the live "enabled-but-unused" payload).
    func testHelperSnapshotRoundTripCarriesExtraTiers() throws {
        let prodPath = ClaudeHelperContract.snapshotPath
        let hadExisting = FileManager.default.fileExists(atPath: prodPath)
        let existingData = hadExisting ? FileManager.default.contents(atPath: prodPath) : nil

        let snapshot = ClaudeSnapshot(
            sessionUsed: 22, weeklyUsed: 18, sonnetUsed: 2,
            designsUsed: 25, dailyRoutinesUsed: 5,
            sessionReset: "2026-05-05T08:00:00Z",
            weeklyReset: "2026-05-05T12:00:01Z",
            designsReset: "2026-05-05T12:00:01Z",
            dailyRoutinesReset: nil,
            rateLimitTier: "max_20x",
            accountEmail: "test@example.com",
            sourceLabel: "web"
        )
        try ClaudeHelperContract.writeSnapshot(snapshot)
        defer {
            if let data = existingData {
                try? data.write(to: URL(fileURLWithPath: prodPath), options: .atomic)
            } else {
                try? FileManager.default.removeItem(atPath: prodPath)
            }
        }

        let read = ClaudeWebStrategy.readHelperSnapshot()
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.designsUsed, 25)
        XCTAssertEqual(read?.designsReset, "2026-05-05T12:00:01Z")
        XCTAssertEqual(read?.dailyRoutinesUsed, 5)
        XCTAssertNil(read?.dailyRoutinesReset)
        // Legacy fields still survive on the same round-trip
        XCTAssertEqual(read?.sessionUsed, 22)
        XCTAssertEqual(read?.weeklyUsed, 18)
        XCTAssertEqual(read?.sonnetUsed, 2)
    }

    // MARK: - Strategy error fallback logic

    func testStrategyErrorShouldFallback() {
        XCTAssertTrue(ClaudeStrategyError.noToken.shouldFallback)
        XCTAssertTrue(ClaudeStrategyError.noBinary.shouldFallback)
        XCTAssertTrue(ClaudeStrategyError.httpError(status: 429, provider: "Claude").shouldFallback)
        XCTAssertTrue(ClaudeStrategyError.httpError(status: 401, provider: "Claude").shouldFallback)
        XCTAssertTrue(ClaudeStrategyError.httpError(status: 403, provider: "Claude").shouldFallback)
        XCTAssertTrue(ClaudeStrategyError.noSessionKey.shouldFallback)
        XCTAssertTrue(ClaudeStrategyError.unauthorized.shouldFallback)
        XCTAssertTrue(ClaudeStrategyError.timedOut.shouldFallback)
        XCTAssertTrue(ClaudeStrategyError.parseFailed("test").shouldFallback)
    }
}
#endif
