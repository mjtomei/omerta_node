import Foundation

#if canImport(Security)
import Security
#endif

/// Central configuration for Omerta
/// Stored at ~/.omerta/config.json
public struct OmertaConfig: Codable, Sendable {
    public var ssh: SSHConfig
    public var networks: [String: NetworkConfig]
    public var defaultNetwork: String?
    public var localKey: String?  // Auto-generated key for local/direct connections
    public var nat: NATConfig?    // NAT traversal configuration
    public var mesh: MeshConfigOptions?  // Mesh networking configuration

    public init(
        ssh: SSHConfig = SSHConfig(),
        networks: [String: NetworkConfig] = [:],
        defaultNetwork: String? = nil,
        localKey: String? = nil,
        nat: NATConfig? = nil,
        mesh: MeshConfigOptions? = nil
    ) {
        self.ssh = ssh
        self.networks = networks
        self.defaultNetwork = defaultNetwork
        self.localKey = localKey
        self.nat = nat
        self.mesh = mesh
    }

    /// Get the local key as Data, or nil if not set
    public func localKeyData() -> Data? {
        guard let hex = localKey else { return nil }
        return Data(hexString: hex)
    }

    /// Generate a new random local key (32 bytes, hex encoded)
    public static func generateLocalKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        #else
        // On Linux, use SystemRandomNumberGenerator
        var rng = SystemRandomNumberGenerator()
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        #endif
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Get the default config directory path
    public static var defaultConfigDir: String {
        let homeDir = getRealUserHome()
        return "\(homeDir)/.omerta"
    }

    /// Get the config file path
    public static var configFilePath: String {
        "\(defaultConfigDir)/config.json"
    }

    /// Get the real user's home directory, even when running under sudo
    public static func getRealUserHome() -> String {
        if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"] {
            #if os(macOS)
            return "/Users/\(sudoUser)"
            #else
            return "/home/\(sudoUser)"
            #endif
        }

        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return home
        }

        return NSHomeDirectory()
    }
}

// MARK: - SSH Configuration

public struct SSHConfig: Codable, Sendable {
    public var privateKeyPath: String
    public var publicKeyPath: String
    public var publicKey: String?  // Cached public key content
    public var defaultUser: String

    public init(
        privateKeyPath: String = "~/.omerta/ssh/id_ed25519",
        publicKeyPath: String = "~/.omerta/ssh/id_ed25519.pub",
        publicKey: String? = nil,
        defaultUser: String = "omerta"
    ) {
        self.privateKeyPath = privateKeyPath
        self.publicKeyPath = publicKeyPath
        self.publicKey = publicKey
        self.defaultUser = defaultUser
    }

    /// Get expanded private key path
    public func expandedPrivateKeyPath() -> String {
        expandPath(privateKeyPath)
    }

    /// Get expanded public key path
    public func expandedPublicKeyPath() -> String {
        expandPath(publicKeyPath)
    }

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let homeDir = OmertaConfig.defaultConfigDir.replacingOccurrences(
                of: "/.omerta",
                with: ""
            )
            return homeDir + String(path.dropFirst(1))
        }
        return path
    }
}

// MARK: - Network Configuration

public struct NetworkConfig: Codable, Sendable {
    public var key: String  // Hex-encoded network key
    public var name: String?
    public var description: String?

    public init(key: String, name: String? = nil, description: String? = nil) {
        self.key = key
        self.name = name
        self.description = description
    }
}

// MARK: - Mesh Configuration

/// Configuration for mesh networking (persistent, Codable version)
public struct MeshConfigOptions: Codable, Sendable {
    /// Whether mesh networking is enabled
    public var enabled: Bool

    /// Local peer ID (if not set, will be auto-generated)
    public var peerId: String?

    /// Port to bind to (0 for automatic)
    public var port: Int

    /// Bootstrap peers for initial discovery (format: "peerId@host:port")
    public var bootstrapPeers: [String]

    /// STUN servers for NAT detection
    public var stunServers: [String]

    /// Whether this node can act as a relay for other peers
    public var canRelay: Bool

    /// Whether this node can coordinate hole punches
    public var canCoordinateHolePunch: Bool

    /// Keepalive interval in seconds
    public var keepaliveInterval: Double

    /// Connection timeout in seconds
    public var connectionTimeout: Double

    public init(
        enabled: Bool = false,
        peerId: String? = nil,
        port: Int = 0,
        bootstrapPeers: [String] = [],
        stunServers: [String] = MeshConfigOptions.defaultSTUNServers,
        canRelay: Bool = false,
        canCoordinateHolePunch: Bool = false,
        keepaliveInterval: Double = 15,
        connectionTimeout: Double = 10
    ) {
        self.enabled = enabled
        self.peerId = peerId
        self.port = port
        self.bootstrapPeers = bootstrapPeers
        self.stunServers = stunServers
        self.canRelay = canRelay
        self.canCoordinateHolePunch = canCoordinateHolePunch
        self.keepaliveInterval = keepaliveInterval
        self.connectionTimeout = connectionTimeout
    }

    /// Default STUN servers (Omerta STUN servers for NAT detection)
    public static let defaultSTUNServers = [
        "52.27.78.210:3478",
        "52.88.62.29:3478"
    ]

    /// Default configuration (mesh disabled)
    public static let `default` = MeshConfigOptions()

    /// Configuration for a relay/provider node
    public static var provider: MeshConfigOptions {
        MeshConfigOptions(
            enabled: true,
            canRelay: true,
            canCoordinateHolePunch: true,
            keepaliveInterval: 10
        )
    }

    /// Configuration for a consumer/client node
    public static var consumer: MeshConfigOptions {
        MeshConfigOptions(
            enabled: true,
            canRelay: false,
            canCoordinateHolePunch: false,
            keepaliveInterval: 15
        )
    }
}

// MARK: - NAT Configuration

/// Configuration for NAT traversal
public struct NATConfig: Codable, Sendable {
    /// STUN servers for NAT type detection
    public var stunServers: [String]

    /// Prefer direct connections over relay
    public var preferDirect: Bool

    /// Hole punch timeout in milliseconds
    public var holePunchTimeout: Int

    /// Number of probe packets for hole punching
    public var probeCount: Int

    /// Local port for NAT traversal (0 = auto)
    public var localPort: UInt16

    public init(
        stunServers: [String] = NATConfig.defaultSTUNServers,
        preferDirect: Bool = true,
        holePunchTimeout: Int = 5000,
        probeCount: Int = 5,
        localPort: UInt16 = 0
    ) {
        self.stunServers = stunServers
        self.preferDirect = preferDirect
        self.holePunchTimeout = holePunchTimeout
        self.probeCount = probeCount
        self.localPort = localPort
    }

    /// Default STUN servers (Omerta STUN servers for NAT detection)
    public static let defaultSTUNServers = [
        "52.27.78.210:3478",
        "52.88.62.29:3478"
    ]

    /// Timeout as TimeInterval
    public var timeoutInterval: TimeInterval {
        Double(holePunchTimeout) / 1000.0
    }
}

// MARK: - Config Manager

public actor ConfigManager {
    private var config: OmertaConfig?
    private let configPath: String

    public init(configPath: String = OmertaConfig.configFilePath) {
        self.configPath = Self.expandPath(configPath)
    }

    /// Load configuration from disk
    public func load() throws -> OmertaConfig {
        if let config = self.config {
            return config
        }

        let expandedPath = configPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw ConfigError.notInitialized
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
        let decoder = JSONDecoder()
        let config = try decoder.decode(OmertaConfig.self, from: data)
        self.config = config
        return config
    }

    /// Save configuration to disk
    public func save(_ config: OmertaConfig) throws {
        let expandedPath = configPath
        let dir = (expandedPath as NSString).deletingLastPathComponent

        // Create directory if needed
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        try data.write(to: URL(fileURLWithPath: expandedPath))
        self.config = config
    }

    /// Check if config exists
    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: configPath)
    }

    /// Get loaded config or throw
    public func getConfig() throws -> OmertaConfig {
        if let config = self.config {
            return config
        }
        return try load()
    }

    /// Update config
    public func update(_ transform: (inout OmertaConfig) -> Void) throws {
        var config = try load()
        transform(&config)
        try save(config)
    }

    private static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let homeDir = OmertaConfig.defaultConfigDir.replacingOccurrences(
                of: "/.omerta",
                with: ""
            )
            return homeDir + String(path.dropFirst(1))
        }
        return path
    }
}

// MARK: - SSH Key Generator

public enum SSHKeyGenerator {
    /// Generate a new Ed25519 SSH keypair
    public static func generateKeyPair(
        privateKeyPath: String,
        publicKeyPath: String,
        comment: String? = nil
    ) throws -> (privateKey: String, publicKey: String) {
        let expandedPrivatePath = expandPath(privateKeyPath)
        let expandedPublicPath = expandPath(publicKeyPath)

        // Create directory if needed
        let dir = (expandedPrivatePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // Generate key using ssh-keygen
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")

        var args = [
            "-t", "ed25519",
            "-f", expandedPrivatePath,
            "-N", "",  // No passphrase
            "-q"       // Quiet mode
        ]

        if let comment = comment {
            args.append(contentsOf: ["-C", comment])
        }

        process.arguments = args

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ConfigError.keyGenerationFailed(errorMessage)
        }

        // Read the generated keys
        let privateKey = try String(contentsOfFile: expandedPrivatePath, encoding: .utf8)
        let publicKey = try String(contentsOfFile: expandedPublicPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Set proper permissions on private key
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: expandedPrivatePath
        )

        return (privateKey, publicKey)
    }

    /// Read existing public key
    public static func readPublicKey(path: String) throws -> String {
        let expandedPath = expandPath(path)
        return try String(contentsOfFile: expandedPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if keypair exists
    public static func keyPairExists(privateKeyPath: String, publicKeyPath: String) -> Bool {
        let expandedPrivate = expandPath(privateKeyPath)
        let expandedPublic = expandPath(publicKeyPath)
        return FileManager.default.fileExists(atPath: expandedPrivate) &&
               FileManager.default.fileExists(atPath: expandedPublic)
    }

    private static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let homeDir = OmertaConfig.defaultConfigDir.replacingOccurrences(
                of: "/.omerta",
                with: ""
            )
            return homeDir + String(path.dropFirst(1))
        }
        return path
    }
}

// MARK: - Errors

public enum ConfigError: Error, CustomStringConvertible {
    case notInitialized
    case keyGenerationFailed(String)
    case invalidConfig(String)
    case networkNotFound(String)

    public var description: String {
        switch self {
        case .notInitialized:
            return "Omerta not initialized. Run 'omerta init' first."
        case .keyGenerationFailed(let reason):
            return "Failed to generate SSH key: \(reason)"
        case .invalidConfig(let reason):
            return "Invalid configuration: \(reason)"
        case .networkNotFound(let name):
            return "Network '\(name)' not found in configuration"
        }
    }
}

// MARK: - Data Hex Extension

public extension Data {
    /// Initialize Data from a hex string
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex

        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Convert Data to hex string
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
