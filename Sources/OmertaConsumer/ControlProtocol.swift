import Foundation
import OmertaCore

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
    case vmCreated(VMCreatedResponse)
    case vmReleased(VMReleasedResponse)
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

    public init(vmId: UUID, vmIP: String, sshPort: UInt16 = 22) {
        self.vmId = vmId
        self.vmIP = vmIP
        self.sshPort = sshPort
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

// MARK: - Provider Notifications (Async)

/// Async notifications sent from provider to consumer
public enum ProviderNotification: Codable, Sendable {
    case vmReady(vmId: UUID, vmIP: String)
    case vmKilled(vmId: UUID, reason: String)
    case vpnDied(vmId: UUID)
}
