// SSHProxy.swift - Stub for OmertaSSH module
// TODO: Implement SSH proxy with mosh-like local echo

import Foundation
import OmertaTunnel

/// SSH proxy that connects through netstack
public struct SSHProxy {
    /// Create a connection through netstack
    public static func connect(via netstack: NetstackBridge, host: String, port: Int) throws -> SSHProxy {
        fatalError("SSHProxy not yet implemented")
    }

    /// Run the proxy (blocks until connection closes)
    public func run() throws {
        fatalError("SSHProxy not yet implemented")
    }
}
