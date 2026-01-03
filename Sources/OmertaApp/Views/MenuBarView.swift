import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var vmManager = VMManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "network")
                    .foregroundColor(.accentColor)
                Text("Omerta")
                    .font(.headline)
                Spacer()
                statusIndicator
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Divider()

            // Active VMs
            if vmManager.activeVMs.isEmpty {
                HStack {
                    Spacer()
                    Text("No active VMs")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                ForEach(vmManager.activeVMs) { vm in
                    VMRowView(vm: vm)
                }
            }

            Divider()

            // Quick actions
            Button(action: { vmManager.requestNewVM() }) {
                Label("Request VM...", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            Button(action: { vmManager.openTerminal() }) {
                Label("Open Terminal", systemImage: "terminal")
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            Divider()

            // Settings and quit
            Button(action: { openSettings() }) {
                Label("Settings...", systemImage: "gear")
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit Omerta", systemImage: "power")
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(width: 280)
    }

    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(vmManager.isExtensionActive ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(vmManager.isExtensionActive ? "Ready" : "Setup Required")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

struct VMRowView: View {
    let vm: VMInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.displayName)
                    .font(.system(.body, design: .monospaced))
                Text(vm.sshCommand)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { copySSHCommand() }) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy SSH command")

            Button(action: { connectSSH() }) {
                Image(systemName: "terminal")
            }
            .buttonStyle(.plain)
            .help("Connect via SSH")

            Button(action: { releaseVM() }) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            .help("Release VM")
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func copySSHCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vm.sshCommand, forType: .string)
    }

    private func connectSSH() {
        // Open Terminal with SSH command
        let script = """
            tell application "Terminal"
                do script "\(vm.sshCommand)"
                activate
            end tell
            """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    private func releaseVM() {
        Task {
            await VMManager.shared.releaseVM(vm.id)
        }
    }
}

// MARK: - Preview

struct MenuBarView_Previews: PreviewProvider {
    static var previews: some View {
        MenuBarView()
    }
}
