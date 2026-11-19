import Foundation
import Security

enum RelayCredential {
    private static var query: [String: Any] {
        var values: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cc.macseek.cliprelay.relay",
            kSecAttrAccount as String: "authorization",
        ]
        #if os(iOS)
        values[kSecUseDataProtectionKeychain as String] = true
        values[kSecAttrAccessGroup as String] = "group.cc.macseek.cliprelay"
        #endif
        return values
    }

    static func read(address: String) throws -> String {
        var result: CFTypeRef?
        let read = query.merging([kSecReturnData as String: true]) { _, new in new }
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        guard status == errSecSuccess, let bytes = result as? Data,
              let pair = try? Codec.read([String].self, bytes),
              pair.count == 2, pair[0] == address else { throw RelayFailure.unauthorized }
        return pair[1]
    }

    static func save(_ token: String, address: String) throws {
        let value = [kSecValueData as String: try Codec.pack([address, token])]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(value) { _, new in new }
            #if os(iOS)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #endif
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RelayFailure.storage }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayFailure.storage }
    }
}
