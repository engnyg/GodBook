import Foundation
import Security

/// 簡易 Keychain 存取（用來保存 WebDAV 密碼、漫畫源登入憑證）。
enum Keychain {
    private static let service = "com.godbook.app"

    private static func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    static func set(_ value: String, for key: String) {
        delete(key)
        var item = query(key)
        item[kSecValueData] = Data(value.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var item = query(key)
        item[kSecReturnData] = true
        item[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
