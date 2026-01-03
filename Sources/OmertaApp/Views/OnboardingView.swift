import SwiftUI

struct OnboardingView: View {
    @ObservedObject private var extensionManager = ExtensionManager.shared
    @State private var currentStep = 0
    @State private var isActivating = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Welcome to Omerta")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Secure ephemeral compute for everyone")
                .font(.title3)
                .foregroundColor(.secondary)

            Spacer()

            // Step content
            Group {
                switch currentStep {
                case 0:
                    introStep
                case 1:
                    extensionStep
                case 2:
                    completeStep
                default:
                    EmptyView()
                }
            }
            .transition(.slide)

            Spacer()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(currentStep == 2 ? "Get Started" : "Continue") {
                    handleContinue()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isActivating)
            }
        }
        .padding(40)
        .frame(width: 500, height: 450)
    }

    private var introStep: some View {
        VStack(spacing: 16) {
            FeatureRow(
                icon: "desktopcomputer",
                title: "Request VMs",
                description: "Spin up VMs from network providers in seconds"
            )

            FeatureRow(
                icon: "lock.shield",
                title: "Secure by Default",
                description: "All traffic routed through encrypted WireGuard tunnels"
            )

            FeatureRow(
                icon: "clock.badge.xmark",
                title: "Ephemeral",
                description: "VMs are destroyed when you're done - no traces left behind"
            )
        }
    }

    private var extensionStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 40))
                .foregroundColor(.orange)

            Text("VPN Extension Required")
                .font(.headline)

            Text("Omerta needs to install a VPN extension to create secure tunnels to VMs. This is a one-time setup.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if let error = error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            if isActivating {
                ProgressView()
                    .padding()
            }
        }
    }

    private var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)

            Text("You're all set!")
                .font(.headline)

            Text("Omerta is ready to use. Click the menu bar icon to request VMs or use the command line.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Text("omerta vm request --provider <address> --network-key <key>")
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
    }

    private func handleContinue() {
        switch currentStep {
        case 0:
            withAnimation {
                currentStep = 1
            }

        case 1:
            activateExtension()

        case 2:
            dismiss()

        default:
            break
        }
    }

    private func activateExtension() {
        isActivating = true
        error = nil

        Task {
            do {
                try await extensionManager.createInitialConfiguration()
                await MainActor.run {
                    isActivating = false
                    withAnimation {
                        currentStep = 2
                    }
                }
            } catch {
                await MainActor.run {
                    isActivating = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView()
    }
}
