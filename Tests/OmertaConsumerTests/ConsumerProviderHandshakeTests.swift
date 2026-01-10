// ConsumerProviderHandshakeTests.swift
// Phase 1: Consumer-Provider Handshake Protocol Tests

import XCTest
import Crypto
@testable import OmertaConsumer
@testable import OmertaCore

/// Tests for the consumer-provider handshake protocol
/// Covers message envelope format, encryption/decryption, and message structure
final class ConsumerProviderHandshakeTests: XCTestCase {

    /// Generate a valid 32-byte network key for testing
    private func generateTestNetworkKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }

    // MARK: - Message Envelope Tests

    func testMessageEnvelopeSerializeRoundTrip() {
        // Given: A message envelope
        let networkId = "test-network-123"
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        let envelope = MessageEnvelope(networkId: networkId, encryptedPayload: payload)

        // When: We serialize and parse
        let serialized = envelope.serialize()
        let parsed = MessageEnvelope.parse(serialized)

        // Then: Data matches
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.networkId, networkId)
        XCTAssertEqual(parsed?.encryptedPayload, payload)
    }

    func testMessageEnvelopeFormat() {
        // Given: A simple envelope
        let networkId = "abc"
        let payload = Data([0x01, 0x02])
        let envelope = MessageEnvelope(networkId: networkId, encryptedPayload: payload)

        // When: We serialize
        let serialized = envelope.serialize()

        // Then: Format is [1 byte length][networkId bytes][payload]
        XCTAssertEqual(serialized.count, 1 + 3 + 2)  // 1 + "abc".count + payload.count
        XCTAssertEqual(serialized[0], 3)  // networkId length
        XCTAssertEqual(String(data: serialized[1..<4], encoding: .utf8), "abc")
        XCTAssertEqual(Array(serialized[4...]), [0x01, 0x02])
    }

    func testMessageEnvelopeTruncatesLongNetworkId() {
        // Given: A very long networkId (>255 chars)
        let longNetworkId = String(repeating: "a", count: 300)
        let payload = Data([0x01])
        let envelope = MessageEnvelope(networkId: longNetworkId, encryptedPayload: payload)

        // When: We serialize and parse
        let serialized = envelope.serialize()
        let parsed = MessageEnvelope.parse(serialized)

        // Then: NetworkId is truncated to 255 chars
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.networkId.count, 255)
    }

    func testMessageEnvelopeParseInvalidData() {
        // Given: Invalid data
        let emptyData = Data()
        let tooShort = Data([5])  // Says 5 bytes but no networkId follows

        // Then: Parse returns nil
        XCTAssertNil(MessageEnvelope.parse(emptyData))
        XCTAssertNil(MessageEnvelope.parse(tooShort))
    }

    func testMessageEnvelopeEmptyPayload() {
        // Given: An envelope with empty payload
        let envelope = MessageEnvelope(networkId: "test", encryptedPayload: Data())

        // When: We serialize and parse
        let parsed = MessageEnvelope.parse(envelope.serialize())

        // Then: It works
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.networkId, "test")
        XCTAssertEqual(parsed?.encryptedPayload.count, 0)
    }

    // MARK: - Control Message Tests

    func testControlMessageTimestamp() {
        // Given: A control message with default timestamp
        let message = ControlMessage(action: .queryVMStatus(VMStatusRequest()))

        // Then: Timestamp is close to now
        let now = UInt64(Date().timeIntervalSince1970)
        XCTAssertTrue(abs(Int64(message.timestamp) - Int64(now)) < 5,
                     "Timestamp should be close to current time")
    }

    func testControlMessageHasUniqueId() {
        // Given: Two control messages
        let msg1 = ControlMessage(action: .queryVMStatus(VMStatusRequest()))
        let msg2 = ControlMessage(action: .queryVMStatus(VMStatusRequest()))

        // Then: They have different IDs
        XCTAssertNotEqual(msg1.messageId, msg2.messageId)
    }

    func testControlMessageEncodesDecode() throws {
        // Given: A control message
        let vmId = UUID()
        let request = ReleaseVMMessage(vmId: vmId)
        let message = ControlMessage(
            messageId: UUID(),
            timestamp: 1234567890,
            action: .releaseVM(request)
        )

        // When: We encode and decode
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(message)
        let decoded = try decoder.decode(ControlMessage.self, from: data)

        // Then: Fields match
        XCTAssertEqual(decoded.messageId, message.messageId)
        XCTAssertEqual(decoded.timestamp, message.timestamp)
        if case .releaseVM(let decodedRequest) = decoded.action {
            XCTAssertEqual(decodedRequest.vmId, vmId)
        } else {
            XCTFail("Expected releaseVM action")
        }
    }

    // MARK: - RequestVM Message Tests

    func testRequestVMMessageFormat() throws {
        // Given: A RequestVM message with all fields
        let vmId = UUID()
        let requirements = ResourceRequirements(cpuCores: 4, memoryMB: 8192)
        let vpnConfig = VPNConfiguration(
            consumerPublicKey: "testPublicKey123==",
            consumerEndpoint: "192.168.1.100:51820",
            consumerVPNIP: "10.0.0.1",
            vmVPNIP: "10.0.0.2",
            vpnSubnet: "10.0.0.0/24"
        )

        let request = RequestVMMessage(
            vmId: vmId,
            requirements: requirements,
            vpnConfig: vpnConfig,
            consumerEndpoint: "192.168.1.100:51821",
            sshPublicKey: "ssh-ed25519 AAAA... test@example.com",
            sshUser: "testuser"
        )

        // When: We encode and decode
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(request)
        let decoded = try decoder.decode(RequestVMMessage.self, from: data)

        // Then: All fields are preserved
        XCTAssertEqual(decoded.vmId, vmId)
        XCTAssertEqual(decoded.requirements.cpuCores, 4)
        XCTAssertEqual(decoded.requirements.memoryMB, 8192)
        XCTAssertEqual(decoded.vpnConfig.consumerPublicKey, "testPublicKey123==")
        XCTAssertEqual(decoded.vpnConfig.consumerEndpoint, "192.168.1.100:51820")
        XCTAssertEqual(decoded.vpnConfig.vmVPNIP, "10.0.0.2")
        XCTAssertEqual(decoded.consumerEndpoint, "192.168.1.100:51821")
        XCTAssertEqual(decoded.sshPublicKey, "ssh-ed25519 AAAA... test@example.com")
        XCTAssertEqual(decoded.sshUser, "testuser")
    }

    func testRequestVMMessageDefaultSSHUser() throws {
        // Given: A request with default SSH user
        let request = RequestVMMessage(
            requirements: ResourceRequirements(),
            vpnConfig: VPNConfiguration(
                consumerPublicKey: "key",
                consumerEndpoint: "1.2.3.4:51820",
                consumerVPNIP: "10.0.0.1",
                vmVPNIP: "10.0.0.2",
                vpnSubnet: "10.0.0.0/24"
            ),
            consumerEndpoint: "1.2.3.4:51821",
            sshPublicKey: "ssh-ed25519 AAAA..."
        )

        // Then: Default user is "omerta"
        XCTAssertEqual(request.sshUser, "omerta")
    }

    // MARK: - VMCreatedResponse Tests

    func testVMCreatedResponseSuccessFormat() throws {
        // Given: A successful response
        let response = VMCreatedResponse(
            vmId: UUID(),
            vmIP: "10.0.0.2",
            sshPort: 22,
            providerPublicKey: "providerKey123=="
        )

        // Then: It's not an error
        XCTAssertFalse(response.isError)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.vmIP, "10.0.0.2")
        XCTAssertEqual(response.sshPort, 22)
    }

    func testVMCreatedResponseErrorFormat() throws {
        // Given: An error response
        let response = VMCreatedResponse(
            vmId: UUID(),
            vmIP: "",
            providerPublicKey: "",
            error: "Insufficient resources"
        )

        // Then: It's marked as error
        XCTAssertTrue(response.isError)
        XCTAssertEqual(response.error, "Insufficient resources")
    }

    func testVMCreatedResponseRequiredFields() throws {
        // Test that isError detects missing required fields
        let emptyIP = VMCreatedResponse(
            vmId: UUID(),
            vmIP: "",
            providerPublicKey: "key"
        )
        XCTAssertTrue(emptyIP.isError, "Empty vmIP should be an error")

        let emptyKey = VMCreatedResponse(
            vmId: UUID(),
            vmIP: "10.0.0.2",
            providerPublicKey: ""
        )
        XCTAssertTrue(emptyKey.isError, "Empty providerPublicKey should be an error")

        let valid = VMCreatedResponse(
            vmId: UUID(),
            vmIP: "10.0.0.2",
            providerPublicKey: "key"
        )
        XCTAssertFalse(valid.isError, "Valid response should not be an error")
    }

    // MARK: - ChaCha20-Poly1305 Encryption Tests

    func testChaChaPolyEncryptDecryptRoundTrip() throws {
        // Given: A message and key
        let key = SymmetricKey(data: generateTestNetworkKey())
        let plaintext = "Hello, World!".data(using: .utf8)!

        // When: We encrypt and decrypt
        let nonce = ChaChaPoly.Nonce()
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        let decrypted = try ChaChaPoly.open(sealedBox, using: key)

        // Then: Plaintext matches
        XCTAssertEqual(decrypted, plaintext)
    }

    func testChaChaPolyDifferentNoncesProduceDifferentCiphertext() throws {
        // Given: Same message, same key, different nonces
        let key = SymmetricKey(data: generateTestNetworkKey())
        let plaintext = "Same message".data(using: .utf8)!

        let nonce1 = ChaChaPoly.Nonce()
        let nonce2 = ChaChaPoly.Nonce()

        // When: We encrypt with different nonces
        let sealed1 = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce1)
        let sealed2 = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce2)

        // Then: Ciphertexts are different
        XCTAssertNotEqual(sealed1.combined, sealed2.combined)
    }

    func testChaChaPolyWrongKeyFails() throws {
        // Given: A message encrypted with key1
        let key1 = SymmetricKey(data: generateTestNetworkKey())
        let key2 = SymmetricKey(data: generateTestNetworkKey())
        let plaintext = "Secret message".data(using: .utf8)!

        let sealedBox = try ChaChaPoly.seal(plaintext, using: key1)

        // Then: Decryption with wrong key fails
        XCTAssertThrowsError(try ChaChaPoly.open(sealedBox, using: key2))
    }

    func testChaChaPolyTamperedCiphertextFails() throws {
        // Given: A valid sealed box
        let key = SymmetricKey(data: generateTestNetworkKey())
        let plaintext = "Integrity check".data(using: .utf8)!
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key)

        // When: We tamper with the ciphertext
        var tamperedData = sealedBox.combined
        tamperedData[tamperedData.count - 1] ^= 0xFF  // Flip bits in last byte (tag)

        // Then: Opening the tampered box fails authentication
        // (SealedBox(combined:) just parses the format, open() does auth)
        let tamperedBox = try ChaChaPoly.SealedBox(combined: tamperedData)
        XCTAssertThrowsError(try ChaChaPoly.open(tamperedBox, using: key)) { error in
            // Authentication failure expected
        }
    }

    // MARK: - Full Message Encryption Tests

    func testControlMessageEncryptDecrypt() throws {
        // Given: A control message and network key
        let networkKey = generateTestNetworkKey()
        let key = SymmetricKey(data: networkKey)

        let vmId = UUID()
        let message = ControlMessage(
            action: .vmCreated(VMCreatedResponse(
                vmId: vmId,
                vmIP: "10.0.0.2",
                providerPublicKey: "testKey123=="
            ))
        )

        // When: We encrypt
        let encoder = JSONEncoder()
        let plaintext = try encoder.encode(message)
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key)

        // And: Decrypt
        let decrypted = try ChaChaPoly.open(sealedBox, using: key)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ControlMessage.self, from: decrypted)

        // Then: Message matches
        XCTAssertEqual(decoded.messageId, message.messageId)
        if case .vmCreated(let response) = decoded.action {
            XCTAssertEqual(response.vmId, vmId)
            XCTAssertEqual(response.vmIP, "10.0.0.2")
        } else {
            XCTFail("Expected vmCreated action")
        }
    }

    // MARK: - VPN Configuration Tests

    func testVPNConfigurationContainsRequiredFields() {
        // Given: A VPN configuration
        let config = VPNConfiguration(
            consumerPublicKey: "publicKey123==",
            consumerEndpoint: "192.168.1.100:51820",
            consumerVPNIP: "10.0.0.1",
            vmVPNIP: "10.0.0.2",
            vpnSubnet: "10.0.0.0/24"
        )

        // Then: All required fields are present
        XCTAssertEqual(config.consumerPublicKey, "publicKey123==")
        XCTAssertEqual(config.consumerEndpoint, "192.168.1.100:51820")
        XCTAssertEqual(config.consumerVPNIP, "10.0.0.1")
        XCTAssertEqual(config.vmVPNIP, "10.0.0.2")
        XCTAssertEqual(config.vpnSubnet, "10.0.0.0/24")
    }

    func testVPNConfigurationEncodeDecode() throws {
        // Given: A VPN configuration
        let config = VPNConfiguration(
            consumerPublicKey: "publicKey123==",
            consumerEndpoint: "192.168.1.100:51820",
            consumerVPNIP: "10.0.0.1",
            vmVPNIP: "10.0.0.2",
            vpnSubnet: "10.0.0.0/24"
        )

        // When: We encode and decode
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(VPNConfiguration.self, from: data)

        // Then: All fields match
        XCTAssertEqual(decoded.consumerPublicKey, config.consumerPublicKey)
        XCTAssertEqual(decoded.consumerEndpoint, config.consumerEndpoint)
        XCTAssertEqual(decoded.consumerVPNIP, config.consumerVPNIP)
        XCTAssertEqual(decoded.vmVPNIP, config.vmVPNIP)
        XCTAssertEqual(decoded.vpnSubnet, config.vpnSubnet)
    }

    // MARK: - Action Enum Tests

    func testAllControlActionsEncodeDecode() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let actions: [ControlAction] = [
            .requestVM(RequestVMMessage(
                requirements: ResourceRequirements(),
                vpnConfig: VPNConfiguration(
                    consumerPublicKey: "k",
                    consumerEndpoint: "1.2.3.4:51820",
                    consumerVPNIP: "10.0.0.1",
                    vmVPNIP: "10.0.0.2",
                    vpnSubnet: "10.0.0.0/24"
                ),
                consumerEndpoint: "1.2.3.4:51821",
                sshPublicKey: "ssh-ed25519 AAA..."
            )),
            .releaseVM(ReleaseVMMessage(vmId: UUID())),
            .queryVMStatus(VMStatusRequest(vmId: nil)),
            .vmCreated(VMCreatedResponse(vmId: UUID(), vmIP: "10.0.0.2", providerPublicKey: "k")),
            .vmReleased(VMReleasedResponse(vmId: UUID())),
            .vmStatus(VMStatusResponse(vms: []))
        ]

        for action in actions {
            let message = ControlMessage(action: action)
            let data = try encoder.encode(message)
            let decoded = try decoder.decode(ControlMessage.self, from: data)

            // Verify action type preserved (basic check)
            switch (message.action, decoded.action) {
            case (.requestVM, .requestVM),
                 (.releaseVM, .releaseVM),
                 (.queryVMStatus, .queryVMStatus),
                 (.vmCreated, .vmCreated),
                 (.vmReleased, .vmReleased),
                 (.vmStatus, .vmStatus):
                break  // Match
            default:
                XCTFail("Action type mismatch: expected \(message.action), got \(decoded.action)")
            }
        }
    }
}
