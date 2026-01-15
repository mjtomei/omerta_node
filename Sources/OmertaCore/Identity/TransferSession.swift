import Foundation
import Crypto

/// A device-to-device transfer session
public struct TransferSession: Codable, Sendable {
    /// Unique session identifier
    public let id: String

    /// 6-digit code displayed to user (e.g., "847-293")
    public let code: String

    /// New device's ephemeral public key for encryption
    public let newDevicePublicKey: Data

    /// When this session expires (typically 5 minutes)
    public let expiresAt: Date

    /// Session state
    public let state: TransferState

    public init(
        id: String,
        code: String,
        newDevicePublicKey: Data,
        expiresAt: Date,
        state: TransferState = .pending
    ) {
        self.id = id
        self.code = code
        self.newDevicePublicKey = newDevicePublicKey
        self.expiresAt = expiresAt
        self.state = state
    }

    /// Check if session has expired
    public var isExpired: Bool {
        Date() > expiresAt
    }

    /// Generate a new 6-digit transfer code
    public static func generateCode() -> String {
        let first = Int.random(in: 100...999)
        let second = Int.random(in: 100...999)
        return "\(first)-\(second)"
    }
}

/// Transfer session state
public enum TransferState: String, Codable, Sendable {
    case pending      // Waiting for approval
    case approved     // Approved, identity being transferred
    case completed    // Transfer successful
    case denied       // Transfer denied by existing device
    case expired      // Session timed out
}

/// Encrypted identity for transfer
public struct EncryptedTransfer: Codable, Sendable {
    /// Sender's ephemeral public key
    public let senderPublicKey: Data

    /// Encrypted identity data
    public let ciphertext: Data

    /// Nonce used for encryption
    public let nonce: Data

    public init(senderPublicKey: Data, ciphertext: Data, nonce: Data) {
        self.senderPublicKey = senderPublicKey
        self.ciphertext = ciphertext
        self.nonce = nonce
    }
}

/// Device transfer coordinator
public actor DeviceTransfer {
    private let identityCloud: IdentityCloudClient

    public init(identityCloud: IdentityCloudClient) {
        self.identityCloud = identityCloud
    }

    /// Request transfer on NEW device
    /// Returns the code to display and a function to wait for the identity
    public func requestTransfer(
        session: AuthSession
    ) async throws -> (code: String, waitForIdentity: () async throws -> IdentityKeypair) {
        // Generate ephemeral keypair for this transfer
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        // Create transfer session on control plane
        let transfer = try await identityCloud.createTransferSession(
            publicKey: ephemeral.publicKey.rawRepresentation,
            session: session
        )

        return (
            code: transfer.code,
            waitForIdentity: { [identityCloud] in
                // Poll for encrypted identity
                while Date() < transfer.expiresAt {
                    if let encrypted = try await identityCloud.getTransferResult(sessionId: transfer.id) {
                        // Decrypt with ephemeral private key
                        let senderPublicKey = try Curve25519.KeyAgreement.PublicKey(
                            rawRepresentation: encrypted.senderPublicKey
                        )
                        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: senderPublicKey)

                        // Derive symmetric key
                        let key = shared.hkdfDerivedSymmetricKey(
                            using: SHA256.self,
                            salt: "omerta-transfer".data(using: .utf8)!,
                            sharedInfo: Data(),
                            outputByteCount: 32
                        )

                        // Decrypt identity
                        let box = try ChaChaPoly.SealedBox(
                            nonce: ChaChaPoly.Nonce(data: encrypted.nonce),
                            ciphertext: encrypted.ciphertext.dropLast(16),
                            tag: encrypted.ciphertext.suffix(16)
                        )
                        let plaintext = try ChaChaPoly.open(box, using: key)

                        return try JSONDecoder().decode(IdentityKeypair.self, from: plaintext)
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                throw IdentityError.transferExpired
            }
        )
    }

    /// Approve transfer on EXISTING device
    public func approveTransfer(
        code: String,
        identity: IdentityKeypair,
        session: AuthSession
    ) async throws {
        // Look up transfer session by code
        let transfer = try await identityCloud.getTransferSession(code: code)

        guard !transfer.isExpired else {
            throw IdentityError.transferExpired
        }

        // Generate ephemeral keypair for encryption
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        // Derive shared secret with new device's public key
        let newDevicePublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: transfer.newDevicePublicKey
        )
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: newDevicePublicKey)

        // Derive symmetric key
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "omerta-transfer".data(using: .utf8)!,
            sharedInfo: Data(),
            outputByteCount: 32
        )

        // Encrypt identity
        let plaintext = try JSONEncoder().encode(identity)
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key)

        // Upload encrypted identity
        let encrypted = EncryptedTransfer(
            senderPublicKey: ephemeral.publicKey.rawRepresentation,
            ciphertext: sealedBox.ciphertext + sealedBox.tag,
            nonce: Data(sealedBox.nonce)
        )

        try await identityCloud.completeTransfer(
            sessionId: transfer.id,
            encryptedIdentity: encrypted
        )
    }

    /// Deny a transfer request
    public func denyTransfer(code: String, session: AuthSession) async throws {
        let transfer = try await identityCloud.getTransferSession(code: code)
        try await identityCloud.denyTransfer(sessionId: transfer.id)
    }
}
