// main.swift
// Omerta Rendezvous Server - Signaling, STUN, and Relay

import Foundation
import ArgumentParser
import Logging
import OmertaRendezvousLib

@main
struct RendezvousCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "omerta-rendezvous",
        abstract: "Rendezvous server for NAT traversal coordination",
        discussion: """
            Runs signaling (WebSocket), STUN, and relay servers for coordinating
            peer-to-peer connections through NAT.
            """
    )

    @Option(name: .shortAndLong, help: "WebSocket signaling port")
    var port: Int = 8080

    @Option(name: .long, help: "STUN server port")
    var stunPort: UInt16 = 3478

    @Option(name: .long, help: "UDP relay port")
    var relayPort: UInt16 = 3479

    @Option(name: .shortAndLong, help: "Log level (trace, debug, info, warning, error)")
    var logLevel: String = "info"

    @Flag(name: .long, help: "Disable STUN server")
    var noStun: Bool = false

    @Flag(name: .long, help: "Disable relay server")
    var noRelay: Bool = false

    mutating func run() async throws {
        // Configure logging
        let level = parseLogLevel(logLevel)
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = level
            return handler
        }

        let logger = Logger(label: "io.omerta.rendezvous")
        logger.info("Starting Omerta Rendezvous Server")

        // Start servers
        let signaling = SignalingServer(port: port)
        var stun: STUNServer?
        var relay: RelayServer?

        do {
            // Start signaling server
            try await signaling.start()
            logger.info("Signaling server listening", metadata: ["port": "\(port)"])

            // Start STUN server
            if !noStun {
                let stunServer = STUNServer(port: stunPort)
                try await stunServer.start()
                stun = stunServer
                logger.info("STUN server listening", metadata: ["port": "\(stunPort)"])
            }

            // Start relay server
            if !noRelay {
                let relayServer = RelayServer(port: relayPort)
                try await relayServer.start()
                relay = relayServer
                logger.info("Relay server listening", metadata: ["port": "\(relayPort)"])
            }

            logger.info("All servers started successfully")
            printStartupInfo()

            // Wait for shutdown signal
            await waitForShutdown()

            logger.info("Shutting down...")

            // Stop servers
            if let relay = relay {
                await relay.stop()
            }
            if let stun = stun {
                await stun.stop()
            }
            await signaling.stop()

            logger.info("Shutdown complete")

        } catch {
            logger.error("Server error: \(error)")
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

    private func printStartupInfo() {
        print("""

        ╔════════════════════════════════════════════════════════════╗
        ║               Omerta Rendezvous Server                     ║
        ╠════════════════════════════════════════════════════════════╣
        ║  Signaling (WebSocket): ws://0.0.0.0:\(String(format: "%-5d", port))                  ║
        \(noStun ? "║  STUN: disabled                                            ║" : "║  STUN: 0.0.0.0:\(String(format: "%-5d", stunPort))                                    ║")
        \(noRelay ? "║  Relay: disabled                                           ║" : "║  Relay: 0.0.0.0:\(String(format: "%-5d", relayPort))                                   ║")
        ╠════════════════════════════════════════════════════════════╣
        ║  Press Ctrl+C to stop                                      ║
        ╚════════════════════════════════════════════════════════════╝

        """)
    }

    private func waitForShutdown() async {
        // Set up signal handling
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
