import Foundation
import Security

enum KeychainService {
    private static let sshService = "warp-ios-ssh-keys"
    private static let sshPasswordService = "warp-ios-ssh-passwords"

    static func saveKey(_ pem: String, tag: String) throws {
        let data = Data(pem.utf8)
        try saveData(data, account: tag, service: sshService)
    }

    static func loadKey(tag: String) throws -> String {
        let data = try loadData(account: tag, service: sshService)
        guard let pem = String(data: data, encoding: .utf8) else {
            throw KeychainError.notFound
        }
        return pem
    }

    static func deleteKey(tag: String) {
        deleteData(account: tag, service: sshService)
    }

    static func savePassword(_ password: String, hostID: UUID) throws {
        let data = Data(password.utf8)
        let account = "ssh-password-\(hostID.uuidString.lowercased())"
        try saveData(data, account: account, service: sshPasswordService)
    }

    static func loadPassword(hostID: UUID) throws -> String {
        let account = "ssh-password-\(hostID.uuidString.lowercased())"
        let data = try loadData(account: account, service: sshPasswordService)
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.notFound
        }
        return password
    }

    static func deletePassword(hostID: UUID) {
        let account = "ssh-password-\(hostID.uuidString.lowercased())"
        deleteData(account: account, service: sshPasswordService)
    }

    static func saveData(_ data: Data, account: String, service: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func loadData(account: String, service: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data
        else { throw KeychainError.notFound }
        return data
    }

    static func deleteData(account: String, service: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case notFound
    }
}
