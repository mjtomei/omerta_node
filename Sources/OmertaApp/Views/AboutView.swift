import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Omerta")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 0.6.0")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Ephemeral Compute Swarm")
                .font(.subheadline)

            Divider()
                .frame(width: 200)

            Text("Request VMs from a distributed network of providers. All traffic secured with WireGuard tunnels.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 250)

            Spacer()

            HStack(spacing: 16) {
                Button("GitHub") {
                    if let url = URL(string: "https://github.com/omerta/omerta") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)

                Button("Documentation") {
                    if let url = URL(string: "https://omerta.dev/docs") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(24)
        .frame(width: 300, height: 280)
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
