import Foundation
#if canImport(Combine)
import Combine
#endif

/// v1.19.1 — runtime privacy preferences. Two-tier toggle:
///
/// - `skipClaudeKeychain` — when true, every cross-app Claude Code
///   keychain read (`ClaudeCredentials.readKeychainCredentials()`) is
///   bypassed at its call sites. User-initiated reads from the
///   Provider Config "Connect Claude Code" button are intentionally
///   NOT guarded — explicit user action overrides this preference.
///
/// - `localOnlyMode` — master toggle. When on, forces
///   `skipClaudeKeychain` to true and reserves room for future
///   external-API enrichment opt-outs. UI disables the per-toggle
///   when master is active.
///
/// Defaults: both OFF (preserves pre-1.19.1 behaviour for users who
/// already accepted the keychain prompt + populated the cache). This
/// is opt-in.
///
/// Motivation: macOS 26.x Keychain Agent rejects valid login passwords
/// in cross-app ACL grants on the user's Mac (see
/// `feedback_keychain_agent_bug_macos26` memory). Users must be able
/// to escape the buggy dialog without losing all telemetry.
public final class PrivacySettings: ObservableObject {
    public static let shared = PrivacySettings()

    private enum Keys {
        static let skipClaudeKeychain = "privacy.skipClaudeKeychain"
        static let localOnlyMode = "privacy.localOnlyMode"
        // v1.34 R1d: managed-session safety toggle (co-located here for the same
        // didSet→defaults plumbing). The `privacy.` namespace is in the
        // UnsandboxedDataMigration allowlist, so it survives the MAS→DEVID move.
        static let blockClaudeOnOutdatedHelper = "privacy.blockClaudeOnOutdatedHelper"
    }

    @Published public var skipClaudeKeychain: Bool {
        didSet {
            defaults.set(skipClaudeKeychain, forKey: Keys.skipClaudeKeychain)
        }
    }

    @Published public var localOnlyMode: Bool {
        didSet {
            defaults.set(localOnlyMode, forKey: Keys.localOnlyMode)
            if localOnlyMode && !skipClaudeKeychain {
                skipClaudeKeychain = true
            }
        }
    }

    /// v1.34 R1d: when ON, the app HARD-BLOCKS starting a managed Claude session
    /// whenever the helper owning the socket is below the OAuth-injection floor
    /// (which would silently run Claude on the API, not the user's Max/Pro
    /// plan). Default OFF = warn-only: the session is allowed but a prominent
    /// banner tells the user to update the helper.
    @Published public var blockClaudeOnOutdatedHelper: Bool {
        didSet {
            defaults.set(blockClaudeOnOutdatedHelper, forKey: Keys.blockClaudeOnOutdatedHelper)
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedMaster = defaults.bool(forKey: Keys.localOnlyMode)
        let storedSpecific = defaults.bool(forKey: Keys.skipClaudeKeychain)
        self.localOnlyMode = storedMaster
        self.skipClaudeKeychain = storedMaster || storedSpecific
        self.blockClaudeOnOutdatedHelper = defaults.bool(forKey: Keys.blockClaudeOnOutdatedHelper)
    }
}
