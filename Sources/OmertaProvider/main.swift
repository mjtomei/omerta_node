import Foundation
import ArgumentParser
import OmertaCore
import OmertaVM

@main
struct OmertaProvider: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "omertad",
        abstract: "Omerta provider daemon",
        version: "0.1.0"
    )
    
    @Option(name: .long, help: "Port to listen on")
    var port: Int = 50051
    
    mutating func run() async throws {
        print("Omerta Provider Daemon")
        print("Phase 1: VM Management ready")
        print("Listening on port \(port)...")
        
        // Keep running
        try await Task.sleep(for: .seconds(3600))
    }
}
