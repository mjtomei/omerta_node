#!/bin/bash
# Sign Omerta binaries with Apple Developer identity for macOS Virtualization framework

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/debug"
ENTITLEMENTS="$PROJECT_DIR/Omerta.entitlements"

# Find signing identity
IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [ -z "$IDENTITY" ]; then
    echo "Error: No Apple Development signing identity found"
    echo "Run 'security find-identity -v -p codesigning' to see available identities"
    exit 1
fi

echo "Using signing identity: $IDENTITY"
echo "Entitlements: $ENTITLEMENTS"
echo ""

# Sign omertad
echo "Signing omertad..."
codesign --force --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$BUILD_DIR/omertad"

# Sign omerta
echo "Signing omerta..."
codesign --force --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$BUILD_DIR/omerta"

echo ""
echo "Verifying signatures..."
codesign -dv "$BUILD_DIR/omertad" 2>&1 | grep -E "Authority|Signature"
codesign -dv "$BUILD_DIR/omerta" 2>&1 | grep -E "Authority|Signature"

echo ""
echo "Verifying entitlements..."
codesign -d --entitlements - "$BUILD_DIR/omertad" 2>&1 | grep -E "virtualization|network"

echo ""
echo "Done! Binaries signed successfully."
