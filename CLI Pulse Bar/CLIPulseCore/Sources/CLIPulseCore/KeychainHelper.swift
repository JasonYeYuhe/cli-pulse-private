import Foundation
import Security

public enum KeychainHelper {
    private static let service = "com.clipulse.app"

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
