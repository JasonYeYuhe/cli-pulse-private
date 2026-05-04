#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Pinning tests for the OAuth-429 backoff state. Codex review's
/// required scenarios:
///
///   1. 429 records backoff
///   2. calls during backoff skip OAuth
///   3. non-429 failures do NOT poison the backoff path
///   4. backoff expiry allows OAuth to retry
///
/// Plus the design choices our own review caught:
///
///   5. token-fingerprint keying — re-auth with a fresh token is NOT
///      blocked by the previous token's backoff
///   6. successful response immediately clears backoff (no waiting
///      for natural expiry)
///   7. fingerprint is stable across calls for the same token
///
/// Tests use an injected clock (`ControllableClock`) so we can fast-
/// forward without `sleep()`. Each test instantiates its own
/// `ClaudeOAuthBackoffState`; the production singleton is never
/// touched.
final class ClaudeOAuthBackoffStateTests: XCTestCase {

    /// Tiny mutable clock wrapper. `nonisolated(unsafe)` because tests
    /// are single-threaded and we want a plain mutable Date — a class
    /// would also work but a final class with a single Date property
    /// is overkill.
    private final class ControllableClock: @unchecked Sendable {
        private var current: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            self.current = start
        }
        func now() -> Date { current }
        func advance(by seconds: TimeInterval) { current.addTimeInterval(seconds) }
    }

    private func makeState(window: TimeInterval = 900) -> (ClaudeOAuthBackoffState, ControllableClock) {
        let clock = ControllableClock()
        let state = ClaudeOAuthBackoffState(window: window, clock: { clock.now() })
        return (state, clock)
    }

    // MARK: - 1. 429 records backoff

    func test_recordFailure_makesRemainingBackoffReturnPositiveInterval() async {
        let (state, _) = makeState(window: 900)
        let fp = ClaudeOAuthBackoffState.fingerprint(forToken: "sk-ant-oat01-tokenA")

        // Before recording: no backoff.
        let before = await state.remainingBackoff(forFingerprint: fp)
        XCTAssertNil(before)

        await state.recordFailure(forFingerprint: fp)

        // After recording: full window remaining.
        let after = await state.remainingBackoff(forFingerprint: fp)
        XCTAssertNotNil(after)
        XCTAssertEqual(after ?? -1, 900, accuracy: 0.01)
    }

    // MARK: - 2. Calls during backoff skip OAuth (the strategy short-circuits)

    func test_remainingBackoff_isStableMidWindow() async {
        let (state, clock) = makeState(window: 900)
        let fp = ClaudeOAuthBackoffState.fingerprint(forToken: "sk-ant-oat01-tokenA")
        await state.recordFailure(forFingerprint: fp)

        clock.advance(by: 60)  // 1 min into the window
        let mid = await state.remainingBackoff(forFingerprint: fp)
        XCTAssertEqual(mid ?? -1, 840, accuracy: 0.01)

        clock.advance(by: 60)
        let mid2 = await state.remainingBackoff(forFingerprint: fp)
        XCTAssertEqual(mid2 ?? -1, 780, accuracy: 0.01)
    }

    // MARK: - 3. Non-429 failures don't poison the 429 backoff path

    /// The actor itself doesn't have a "non-429 failure" notion — it
    /// just records what callers tell it. This test pins the
    /// CONTRACT that callers MUST NOT call `recordFailure` for non-
    /// 429 failures. The strategy enforces this; this test guards the
    /// behaviour the strategy depends on (fingerprint absence ⇒ no
    /// backoff). See `ClaudeOAuthStrategy.fetch` for the call sites.
    func test_unrelatedFingerprintsAreIndependent() async {
        let (state, _) = makeState()
        let fpA = ClaudeOAuthBackoffState.fingerprint(forToken: "tokenA")
        let fpB = ClaudeOAuthBackoffState.fingerprint(forToken: "tokenB")

        await state.recordFailure(forFingerprint: fpA)

        // tokenB never had a 429 → no backoff.
        let bRemaining = await state.remainingBackoff(forFingerprint: fpB)
        XCTAssertNil(
            bRemaining,
            "Recording failure for tokenA must not affect tokenB"
        )

        // tokenA has a backoff.
        let aRemaining = await state.remainingBackoff(forFingerprint: fpA)
        XCTAssertNotNil(aRemaining)
    }

    // MARK: - 4. Backoff expiry allows OAuth to retry

    func test_remainingBackoff_returnsNilAfterWindowExpires() async {
        let (state, clock) = makeState(window: 900)
        let fp = ClaudeOAuthBackoffState.fingerprint(forToken: "tokenA")
        await state.recordFailure(forFingerprint: fp)

        // Advance past the window.
        clock.advance(by: 901)

        let remaining = await state.remainingBackoff(forFingerprint: fp)
        XCTAssertNil(remaining, "Expired backoff must return nil so the strategy retries OAuth")
    }

    func test_expiredEntryIsLazilyEvicted() async {
        let (state, clock) = makeState(window: 60)
        let fp = ClaudeOAuthBackoffState.fingerprint(forToken: "tokenA")
        await state.recordFailure(forFingerprint: fp)

        // Read once after expiry — eviction happens.
        clock.advance(by: 61)
        _ = await state.remainingBackoff(forFingerprint: fp)

        // Re-record + read again before window expires.
        await state.recordFailure(forFingerprint: fp)
        let after = await state.remainingBackoff(forFingerprint: fp)
        XCTAssertEqual(after ?? -1, 60, accuracy: 0.01)
    }

    // MARK: - 5. Token-fingerprint keying

    func test_freshTokenFromReAuthIsNotBlockedByPreviousTokenBackoff() async {
        let (state, _) = makeState()
        let fpOld = ClaudeOAuthBackoffState.fingerprint(forToken: "old-token-burned-out")
        let fpNew = ClaudeOAuthBackoffState.fingerprint(forToken: "fresh-token-after-reauth")
        XCTAssertNotEqual(fpOld, fpNew)

        await state.recordFailure(forFingerprint: fpOld)

        // The fresh token has its own (clean) budget.
        let newRemaining = await state.remainingBackoff(forFingerprint: fpNew)
        XCTAssertNil(newRemaining)
    }

    // MARK: - 6. Successful response clears backoff

    func test_resetClearsBackoffImmediately() async {
        let (state, clock) = makeState(window: 900)
        let fp = ClaudeOAuthBackoffState.fingerprint(forToken: "tokenA")
        await state.recordFailure(forFingerprint: fp)

        // Even mid-window, reset wipes the entry.
        clock.advance(by: 60)
        await state.reset(forFingerprint: fp)

        let remaining = await state.remainingBackoff(forFingerprint: fp)
        XCTAssertNil(remaining)
    }

    // MARK: - 7. Fingerprint stability + privacy

    func test_fingerprintIsStableForSameToken() {
        let token = "sk-ant-oat01-12345"
        XCTAssertEqual(
            ClaudeOAuthBackoffState.fingerprint(forToken: token),
            ClaudeOAuthBackoffState.fingerprint(forToken: token)
        )
    }

    func test_fingerprintDiffersAcrossTokens() {
        XCTAssertNotEqual(
            ClaudeOAuthBackoffState.fingerprint(forToken: "tokenA"),
            ClaudeOAuthBackoffState.fingerprint(forToken: "tokenB")
        )
    }

    func test_fingerprintIsExactly16HexChars() {
        let fp = ClaudeOAuthBackoffState.fingerprint(forToken: "anytoken")
        XCTAssertEqual(fp.count, 16)
        // Every character is hex.
        XCTAssertTrue(fp.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func test_fingerprintDoesNotReturnRawToken() {
        let token = "sk-ant-oat01-supersecretREVEALEDtoken"
        let fp = ClaudeOAuthBackoffState.fingerprint(forToken: token)
        XCTAssertFalse(fp.contains("supersecret"))
        XCTAssertFalse(fp.contains("oat01"))
    }
}
#endif
