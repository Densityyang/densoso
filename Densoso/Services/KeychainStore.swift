import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case duplicateItem
    case invalidStatus(OSStatus)
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .itemNotFound: return "Keychain 中未找到该条目"
        case .duplicateItem: return "Keychain 中已存在该条目"
        case .invalidStatus(let status): return "Keychain 操作失败，状态码: \(status)"
        case .conversionFailed: return "字符串/数据转换失败"
        }
    }
}

final class KeychainStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = KeychainStore()

    private let service = "com.densoso.keychain"
    private let deepSeekAPIKeyAccount = "deepseek_api_key"
    private let modelStudioAPIKeyAccount = "model_studio_api_key"

    private init() {}

    func saveAPIKey(_ key: String) throws {
        try saveCredential(key, account: deepSeekAPIKeyAccount)
    }

    func readAPIKey() throws -> String? {
        try readCredential(account: deepSeekAPIKeyAccount)
    }

    func deleteAPIKey() throws {
        try deleteCredential(account: deepSeekAPIKeyAccount)
    }

    func saveModelStudioAPIKey(_ key: String) throws {
        try saveCredential(key, account: modelStudioAPIKeyAccount)
    }

    func readModelStudioAPIKey() throws -> String? {
        try readCredential(account: modelStudioAPIKeyAccount)
    }

    func deleteModelStudioAPIKey() throws {
        try deleteCredential(account: modelStudioAPIKeyAccount)
    }

    private func saveCredential(_ key: String, account: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.conversionFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.invalidStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.invalidStatus(status)
        }
    }

    private func readCredential(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return nil
            }
            throw KeychainError.invalidStatus(status)
        }

        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.conversionFailed
        }

        return key
    }

    private func deleteCredential(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.invalidStatus(status)
        }
    }
}
