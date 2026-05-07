import XCTest
@testable import HelperKit
import Foundation

final class OAuthBackoffTests: XCTestCase {

    /// Mutable mock clock — must be a class so `clock` closure capture
    /// shares one source of truth across `register` / `remaining`.
    private final class MockClock: @unchecked Sendable {
        var t: TimeInterval = 0
        func now() -> TimeInterval { return t }
    }

    // MARK: - Fingerprint

    func testFingerprintIsStableAcrossCalls() {
        let a = OAuthBackoff.fingerprint(forToken: "sk-ant-oat01-abc")
        let b = OAuthBackoff.fingerprint(forToken: "sk-ant-oat01-abc")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 16)
    }

    func testFingerprintDiffersBetweenTokens() {
        let a = OAuthBackoff.fingerprint(forToken: "tokenA")
        let b = OAuthBackoff.fingerprint(forToken: "tokenB")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Register / remaining lifecycle

    func testRegisterMakesRemainingNonNil() async {
        let clock = MockClock()
        let backoff = OAuthBackoff(clock: { clock.now() })
        let fp = "abcd1234abcd1234"
        let before = await backoff.remaining(fp)
        XCTAssertNil(before)

        await backoff.register(fp)
        guard let after = await backoff.remaining(fp) else {
            XCTFail("remaining was nil after register")
            return
        }
        XCTAssertEqual(after, OAuthBackoff.windowSeconds, accuracy: 0.001)
    }

    func testRemainingExpiresAfterWindow() async {
        let clock = MockClock()
        let backoff = OAuthBackoff(clock: { clock.now() })
        let fp = "abcd1234abcd1234"

        await backoff.register(fp)
        clock.t = OAuthBackoff.windowSeconds + 1
        let result = await backoff.remaining(fp)
        XCTAssertNil(result, "expired entries should evict lazily and return nil")
    }

    func testResetDropsEntry() async {
        let clock = MockClock()
        let backoff = OAuthBackoff(clock: { clock.now() })
        let fp = "abcd1234abcd1234"

        await backoff.register(fp)
        await backoff.reset(fp)
        let result = await backoff.remaining(fp)
        XCTAssertNil(result)
    }

    // MARK: - Per-fingerprint isolation

    func testDifferentFingerprintsAreIndependent() async {
        let clock = MockClock()
        let backoff = OAuthBackoff(clock: { clock.now() })
        let fpA = OAuthBackoff.fingerprint(forToken: "tokenA")
        let fpB = OAuthBackoff.fingerprint(forToken: "tokenB")

        await backoff.register(fpA)
        let aRemain = await backoff.remaining(fpA)
        let bRemain = await backoff.remaining(fpB)
        XCTAssertNotNil(aRemain)
        XCTAssertNil(bRemain, "registering fpA must not leak to fpB")
    }

    // MARK: - Single-writer guarantee (Gemini Phase 4E v2 P1)

    func testSecondConcurrentRegisterPreservesOriginalExpiry() async {
        // Phase 4E v2 P1: actor-isolated single-writer. Two register
        // calls for the same fingerprint within the active window must
        // NOT reset the expiry — the first call's window stands.
        let clock = MockClock()
        let backoff = OAuthBackoff(clock: { clock.now() })
        let fp = "abcd1234abcd1234"

        // First register at t=0.
        await backoff.register(fp)
        let first = await backoff.remaining(fp)!

        // Advance 60 s, register again. With single-writer, the second
        // register no-ops because the original entry is still valid.
        // remaining now should reflect (window - 60), NOT a fresh
        // (window) reset.
        clock.t = 60
        await backoff.register(fp)
        let second = await backoff.remaining(fp)!

        XCTAssertEqual(first - 60, second, accuracy: 0.001,
                       "second register inside the active window must NOT reset the expiry")
    }

    func testRegisterAfterExpiryStartsFreshWindow() async {
        // After the original expires, the next register starts a fresh
        // 15-min window — that's the explicit recovery path.
        let clock = MockClock()
        let backoff = OAuthBackoff(clock: { clock.now() })
        let fp = "abcd1234abcd1234"

        await backoff.register(fp)
        clock.t = OAuthBackoff.windowSeconds + 1   // expired
        await backoff.register(fp)
        let result = await backoff.remaining(fp)!
        XCTAssertEqual(result, OAuthBackoff.windowSeconds, accuracy: 0.001)
    }

    // MARK: - Reset all

    func testResetAllClearsEverything() async {
        let backoff = OAuthBackoff()
        await backoff.register("a")
        await backoff.register("b")
        await backoff.resetAllForTesting()
        let a = await backoff.remaining("a")
        let b = await backoff.remaining("b")
        XCTAssertNil(a)
        XCTAssertNil(b)
    }
}
