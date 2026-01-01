import Foundation
import ArgumentParser
import OmertaCore

@main
struct OmertaCLI: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "omerta",
        abstract: "Omerta compute sharing client",
        version: "0.1.0"
    )
    
    mutating func run() async throws {
        print("Omerta CLI - Phase 0 Bootstrap Complete")
        print("Phase 1 (VM Management) in progress...")
    }
}
