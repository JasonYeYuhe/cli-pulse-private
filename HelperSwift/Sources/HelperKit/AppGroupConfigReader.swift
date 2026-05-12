import Foundation
import Security

/// Reads pairing state (`deviceId`, `helperSecret`) the macOS app
/// wrote during the pairing flow:
///
///   * `deviceId` (+ companion non-secret fields) → UserDefaults
///     `(suiteName: "group.yyh.CLI-Pulse", key: "helper_config")`
///   * `helperSecret` → Keychain
///     `(service: "com.clipulse.app", account: "helper_secret",
///       accessGroup: "group.yyh.CLI-Pulse")`
///
/// All constants below MUST match `CLIPulseCore/HelperConfig.swift`
/// and `CLIPulseCore/KeychainHelper.swift` exactly. A drift breaks
/// the bridge silently — `readPairing()` returns `nil` and the
/// daemon falls back to JSON / unpaired state.
///
/// Schema parity is tracked by
/// `HelperConfigStoreTests.testStoredConfigSchemaMatchesCLIPulseCore`.
///
/// B3-bis (2026-05-12): introduced as the modern read path. Pre-bridge,
/// `HelperConfigStore` read `~/.cli-pulse-helper.json` exclusively; the
/// modern app never wrote to that path, so fresh MAS users had no
/// daemon-visible pairing state and cloud sync silently no-op'd.
public enum AppGroupConfigReader {

    // MARK: - Constants (mirror of CLIPulseCore)

    public static let suiteName = "group.yyh.CLI-Pulse"
    public static let userDefaultsKey = "helper_config"
    public static let keychainService = "com.clipulse.app"
    public static let keychainAccount = "helper_secret"
    public static let keychainAccessGroup = "group.yyh.CLI-Pulse"

    // MARK: - Public API

    public struct AppPairing: Equatable, Sendable {
        public let deviceId: String
        public let helperSecret: String

        public init(deviceId: String, helperSecret: String) {
            self.deviceId = deviceId
            self.helperSecret = helperSecret
        }
    }

    /// Returns the modern (`UserDefaults` + `Keychain`) pairing
    /// state, or `nil` when either source is empty. Both must be
    /// populated for the daemon to consider the device paired —
    /// `deviceId` without `helperSecret` cannot authenticate Supabase
    /// RPCs, and vice versa.
    ///
    /// On macOS the entitlement
    /// `keychain-access-groups: [$(AppIdentifierPrefix)group.yyh.CLI-Pulse]`
    /// MUST be present on the codesigned daemon binary for the
    /// keychain lookup to succeed. See
    /// `HelperSwift/cli_pulse_helper.entitlements`.
    public static func readPairing() -> AppPairing? {
        guard let stored = readStoredConfig() else { return nil }
        guard !stored.deviceId.isEmpty else { return nil }
        guard let secret = readSecretFromKeychain(),
              !secret.isEmpty
        else { return nil }
        return AppPairing(deviceId: stored.deviceId, helperSecret: secret)
    }

    // MARK: - Internals

    /// Mirrors `CLIPulseCore.HelperConfig.StoredConfig` exactly.
    /// Codable round-trips with the encoded blob the app's
    /// `HelperConfig.save()` writes to UserDefaults. Schema drift
    /// between this struct and the app's would corrupt the decode;
    /// the parity test in `HelperConfigStoreTests` pins the fields.
    struct StoredConfig: Codable, Equatable {
        let deviceId: String
        let userId: String?
        let deviceName: String?
        let helperVersion: String?
    }

    static func readStoredConfig(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName)
    ) -> StoredConfig? {
        guard let defaults,
              let data = defaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(StoredConfig.self,
                                                     from: data)
        else { return nil }
        return decoded
    }

    /// Reads `helper_secret` from the keychain access group the app
    /// shares. Uses the native `SecItemCopyMatching` API rather than
    /// the `/usr/bin/security` CLI: the CLI tool does NOT honour
    /// `kSecAttrAccessGroup` in its query (it can only read items
    /// signed by the calling binary's own access groups, which
    /// excludes app-group-scoped items). The native API does the
    /// right thing as long as the daemon has the entitlement.
    static func readSecretFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty
        else { return nil }
        return str
    }
}
