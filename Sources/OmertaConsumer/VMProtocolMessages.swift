// VMProtocolMessages.swift - Shared message types for VM operations over mesh

import Foundation
import OmertaCore

// MARK: - VM Request/Response Messages

/// VM request sent over mesh
public struct MeshVMRequest: Codable, Sendable {
    public let type: String
    public let vmId: UUID
    public let requirements: ResourceRequirements
    public let consumerPublicKey: String
    public let consumerEndpoint: String
    public let consumerVPNIP: String      // Consumer's WireGuard IP (e.g., 10.x.y.1)
    public let vmVPNIP: String            // VM's WireGuard IP (e.g., 10.x.y.2)
    public let sshPublicKey: String
    public let sshUser: String
    public let timeoutMinutes: Int?       // Heartbeat timeout (nil = default 10 minutes)

    public init(
        vmId: UUID,
        requirements: ResourceRequirements,
        consumerPublicKey: String,
        consumerEndpoint: String,
        consumerVPNIP: String,
        vmVPNIP: String,
        sshPublicKey: String,
        sshUser: String,
        timeoutMinutes: Int? = nil
    ) {
        self.type = "vm_request"
        self.vmId = vmId
        self.requirements = requirements
        self.consumerPublicKey = consumerPublicKey
        self.consumerEndpoint = consumerEndpoint
        self.consumerVPNIP = consumerVPNIP
        self.vmVPNIP = vmVPNIP
        self.sshPublicKey = sshPublicKey
        self.sshUser = sshUser
        self.timeoutMinutes = timeoutMinutes
    }
}

/// VM response received over mesh
public struct MeshVMResponse: Codable, Sendable {
    public let type: String
    public let vmId: UUID
    public let vmIP: String?
    public let providerPublicKey: String?
    public let error: String?

    public init(
        type: String,
        vmId: UUID,
        vmIP: String?,
        providerPublicKey: String?,
        error: String?
    ) {
        self.type = type
        self.vmId = vmId
        self.vmIP = vmIP
        self.providerPublicKey = providerPublicKey
        self.error = error
    }
}

/// VM release request sent over mesh
public struct MeshVMReleaseRequest: Codable, Sendable {
    public let type: String
    public let vmId: UUID

    public init(vmId: UUID) {
        self.type = "vm_release"
        self.vmId = vmId
    }
}

/// VM release response
public struct MeshVMReleaseResponse: Codable, Sendable {
    public let type: String
    public let vmId: UUID
    public let error: String?

    public init(type: String, vmId: UUID, error: String?) {
        self.type = type
        self.vmId = vmId
        self.error = error
    }
}

// MARK: - VM Heartbeat Messages

/// Provider asks consumer about VM liveness
/// Sent every 60 seconds for each consumer with active VMs
public struct MeshVMHeartbeat: Codable, Sendable {
    public let type: String
    public let providerPeerId: String   // Provider's peer identity for VM filtering
    public let vmIds: [UUID]            // VMs provider thinks consumer owns
    public let timestamp: Date

    public init(providerPeerId: String, vmIds: [UUID]) {
        self.type = "vm_heartbeat"
        self.providerPeerId = providerPeerId
        self.vmIds = vmIds
        self.timestamp = Date()
    }
}

/// Consumer responds with VMs still active
/// Only includes VMs that are BOTH in the request AND tracked locally
public struct MeshVMHeartbeatResponse: Codable, Sendable {
    public let type: String
    public let activeVmIds: [UUID]     // Intersection: requested AND tracked
    public let timestamp: Date

    public init(activeVmIds: [UUID]) {
        self.type = "vm_heartbeat_response"
        self.activeVmIds = activeVmIds
        self.timestamp = Date()
    }
}

// MARK: - VM ACK Messages

/// ACK for VM response - confirms consumer received and accepted the response
/// Provider waits for this before considering delivery successful
public struct MeshVMAck: Codable, Sendable {
    public let type: String
    public let vmId: UUID
    public let success: Bool  // false if consumer rejected/error

    public init(vmId: UUID, success: Bool) {
        self.type = "vm_ack"
        self.vmId = vmId
        self.success = success
    }
}

// MARK: - Provider Shutdown Notification

/// Notification sent by provider to consumers when shutting down
/// Consumer should clean up VPN tunnels for listed VMs
public struct MeshProviderShutdownNotification: Codable, Sendable {
    public let type: String
    public let providerPeerId: String  // Provider's peer identity for VM filtering
    public let vmIds: [UUID]           // VMs being released due to shutdown
    public let reason: String

    public init(providerPeerId: String, vmIds: [UUID], reason: String = "provider_shutdown") {
        self.type = "provider_shutdown"
        self.providerPeerId = providerPeerId
        self.vmIds = vmIds
        self.reason = reason
    }
}
