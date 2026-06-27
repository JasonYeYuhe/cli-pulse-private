#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Tests the `CredentialBridge` decode + 5-minute staleness gate — the cache that
/// feeds bridged OAuth tokens to the sandboxed helper/collectors. A wrong gate
/// silently serves stale tokens (auth fails) or drops fresh ones. Exercised via
/// the pure `decodeBridgedCredentials(_:provider:now:maxAge:)` seam (no Keychain).
final class CredentialBridgeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let claudeCreds: [String: Any] = ["Claude": ["accessToken": "tok-x", "rateLimitTier": "Max 20x"]]

    private func blob(ageSeconds: TimeInterval?, creds: [String: Any]) -> Data {
        var obj: [String: Any] = ["credentials": creds]
        if let age = ageSeconds {
            obj["timestamp"] = sharedISO8601Formatter.string(from: now.addingTimeInterval(-age))
        }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func test_fresh_returns_provider_creds() {
        let out = CredentialBridge.decodeBridgedCredentials(blob(ageSeconds: 100, creds: claudeCreds),
                                                            provider: "Claude", now: now)
        XCTAssertEqual(out?["accessToken"] as? String, "tok-x")
        XCTAssertEqual(out?["rateLimitTier"] as? String, "Max 20x")
    }

    func test_stale_beyond_maxAge_returns_nil() {
        XCTAssertNil(CredentialBridge.decodeBridgedCredentials(blob(ageSeconds: 301, creds: claudeCreds),
                                                               provider: "Claude", now: now))
    }

    func test_exactly_at_maxAge_is_still_fresh() {
        // The gate is `> maxAge`, so exactly 300s old is NOT stale; 301s is.
        XCTAssertNotNil(CredentialBridge.decodeBridgedCredentials(blob(ageSeconds: 300, creds: claudeCreds),
                                                                  provider: "Claude", now: now))
        XCTAssertNil(CredentialBridge.decodeBridgedCredentials(blob(ageSeconds: 301, creds: claudeCreds),
                                                               provider: "Claude", now: now))
    }

    func test_missing_timestamp_treated_as_fresh() {
        XCTAssertNotNil(CredentialBridge.decodeBridgedCredentials(blob(ageSeconds: nil, creds: claudeCreds),
                                                                  provider: "Claude", now: now))
    }

    func test_malformed_json_returns_nil() {
        XCTAssertNil(CredentialBridge.decodeBridgedCredentials(Data("not json".utf8), provider: "Claude", now: now))
    }

    func test_absent_provider_returns_nil() {
        XCTAssertNil(CredentialBridge.decodeBridgedCredentials(blob(ageSeconds: 10, creds: claudeCreds),
                                                               provider: "Codex", now: now))
    }

    func test_custom_maxAge_is_respected() {
        let d = blob(ageSeconds: 50, creds: claudeCreds)
        XCTAssertNil(CredentialBridge.decodeBridgedCredentials(d, provider: "Claude", now: now, maxAge: 30))
        XCTAssertNotNil(CredentialBridge.decodeBridgedCredentials(d, provider: "Claude", now: now, maxAge: 60))
    }
}
#endif
