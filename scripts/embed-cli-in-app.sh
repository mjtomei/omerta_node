#!/bin/bash
# Embed the omerta CLI binary into Omerta.app bundle
# Run this after building both the CLI and the app

set -e

# Paths
OMERTA_REPO="$HOME/omerta"
CLI_BINARY="$OMERTA_REPO/.build/release/omerta"
APP_BUNDLE="$OMERTA_REPO/Omerta/Omerta/build/Debug/Omerta.app"
APP_MACOS_DIR="$APP_BUNDLE/Contents/MacOS"

echo "Embedding omerta CLI in Omerta.app bundle..."

# Build CLI in release mode
echo "Building CLI in release mode..."
cd "$OMERTA_REPO"
swift build -c release --product omerta

# Check that both exist
if [ ! -f "$CLI_BINARY" ]; then
    echo "Error: CLI binary not found at $CLI_BINARY"
    echo "Run 'swift build -c release --product omerta' first"
    exit 1
fi

if [ ! -d "$APP_BUNDLE" ]; then
    # Try the Xcode DerivedData location
    APP_BUNDLE="$HOME/Library/Developer/Xcode/DerivedData/Omerta-*/Build/Products/Debug/Omerta.app"
    APP_BUNDLE=$(echo $APP_BUNDLE)  # Expand glob
    APP_MACOS_DIR="$APP_BUNDLE/Contents/MacOS"

    if [ ! -d "$APP_BUNDLE" ]; then
        echo "Error: Omerta.app not found"
        echo "Build the app in Xcode first"
        exit 1
    fi
fi

echo "Found app bundle at: $APP_BUNDLE"

# Copy CLI binary
echo "Copying CLI binary..."
cp "$CLI_BINARY" "$APP_MACOS_DIR/omerta"

# Re-sign the CLI binary with the same identity as the app
echo "Re-signing CLI binary..."
APP_IDENTITY=$(codesign -dv "$APP_BUNDLE" 2>&1 | grep "Authority=" | head -1 | sed 's/Authority=//')
if [ -n "$APP_IDENTITY" ]; then
    codesign --force --sign "$APP_IDENTITY" --options runtime "$APP_MACOS_DIR/omerta"
fi

# Re-sign the entire app bundle
echo "Re-signing app bundle..."
codesign --force --deep --sign "$APP_IDENTITY" --options runtime "$APP_BUNDLE"

echo ""
echo "Done! CLI embedded at: $APP_MACOS_DIR/omerta"
echo ""
echo "Users can now run the CLI from within the app bundle:"
echo "  /Applications/Omerta.app/Contents/MacOS/omerta"
echo ""
echo "Or create a symlink:"
echo "  ln -sf /Applications/Omerta.app/Contents/MacOS/omerta /usr/local/bin/omerta"
