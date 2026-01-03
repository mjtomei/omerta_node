#!/bin/bash
# Sign the embedded CLI with developer identity and test VPN flow
# Run this locally on macOS (not over SSH) to access keychain

set -e

OMERTA_REPO="$HOME/omerta"
APP_BUNDLE="$HOME/Library/Developer/Xcode/DerivedData/Omerta-dazmcswhxzmdtnectdslbibkprwa/Build/Products/Debug/Omerta.app"
CLI_PATH="$APP_BUNDLE/Contents/MacOS/omerta-cli"

echo "=== Omerta CLI Signing and Test ==="
echo ""

# Check if app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: Omerta.app not found at $APP_BUNDLE"
    echo "Build the app in Xcode first."
    exit 1
fi

# Check if CLI exists
if [ ! -f "$CLI_PATH" ]; then
    echo "CLI not found in app bundle. Building and embedding..."
    cd "$OMERTA_REPO"
    swift build -c release --product omerta
    cp .build/release/omerta "$CLI_PATH"
fi

# Sign CLI with ad-hoc signature (network extension entitlement requires provisioning profile)
# The CLI will fall back to wg-quick which requires sudo
echo "Signing CLI..."
codesign --force --sign - "$CLI_PATH"

echo ""
echo "Verifying signature..."
codesign -dv "$CLI_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier"

echo ""
echo "=== CLI signed successfully ==="
echo ""

# Check if omertad is running
if ! pgrep -f "omertad" > /dev/null; then
    echo "Starting omertad..."
    cd "$OMERTA_REPO"
    codesign --force --sign - --entitlements /tmp/omertad.entitlements .build/debug/omertad 2>/dev/null || true
    nohup .build/debug/omertad start --port 51820 \
        --network-key 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
        > /tmp/omertad.log 2>&1 &
    sleep 2
    echo "omertad started"
fi

echo ""
echo "=== Cleaning up old WireGuard interfaces ==="
# Use the CLI cleanup command if available, otherwise manual cleanup
if "$CLI_PATH" vm cleanup --force 2>/dev/null; then
    echo "Cleaned up via CLI"
else
    # Fallback to manual cleanup
    for iface in $(sudo wg show interfaces 2>/dev/null); do
        echo "Stopping $iface..."
        sudo wg-quick down "$iface" 2>/dev/null || true
    done
    # Clean up old config files
    sudo rm -f /opt/homebrew/etc/wireguard/wg*.conf 2>/dev/null || true
    sudo rm -rf /var/folders/*/T/omerta-wg/*.conf 2>/dev/null || true
fi

echo ""
echo "=== Testing VM Request ==="
echo "(Using wg-quick fallback - requires sudo)"
echo ""

sudo "$CLI_PATH" vm request \
    --provider 127.0.0.1:51820 \
    --network-key 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    --cpu 2 \
    --memory 2048
