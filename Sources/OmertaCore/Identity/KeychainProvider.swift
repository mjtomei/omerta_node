import Foundation

#if os(macOS) || os(iOS)
import Security

/// Low-level keychain operations for identity storage (Apple platforms only)
public struct KeychainProvider: Sendable {
    private let service: String
    private let accessGroup: String?
    private let synchronizable: Bool

    public init(
        service: String = "io.omerta.identity",
        accessGroup: String? = nil,
        synchronizable: Bool = false
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    /// Save data to keychain
    public func save(key: String, data: Data) throws {
        var query = baseQuery(key: key)
        query[kSecValueData as String] = data

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load data from keychain
    public func load(key: String) throws -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.loadFailed(status)
        }
    }

    /// Delete data from keychain
    public func delete(key: String) throws {
        let query = baseQuery(key: key)
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Check if key exists in keychain
    public func exists(key: String) -> Bool {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = false

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// List all keys in this service
    public func allKeys() throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        if synchronizable {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else { return [] }
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.loadFailed(status)
        }
    }

    // MARK: - Private

    private func baseQuery(key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
        }

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }
}

/// iCloud Keychain provider (synchronizable)
public struct ICloudKeychainProvider: Sendable {
    private let provider: KeychainProvider

    public init(service: String = "io.omerta.identity", accessGroup: String? = nil) {
        self.provider = KeychainProvider(
            service: service,
            accessGroup: accessGroup,
            synchronizable: true
        )
    }

    public func save(key: String, data: Data) throws {
        try provider.save(key: key, data: data)
    }

    public func load(key: String) throws -> Data? {
        try provider.load(key: key)
    }

    public func delete(key: String) throws {
        try provider.delete(key: key)
    }

    /// Check if iCloud is available
    public static var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }
}

#else

/// Stub keychain provider for non-Apple platforms
/// On Linux, use file-based storage instead
public struct KeychainProvider: Sendable {
    public init(
        service: String = "io.omerta.identity",
        accessGroup: String? = nil,
        synchronizable: Bool = false
    ) {}

    public func save(key: String, data: Data) throws {
        throw KeychainError.notAvailable
    }

    public func load(key: String) throws -> Data? {
        throw KeychainError.notAvailable
    }

    public func delete(key: String) throws {
        throw KeychainError.notAvailable
    }

    public func exists(key: String) -> Bool {
        false
    }

    public func allKeys() throws -> [String] {
        throw KeychainError.notAvailable
    }
}

/// Stub iCloud keychain provider for non-Apple platforms
public struct ICloudKeychainProvider: Sendable {
    public init(service: String = "io.omerta.identity", accessGroup: String? = nil) {}

    public func save(key: String, data: Data) throws {
        throw KeychainError.notAvailable
    }

    public func load(key: String) throws -> Data? {
        throw KeychainError.notAvailable
    }

    public func delete(key: String) throws {
        throw KeychainError.notAvailable
    }

    public static var isAvailable: Bool { false }
}

#endif

/// Keychain-specific errors
public enum KeychainError: Error, Sendable {
    case saveFailed(Int32)
    case loadFailed(Int32)
    case deleteFailed(Int32)
    case dataConversionFailed
    case notAvailable

    public var localizedDescription: String {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed with status: \(status)"
        case .loadFailed(let status):
            return "Keychain load failed with status: \(status)"
        case .deleteFailed(let status):
            return "Keychain delete failed with status: \(status)"
        case .dataConversionFailed:
            return "Failed to convert data for keychain storage"
        case .notAvailable:
            return "Keychain is not available on this platform"
        }
    }
}
