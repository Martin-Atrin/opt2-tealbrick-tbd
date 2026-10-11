import Foundation
import Security

/// Minimal secret storage. Values never leave this process except to the model endpoint.
public protocol TBDSecretStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ value: String, for key: String) throws
    func remove(_ key: String) throws
}

public struct TBDSecretStoreError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? { "Keychain error \(status)" }
}

/// Generic-password Keychain items, this device only, available when unlocked.
public struct TBDKeychainStore: TBDSecretStore {
    public let service: String
    public init(service: String) { self.service = service }

    private func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func get(_ key: String) throws -> String? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw TBDSecretStoreError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(base(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw TBDSecretStoreError(status: update) }
        var add = base(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw TBDSecretStoreError(status: status) }
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(base(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TBDSecretStoreError(status: status) }
    }
}

/// In-memory store for tests.
public final class TBDMemorySecretStore: TBDSecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(_ key: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ value: String, for key: String) throws { lock.lock(); values[key] = value; lock.unlock() }
    public func remove(_ key: String) throws { lock.lock(); values[key] = nil; lock.unlock() }
}
