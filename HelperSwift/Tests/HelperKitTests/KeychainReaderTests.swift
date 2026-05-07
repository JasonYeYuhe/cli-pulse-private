import XCTest
@testable import HelperKit
import Foundation

final class KeychainReaderTests: XCTestCase {

    private final class MockClock: @unchecked Sendable {
        var t: TimeInterval = 0
        func now() -> TimeInterval { return t }
    }

    /// Mock fetch hook backed by a script — returns canned `RunResult`s
    /// for configured services. Tests construct `RunResult.success`
    /// for the happy path, `.nonZeroExit(44, "")` for errSecItemNotFound,
    /// `.nonZeroExit(51, "")` for errSecAuthFailed (user denied),
    /// `.timedOut` for the watchdog-tripped path, etc.
    private final class FetchScript: @unchecked Sendable {
        var responses: [String: SubprocessRunner.RunResult] = [:]
        var calls: [String] = []
        func fetch(service: String) -> SubprocessRunner.RunResult {
            calls.append(service)
            return responses[service] ?? .nonZeroExit(code: 44, stdout: "")
        }
    }

    // MARK: - Happy path

    func testFindGenericReturnsTrimmedSuccess() async {
        let script = FetchScript()
        script.responses["TestService"] = .success(stdout: "  payload-json  \n")
        let reader = KeychainReader(
            clock: { 0 },
            fetch: { service in script.fetch(service: service) }
        )
        let result = await reader.find(generic: "TestService")
        XCTAssertEqual(result, .success(value: "payload-json"))
        XCTAssertEqual(script.calls, ["TestService"])
    }

    func testEmptyResponseIsServiceNotFound() async {
        let script = FetchScript()
        script.responses["EmptyService"] = .success(stdout: "")
        let reader = KeychainReader(
            clock: { 0 },
            fetch: { service in script.fetch(service: service) }
        )
        let result = await reader.find(generic: "EmptyService")
        XCTAssertEqual(result, .unavailable(reason: .serviceNotFound))
    }

    // MARK: - errSecItemNotFound (Phase 4E Slice 2b Gemini P0)

    func testItemNotFoundDoesNotCacheDenial() async {
        // `security` exits 44 (`errSecItemNotFound`) when the user
        // simply hasn't installed Claude CLI yet. This is NOT a
        // denial — should not lock out subsequent fetches for 24 h.
        let clock = MockClock()
        let script = FetchScript()
        script.responses["NoSuchService"] = .nonZeroExit(code: 44, stdout: "")
        let reader = KeychainReader(
            clock: { clock.now() },
            fetch: { service in script.fetch(service: service) }
        )

        let first = await reader.find(generic: "NoSuchService")
        XCTAssertEqual(first, .unavailable(reason: .serviceNotFound))

        // 1 second later, user installs Claude CLI; service appears.
        clock.t = 1
        script.responses["NoSuchService"] = .success(stdout: "fresh-payload")
        let second = await reader.find(generic: "NoSuchService")
        XCTAssertEqual(second, .success(value: "fresh-payload"),
                       "errSecItemNotFound must NOT trigger a denial cache; subsequent reads pick up new state")
        XCTAssertEqual(script.calls.count, 2)
    }

    // MARK: - User denied / watchdog (Phase 4E v2.1 P1)

    func testUserDeniedTriggersDenialCache() async {
        let clock = MockClock()
        let script = FetchScript()
        // errSecAuthFailed = 51 (user clicked Deny on the prompt).
        script.responses["DenyService"] = .nonZeroExit(code: 51, stdout: "")
        let reader = KeychainReader(
            clock: { clock.now() },
            fetch: { service in script.fetch(service: service) }
        )

        let first = await reader.find(generic: "DenyService")
        XCTAssertEqual(first, .unavailable(reason: .userDenied))
        XCTAssertEqual(script.calls.count, 1)

        clock.t = 60
        let second = await reader.find(generic: "DenyService")
        XCTAssertEqual(second, .unavailable(reason: .denialCached))
        XCTAssertEqual(script.calls.count, 1,
                       "denial cache must short-circuit before the subprocess")
    }

    func testWatchdogTimeoutTriggersDenialCache() async {
        let clock = MockClock()
        let script = FetchScript()
        script.responses["AfkService"] = .timedOut
        let reader = KeychainReader(
            clock: { clock.now() },
            fetch: { service in script.fetch(service: service) }
        )

        let result = await reader.find(generic: "AfkService")
        XCTAssertEqual(result, .unavailable(reason: .watchdogTimeout))

        clock.t = 100
        let cached = await reader.find(generic: "AfkService")
        XCTAssertEqual(cached, .unavailable(reason: .denialCached))
    }

    func testDenialCacheExpiresAfter24Hours() async {
        let clock = MockClock()
        let script = FetchScript()
        script.responses["DenyService"] = .nonZeroExit(code: 51, stdout: "")
        let reader = KeychainReader(
            clock: { clock.now() },
            fetch: { service in script.fetch(service: service) }
        )

        _ = await reader.find(generic: "DenyService")
        clock.t = 24 * 60 * 60 + 1
        script.responses["DenyService"] = .success(stdout: "later-payload")
        let result = await reader.find(generic: "DenyService")
        XCTAssertEqual(result, .success(value: "later-payload"))
        XCTAssertEqual(script.calls.count, 2)
    }

    func testForceRetryClearsCache() async {
        let clock = MockClock()
        let script = FetchScript()
        script.responses["DenyService"] = .nonZeroExit(code: 51, stdout: "")
        let reader = KeychainReader(
            clock: { clock.now() },
            fetch: { service in script.fetch(service: service) }
        )

        _ = await reader.find(generic: "DenyService")
        script.responses["DenyService"] = .success(stdout: "post-retry-payload")
        let result = await reader.find(generic: "DenyService", forceRetry: true)
        XCTAssertEqual(result, .success(value: "post-retry-payload"))
    }

    // MARK: - Reset

    func testResetDenialCache() async {
        let clock = MockClock()
        let script = FetchScript()
        script.responses["S"] = .nonZeroExit(code: 51, stdout: "")
        let reader = KeychainReader(
            clock: { clock.now() },
            fetch: { service in script.fetch(service: service) }
        )
        _ = await reader.find(generic: "S")
        await reader.resetDenialCacheForTesting()
        script.responses["S"] = .success(stdout: "fresh")
        let result = await reader.find(generic: "S")
        XCTAssertEqual(result, .success(value: "fresh"))
    }

    // MARK: - Per-service isolation

    func testDenialOfOneServiceDoesntAffectAnother() async {
        let clock = MockClock()
        let script = FetchScript()
        script.responses["A"] = .nonZeroExit(code: 51, stdout: "")
        script.responses["B"] = .success(stdout: "payload-b")
        let reader = KeychainReader(
            clock: { clock.now() },
            fetch: { service in script.fetch(service: service) }
        )
        let a = await reader.find(generic: "A")
        XCTAssertEqual(a, .unavailable(reason: .userDenied))
        let b = await reader.find(generic: "B")
        XCTAssertEqual(b, .success(value: "payload-b"))
    }
}
