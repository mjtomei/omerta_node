import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultNetworkKey") private var defaultNetworkKey = ""
    @AppStorage("defaultProvider") private var defaultProvider = ""
    @AppStorage("sshUser") private var sshUser = "root"
    @AppStorage("sshKeyPath") private var sshKeyPath = "~/.ssh/id_rsa"
    @ObservedObject private var extensionManager = ExtensionManager.shared

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            networkTab
                .tabItem {
                    Label("Network", systemImage: "network")
                }

            extensionTab
                .tabItem {
                    Label("Extension", systemImage: "puzzlepiece.extension")
                }
        }
        .frame(width: 450, height: 300)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section("SSH Settings") {
                TextField("Default SSH User", text: $sshUser)
                TextField("SSH Key Path", text: $sshKeyPath)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: .constant(false))
                Toggle("Show in Dock", isOn: .constant(true))
            }
        }
        .formStyle(.grouped)
    }

    private var networkTab: some View {
        Form {
            Section("Default Provider") {
                TextField("Provider Address", text: $defaultProvider)
                    .textFieldStyle(.roundedBorder)
                Text("e.g., provider.example.com:51820")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Network Key") {
                SecureField("Default Network Key", text: $defaultNetworkKey)
                    .textFieldStyle(.roundedBorder)
                Text("64-character hex string (32 bytes)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var extensionTab: some View {
        Form {
            Section("VPN Extension Status") {
                HStack {
                    Text("Installed")
                    Spacer()
                    Image(systemName: extensionManager.status.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(extensionManager.status.isInstalled ? .green : .red)
                }

                HStack {
                    Text("Approved")
                    Spacer()
                    Image(systemName: extensionManager.status.isApproved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(extensionManager.status.isApproved ? .green : .red)
                }

                HStack {
                    Text("Enabled")
                    Spacer()
                    Image(systemName: extensionManager.status.isEnabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(extensionManager.status.isEnabled ? .green : .orange)
                }
            }

            Section {
                Button("Reinstall Extension") {
                    reinstallExtension()
                }
                .disabled(extensionManager.status.isInstalled)

                Button("Open System Preferences") {
                    openSystemPreferences()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task {
                _ = await extensionManager.checkStatus()
            }
        }
    }

    private func reinstallExtension() {
        Task {
            do {
                try await extensionManager.activateExtension()
            } catch {
                print("Failed to reinstall extension: \(error)")
            }
        }
    }

    private func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_VPN") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
