import XCTest
import Crypto
@testable import OmertaCore

final class IdentityTests: XCTestCase {

    // MARK: - PeerIdentity Tests

    func testIdentityGeneration() throws {
        let (keypair, mnemonic) = IdentityKeypair.generate()

        // Verify we got a 12-word mnemonic
        XCTAssertEqual(mnemonic.count, 12)

        // Verify peerId matches publicKey
        XCTAssertTrue(keypair.identity.isValid)

        // Verify peerId is 16 hex characters
        XCTAssertEqual(keypair.identity.peerId.count, 16)
        XCTAssertTrue(keypair.identity.peerId.allSatisfy { $0.isHexDigit })
    }

    func testIdentityValidation() throws {
        let (keypair, _) = IdentityKeypair.generate()

        // Valid identity should pass
        XCTAssertTrue(keypair.identity.isValid)

        // Tampered identity should fail
        let tampered = PeerIdentity(
            peerId: "0000000000000000",  // Wrong peerId
            publicKey: keypair.identity.publicKey
        )
        XCTAssertFalse(tampered.isValid)
    }

    func testPeerIdDerivation() throws {
        // Generate a keypair
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation

        // Derive peer ID
        let peerId = PeerIdentity.deriveId(from: publicKeyData)

        // Verify it's consistent
        let peerId2 = PeerIdentity.deriveId(from: publicKeyData)
        XCTAssertEqual(peerId, peerId2)

        // Verify length
        XCTAssertEqual(peerId.count, 16)
    }

    // MARK: - BIP39 Tests

    func testBIP39MnemonicGeneration() throws {
        // 128 bits = 12 words
        let entropy = Data(repeating: 0, count: 16)
        let mnemonic = BIP39.mnemonic(from: entropy)
        XCTAssertEqual(mnemonic.count, 12)
    }

    func testBIP39Derivation() throws {
        let (keypair1, mnemonic) = IdentityKeypair.generate()

        // Derive again from same mnemonic
        let keypair2 = try IdentityKeypair.derive(from: mnemonic)

        // Should produce same identity
        XCTAssertEqual(keypair1.identity.peerId, keypair2.identity.peerId)
        XCTAssertEqual(keypair1.identity.publicKey, keypair2.identity.publicKey)
        XCTAssertEqual(keypair1.privateKey, keypair2.privateKey)
    }

    func testBIP39Validation() throws {
        let (_, mnemonic) = IdentityKeypair.generate()

        // Valid mnemonic should pass
        XCTAssertTrue(BIP39.isValid(mnemonic))

        // Invalid mnemonic should fail
        var invalidMnemonic = mnemonic
        invalidMnemonic[0] = "notaword"
        XCTAssertFalse(BIP39.isValid(invalidMnemonic))

        // Wrong checksum should fail
        var wrongChecksum = mnemonic
        wrongChecksum[11] = mnemonic[0]  // Replace last word
        XCTAssertFalse(BIP39.isValid(wrongChecksum))
    }

    func testBIP39EntropyRoundtrip() throws {
        let originalEntropy = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let mnemonic = BIP39.mnemonic(from: originalEntropy)
        let recoveredEntropy = try BIP39.entropy(from: mnemonic)

        XCTAssertEqual(originalEntropy, recoveredEntropy)
    }

    // MARK: - Signature Tests

    func testSignatureVerification() throws {
        let (keypair, _) = IdentityKeypair.generate()
        let message = "Hello, World!".data(using: .utf8)!

        // Sign the message
        let signature = try keypair.sign(message)

        // Verify with public key
        XCTAssertTrue(keypair.identity.verify(signature: signature, for: message))
    }

    func testSignatureTampering() throws {
        let (keypair, _) = IdentityKeypair.generate()
        let message = "Hello, World!".data(using: .utf8)!

        // Sign the message
        let signature = try keypair.sign(message)

        // Tampered message should fail verification
        let tamperedMessage = "Hello, World?".data(using: .utf8)!
        XCTAssertFalse(keypair.identity.verify(signature: signature, for: tamperedMessage))

        // Tampered signature should fail verification
        var tamperedSignature = signature
        tamperedSignature[0] ^= 0xFF
        XCTAssertFalse(keypair.identity.verify(signature: tamperedSignature, for: message))
    }

    func testCrossKeypairSignatureRejection() throws {
        let (keypair1, _) = IdentityKeypair.generate()
        let (keypair2, _) = IdentityKeypair.generate()
        let message = "Hello, World!".data(using: .utf8)!

        // Sign with keypair1
        let signature = try keypair1.sign(message)

        // Should verify with keypair1's identity
        XCTAssertTrue(keypair1.identity.verify(signature: signature, for: message))

        // Should NOT verify with keypair2's identity
        XCTAssertFalse(keypair2.identity.verify(signature: signature, for: message))
    }

    // MARK: - Recovery Phrase Tests

    func testRecoveryPhraseExport() throws {
        let (keypair, originalMnemonic) = IdentityKeypair.generate()

        // Should be able to retrieve recovery phrase
        let recoveredMnemonic = keypair.recoveryPhrase()
        XCTAssertNotNil(recoveredMnemonic)
        XCTAssertEqual(recoveredMnemonic, originalMnemonic)
    }

    func testNoRecoveryPhraseForRawKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let keypair = try IdentityKeypair.fromPrivateKey(privateKey.rawRepresentation)

        // Should not have recovery phrase
        XCTAssertNil(keypair.recoveryPhrase())
        XCTAssertFalse(keypair.hasRecoveryPhrase)
    }

    // MARK: - Export/Import Tests

    func testExportImport() async throws {
        let (keypair, _) = IdentityKeypair.generate()
        let store = IdentityStore()
        let password = "test-password-123"

        // Export
        let encrypted = try await store.export(keypair: keypair, password: password)

        // Import
        let imported = try await store.importFrom(data: encrypted, password: password)

        // Should match
        XCTAssertEqual(imported.identity.peerId, keypair.identity.peerId)
        XCTAssertEqual(imported.privateKey, keypair.privateKey)
    }

    func testExportImportWrongPassword() async throws {
        let (keypair, _) = IdentityKeypair.generate()
        let store = IdentityStore()

        // Export with one password
        let encrypted = try await store.export(keypair: keypair, password: "correct-password")

        // Import with wrong password should fail
        do {
            _ = try await store.importFrom(data: encrypted, password: "wrong-password")
            XCTFail("Should have thrown an error")
        } catch {
            // Expected
        }
    }

    // MARK: - Transfer Code Tests

    func testTransferCodeGeneration() {
        let code = TransferSession.generateCode()

        // Should be in format "XXX-XXX"
        XCTAssertEqual(code.count, 7)
        XCTAssertTrue(code.contains("-"))

        let parts = code.split(separator: "-")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].count, 3)
        XCTAssertEqual(parts[1].count, 3)
    }

    func testTransferSessionExpiry() {
        let expired = TransferSession(
            id: "test",
            code: "123-456",
            newDevicePublicKey: Data(),
            expiresAt: Date().addingTimeInterval(-60),  // 1 minute ago
            state: .pending
        )
        XCTAssertTrue(expired.isExpired)

        let valid = TransferSession(
            id: "test",
            code: "123-456",
            newDevicePublicKey: Data(),
            expiresAt: Date().addingTimeInterval(300),  // 5 minutes from now
            state: .pending
        )
        XCTAssertFalse(valid.isExpired)
    }

    // MARK: - Keychain Provider Tests

    func testKeychainProviderAvailability() {
        let providers = IdentityStore.availableProviders()

        // File should always be available
        XCTAssertTrue(providers.contains(.file))

        // System keychain is only available on Apple platforms
        #if os(macOS) || os(iOS)
        XCTAssertTrue(providers.contains(.system))
        #endif
    }
}
