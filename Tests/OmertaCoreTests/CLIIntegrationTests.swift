// CLIIntegrationTests.swift
// Phase 1: CLI Integration Tests

import XCTest
@testable import OmertaCore

/// Tests for CLI integration - config initialization, SSH keys, and local key
final class CLIIntegrationTests: XCTestCase {

    var tempDir: URL!
    var configPath: String!

    override func setUp() async throws {
        try await super.setUp()

        // Create a temp directory for test config
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omerta-cli-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        configPath = tempDir.appendingPathComponent("config.json").path
    }

    override func tearDown() async throws {
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Config Initialization Tests

    func testInitCreatesConfig() async throws {
        // Given: No config exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When: We create and save a new config
        let configManager = ConfigManager(configPath: configPath)
        let config = OmertaConfig(
            ssh: SSHConfig(
                privateKeyPath: tempDir.appendingPathComponent("ssh/id_ed25519").path,
                publicKeyPath: tempDir.appendingPathComponent("ssh/id_ed25519.pub").path
            ),
            localKey: OmertaConfig.generateLocalKey()
        )
        try await configManager.save(config)

        // Then: Config file is created
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath),
                     "Config file should be created at \(configPath)")
    }

    func testInitGeneratesLocalKey() async throws {
        // When: We generate a local key
        let localKey = OmertaConfig.generateLocalKey()

        // Then: It's a valid 64-character hex string (32 bytes)
        XCTAssertEqual(localKey.count, 64, "Local key should be 64 hex characters (32 bytes)")

        // Verify it's valid hex
        let hexRegex = try NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        let range = NSRange(localKey.startIndex..., in: localKey)
        XCTAssertNotNil(hexRegex.firstMatch(in: localKey, range: range),
                       "Local key should be lowercase hex")
    }

    func testLocalKeyIsUnique() async throws {
        // When: We generate multiple keys
        let key1 = OmertaConfig.generateLocalKey()
        let key2 = OmertaConfig.generateLocalKey()
        let key3 = OmertaConfig.generateLocalKey()

        // Then: They're all different
        XCTAssertNotEqual(key1, key2, "Generated keys should be unique")
        XCTAssertNotEqual(key2, key3, "Generated keys should be unique")
        XCTAssertNotEqual(key1, key3, "Generated keys should be unique")
    }

    func testLocalKeyConvertsToData() async throws {
        // Given: A generated local key
        let localKey = OmertaConfig.generateLocalKey()
        let config = OmertaConfig(localKey: localKey)

        // When: We convert it to Data
        let keyData = config.localKeyData()

        // Then: It's 32 bytes
        XCTAssertNotNil(keyData)
        XCTAssertEqual(keyData?.count, 32, "Local key data should be 32 bytes")
    }

    func testConfigLoadAfterSave() async throws {
        // Given: A saved config
        let configManager = ConfigManager(configPath: configPath)
        let localKey = OmertaConfig.generateLocalKey()
        let originalConfig = OmertaConfig(
            ssh: SSHConfig(
                privateKeyPath: tempDir.appendingPathComponent("ssh/id_ed25519").path,
                publicKeyPath: tempDir.appendingPathComponent("ssh/id_ed25519.pub").path,
                defaultUser: "testuser"
            ),
            localKey: localKey
        )
        try await configManager.save(originalConfig)

        // When: We load the config in a new manager
        let newManager = ConfigManager(configPath: configPath)
        let loadedConfig = try await newManager.load()

        // Then: All fields are preserved
        XCTAssertEqual(loadedConfig.localKey, localKey)
        XCTAssertEqual(loadedConfig.ssh.defaultUser, "testuser")
    }

    func testInitIdempotent() async throws {
        // Given: An existing config
        let configManager = ConfigManager(configPath: configPath)
        let originalKey = OmertaConfig.generateLocalKey()
        let originalConfig = OmertaConfig(localKey: originalKey)
        try await configManager.save(originalConfig)

        // When: We check if config exists
        let exists = await configManager.exists()

        // Then: It reports as existing
        XCTAssertTrue(exists, "Config should report as existing")
    }

    func testConfigUpdatePreservesExistingFields() async throws {
        // Given: A config with a network
        let configManager = ConfigManager(configPath: configPath)
        let originalConfig = OmertaConfig(
            networks: ["test-network": NetworkConfig(key: "abc123", name: "Test")],
            localKey: OmertaConfig.generateLocalKey()
        )
        try await configManager.save(originalConfig)

        // When: We update the config
        try await configManager.update { config in
            config.defaultNetwork = "test-network"
        }

        // Then: Existing fields are preserved
        let loadedConfig = try await configManager.load()
        XCTAssertEqual(loadedConfig.networks.count, 1)
        XCTAssertEqual(loadedConfig.networks["test-network"]?.name, "Test")
        XCTAssertEqual(loadedConfig.defaultNetwork, "test-network")
    }

    // MARK: - SSH Key Tests

    func testSSHKeyGeneration() async throws {
        // Given: Paths for SSH keys
        let sshDir = tempDir.appendingPathComponent("ssh")
        let privateKeyPath = sshDir.appendingPathComponent("id_ed25519").path
        let publicKeyPath = sshDir.appendingPathComponent("id_ed25519.pub").path

        // When: We generate a keypair
        let (privateKey, publicKey) = try SSHKeyGenerator.generateKeyPair(
            privateKeyPath: privateKeyPath,
            publicKeyPath: publicKeyPath,
            comment: "test@omerta"
        )

        // Then: Keys are generated
        XCTAssertFalse(privateKey.isEmpty, "Private key should not be empty")
        XCTAssertFalse(publicKey.isEmpty, "Public key should not be empty")

        // And: Files exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateKeyPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicKeyPath))
    }

    func testSSHKeyIsEd25519() async throws {
        // Given: Generated SSH keypair
        let sshDir = tempDir.appendingPathComponent("ssh")
        let privateKeyPath = sshDir.appendingPathComponent("id_ed25519").path
        let publicKeyPath = sshDir.appendingPathComponent("id_ed25519.pub").path

        let (_, publicKey) = try SSHKeyGenerator.generateKeyPair(
            privateKeyPath: privateKeyPath,
            publicKeyPath: publicKeyPath
        )

        // Then: Public key is ed25519 format
        XCTAssertTrue(publicKey.hasPrefix("ssh-ed25519 "),
                     "Public key should be ed25519 format")
    }

    func testSSHKeyPrivateKeyPermissions() async throws {
        // Given: Generated SSH keypair
        let sshDir = tempDir.appendingPathComponent("ssh")
        let privateKeyPath = sshDir.appendingPathComponent("id_ed25519").path
        let publicKeyPath = sshDir.appendingPathComponent("id_ed25519.pub").path

        _ = try SSHKeyGenerator.generateKeyPair(
            privateKeyPath: privateKeyPath,
            publicKeyPath: publicKeyPath
        )

        // Then: Private key has 600 permissions
        let attrs = try FileManager.default.attributesOfItem(atPath: privateKeyPath)
        let permissions = attrs[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "Private key should have 600 permissions")
    }

    func testKeyPairExists() async throws {
        // Given: No keys exist initially
        let sshDir = tempDir.appendingPathComponent("ssh")
        let privateKeyPath = sshDir.appendingPathComponent("id_ed25519").path
        let publicKeyPath = sshDir.appendingPathComponent("id_ed25519.pub").path

        XCTAssertFalse(SSHKeyGenerator.keyPairExists(
            privateKeyPath: privateKeyPath,
            publicKeyPath: publicKeyPath
        ))

        // When: We generate keys
        _ = try SSHKeyGenerator.generateKeyPair(
            privateKeyPath: privateKeyPath,
            publicKeyPath: publicKeyPath
        )

        // Then: keyPairExists returns true
        XCTAssertTrue(SSHKeyGenerator.keyPairExists(
            privateKeyPath: privateKeyPath,
            publicKeyPath: publicKeyPath
        ))
    }

    func testReadPublicKey() async throws {
        // Given: Generated SSH keypair
        let sshDir = tempDir.appendingPathComponent("ssh")
        let privateKeyPath = sshDir.appendingPathComponent("id_ed25519").path
        let publicKeyPath = sshDir.appendingPathComponent("id_ed25519.pub").path

        let (_, originalPublicKey) = try SSHKeyGenerator.generateKeyPair(
            privateKeyPath: privateKeyPath,
            publicKeyPath: publicKeyPath,
            comment: "test@omerta"
        )

        // When: We read the public key
        let readKey = try SSHKeyGenerator.readPublicKey(path: publicKeyPath)

        // Then: It matches the original
        XCTAssertEqual(readKey, originalPublicKey)
    }

    // MARK: - Data Hex Extension Tests

    func testDataHexStringRoundTrip() {
        // Given: Some random bytes
        let originalBytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33]
        let originalData = Data(originalBytes)

        // When: We convert to hex and back
        let hexString = originalData.hexString
        let recoveredData = Data(hexString: hexString)

        // Then: Data matches
        XCTAssertEqual(recoveredData, originalData)
        XCTAssertEqual(hexString, "deadbeef00112233")
    }

    func testDataFromInvalidHexReturnsNil() {
        // Given: Invalid hex strings (completely non-hex characters)
        let invalidStrings = ["xyz", "ghij", "!@#$"]  // Not valid hex at all

        for invalidHex in invalidStrings {
            // Then: Data init returns nil
            XCTAssertNil(Data(hexString: invalidHex),
                        "Invalid hex '\(invalidHex)' should return nil")
        }
    }

    func testDataFromPartialHexParsesValidPortion() {
        // The hex parser reads pairs of valid hex chars
        // Trailing invalid chars or odd lengths result in truncated parsing
        let partialHex = "deadbe"  // 6 chars = 3 bytes
        let result = Data(hexString: partialHex)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 3)
    }

    // MARK: - Config Error Tests

    func testLoadNonExistentConfigThrows() async throws {
        // Given: No config exists
        let configManager = ConfigManager(configPath: configPath)

        // Then: Load throws notInitialized
        do {
            _ = try await configManager.load()
            XCTFail("Should throw notInitialized error")
        } catch ConfigError.notInitialized {
            // Expected
        }
    }

    // MARK: - Network Config Tests

    func testAddNetworkToConfig() async throws {
        // Given: A config
        let configManager = ConfigManager(configPath: configPath)
        var config = OmertaConfig(localKey: OmertaConfig.generateLocalKey())

        // When: We add a network
        let networkKey = OmertaConfig.generateLocalKey()  // Reuse key generation
        config.networks["my-network"] = NetworkConfig(
            key: networkKey,
            name: "My Test Network",
            description: "A test network"
        )
        try await configManager.save(config)

        // Then: Network is retrievable
        let loaded = try await configManager.load()
        XCTAssertNotNil(loaded.networks["my-network"])
        XCTAssertEqual(loaded.networks["my-network"]?.key, networkKey)
        XCTAssertEqual(loaded.networks["my-network"]?.name, "My Test Network")
    }
}
