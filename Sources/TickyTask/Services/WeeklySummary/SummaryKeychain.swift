import Foundation
import Security

/// Stores the optional local-model-server API key in the login Keychain — never
/// in UserDefaults or backups.
struct SummaryKeychain: Sendable {
    var service = "com.tickytask.mac.weekly-summary"
    /// UI-test runs use a separate item so they never read or replace the user's real key.
    var account = UITestSupport.isRunning ? "uitest-local-model-api-key" : "local-model-api-key"

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// Saves `value`, or deletes the item when it's blank. Returns whether it succeeded.
    @discardableResult
    func write(_ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        SecItemDelete(baseQuery as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
