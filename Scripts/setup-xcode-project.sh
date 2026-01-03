#!/bin/bash
set -e

# Omerta Xcode Project Setup Script
# This script helps set up the Xcode project for building with Network Extension support

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Omerta Xcode Project Setup"
echo "=========================="
echo ""

# Check if we're on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: This script must be run on macOS"
    exit 1
fi

# Check for Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "Error: Xcode is not installed"
    exit 1
fi

echo "Project directory: $PROJECT_DIR"
echo ""

# Check for Apple Developer Team ID
if [[ -z "$DEVELOPMENT_TEAM" ]]; then
    echo "Please set your Apple Developer Team ID:"
    echo "  export DEVELOPMENT_TEAM=YOUR_TEAM_ID"
    echo ""
    echo "You can find your Team ID at:"
    echo "  https://developer.apple.com/account/#!/membership"
    echo ""
    read -p "Enter your Team ID (or press Enter to skip): " TEAM_ID
    if [[ -n "$TEAM_ID" ]]; then
        export DEVELOPMENT_TEAM="$TEAM_ID"
    fi
fi

# Generate Xcode project using swift package generate-xcodeproj (deprecated but works)
# Or we'll create instructions for manual setup

echo "Creating Xcode project structure..."

# Create project directory
mkdir -p "$PROJECT_DIR/Omerta.xcodeproj"

cat > "$PROJECT_DIR/XCODE_SETUP.md" << 'EOF'
# Xcode Project Setup for Network Extension

Since Network Extensions require specific Xcode configuration, follow these steps to set up the project:

## Prerequisites

1. Apple Developer Account (paid, $99/year)
2. Xcode 14+ installed
3. Network Extension entitlement enabled in your Developer account

## Step 1: Create Xcode Project

1. Open Xcode
2. File → New → Project
3. Choose "App" under macOS
4. Configure:
   - Product Name: `Omerta`
   - Team: Your Apple Developer Team
   - Organization Identifier: `com.omerta`
   - Bundle Identifier: `com.omerta.Omerta`
   - Interface: SwiftUI
   - Language: Swift

## Step 2: Add Network Extension Target

1. File → New → Target
2. Choose "Network Extension" under macOS
3. Configure:
   - Product Name: `OmertaVPNExtension`
   - Bundle Identifier: `com.omerta.Omerta.vpn-extension`
   - Provider Type: Packet Tunnel Provider
4. When prompted, activate the scheme

## Step 3: Add Existing Sources

1. Remove the auto-generated source files from both targets
2. Add existing sources:
   - Drag `Sources/OmertaApp/` into the Omerta target
   - Drag `Sources/OmertaVPNExtension/` into the OmertaVPNExtension target
3. Add library dependencies:
   - File → Add Packages
   - Add this repository's SPM packages to the Omerta target:
     - OmertaCore
     - OmertaNetwork
     - OmertaConsumer

## Step 4: Configure Entitlements

1. Select the Omerta target → Signing & Capabilities
2. Add capabilities:
   - Network Extensions (Packet Tunnel)
   - System Extension
   - Keychain Sharing (group: `com.omerta.shared`)

3. Select the OmertaVPNExtension target → Signing & Capabilities
4. Add capabilities:
   - Network Extensions (Packet Tunnel)
   - Keychain Sharing (group: `com.omerta.shared`)

## Step 5: Add WireGuardKit

1. File → Add Packages
2. Add: `https://github.com/WireGuard/wireguard-apple`
3. Add `WireGuardKit` to the OmertaVPNExtension target

## Step 6: Embed CLI Tool

1. Select the Omerta target → Build Phases
2. Add "Copy Files" phase
3. Configure:
   - Destination: Executables
   - Add the `omerta` CLI binary

## Step 7: Configure Build Settings

For both targets, ensure:
- `CODE_SIGN_IDENTITY` = "Apple Development" or "Developer ID Application"
- `DEVELOPMENT_TEAM` = Your Team ID
- `CODE_SIGN_STYLE` = Automatic

## Step 8: Request Network Extension Entitlement

1. Go to https://developer.apple.com/account/resources/identifiers
2. Edit the App ID for `com.omerta.Omerta`
3. Enable "Network Extensions"
4. Do the same for `com.omerta.Omerta.vpn-extension`

## Building

```bash
# Debug build
xcodebuild -project Omerta.xcodeproj -scheme Omerta -configuration Debug build

# Release build (signed)
xcodebuild -project Omerta.xcodeproj -scheme Omerta -configuration Release build
```

## Testing

1. Build and run from Xcode
2. First launch will prompt for VPN permission
3. Approve in System Preferences → Security & Privacy → Privacy → VPN & Network

## Troubleshooting

### "Network Extension entitlement is missing"
- Ensure the entitlement is added in Xcode Signing & Capabilities
- Verify the App ID has Network Extensions enabled in Developer portal

### "System Extension blocked"
- Go to System Preferences → Security & Privacy → General
- Click "Allow" for the Omerta extension

### Extension not loading
- Check Console.app for `nesessionmanager` logs
- Ensure the extension bundle ID matches in all places
EOF

echo ""
echo "Setup instructions written to: $PROJECT_DIR/XCODE_SETUP.md"
echo ""
echo "Next steps:"
echo "1. Open $PROJECT_DIR/XCODE_SETUP.md"
echo "2. Follow the manual setup instructions in Xcode"
echo ""
echo "Alternatively, if you have an existing Xcode project generator preference,"
echo "you can use that and add the sources manually."
