import Foundation
import Security

enum KeychainService {
    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case readFailed(OSStatus)
        case deleteFailed(OSStatus)
        case unexpectedData
    }

    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        // Delete existing item first (update = delete + add)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Multi-org credential management

    /// Load all stored org credentials.
    static func loadCredentials() -> [OrgCredential] {
        guard let json = read(key: Constants.Keychain.credentials),
              let data = json.data(using: .utf8),
              let creds = try? JSONDecoder().decode([OrgCredential].self, from: data) else {
            return []
        }
        return creds
    }

    /// Save all org credentials.
    static func saveAllCredentials(_ credentials: [OrgCredential]) throws {
        let data = try JSONEncoder().encode(credentials)
        guard let json = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try save(key: Constants.Keychain.credentials, value: json)
    }

    /// Get the active org ID.
    static var activeOrgId: String? {
        read(key: Constants.Keychain.activeOrgId)
    }

    /// Set the active org ID.
    static func setActiveOrgId(_ orgId: String) throws {
        try save(key: Constants.Keychain.activeOrgId, value: orgId)
    }

    /// Migrate from single-credential format to multi-credential format.
    /// Returns true if migration was performed.
    @discardableResult
    static func migrateIfNeeded() -> Bool {
        // Already migrated if credentials key exists
        if read(key: Constants.Keychain.credentials) != nil {
            return false
        }

        // Check for old single-credential keys
        guard let oldApiKey = read(key: Constants.Keychain.apiKey),
              let oldOrgId = read(key: Constants.Keychain.orgId) else {
            return false
        }

        // Migrate: wrap old credentials into array format
        let cred = OrgCredential(orgId: oldOrgId, orgName: oldOrgId, apiKey: oldApiKey)
        do {
            try saveAllCredentials([cred])
            try setActiveOrgId(oldOrgId)
            // Delete old keys
            delete(key: Constants.Keychain.apiKey)
            delete(key: Constants.Keychain.orgId)
            return true
        } catch {
            return false
        }
    }
}
