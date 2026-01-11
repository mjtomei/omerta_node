import Foundation
import Crypto

/// A peer's cryptographic identity (public info, safe to share)
public struct PeerIdentity: Codable, Hashable, Sendable {
    /// 16-character hex string derived from public key (first 8 bytes of SHA256)
    public let peerId: String

    /// Curve25519 public key (32 bytes, base64 encoded)
    public let publicKey: String

    public init(peerId: String, publicKey: String) {
        self.peerId = peerId
        self.publicKey = publicKey
    }

    /// Verify that peerId matches publicKey (prevents impersonation)
    public var isValid: Bool {
        guard let keyData = Data(base64Encoded: publicKey) else { return false }
        let hash = SHA256.hash(data: keyData)
        let expected = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return peerId == expected
    }

    /// Derive peer ID from a public key
    public static func deriveId(from publicKeyData: Data) -> String {
        let hash = SHA256.hash(data: publicKeyData)
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Create identity from raw public key data
    public static func from(publicKeyData: Data) -> PeerIdentity {
        let peerId = deriveId(from: publicKeyData)
        let publicKey = publicKeyData.base64EncodedString()
        return PeerIdentity(peerId: peerId, publicKey: publicKey)
    }

    /// Get raw public key bytes
    public var publicKeyData: Data? {
        Data(base64Encoded: publicKey)
    }

    /// Verify a signature against this identity
    public func verify(signature: Data, for data: Data) -> Bool {
        guard let keyData = publicKeyData else { return false }
        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            return publicKey.isValidSignature(signature, for: data)
        } catch {
            return false
        }
    }
}

/// Errors related to identity operations
public enum IdentityError: Error, Sendable {
    case invalidPublicKey
    case invalidPrivateKey
    case invalidMnemonic
    case invalidChecksum
    case mnemonicTooShort
    case mnemonicTooLong
    case wordNotInWordlist(String)
    case keychainError(String)
    case fileRequiresExplicitPath
    case exportFailed(String)
    case importFailed(String)
    case decryptionFailed
    case transferExpired
    case transferNotFound
    case noIdentityFound
    case providerNotAvailable(String)
}

extension IdentityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return "Invalid public key format"
        case .invalidPrivateKey:
            return "Invalid private key format"
        case .invalidMnemonic:
            return "Invalid recovery phrase"
        case .invalidChecksum:
            return "Recovery phrase checksum failed"
        case .mnemonicTooShort:
            return "Recovery phrase is too short"
        case .mnemonicTooLong:
            return "Recovery phrase is too long"
        case .wordNotInWordlist(let word):
            return "Word '\(word)' is not in the BIP-39 wordlist"
        case .keychainError(let message):
            return "Keychain error: \(message)"
        case .fileRequiresExplicitPath:
            return "File storage requires an explicit path"
        case .exportFailed(let message):
            return "Export failed: \(message)"
        case .importFailed(let message):
            return "Import failed: \(message)"
        case .decryptionFailed:
            return "Failed to decrypt identity"
        case .transferExpired:
            return "Transfer session expired"
        case .transferNotFound:
            return "Transfer session not found"
        case .noIdentityFound:
            return "No identity found"
        case .providerNotAvailable(let name):
            return "Provider '\(name)' is not available"
        }
    }
}
