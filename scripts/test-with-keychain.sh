#!/bin/bash
# Run tests with keychain entitlements on macOS
# This script builds, signs, and runs the test binary with proper entitlements

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENTITLEMENTS="$PROJECT_ROOT/Tests/OmertaCoreTests/OmertaCoreTests.entitlements"

# Check if we're on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "This script is only needed on macOS. Running swift test directly."
    exec swift test "$@"
fi

# Build the tests
echo "Building tests..."
swift build --build-tests

# Find the xctest bundle
XCTEST_BUNDLE=$(find "$PROJECT_ROOT/.build" -name "*.xctest" -type d 2>/dev/null | head -1)

if [[ -z "$XCTEST_BUNDLE" ]]; then
    echo "Error: Could not find xctest bundle"
    exit 1
fi

echo "Found test bundle: $XCTEST_BUNDLE"

# Find the executable inside the bundle
BUNDLE_NAME=$(basename "$XCTEST_BUNDLE" .xctest)
EXECUTABLE="$XCTEST_BUNDLE/Contents/MacOS/$BUNDLE_NAME"

if [[ ! -f "$EXECUTABLE" ]]; then
    echo "Error: Could not find executable at $EXECUTABLE"
    exit 1
fi

# Sign with ad-hoc identity and entitlements
echo "Signing with ad-hoc identity and entitlements..."
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$EXECUTABLE"

# Verify signing
echo "Verifying signature..."
codesign -dvv "$EXECUTABLE" 2>&1 | grep -E "^(Authority|Signature|Identifier)" || true

# Run tests using xctest directly
echo ""
echo "Running tests..."

# Parse arguments for test filtering
FILTER=""
REMAINING_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --filter)
            FILTER="$2"
            shift 2
            ;;
        --filter=*)
            FILTER="${1#*=}"
            shift
            ;;
        *)
            REMAINING_ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ -n "$FILTER" ]]; then
    # Run with filter - xctest uses -XCTest flag for filtering
    xcrun xctest -XCTest "$FILTER" "$XCTEST_BUNDLE"
else
    xcrun xctest "$XCTEST_BUNDLE"
fi
