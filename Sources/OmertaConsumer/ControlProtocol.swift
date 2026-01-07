import Foundation
import OmertaCore

// MARK: - Message Envelope

/// Envelope format for UDP messages with plaintext networkId header
/// Format: [1 byte: networkId length][N bytes: networkId UTF-8][rest: encrypted payload]
/// This allows the provider to look up the correct decryption key based on networkId
public struct MessageEnvelope: Sendable {
    public let networkId: String
    public let encryptedPayload: Data

    public init(networkId: String, encryptedPayload: Data) {
        self.networkId = networkId
        self.encryptedPayload = encryptedPayload
    }

    /// Serialize envelope to wire format
    public func serialize() -> Data {
        let networkIdData = networkId.data(using: .utf8) ?? Data()
        let length = UInt8(min(networkIdData.count, 255))

        var result = Data(capacity: 1 + Int(length) + encryptedPayload.count)
        result.append(length)
        result.append(networkIdData.prefix(Int(length)))
        result.append(encryptedPayload)
        return result
    }

    /// Parse envelope from wire format
    public static func parse(_ data: Data) -> MessageEnvelope? {
        guard data.count >= 1 else { return nil }

        let length = Int(data[0])
        guard data.count >= 1 + length else { return nil }

        let networkIdData = data.subdata(in: 1..<(1 + length))
        guard let networkId = String(data: networkIdData, encoding: .utf8) else { return nil }

        let encryptedPayload = data.subdata(in: (1 + length)..<data.count)
        return MessageEnvelope(networkId: networkId, encryptedPayload: encryptedPayload)
    }
}

// MARK: - Control Message (Top-Level)

/// Top-level control message sent over UDP
public struct ControlMessage: Codable, Sendable {
    public let messageId: UUID
    public let timestamp: UInt64  // Unix timestamp for replay attack prevention
    public let action: ControlAction

    public init(messageId: UUID = UUID(), timestamp: UInt64, action: ControlAction) {
        self.messageId = messageId
        self.timestamp = timestamp
        self.action = action
    }

    /// Convenience initializer with current timestamp
    public init(action: ControlAction) {
        self.messageId = UUID()
        self.timestamp = UInt64(Date().timeIntervalSince1970)
        self.action = action
    }
}

// MARK: - Control Actions

/// Actions that can be requested via control messages
public enum ControlAction: Codable, Sendable {
    case requestVM(RequestVMMessage)
    case releaseVM(ReleaseVMMessage)
    case queryVMStatus(VMStatusRequest)
    case vmCreated(VMCreatedResponse)
    case vmReleased(VMReleasedResponse)
    case vmStatus(VMStatusResponse)
}

// MARK: - Request VM Message

/// Request to create a new VM
public struct RequestVMMessage: Codable, Sendable {
    public let vmId: UUID  // Consumer-generated ID
    public let requirements: ResourceRequirements
    public let vpnConfig: VPNConfiguration
    public let consumerEndpoint: String  // For async notifications (IP:port)
    public let sshPublicKey: String  // Consumer's SSH public key for VM access
    public let sshUser: String  // Username to create in VM (default: "omerta")

    public init(
        vmId: UUID = UUID(),
        requirements: ResourceRequirements,
        vpnConfig: VPNConfiguration,
        consumerEndpoint: String,
        sshPublicKey: String,
        sshUser: String = "omerta"
    ) {
        self.vmId = vmId
        self.requirements = requirements
        self.vpnConfig = vpnConfig
        self.consumerEndpoint = consumerEndpoint
        self.sshPublicKey = sshPublicKey
        self.sshUser = sshUser
    }
}

// MARK: - Release VM Message

/// Request to release/destroy a VM
public struct ReleaseVMMessage: Codable, Sendable {
    public let vmId: UUID

    public init(vmId: UUID) {
        self.vmId = vmId
    }
}

// MARK: - VM Created Response

/// Response after VM has been created
public struct VMCreatedResponse: Codable, Sendable {
    public let vmId: UUID
    public let vmIP: String  // IP address within VPN tunnel
    public let sshPort: UInt16  // SSH port (usually 22)
    public let providerPublicKey: String  // Provider's WireGuard public key for this tunnel
    public let error: String?  // Error message if VM creation failed

    public init(vmId: UUID, vmIP: String, sshPort: UInt16 = 22, providerPublicKey: String, error: String? = nil) {
        self.vmId = vmId
        self.vmIP = vmIP
        self.sshPort = sshPort
        self.providerPublicKey = providerPublicKey
        self.error = error
    }

    /// Check if this response indicates an error
    public var isError: Bool {
        error != nil || vmIP.isEmpty || providerPublicKey.isEmpty
    }
}

// MARK: - VM Released Response

/// Response after VM has been released
public struct VMReleasedResponse: Codable, Sendable {
    public let vmId: UUID

    public init(vmId: UUID) {
        self.vmId = vmId
    }
}

// MARK: - VM Status Request

/// Request VM status from provider
public struct VMStatusRequest: Codable, Sendable {
    public let vmId: UUID?  // nil = query all VMs

    public init(vmId: UUID? = nil) {
        self.vmId = vmId
    }
}

// MARK: - VM Status Response

/// Response with VM status information
public struct VMStatusResponse: Codable, Sendable {
    public let vms: [VMInfo]

    public init(vms: [VMInfo]) {
        self.vms = vms
    }
}

/// Information about a single VM
public struct VMInfo: Codable, Sendable {
    public let vmId: UUID
    public let status: VMStatus
    public let vmIP: String
    public let createdAt: Date
    public let uptimeSeconds: Int
    public let consoleOutput: String?  // Last few lines of console

    public init(
        vmId: UUID,
        status: VMStatus,
        vmIP: String,
        createdAt: Date,
        uptimeSeconds: Int,
        consoleOutput: String? = nil
    ) {
        self.vmId = vmId
        self.status = status
        self.vmIP = vmIP
        self.createdAt = createdAt
        self.uptimeSeconds = uptimeSeconds
        self.consoleOutput = consoleOutput
    }
}

/// VM status enum
public enum VMStatus: String, Codable, Sendable {
    case starting = "starting"
    case running = "running"
    case stopping = "stopping"
    case stopped = "stopped"
    case error = "error"
}

// MARK: - Provider Notifications (Async)

/// Async notifications sent from provider to consumer
public enum ProviderNotification: Codable, Sendable {
    case vmReady(vmId: UUID, vmIP: String)
    case vmKilled(vmId: UUID, reason: String)
    case vpnDied(vmId: UUID)
}
