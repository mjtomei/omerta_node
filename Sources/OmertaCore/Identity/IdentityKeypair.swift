import Foundation
import Crypto

/// Full identity including private key (NEVER shared)
public struct IdentityKeypair: Codable, Sendable {
    public let identity: PeerIdentity
    public let privateKey: Data  // 32 bytes

    /// BIP-39 entropy if created from mnemonic (enables recovery phrase export)
    public let bip39Entropy: Data?

    /// When this identity was created
    public let createdAt: Date

    public init(identity: PeerIdentity, privateKey: Data, bip39Entropy: Data? = nil, createdAt: Date = Date()) {
        self.identity = identity
        self.privateKey = privateKey
        self.bip39Entropy = bip39Entropy
        self.createdAt = createdAt
    }

    /// Generate new random identity with BIP-39 recovery phrase
    public static func generate() -> (keypair: IdentityKeypair, mnemonic: [String]) {
        // Generate 128 bits of entropy (12-word mnemonic)
        var entropy = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        let mnemonic = BIP39.mnemonic(from: entropy)
        let keypair = try! derive(from: mnemonic)
        return (keypair, mnemonic)
    }

    /// Derive identity from BIP-39 mnemonic (for recovery or crypto wallet compatibility)
    public static func derive(from mnemonic: [String]) throws -> IdentityKeypair {
        let entropy = try BIP39.entropy(from: mnemonic)
        let seed = BIP39.seed(from: mnemonic)

        // Derive at Omerta's HD path: m/44'/0'/0'/0/0
        // Using first 32 bytes of seed for simplicity (proper BIP32 would do full derivation)
        let derivedKey = BIP32.derive(seed: seed, path: "m/44'/0'/0'/0/0")
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: derivedKey.prefix(32))

        let publicKeyData = privateKey.publicKey.rawRepresentation
        let peerIdentity = PeerIdentity.from(publicKeyData: publicKeyData)

        return IdentityKeypair(
            identity: peerIdentity,
            privateKey: Data(privateKey.rawRepresentation),
            bip39Entropy: entropy,
            createdAt: Date()
        )
    }

    /// Create identity from raw private key (no recovery phrase)
    public static func fromPrivateKey(_ privateKeyData: Data) throws -> IdentityKeypair {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let peerIdentity = PeerIdentity.from(publicKeyData: publicKeyData)

        return IdentityKeypair(
            identity: peerIdentity,
            privateKey: Data(privateKey.rawRepresentation),
            bip39Entropy: nil,
            createdAt: Date()
        )
    }

    /// Sign data to prove ownership of this identity
    public func sign(_ data: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return Data(try key.signature(for: data))
    }

    /// Get recovery phrase (only if created from BIP-39)
    public func recoveryPhrase() -> [String]? {
        guard let entropy = bip39Entropy else { return nil }
        return BIP39.mnemonic(from: entropy)
    }

    /// Check if this keypair has a recovery phrase
    public var hasRecoveryPhrase: Bool {
        bip39Entropy != nil
    }

    /// Get the Curve25519 signing private key
    public func signingKey() throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
    }

    /// Get a key agreement private key (for encryption/key exchange)
    public func keyAgreementKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        // Derive key agreement key from signing key using HKDF
        let hkdf = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: privateKey),
            salt: "omerta-key-agreement".data(using: .utf8)!,
            info: Data(),
            outputByteCount: 32
        )
        return try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hkdf.withUnsafeBytes { Data($0) }
        )
    }
}
