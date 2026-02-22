import Foundation
import Security

actor KeychainStore {
    enum KeychainStoreError: LocalizedError {
        case unexpectedData
        case invalidStringData
        case unhandledStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedData:
                return "Keychain returned an unexpected result."
            case .invalidStringData:
                return "Keychain value could not be decoded as text."
            case .unhandledStatus(let status):
                if let message = SecCopyErrorMessageString(status, nil) as String? {
                    return "Keychain error (\(status)): \(message)"
                }
                return "Keychain error (\(status))."
            }
        }
    }

    private let service = "com.jesse.voxscribe"
    private let huggingFaceTokenAccount = "huggingface_token"

    func loadHuggingFaceToken() throws -> String? {
        try readString(account: huggingFaceTokenAccount)
    }

    func saveHuggingFaceToken(_ token: String?) throws {
        let normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            try deleteValue(account: huggingFaceTokenAccount)
            return
        }
        try upsertString(normalized, account: huggingFaceTokenAccount)
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    private func readString(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandledStatus(status)
        }
        guard let data = item as? Data else {
            throw KeychainStoreError.unexpectedData
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidStringData
        }
        return value
    }

    private func upsertString(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attrs: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData] = data
            insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unhandledStatus(addStatus)
            }
        default:
            throw KeychainStoreError.unhandledStatus(status)
        }
    }

    private func deleteValue(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandledStatus(status)
        }
    }
}
