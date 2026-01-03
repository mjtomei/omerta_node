import Foundation
import SwiftUI
import Combine

/// Manages VM state for the GUI
@MainActor
class VMManager: ObservableObject {
    static let shared = VMManager()

    @Published var activeVMs: [VMInfo] = []
    @Published var isExtensionActive: Bool = false
    @Published var isLoading: Bool = false

    private init() {
        Task {
            await refreshStatus()
        }
    }

    func refreshStatus() async {
        isExtensionActive = await ExtensionManager.shared.checkStatus().isApproved
        await loadActiveVMs()
    }

    func loadActiveVMs() async {
        // Load VMs from persistence
        let persistencePath = NSHomeDirectory() + "/.omerta/vms/active.json"

        guard FileManager.default.fileExists(atPath: persistencePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: persistencePath)),
              let vms = try? JSONDecoder().decode([VMInfo].self, from: data) else {
            activeVMs = []
            return
        }

        activeVMs = vms
    }

    func requestNewVM() {
        // Open request dialog
        let panel = VMRequestPanel()
        panel.show { [weak self] config in
            guard let config = config else { return }
            Task {
                await self?.createVM(with: config)
            }
        }
    }

    func createVM(with config: VMRequestConfig) async {
        isLoading = true
        defer { isLoading = false }

        // Run CLI command
        let process = Process()
        process.executableURL = Bundle.main.url(forAuxiliaryExecutable: "omerta")

        var args = ["vm", "request"]
        args += ["--provider", config.provider]
        args += ["--network-key", config.networkKey]

        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                await loadActiveVMs()
            } else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                print("VM request failed: \(output)")
            }
        } catch {
            print("Failed to run omerta CLI: \(error)")
        }
    }

    func releaseVM(_ vmId: UUID) async {
        isLoading = true
        defer { isLoading = false }

        // Run CLI command
        let process = Process()
        process.executableURL = Bundle.main.url(forAuxiliaryExecutable: "omerta")
        process.arguments = ["vm", "release", vmId.uuidString]

        do {
            try process.run()
            process.waitUntilExit()
            await loadActiveVMs()
        } catch {
            print("Failed to release VM: \(error)")
        }
    }

    func openTerminal() {
        // Open Terminal app
        NSWorkspace.shared.launchApplication("Terminal")
    }
}

/// VM information for display
struct VMInfo: Identifiable, Codable {
    let id: UUID
    let provider: String
    let vmIP: String
    let sshUser: String
    let createdAt: Date
    let networkId: String

    var displayName: String {
        "vm-\(id.uuidString.prefix(8))"
    }

    var sshCommand: String {
        "ssh \(sshUser)@\(vmIP)"
    }
}

/// Configuration for VM request
struct VMRequestConfig {
    let provider: String
    let networkKey: String
    let cpuCores: Int?
    let memoryMB: Int?
}

/// Panel for requesting a new VM
class VMRequestPanel {
    func show(completion: @escaping (VMRequestConfig?) -> Void) {
        // For now, use a simple dialog
        // In a full implementation, this would be a proper SwiftUI sheet

        let alert = NSAlert()
        alert.messageText = "Request VM"
        alert.informativeText = "Enter provider address and network key"
        alert.addButton(withTitle: "Request")
        alert.addButton(withTitle: "Cancel")

        let providerField = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        providerField.placeholderString = "provider:port"

        let keyField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        keyField.placeholderString = "network key (hex)"

        let stackView = NSStackView(views: [providerField, keyField])
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.frame = NSRect(x: 0, y: 0, width: 300, height: 64)

        alert.accessoryView = stackView

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let config = VMRequestConfig(
                provider: providerField.stringValue,
                networkKey: keyField.stringValue,
                cpuCores: nil,
                memoryMB: nil
            )
            completion(config)
        } else {
            completion(nil)
        }
    }
}
