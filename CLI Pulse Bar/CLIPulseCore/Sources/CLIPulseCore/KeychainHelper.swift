import Foundation
import Security

public enum KeychainHelper {
    private static let service = "com.clipulse.app"

    /// The app-group keychain access group shared by the main app, the
    /// LoginItem helper, and the .pkg daemon. Bare group string (no
    /// `$(AppIdentifierPrefix)`) — Apple's keychain APIs auto-prepend the
    /// team prefix at query time. Mirrors `HelperConfig.keychainAccessGroup`
    /// and the `keychain-access-groups` entry in the app/LoginItem/.pkg
    /// entitlements. Items written into this group are readable by every
    /// process that declares the group, with NO per-item consent prompt.
    public static let sharedAccessGroup = "group.yyh.CLI-Pulse"

    /// One-time migration: re-home a keychain item that was written WITHOUT
    /// an access group (so its ACL trusts only the writing app) into
    /// `sharedAccessGroup`, so the LoginItem helper can read it without the
    /// recurring "wants to use information stored by ... in your keychain"
    /// consent prompt. Safe to call on every launch — idempotent and
    /// prompt-free, because it runs in the MAIN APP reading its OWN item.
    ///
    /// We intentionally do NOT delete the legacy no-group copy afterward: a
    /// `SecItemDelete` that omits `kSecAttrAccessGroup` is not reliably
    /// scoped once the app declares `keychain-access-groups`, so deleting it
    /// could wipe the group value we just wrote. A lingering no-group
    /// duplicate is harmless — every reader now queries the group explicitly.
    public static func migrateToSharedGroup(key: String) {
        // Already present in the shared group (migrated earlier, or written
        // there by a newer build) ⇒ nothing to do. Guard also prevents
        // clobbering a fresher in-group value with a stale legacy copy.
        if load(key: key, accessGroup: sharedAccessGroup) != nil { return }
        // Read the legacy (no access group) item. The main app reading its
        // own item never triggers a consent prompt.
        guard let legacy = load(key: key), !legacy.isEmpty else { return }
        save(key: key, value: legacy, accessGroup: sharedAccessGroup)
    }

    public static func save(key: String, value: String, accessGroup: String? = nil) {
        guard let data = value.data(using: .utf8) else { return }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        // Atomic: try update first, fall back to add if item doesn't exist
        // NOTE: kSecAttrAccessible must NOT be in update attrs — Apple rejects it with errSecParam
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        let status = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // v1.21 D3: WhenUnlockedThisDeviceOnly is tighter than the previous
            // AfterFirstUnlock — token is unreadable while device is locked AND
            // never syncs via iCloud Keychain (which AfterFirstUnlock could,
            // if kSecAttrSynchronizable were ever set). Main-app reads tokens
            // only while user is interacting (= device unlocked), so the
            // tighter access class is compatible. Existing items keep their
            // old accessibility until natural rotation rewrites them — no
            // explicit migration needed (Apple rejects accessibility changes
            // in SecItemUpdate with errSecParam, so the safe path is just
            // new writes = tighter, old items continue to work as-is).
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    public static func load(key: String, accessGroup: String? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(key: String, accessGroup: String? = nil) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        SecItemDelete(query as CFDictionary)
    }
}
