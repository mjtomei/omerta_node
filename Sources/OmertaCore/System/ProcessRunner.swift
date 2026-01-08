import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Utility for running processes with automatic root privilege handling.
/// When the current process is already running as root, commands are executed directly.
/// When not root, sudo is prepended automatically.
public enum ProcessRunner {

    /// Check if the current process is running as root (uid 0)
    public static var isRoot: Bool {
        return getuid() == 0
    }

    /// Get the executable path - either the command directly (if root) or /usr/bin/sudo
    public static func executablePath(for command: String) -> String {
        if isRoot {
            return command
        } else {
            return "/usr/bin/sudo"
        }
    }

    /// Build arguments array - prepends the command if using sudo
    public static func arguments(command: String, args: [String]) -> [String] {
        if isRoot {
            return args
        } else {
            return [command] + args
        }
    }

    /// Create a configured Process for running a privileged command
    /// - Parameters:
    ///   - command: The command to run (e.g., "/usr/sbin/ip", "/opt/homebrew/bin/wg-quick")
    ///   - arguments: Arguments to pass to the command
    ///   - environment: Optional environment variables
    /// - Returns: A configured Process ready to run
    public static func createProcess(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> Process {
        let process = Process()

        if isRoot {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = [command] + arguments
        }

        if let env = environment {
            process.environment = env
        }

        return process
    }

    /// Create a Process that runs a command with PATH set (useful for wg-quick, etc.)
    /// - Parameters:
    ///   - command: The command to run
    ///   - arguments: Arguments to pass
    ///   - pathValue: PATH environment value
    /// - Returns: A configured Process
    public static func createProcessWithPath(
        command: String,
        arguments: [String],
        pathValue: String
    ) -> Process {
        let process = Process()

        if isRoot {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            process.environment = ["PATH": pathValue]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            // Use env to set PATH when running via sudo
            process.arguments = ["env", "PATH=\(pathValue)", command] + arguments
            process.environment = ["PATH": pathValue]
        }

        return process
    }

    /// Run a privileged command and wait for completion
    /// - Parameters:
    ///   - command: The command to run
    ///   - arguments: Arguments to pass
    ///   - environment: Optional environment variables
    /// - Returns: A tuple of (exitCode, stdout, stderr)
    @discardableResult
    public static func run(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = createProcess(command: command, arguments: arguments, environment: environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
