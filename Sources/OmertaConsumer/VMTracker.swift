import Foundation
import OmertaCore

/// Tracks active VMs and persists state to disk for crash recovery
public actor VMTracker {
    private let persistencePath: String
    private var activeVMs: [UUID: VMConnection] = [:]

    public init(persistencePath: String = "~/.omerta/vms/active.json") {
        // Get the real user's home directory (handles sudo correctly)
        let homeDir = Self.getRealUserHome()

        // Replace ~ with actual home directory
        let expandedPath: String
        if persistencePath.hasPrefix("~/") {
            expandedPath = homeDir + String(persistencePath.dropFirst(1))
        } else if persistencePath.hasPrefix("~") {
            expandedPath = homeDir + String(persistencePath.dropFirst(1))
        } else {
            expandedPath = persistencePath
        }

        self.persistencePath = expandedPath

        // Create directory if needed
        let dir = (expandedPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
    }

    /// Get the real user's home directory, even when running under sudo
    private static func getRealUserHome() -> String {
        // Check SUDO_USER first (set when running under sudo)
        if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"] {
            // Get the home directory for this user
            #if os(macOS)
            return "/Users/\(sudoUser)"
            #else
            return "/home/\(sudoUser)"
            #endif
        }

        // Fall back to HOME environment variable
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return home
        }

        // Last resort: use NSHomeDirectory (but this returns root's home under sudo)
        return NSHomeDirectory()
    }

    // MARK: - Tracking Operations

    /// Track a new VM connection
    public func trackVM(_ connection: VMConnection) async throws {
        activeVMs[connection.vmId] = connection
        try await persist()
    }

    /// Remove VM from tracking
    public func removeVM(_ vmId: UUID) async throws {
        activeVMs.removeValue(forKey: vmId)
        try await persist()
    }

    /// Get all active VMs
    public func getActiveVMs() async -> [VMConnection] {
        Array(activeVMs.values).sorted { $0.createdAt > $1.createdAt }
    }

    /// Get specific VM
    public func getVM(_ vmId: UUID) async -> VMConnection? {
        activeVMs[vmId]
    }

    // MARK: - Persistence

    /// Load persisted VMs from disk
    public func loadPersistedVMs() async throws -> [VMConnection] {
        guard FileManager.default.fileExists(atPath: persistencePath) else {
            return []
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: persistencePath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let container = try decoder.decode(VMStateContainer.self, from: data)

        // Restore to in-memory state
        for vm in container.vms {
            activeVMs[vm.vmId] = vm
        }

        return container.vms
    }

    /// Persist current state to disk
    private func persist() async throws {
        let container = VMStateContainer(
            version: 1,
            vms: Array(activeVMs.values)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(container)
        let finalURL = URL(fileURLWithPath: persistencePath)

        // Simple atomic write - Foundation handles temp file internally
        try data.write(to: finalURL, options: .atomic)
    }
}

// MARK: - VM Connection

/// Represents a connection to a VM
public struct VMConnection: Sendable, Codable, Identifiable {
    public let id: UUID  // Same as vmId, for Identifiable
    public let vmId: UUID
    public let provider: PeerInfo  // Simplified peer info for persistence
    public let vmIP: String
    public let sshKeyPath: String
    public let sshUser: String
    public let vpnInterface: String
    public let createdAt: Date
    public let networkId: String

    public init(
        vmId: UUID,
        provider: PeerInfo,
        vmIP: String,
        sshKeyPath: String,
        sshUser: String,
        vpnInterface: String,
        createdAt: Date,
        networkId: String
    ) {
        self.id = vmId
        self.vmId = vmId
        self.provider = provider
        self.vmIP = vmIP
        self.sshKeyPath = sshKeyPath
        self.sshUser = sshUser
        self.vpnInterface = vpnInterface
        self.createdAt = createdAt
        self.networkId = networkId
    }

    /// SSH command for accessing the VM
    public var sshCommand: String {
        "ssh \(sshUser)@\(vmIP) -i \(sshKeyPath)"
    }

    /// SCP command template for file transfer
    public var scpCommand: String {
        "scp -i \(sshKeyPath) <local_file> \(sshUser)@\(vmIP):<remote_path>"
    }
}

/// Simplified peer info for persistence
public struct PeerInfo: Sendable, Codable {
    public let peerId: String
    public let endpoint: String  // IP:port

    public init(peerId: String, endpoint: String) {
        self.peerId = peerId
        self.endpoint = endpoint
    }
}

// MARK: - Storage Format

/// Container for persisted VM state
private struct VMStateContainer: Codable {
    let version: Int
    let vms: [VMConnection]
}
