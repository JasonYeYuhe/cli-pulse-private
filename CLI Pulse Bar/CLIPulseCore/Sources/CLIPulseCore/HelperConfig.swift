import Foundation

/// Pairing configuration shared between the main app and the Login Item helper.
/// Non-secret fields stored in app group UserDefaults; helperSecret stored in Keychain.
public struct HelperConfig: Codable, Sendable {
    public let deviceId: String
    public let userId: String
    public let deviceName: String
    public let helperVersion: String
    public let helperSecret: String

    public init(deviceId: String, userId: String, deviceName: String,
                helperVersion: String, helperSecret: String) {
        self.deviceId = deviceId
        self.userId = userId
        self.deviceName = deviceName
        self.helperVersion = helperVersion
        self.helperSecret = helperSecret
    }

    // MARK: - App Group Persistence

    private static let suiteName = "group.yyh.CLI-Pulse"
    private static let key = "helper_config"
    private static let secretKeychainKey = "helper_secret"
    private static let keychainAccessGroup = "group.yyh.CLI-Pulse"

    /// Non-secret portion stored in UserDefaults.
    private struct StoredConfig: Codable {
        let deviceId: String
        let userId: String
        let deviceName: String
        let helperVersion: String
    }

    /// Read config from shared UserDefaults + Keychain.
    public static func load() -> HelperConfig? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(StoredConfig.self, from: data) else {
            return nil
        }
        // Read secret from Keychain; fall back to legacy UserDefaults migration
        let secret = KeychainHelper.load(key: secretKeychainKey, accessGroup: keychainAccessGroup)
            ?? migrateLegacySecret()
            ?? ""
        guard !secret.isEmpty else { return nil }
        return HelperConfig(
            deviceId: stored.deviceId,
            userId: stored.userId,
            deviceName: stored.deviceName,
            helperVersion: stored.helperVersion,
            helperSecret: secret
        )
    }

    /// 2026-05-08: bug observed in production — when a user signs into the
    /// macOS app under a NEW Supabase account while the app-group already
    /// holds a `helper_config` from a PRIOR account, the stale `deviceId`
    /// + `userId` are silently used by the upload path. The server's
    /// `upsert_daily_usage(p_device_id)` then fails the ownership check
    /// (`devices.user_id` of the stored device != `auth.uid()` of the new
    /// JWT) and raises errcode 42501 → HTTP 403. The Mac sees
    /// `[syncDailyUsage] failed: HTTP 403` every refresh forever; the
    /// iPhone reads stale cloud data.
    ///
    /// `loadIfMatches(...)` returns the config ONLY when the stored
    /// `userId` equals the currently-authenticated user_id (e.g. the
    /// `sub` claim of the access token). Callers that need to send
    /// `p_device_id` MUST use this guarded variant — passing nil for
    /// `p_device_id` is the safe fallback (the server then attributes
    /// the upsert to the sentinel UUID instead of failing the device
    /// check; see migrate_v0.37_daily_usage_device_id.sql).
    public static func loadIfMatches(authenticatedUserId: String?) -> HelperConfig? {
        guard let cfg = load() else { return nil }
        guard let auth = authenticatedUserId, !auth.isEmpty else {
            // No authenticated user yet — caller shouldn't be sending
            // p_device_id at all.
            return nil
        }
        guard cfg.userId == auth else {
            // Cross-account leak: refuse to surface the stale config.
            return nil
        }
        return cfg
    }

    /// Write config: non-secret fields to UserDefaults, secret to Keychain.
    public static func save(_ config: HelperConfig) {
        let stored = StoredConfig(
            deviceId: config.deviceId,
            userId: config.userId,
            deviceName: config.deviceName,
            helperVersion: config.helperVersion
        )
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key)
        KeychainHelper.save(key: secretKeychainKey, value: config.helperSecret, accessGroup: keychainAccessGroup)
    }

    /// Remove config from shared UserDefaults and Keychain.
    public static func remove() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removeObject(forKey: key)
        KeychainHelper.delete(key: secretKeychainKey, accessGroup: keychainAccessGroup)
    }

    /// Migrate helperSecret from old full-config UserDefaults to Keychain.
    private static func migrateLegacySecret() -> String? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let legacy = try? JSONDecoder().decode(HelperConfig.self, from: data),
              !legacy.helperSecret.isEmpty else {
            return nil
        }
        // Move secret to Keychain and re-save without it in UserDefaults
        KeychainHelper.save(key: secretKeychainKey, value: legacy.helperSecret, accessGroup: keychainAccessGroup)
        return legacy.helperSecret
    }

    // MARK: - Migration from Python helper

    /// Attempt to import config from the legacy Python helper JSON file.
    /// Path: ~/.cli-pulse-helper.json
    public static func importFromLegacy() -> HelperConfig? {
        #if os(macOS)
        let home = NSHomeDirectory()
        let path = (home as NSString).appendingPathComponent(".cli-pulse-helper.json")
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceId = json["device_id"] as? String,
              let userId = json["user_id"] as? String,
              let helperSecret = json["helper_secret"] as? String else {
            return nil
        }
        return HelperConfig(
            deviceId: deviceId,
            userId: userId,
            deviceName: json["device_name"] as? String ?? Host.current().localizedName ?? "Mac",
            helperVersion: json["helper_version"] as? String ?? "1.0.0",
            helperSecret: helperSecret
        )
        #else
        return nil
        #endif
    }
}
