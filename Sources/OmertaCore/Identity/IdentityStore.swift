import Foundation
import Crypto

#if os(macOS) || os(iOS)
import Security
#endif

/// Where identity can be stored
public enum StorageProvider: String, Codable, Sendable {
    case system              // Local system keychain (macOS/iOS) or file (Linux)
    case iCloud              // iCloud Keychain (Apple, auto-sync)
    case onePassword         // 1Password (cross-platform)
    case bitwarden           // Bitwarden (cross-platform)
    case file                // Encrypted file
}

/// Identity storage with multi-backend support
public actor IdentityStore {
    private var provider: StorageProvider
    private let keychainService = "io.omerta.identity"

    /// Initialize with preferred provider
    public init(provider: StorageProvider = .system) {
        self.provider = provider
    }

    /// Load existing identity from any available source
    public func load() async throws -> IdentityKeypair? {
        // Try providers in order of preference
        for source in [provider, .iCloud, .system, .onePassword, .bitwarden] {
            if let identity = try? await loadFrom(source) {
                return identity
            }
        }
        return nil
    }

    /// Load from a specific provider
    public func loadFrom(_ source: StorageProvider) async throws -> IdentityKeypair? {
        switch source {
        case .system:
            #if os(macOS) || os(iOS)
            return try await loadFromKeychain(synchronizable: false)
            #else
            throw IdentityError.providerNotAvailable("Keychain not available on Linux")
            #endif
        case .iCloud:
            #if os(macOS) || os(iOS)
            return try await loadFromKeychain(synchronizable: true)
            #else
            throw IdentityError.providerNotAvailable("iCloud not available on Linux")
            #endif
        case .onePassword:
            return try await loadFromOnePassword()
        case .bitwarden:
            return try await loadFromBitwarden()
        case .file:
            throw IdentityError.fileRequiresExplicitPath
        }
    }

    /// Save identity to configured provider
    public func save(_ keypair: IdentityKeypair) async throws {
        switch provider {
        case .iCloud:
            #if os(macOS) || os(iOS)
            try await saveToKeychain(keypair, synchronizable: true)
            #else
            throw IdentityError.providerNotAvailable("iCloud not available on Linux")
            #endif
        case .system:
            #if os(macOS) || os(iOS)
            try await saveToKeychain(keypair, synchronizable: false)
            #else
            throw IdentityError.providerNotAvailable("Keychain not available on Linux")
            #endif
        case .onePassword:
            try await saveToOnePassword(keypair)
        case .bitwarden:
            try await saveToBitwarden(keypair)
        case .file:
            throw IdentityError.fileRequiresExplicitPath
        }
    }

    /// Delete identity from current provider
    public func delete() async throws {
        switch provider {
        case .iCloud:
            #if os(macOS) || os(iOS)
            try await deleteFromKeychain(synchronizable: true)
            #else
            throw IdentityError.providerNotAvailable("iCloud not available on Linux")
            #endif
        case .system:
            #if os(macOS) || os(iOS)
            try await deleteFromKeychain(synchronizable: false)
            #else
            throw IdentityError.providerNotAvailable("Keychain not available on Linux")
            #endif
        case .onePassword:
            try await deleteFromOnePassword()
        case .bitwarden:
            try await deleteFromBitwarden()
        case .file:
            throw IdentityError.fileRequiresExplicitPath
        }
    }

    /// Export identity encrypted with password
    public func export(keypair: IdentityKeypair, password: String) throws -> Data {
        // Generate salt for key derivation
        var salt = Data(count: 16)
        for i in 0..<16 {
            salt[i] = UInt8.random(in: 0...255)
        }

        // Derive key using HKDF (simplified - production should use Argon2id)
        let passwordData = password.data(using: .utf8)!
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: passwordData),
            salt: salt,
            info: "omerta-identity-export".data(using: .utf8)!,
            outputByteCount: 32
        )

        // Encode keypair
        let plaintext = try JSONEncoder().encode(keypair)

        // Encrypt with ChaCha20-Poly1305
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key)

        // Return salt + ciphertext
        return salt + sealedBox.combined
    }

    /// Import identity from encrypted file
    public func importFrom(data: Data, password: String) throws -> IdentityKeypair {
        guard data.count > 16 else {
            throw IdentityError.importFailed("Data too short")
        }

        let salt = data.prefix(16)
        let ciphertext = data.dropFirst(16)

        // Derive key
        let passwordData = password.data(using: .utf8)!
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: passwordData),
            salt: salt,
            info: "omerta-identity-export".data(using: .utf8)!,
            outputByteCount: 32
        )

        // Decrypt
        let box = try ChaChaPoly.SealedBox(combined: ciphertext)
        let plaintext = try ChaChaPoly.open(box, using: key)

        return try JSONDecoder().decode(IdentityKeypair.self, from: plaintext)
    }

    /// Save to encrypted file
    public func saveToFile(_ keypair: IdentityKeypair, path: URL, password: String) throws {
        let encrypted = try export(keypair: keypair, password: password)
        try encrypted.write(to: path)
    }

    /// Load from encrypted file
    public func loadFromFile(path: URL, password: String) throws -> IdentityKeypair {
        let data = try Data(contentsOf: path)
        return try importFrom(data: data, password: password)
    }

    /// Detect available storage providers
    public static func availableProviders() -> [StorageProvider] {
        var available: [StorageProvider] = [.file]

        #if os(macOS) || os(iOS)
        available.append(.system)
        if FileManager.default.ubiquityIdentityToken != nil {
            available.append(.iCloud)
        }
        #endif

        // Check for 1Password CLI
        if (try? ProcessRunner.run(command: "/usr/bin/which", arguments: ["op"]))?.exitCode == 0 {
            available.append(.onePassword)
        }

        // Check for Bitwarden CLI
        if (try? ProcessRunner.run(command: "/usr/bin/which", arguments: ["bw"]))?.exitCode == 0 {
            available.append(.bitwarden)
        }

        return available
    }

    // MARK: - Keychain Implementation (Apple platforms only)

    #if os(macOS) || os(iOS)
    private func saveToKeychain(_ keypair: IdentityKeypair, synchronizable: Bool) async throws {
        let data = try JSONEncoder().encode(keypair)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keypair.identity.peerId,
            kSecValueData as String: data,
        ]

        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
        }

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IdentityError.keychainError("Failed to save: \(status)")
        }
    }

    private func loadFromKeychain(synchronizable: Bool) async throws -> IdentityKeypair? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try JSONDecoder().decode(IdentityKeypair.self, from: data)
    }

    private func deleteFromKeychain(synchronizable: Bool) async throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]

        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityError.keychainError("Failed to delete: \(status)")
        }
    }
    #endif

    // MARK: - 1Password Implementation

    private func saveToOnePassword(_ keypair: IdentityKeypair) async throws {
        let data = try JSONEncoder().encode(keypair)
        let base64 = data.base64EncodedString()

        let result = try ProcessRunner.run(
            command: "/usr/bin/env",
            arguments: ["op", "item", "create",
                       "--category", "password",
                       "--title", "Omerta Identity",
                       "--vault", "Personal",
                       "password=\(base64)"]
        )

        guard result.exitCode == 0 else {
            throw IdentityError.providerNotAvailable("1Password: \(result.stderr)")
        }
    }

    private func loadFromOnePassword() async throws -> IdentityKeypair? {
        let result = try ProcessRunner.run(
            command: "/usr/bin/env",
            arguments: ["op", "item", "get", "Omerta Identity",
                       "--vault", "Personal",
                       "--fields", "password"]
        )

        guard result.exitCode == 0 else { return nil }

        let base64 = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: base64) else { return nil }

        return try JSONDecoder().decode(IdentityKeypair.self, from: data)
    }

    private func deleteFromOnePassword() async throws {
        _ = try ProcessRunner.run(
            command: "/usr/bin/env",
            arguments: ["op", "item", "delete", "Omerta Identity",
                       "--vault", "Personal"]
        )
    }

    // MARK: - Bitwarden Implementation

    private func saveToBitwarden(_ keypair: IdentityKeypair) async throws {
        let data = try JSONEncoder().encode(keypair)
        let base64 = data.base64EncodedString()

        // Create item JSON
        let itemJson = """
        {"type":1,"name":"Omerta Identity","notes":"\(base64)","login":{}}
        """

        let result = try ProcessRunner.run(
            command: "/usr/bin/env",
            arguments: ["bw", "create", "item",
                       itemJson.data(using: .utf8)!.base64EncodedString()]
        )

        guard result.exitCode == 0 else {
            throw IdentityError.providerNotAvailable("Bitwarden: \(result.stderr)")
        }
    }

    private func loadFromBitwarden() async throws -> IdentityKeypair? {
        let result = try ProcessRunner.run(
            command: "/usr/bin/env",
            arguments: ["bw", "get", "item", "Omerta Identity"]
        )

        guard result.exitCode == 0 else { return nil }

        // Parse JSON response to get notes field
        guard let jsonData = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let notes = json["notes"] as? String,
              let data = Data(base64Encoded: notes) else {
            return nil
        }

        return try JSONDecoder().decode(IdentityKeypair.self, from: data)
    }

    private func deleteFromBitwarden() async throws {
        // Get item ID first
        let getResult = try ProcessRunner.run(
            command: "/usr/bin/env",
            arguments: ["bw", "get", "item", "Omerta Identity"]
        )

        guard getResult.exitCode == 0,
              let jsonData = getResult.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let itemId = json["id"] as? String else {
            return
        }

        _ = try ProcessRunner.run(
            command: "/usr/bin/env",
            arguments: ["bw", "delete", "item", itemId]
        )
    }
}
