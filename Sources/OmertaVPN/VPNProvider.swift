import Foundation
import OmertaCore

/// Cross-platform protocol for VPN tunnel management
/// macOS: Uses NetworkExtension framework (no sudo required)
/// Linux: Uses wg-quick with sudo (requires passwordless sudo config)
public protocol VPNProvider: Actor, Sendable {
    /// Create a VPN tunnel for a VM session
    /// - Parameter vmId: Unique identifier for the VM
    /// - Returns: VPN configuration including endpoint and keys
    func createVPN(for vmId: UUID) async throws -> VPNConfiguration

    /// Destroy a VPN tunnel
    /// - Parameter vmId: The VM whose tunnel should be destroyed
    func destroyVPN(for vmId: UUID) async throws

    /// Check if a VPN tunnel is connected
    /// - Parameter vmId: The VM to check
    /// - Returns: True if the tunnel is active and connected
    func isConnected(for vmId: UUID) async throws -> Bool

    /// Get all active VPN tunnels
    func getActiveTunnels() async -> [UUID]
}

/// Factory to create platform-appropriate VPN provider
public struct VPNProviderFactory {
    /// Create a VPN provider for the current platform
    /// - Parameter basePort: Base UDP port for WireGuard listeners
    /// - Returns: Platform-specific VPN provider
    public static func create(basePort: UInt16 = 51820) -> any VPNProvider {
        #if os(macOS)
        // Use NetworkExtension on macOS (set via build config)
        // For now, return EphemeralVPN until NetworkExtension is implemented
        return EphemeralVPN(basePort: basePort)
        #else
        // Use sudo-based wg-quick on Linux
        return EphemeralVPN(basePort: basePort)
        #endif
    }

    /// Create a VPN provider with explicit implementation choice
    /// - Parameters:
    ///   - implementation: Which implementation to use
    ///   - basePort: Base UDP port
    /// - Returns: VPN provider
    public static func create(
        implementation: VPNImplementation,
        basePort: UInt16 = 51820
    ) -> any VPNProvider {
        switch implementation {
        case .ephemeral:
            return EphemeralVPN(basePort: basePort)
        #if os(macOS)
        case .networkExtension:
            // Will be implemented
            fatalError("NetworkExtension VPN not yet implemented")
        #endif
        }
    }
}

/// Available VPN implementations
public enum VPNImplementation: String, Sendable {
    /// Uses wg-quick with sudo (Linux, or macOS with sudo configured)
    case ephemeral

    #if os(macOS)
    /// Uses NetworkExtension framework (macOS only, no sudo)
    case networkExtension
    #endif
}

/// Errors specific to VPN provider operations
public enum VPNProviderError: Error, CustomStringConvertible {
    case extensionNotInstalled
    case extensionNotApproved
    case tunnelCreationFailed(String)
    case tunnelNotFound(UUID)
    case configurationInvalid(String)
    case connectionTimeout
    case platformNotSupported

    public var description: String {
        switch self {
        case .extensionNotInstalled:
            return "VPN extension is not installed"
        case .extensionNotApproved:
            return "VPN extension has not been approved by user"
        case .tunnelCreationFailed(let reason):
            return "Failed to create VPN tunnel: \(reason)"
        case .tunnelNotFound(let vmId):
            return "VPN tunnel not found for VM: \(vmId)"
        case .configurationInvalid(let reason):
            return "Invalid VPN configuration: \(reason)"
        case .connectionTimeout:
            return "VPN connection timed out"
        case .platformNotSupported:
            return "VPN operation not supported on this platform"
        }
    }
}
