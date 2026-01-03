import SwiftUI
import AppKit

@main
struct OmertaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Omerta") {
                    appDelegate.showAboutWindow()
                }
            }
        }

        // Menu bar extra (status item)
        MenuBarExtra("Omerta", systemImage: "network") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check if Network Extension is installed/approved
        Task {
            await checkExtensionStatus()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menu bar even if windows are closed
        return false
    }

    private func checkExtensionStatus() async {
        let manager = ExtensionManager.shared
        let status = await manager.checkStatus()

        if !status.isInstalled {
            // Show onboarding to install extension
            await MainActor.run {
                showOnboarding()
            }
        }
    }

    func showAboutWindow() {
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "About Omerta"
            window.contentView = NSHostingView(rootView: AboutView())
            aboutWindow = window
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Welcome to Omerta"
        window.contentView = NSHostingView(rootView: OnboardingView())
        window.makeKeyAndOrderFront(nil)
    }
}
