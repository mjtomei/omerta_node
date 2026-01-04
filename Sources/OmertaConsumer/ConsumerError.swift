import Foundation
import OmertaCore

/// Errors that can occur during consumer operations
public enum ConsumerError: Error, CustomStringConvertible {
    case noSuitableProviders
    case providerTimeout
    case providerUnavailable(String)  // Peer ID
    case vpnCreationFailed(Error)
    case vmCreationFailed(String)
    case persistenceError(Error)
    case decryptionFailed
    case networkKeyNotFound
    case invalidResponse(String)
    case providerError(String)  // Error message from provider

    public var description: String {
        switch self {
        case .noSuitableProviders:
            return "No suitable providers found matching requirements"
        case .providerTimeout:
            return "Provider did not respond within timeout period"
        case .providerUnavailable(let peerId):
            return "Provider \(peerId) is unavailable"
        case .vpnCreationFailed(let error):
            return "Failed to create VPN tunnel: \(error.localizedDescription)"
        case .vmCreationFailed(let reason):
            return "Failed to create VM: \(reason)"
        case .persistenceError(let error):
            return "Failed to persist data: \(error.localizedDescription)"
        case .decryptionFailed:
            return "Failed to decrypt control message"
        case .networkKeyNotFound:
            return "Network key not found for encryption"
        case .invalidResponse(let reason):
            return "Invalid response from provider: \(reason)"
        case .providerError(let message):
            return "Provider error: \(message)"
        }
    }
}
