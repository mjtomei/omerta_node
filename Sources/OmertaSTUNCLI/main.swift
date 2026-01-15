// main.swift
// Omerta STUN Server - NAT endpoint discovery

import Foundation
import ArgumentParser
import Logging
import OmertaSTUN

@main
struct STUNCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "omerta-stun",
        abstract: "STUN server for NAT endpoint discovery",
        discussion: """
            Runs a STUN server (RFC 5389) that helps peers discover their
            public IP address and port for NAT traversal.
            """
    )

    @Option(name: .shortAndLong, help: "UDP port to listen on")
    var port: UInt16 = 3478

    @Option(name: .shortAndLong, help: "Log level (trace, debug, info, warning, error)")
    var logLevel: String = "info"

    mutating func run() async throws {
        // Configure logging
        let level = parseLogLevel(logLevel)
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = level
            return handler
        }

        let logger = Logger(label: "io.omerta.stun")
        logger.info("Starting Omerta STUN Server")

        let server = STUNServer(port: port)

        do {
            try await server.start()

            print("""

            ╔════════════════════════════════════════════════════════════╗
            ║                   Omerta STUN Server                       ║
            ╠════════════════════════════════════════════════════════════╣
            ║  Listening: 0.0.0.0:\(String(format: "%-5d", port))                                   ║
            ╠════════════════════════════════════════════════════════════╣
            ║  Press Ctrl+C to stop                                      ║
            ╚════════════════════════════════════════════════════════════╝

            """)

            // Wait for shutdown signal
            await waitForShutdown()

            logger.info("Shutting down...")
            await server.stop()
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
