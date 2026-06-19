import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Tests the cross-app keychain-read cooldown that stops the
/// "CLIPulseHelper wants to use Claude Code-credentials" prompt from recurring
/// every refresh cycle (OAuth 401 → clearCachedKeychainCredentials → re-read).
/// See feedback_claude_oauth_keychain_prompt_spam.
final class ClaudeKeychainCooldownTests: XCTestCase {

    private var now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    override func setUp() {
        super.setUp()
        // Throwaway defaults suite so we never touch the real app-group state.
        let suite = "test.cooldown.\(UUID().uuidString)"
        ClaudeCredentials.cooldownDefaults = UserDefaults(suiteName: suite)!
        ClaudeCredentials.nowProvider = { [weak self] in self?.now ?? Date() }
        ClaudeCredentials.keychainReadCooldownInterval = 30 * 60
        ClaudeCredentials.clearKeychainReadCooldown()
    }

    override func tearDown() {
        ClaudeCredentials.nowProvider = { Date() }
        ClaudeCredentials.cooldownDefaults =
            UserDefaults(suiteName: "group.yyh.CLI-Pulse") ?? .standard
        super.tearDown()
    }

    func test_noCooldownByDefault() {
        XCTAssertFalse(ClaudeCredentials.isKeychainReadOnCooldown())
    }

    func test_installSetsCooldownActive() {
        ClaudeCredentials.installKeychainReadCooldown()
        XCTAssertTrue(ClaudeCredentials.isKeychainReadOnCooldown(),
                      "right after install, the read must be suppressed")
    }

    func test_cooldownStillActiveJustBeforeExpiry() {
        ClaudeCredentials.installKeychainReadCooldown()
        now = now.addingTimeInterval(30 * 60 - 1)   // 1s before expiry
        XCTAssertTrue(ClaudeCredentials.isKeychainReadOnCooldown())
    }

    func test_cooldownExpiresAfterInterval() {
        ClaudeCredentials.installKeychainReadCooldown()
        now = now.addingTimeInterval(30 * 60 + 1)   // 1s after expiry
        XCTAssertFalse(ClaudeCredentials.isKeychainReadOnCooldown(),
                       "after the interval, one cross-app read is allowed again")
        // expiry should have cleaned up the key, so it stays false
        XCTAssertFalse(ClaudeCredentials.isKeychainReadOnCooldown())
    }

    func test_clearCachedCredentialsDoesNotArmCooldown() {
        // codex review: clearCachedKeychainCredentials() is cache-only and is
        // ALSO called by the Settings "Disconnect" button — it must NOT arm the
        // cooldown, or a Disconnect→Connect would be blocked for 30 min. Only
        // the 401 path arms it (via installKeychainReadCooldown()).
        XCTAssertFalse(ClaudeCredentials.isKeychainReadOnCooldown())
        ClaudeCredentials.clearCachedKeychainCredentials()
        XCTAssertFalse(ClaudeCredentials.isKeychainReadOnCooldown(),
                       "Disconnect/cache-clear must not arm the cooldown")
    }

    func test_oauth401PathArmsCooldownExplicitly() {
        // The 401 handler clears the cache AND arms the cooldown.
        ClaudeCredentials.clearCachedKeychainCredentials()
        ClaudeCredentials.installKeychainReadCooldown()
        XCTAssertTrue(ClaudeCredentials.isKeychainReadOnCooldown())
    }

    func test_clearCooldownResets() {
        ClaudeCredentials.installKeychainReadCooldown()
        XCTAssertTrue(ClaudeCredentials.isKeychainReadOnCooldown())
        ClaudeCredentials.clearKeychainReadCooldown()   // success-path reset
        XCTAssertFalse(ClaudeCredentials.isKeychainReadOnCooldown())
    }
}

#endif
