# Network Extension Implementation Plan

## Overview

Replace sudo-based WireGuard operations with macOS Network Extension framework. This allows VPN tunnel management without elevated privileges after initial user approval.

## Architecture Changes

```
Current:
  omerta (CLI) -> EphemeralVPN -> sudo wg-quick -> kernel

Proposed:
  Omerta.app/
  ├── omerta (CLI embedded)
  └── OmertaVPN.appex (Network Extension)
        └── PacketTunnelProvider -> WireGuardKit -> NetworkExtension.framework
```

## Implementation Steps

### Phase 1: Project Structure

1. **Create Xcode project wrapper** (or SPM with custom build)
   - Main app target: `Omerta.app`
   - Network Extension target: `OmertaVPN.appex`
   - Shared framework: `OmertaVPNShared` (for IPC between app and extension)

2. **Directory structure**:
   ```
   omerta/
   ├── Package.swift              # Existing SPM (libraries only)
   ├── Omerta.xcodeproj/          # New Xcode project
   ├── Sources/
   │   ├── OmertaApp/             # Main app (hosts CLI + extension)
   │   │   ├── main.swift
   │   │   └── ExtensionManager.swift
   │   ├── OmertaVPNExtension/    # Network Extension
   │   │   ├── PacketTunnelProvider.swift
   │   │   └── Info.plist
   │   └── ... (existing sources)
   └── Entitlements/
       ├── Omerta.entitlements
       └── OmertaVPN.entitlements
   ```

### Phase 2: Network Extension Target

1. **PacketTunnelProvider.swift**:
   ```swift
   import NetworkExtension
   import WireGuardKit

   class PacketTunnelProvider: NEPacketTunnelProvider {
       private var adapter: WireGuardAdapter?

       override func startTunnel(options: [String: NSObject]?) async throws {
           guard let configString = options?["wgConfig"] as? String,
                 let config = try? TunnelConfiguration(fromWgQuickConfig: configString)
           else {
               throw NEVPNError(.configurationInvalid)
           }

           adapter = WireGuardAdapter(with: self) { _, message in
               NSLog("WireGuard: \(message)")
           }

           try await adapter?.start(tunnelConfiguration: config)
       }

       override func stopTunnel(with reason: NEProviderStopReason) async {
           await adapter?.stop()
       }
   }
   ```

2. **Entitlements** (`OmertaVPN.entitlements`):
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
   <plist version="1.0">
   <dict>
       <key>com.apple.developer.networking.networkextension</key>
       <array>
           <string>packet-tunnel-provider</string>
       </array>
       <key>keychain-access-groups</key>
       <array>
           <string>$(AppIdentifierPrefix)com.omerta.shared</string>
       </array>
   </dict>
   </plist>
   ```

3. **Info.plist** for extension:
   ```xml
   <key>NSExtension</key>
   <dict>
       <key>NSExtensionPointIdentifier</key>
       <string>com.apple.networkextension.packet-tunnel</string>
       <key>NSExtensionPrincipalClass</key>
       <string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
   </dict>
   ```

### Phase 3: VPN Layer Replacement

1. **New NetworkExtensionVPN.swift** (replaces EphemeralVPN on macOS):
   ```swift
   import NetworkExtension
   import OmertaCore

   public actor NetworkExtensionVPN {
       private var managers: [UUID: NETunnelProviderManager] = [:]

       public func createVPNForJob(_ jobId: UUID) async throws -> VPNConfiguration {
           // Generate WireGuard config (reuse existing key generation)
           let config = generateWireGuardConfig(for: jobId)

           // Create and save tunnel manager
           let manager = NETunnelProviderManager()
           let proto = NETunnelProviderProtocol()
           proto.providerBundleIdentifier = "com.omerta.vpn-extension"
           proto.providerConfiguration = ["wgConfig": config.clientConfig]
           proto.serverAddress = "Omerta VPN - \(jobId.uuidString.prefix(8))"

           manager.protocolConfiguration = proto
           manager.localizedDescription = "Omerta VM Tunnel"
           manager.isEnabled = true

           try await manager.saveToPreferences()
           try await manager.loadFromPreferences()

           // Start tunnel
           let session = manager.connection as! NETunnelProviderSession
           try session.startVPNTunnel(options: ["wgConfig": config.serverConfig as NSString])

           // Wait for connection
           try await waitForConnection(session)

           managers[jobId] = manager
           return config.vpnConfiguration
       }

       public func destroyVPN(for jobId: UUID) async throws {
           guard let manager = managers[jobId] else { return }
           manager.connection.stopVPNTunnel()
           try await manager.removeFromPreferences()
           managers.removeValue(forKey: jobId)
       }
   }
   ```

2. **Platform abstraction**:
   ```swift
   // VPNProvider.swift - protocol for platform-specific implementations
   public protocol VPNProvider: Actor {
       func createVPN(for jobId: UUID) async throws -> VPNConfiguration
       func destroyVPN(for jobId: UUID) async throws
       func isConnected(for jobId: UUID) async -> Bool
   }

   // Factory
   public func makeVPNProvider() -> any VPNProvider {
       #if os(macOS)
       return NetworkExtensionVPN()
       #else
       return EphemeralVPN()  // Linux keeps sudo-based approach
       #endif
   }
   ```

### Phase 4: Extension Activation

1. **ExtensionManager.swift** (handles first-run approval):
   ```swift
   import SystemExtensions
   import NetworkExtension

   class ExtensionManager: NSObject, OSSystemExtensionRequestDelegate {
       func activateExtension() async throws {
           let request = OSSystemExtensionRequest.activationRequest(
               forExtensionWithIdentifier: "com.omerta.vpn-extension",
               queue: .main
           )
           request.delegate = self
           OSSystemExtensionManager.shared.submitRequest(request)

           // Wait for user approval...
       }

       func checkExtensionStatus() async -> Bool {
           // Check if extension is already approved
       }
   }
   ```

2. **CLI integration**:
   ```swift
   // In VMRequest command
   struct VMRequest: AsyncParsableCommand {
       mutating func run() async throws {
           // Check if Network Extension is activated
           let extManager = ExtensionManager()
           if !await extManager.checkExtensionStatus() {
               print("First run: Network Extension approval required.")
               print("A system dialog will appear - please approve the VPN extension.")
               try await extManager.activateExtension()
           }

           // Proceed with VM request...
       }
   }
   ```

### Phase 5: Dependencies

1. **Add WireGuardKit**:
   ```swift
   // Package.swift
   dependencies: [
       .package(url: "https://github.com/WireGuard/wireguard-apple", from: "1.0.16"),
   ],
   targets: [
       .target(
           name: "OmertaVPNExtension",
           dependencies: [
               .product(name: "WireGuardKit", package: "wireguard-apple"),
           ]
       ),
   ]
   ```

### Phase 6: Build & Sign

**Option A: Development (no paid account)**
```bash
# One-time: Enable developer mode for system extensions
# (Requires Recovery Mode to disable SIP first)
systemextensionsctl developer on

# Build with local signing
xcodebuild -scheme Omerta -configuration Debug CODE_SIGN_IDENTITY="-"
```

**Option B: With Apple Developer Account**
```bash
# Create provisioning profiles in Apple Developer portal
# Enable "Network Extension" capability
xcodebuild -scheme Omerta -configuration Release \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="YOURTEAMID"
```

## File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `Omerta.xcodeproj/` | Create | Xcode project for app bundle |
| `Sources/OmertaApp/` | Create | Main app wrapper |
| `Sources/OmertaVPNExtension/` | Create | Network Extension target |
| `Sources/OmertaNetwork/VPN/NetworkExtensionVPN.swift` | Create | NE-based VPN implementation |
| `Sources/OmertaNetwork/VPN/VPNProvider.swift` | Create | Platform abstraction |
| `Sources/OmertaNetwork/VPN/EphemeralVPN.swift` | Modify | Keep for Linux, wrap with protocol |
| `Sources/OmertaConsumer/ConsumerClient.swift` | Modify | Use VPNProvider protocol |
| `Package.swift` | Modify | Add WireGuardKit dependency |
| `Entitlements/*.entitlements` | Create | Code signing entitlements |

## User Experience

**First run:**
```
$ omerta vm request --provider peer.example.com:51820
First run setup required.
Omerta needs to install a VPN extension for secure VM connections.

[System dialog appears: "Omerta.app wants to add VPN configurations"]
→ User clicks "Allow"

[System Preferences opens to Security & Privacy]
→ User clicks "Allow" for the system extension

Extension activated successfully.
Requesting VM...
```

**Subsequent runs:**
```
$ omerta vm request --provider peer.example.com:51820
Requesting VM...
VM created successfully!
  ID: abc123
  SSH: ssh root@10.99.0.2
```

## Timeline Estimate

- Phase 1-2: Project structure + extension target (scaffolding)
- Phase 3: VPN layer replacement (core logic)
- Phase 4: Extension activation flow (UX)
- Phase 5-6: Dependencies + build (integration)

## Risks & Mitigations

1. **Apple Developer Account** - Required for distribution; development can use `systemextensionsctl developer on`

2. **User approval UX** - First-run requires clicking through dialogs; clear messaging helps

3. **Extension sandbox** - Limited capabilities; WireGuardKit handles this

4. **Cross-platform** - Keep EphemeralVPN for Linux; abstract behind protocol

## Questions Before Starting

1. Do you have an Apple Developer account, or should I optimize for local development mode?

2. Should the CLI remain standalone (launches hidden app for extension), or should we have a proper GUI app?

3. Keep Linux support with the sudo-based approach, or focus solely on macOS for now?
