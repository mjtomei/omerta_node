import Foundation

/// Checks for required system dependencies
public actor DependencyChecker {

    public init() {}

    /// Represents a system dependency requirement
    public struct Dependency: Sendable {
        public let name: String
        public let command: String
        public let minimumVersion: String?
        public let installInstructions: String

        public init(
            name: String,
            command: String,
            minimumVersion: String? = nil,
            installInstructions: String
        ) {
            self.name = name
            self.command = command
            self.minimumVersion = minimumVersion
            self.installInstructions = installInstructions
        }
    }

    /// Result of dependency check
    public struct DependencyStatus: Sendable {
        public let dependency: Dependency
        public let isInstalled: Bool
        public let installedVersion: String?
        public let meetsRequirement: Bool

        public var needsInstallation: Bool {
            !isInstalled || !meetsRequirement
        }
    }

    /// Error when dependencies are missing
    public struct MissingDependenciesError: Error, CustomStringConvertible {
        public let missing: [DependencyStatus]

        public var description: String {
            var message = "Missing required dependencies:\n"
            for status in missing {
                message += "\n  ❌ \(status.dependency.name)\n"
                if status.isInstalled, let version = status.installedVersion {
                    message += "     Installed version: \(version)\n"
                    if let required = status.dependency.minimumVersion {
                        message += "     Required version: \(required) or higher\n"
                    }
                }
                message += "     Install: \(status.dependency.installInstructions)\n"
            }
            return message
        }
    }

    // MARK: - Standard Dependencies
    // Note: WireGuard dependencies removed - mesh tunnels (OmertaTunnel) replace WireGuard
    // No external dependencies required for mesh networking

    /// All required dependencies for provider mode (none - mesh tunnels are pure Swift)
    public static let providerDependencies: [Dependency] = []

    /// All required dependencies for requester mode (none - mesh tunnels are pure Swift)
    public static let requesterDependencies: [Dependency] = []

    // MARK: - Checking

    /// Check if a specific dependency is installed
    public func checkDependency(_ dependency: Dependency) async -> DependencyStatus {
        let isInstalled = await isCommandAvailable(dependency.command)

        var installedVersion: String? = nil
        if isInstalled {
            installedVersion = await getCommandVersion(dependency.command)
        }

        // Version checking (if required)
        var meetsRequirement = isInstalled
        if let minVersion = dependency.minimumVersion,
           let version = installedVersion {
            meetsRequirement = compareVersions(version, isGreaterThanOrEqual: minVersion)
        }

        return DependencyStatus(
            dependency: dependency,
            isInstalled: isInstalled,
            installedVersion: installedVersion,
            meetsRequirement: meetsRequirement
        )
    }

    /// Check multiple dependencies
    public func checkDependencies(_ dependencies: [Dependency]) async -> [DependencyStatus] {
        var results: [DependencyStatus] = []
        for dependency in dependencies {
            let status = await checkDependency(dependency)
            results.append(status)
        }
        return results
    }

    /// Check dependencies and throw if any are missing
    public func verifyDependencies(_ dependencies: [Dependency]) async throws {
        let statuses = await checkDependencies(dependencies)
        let missing = statuses.filter { $0.needsInstallation }

        if !missing.isEmpty {
            throw MissingDependenciesError(missing: missing)
        }
    }

    /// Print dependency status report
    public func printDependencyReport(_ dependencies: [Dependency]) async {
        print("Checking system dependencies...")
        print()

        let statuses = await checkDependencies(dependencies)

        for status in statuses {
            let icon = status.meetsRequirement ? "✅" : "❌"
            print("\(icon) \(status.dependency.name)")

            if status.isInstalled {
                if let version = status.installedVersion {
                    print("   Version: \(version)")
                }
                if !status.meetsRequirement {
                    print("   ⚠️  Version requirement not met")
                    if let required = status.dependency.minimumVersion {
                        print("   Required: \(required) or higher")
                    }
                }
            } else {
                print("   Not installed")
            }

            if status.needsInstallation {
                print("   Install: \(status.dependency.installInstructions)")
            }
            print()
        }

        let allSatisfied = statuses.allSatisfy { $0.meetsRequirement }
        if allSatisfied {
            print("✅ All dependencies satisfied")
        } else {
            print("❌ Some dependencies are missing or outdated")
        }
    }

    // MARK: - Private Helpers

    private func isCommandAvailable(_ command: String) async -> Bool {
        // Check common installation paths
        let searchPaths = [
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/opt/homebrew/bin",  // Apple Silicon Homebrew
            "/usr/local/homebrew/bin",  // Intel Homebrew
            "/opt/local/bin"  // MacPorts
        ]

        for path in searchPaths {
            let commandPath = "\(path)/\(command)"
            if FileManager.default.fileExists(atPath: commandPath) {
                return true
            }
        }

        // Fallback: try using which
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func getCommandVersion(_ command: String) async -> String? {
        // Try common version flags
        let versionFlags = ["--version", "-v", "version"]

        for flag in versionFlags {
            if let version = await runCommand(command, arguments: [flag]) {
                // Extract version number from output
                let lines = version.components(separatedBy: .newlines)
                if let firstLine = lines.first, !firstLine.isEmpty {
                    return firstLine.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return "unknown"
    }

    private func findCommandPath(_ command: String) -> String? {
        let searchPaths = [
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/opt/homebrew/bin",
            "/usr/local/homebrew/bin",
            "/opt/local/bin"
        ]

        for path in searchPaths {
            let commandPath = "\(path)/\(command)"
            if FileManager.default.fileExists(atPath: commandPath) {
                return commandPath
            }
        }

        return nil
    }

    private func runCommand(_ command: String, arguments: [String]) async -> String? {
        // Find full path to command
        guard let commandPath = findCommandPath(command) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: commandPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func compareVersions(_ version1: String, isGreaterThanOrEqual version2: String) -> Bool {
        // Simple version comparison (can be enhanced)
        let v1Components = version1.components(separatedBy: ".").compactMap { Int($0) }
        let v2Components = version2.components(separatedBy: ".").compactMap { Int($0) }

        for i in 0..<max(v1Components.count, v2Components.count) {
            let v1 = i < v1Components.count ? v1Components[i] : 0
            let v2 = i < v2Components.count ? v2Components[i] : 0

            if v1 > v2 { return true }
            if v1 < v2 { return false }
        }

        return true // Equal versions
    }
}

// MARK: - Convenience Extensions

extension DependencyChecker {
    /// Quick check for provider mode dependencies
    public func verifyProviderMode() async throws {
        try await verifyDependencies(Self.providerDependencies)
    }

    /// Quick check for requester mode dependencies
    public func verifyRequesterMode() async throws {
        try await verifyDependencies(Self.requesterDependencies)
    }

    /// Print provider mode dependency report
    public func printProviderReport() async {
        await printDependencyReport(Self.providerDependencies)
    }

    /// Print requester mode dependency report
    public func printRequesterReport() async {
        await printDependencyReport(Self.requesterDependencies)
    }
}
