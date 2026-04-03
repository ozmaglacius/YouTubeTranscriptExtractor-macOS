import Foundation
import Security

enum KeychainService {
    private static let service = "com.local.YouTubeTranscriptExtractor"
    private static let account = "YouTubeDataAPIKey"

    static func saveAPIKey(_ key: String) {
        let data = Data(key.utf8)
        // Try update first
        let updateQuery: [CFString: Any] = [
            kSecClass:   kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attrs: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(updateQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            // Insert new
            var addQuery = updateQuery
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func loadAPIKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     account,
            kSecReturnData:      true,
            kSecMatchLimit:      kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAPIKey() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
