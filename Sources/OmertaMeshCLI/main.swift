// OmertaMeshCLI - Simple mesh node for E2E testing
// Uses the OmertaMesh library for real NAT traversal and hole punching

import Foundation
import ArgumentParser
import OmertaMesh
import Logging
import NIOCore
import NIOPosix

@main
struct MeshCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "omerta-mesh",
        abstract: "Run a standalone mesh network node",
        discussion: """
            Runs a mesh node that can connect to other peers via NAT traversal
            and hole punching. Uses the OmertaMesh library.
            """
    )

    @Option(name: .long, help: "Unique peer ID for this node")
    var peerId: String?

    @Option(name: .shortAndLong, help: "Local port to bind (0 = auto)")
    var port: Int = 0

    @Option(name: .long, help: "Bootstrap peer in format peer_id@host:port")
    var bootstrap: [String] = []

    @Option(name: .long, help: "Target peer ID to connect to")
    var target: String?

    @Option(name: .long, help: "Wait time in seconds for peer discovery")
    var waitTime: Int = 30

    @Option(name: .long, help: "Number of test messages to send")
    var messageCount: Int = 3

    @Option(name: .shortAndLong, help: "Log level (trace, debug, info, warning, error)")
    var logLevel: String = "info"

    @Flag(name: .long, help: "Run as a relay node")
    var relay: Bool = false

    @Flag(name: .long, help: "Test mode - exit after completing test")
    var testMode: Bool = false

    mutating func run() async throws {
        // Configure logging
        let level = parseLogLevel(logLevel)
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = level
            return handler
        }

        let logger = Logger(label: "io.omerta.mesh.cli")

        // Generate peer ID if not provided
        let myPeerId = peerId ?? "mesh-\(UUID().uuidString.prefix(8))"

        print("==============================================")
        print("OmertaMesh Node")
        print("==============================================")
        print("Peer ID: \(myPeerId)")
        print("Port: \(port == 0 ? "auto" : String(port))")
        print("Relay mode: \(relay)")
        if !bootstrap.isEmpty {
            print("Bootstrap peers: \(bootstrap.joined(separator: ", "))")
        }
        if let target = target {
            print("Target peer: \(target)")
        }
        print("")

        // Create mesh config
        var config = relay ? MeshConfig.relayNode : MeshConfig.default
        config.port = port
        config.bootstrapPeers = bootstrap
        config.canRelay = relay
        config.canCoordinateHolePunch = relay

        // Create mesh network
        let mesh = MeshNetwork(peerId: myPeerId, config: config)

        // Track received messages
        var receivedMessages: [(from: PeerId, data: Data, isDirect: Bool)] = []
        var testPassed = false

        // Set up message handler
        await mesh.setMessageHandler { from, data in
            if let message = String(data: data, encoding: .utf8) {
                let connection = await mesh.connection(to: from)
                let isDirect = connection?.isDirect ?? false
                let mode = isDirect ? "direct" : "relay"
                print("[\(myPeerId)] Received [\(mode)] from \(from.prefix(16))...: \(message)")
                receivedMessages.append((from, data, isDirect))
            }
        }

        // Subscribe to events
        let events = await mesh.events()

        // Start event handler
        let eventTask = Task {
            for await event in events {
                switch event {
                case .started(let localPeerId):
                    print("[\(myPeerId)] Started with peer ID: \(localPeerId.prefix(16))...")

                case .natDetected(let natType, let endpoint):
                    print("[\(myPeerId)] NAT detected: \(natType.rawValue), endpoint: \(endpoint ?? "unknown")")

                case .peerDiscovered(let peerId, let endpoint, let viaBootstrap):
                    let source = viaBootstrap ? "bootstrap" : "discovery"
                    print("[\(myPeerId)] Peer discovered via \(source): \(peerId.prefix(16))... at \(endpoint)")

                case .holePunchStarted(let peerId):
                    print("[\(myPeerId)] Hole punch started to \(peerId.prefix(16))...")

                case .holePunchSucceeded(let peerId, let endpoint, let rttMs):
                    print("[\(myPeerId)] Hole punch SUCCEEDED to \(peerId.prefix(16))... at \(endpoint) (RTT: \(String(format: "%.1f", rttMs))ms)")

                case .holePunchFailed(let peerId, let reason):
                    print("[\(myPeerId)] Hole punch FAILED to \(peerId.prefix(16))...: \(reason)")

                case .directConnectionEstablished(let peerId, let endpoint):
                    print("[\(myPeerId)] Direct connection to \(peerId.prefix(16))... at \(endpoint)")

                case .peerConnected(let peerId, let endpoint, let isDirect):
                    let mode = isDirect ? "direct" : "relay"
                    print("[\(myPeerId)] Connected to \(peerId.prefix(16))... via \(mode) at \(endpoint)")

                case .peerDisconnected(let peerId, let reason):
                    print("[\(myPeerId)] Disconnected from \(peerId.prefix(16))...: \(reason)")

                case .warning(let message):
                    print("[\(myPeerId)] Warning: \(message)")

                default:
                    break
                }
            }
        }

        do {
            // Start the mesh network
            print("[\(myPeerId)] Starting mesh network...")
            try await mesh.start()

            print("[\(myPeerId)] Mesh network running")

            // If we have a target, try to connect to it
            if let targetPeerId = target {
                print("")
                print("[\(myPeerId)] Waiting for target peer \(targetPeerId.prefix(16))...")

                var targetFound = false
                for _ in 0..<waitTime {
                    try await Task.sleep(nanoseconds: 1_000_000_000)

                    // Request peers from bootstrap
                    try await mesh.discoverPeers()

                    // Check if target is known
                    let knownPeers = await mesh.knownPeers()
                    if knownPeers.contains(targetPeerId) {
                        print("[\(myPeerId)] Found target peer!")
                        targetFound = true
                        break
                    }

                    // Check if target has sent us a message
                    if receivedMessages.contains(where: { $0.from == targetPeerId }) {
                        print("[\(myPeerId)] Target peer contacted us!")
                        targetFound = true
                        break
                    }
                }

                if targetFound {
                    // Try to establish connection
                    print("[\(myPeerId)] Attempting connection to target...")

                    do {
                        let connection = try await mesh.connect(to: targetPeerId)
                        print("[\(myPeerId)] Connected! Method: \(connection.method), Direct: \(connection.isDirect)")

                        // Send test messages
                        for i in 1...messageCount {
                            let message = "Test message \(i) from \(myPeerId)"
                            let data = message.data(using: .utf8)!
                            try await mesh.send(data, to: targetPeerId)
                            print("[\(myPeerId)] Sent: \(message)")
                            try await Task.sleep(nanoseconds: 500_000_000)
                        }

                        // Wait for responses
                        print("[\(myPeerId)] Waiting for responses...")
                        try await Task.sleep(nanoseconds: 5_000_000_000)

                    } catch {
                        print("[\(myPeerId)] Connection failed: \(error)")

                        // Even if connection fails, we might still receive messages
                        print("[\(myPeerId)] Waiting for potential relay messages...")
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    }

                    // Report results
                    print("")
                    print("[\(myPeerId)] === TEST RESULTS ===")
                    let stats = await mesh.statistics()
                    print("  NAT Type: \(stats.natType.rawValue)")
                    print("  Public Endpoint: \(stats.publicEndpoint ?? "none")")
                    print("  Known Peers: \(stats.peerCount)")
                    print("  Connections: \(stats.connectionCount)")
                    print("  Direct Connections: \(stats.directConnectionCount)")
                    print("  Messages Received: \(receivedMessages.count)")

                    for (from, data, isDirect) in receivedMessages {
                        let message = String(data: data, encoding: .utf8) ?? "<binary>"
                        let mode = isDirect ? "direct" : "relay"
                        print("    [\(mode)] from \(from.prefix(16))...: \(message)")
                    }

                    testPassed = receivedMessages.count > 0
                    print("")
                    print("[\(myPeerId)] Test \(testPassed ? "PASSED" : "FAILED")")

                } else {
                    print("[\(myPeerId)] Target peer not found within \(waitTime) seconds")
                    testPassed = false
                }

                if testMode {
                    await mesh.stop()
                    eventTask.cancel()
                    Foundation.exit(testPassed ? 0 : 1)
                }

            } else if relay {
                // Run as relay node
                print("[\(myPeerId)] Running as relay node. Press Ctrl+C to stop.")
            } else {
                // Run as regular node
                print("[\(myPeerId)] Running as mesh node. Press Ctrl+C to stop.")
            }

            // Wait for shutdown
            await waitForShutdown()

            print("[\(myPeerId)] Shutting down...")
            await mesh.stop()
            eventTask.cancel()

        } catch {
            logger.error("Error: \(error)")
            await mesh.stop()
            eventTask.cancel()
            throw error
        }
    }

    private func parseLogLevel(_ level: String) -> Logger.Level {
        switch level.lowercased() {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "warning", "warn": return .warning
        case "error": return .error
        case "critical": return .critical
        default: return .info
        }
    }

    private func waitForShutdown() async {
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            signalSource.setEventHandler {
                signalSource.cancel()
                continuation.resume()
            }
            signalSource.resume()
        }
    }
}
