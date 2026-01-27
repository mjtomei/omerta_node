#!/bin/bash
# E2E Mesh Network Test using OmertaMesh Swift code
#
# This test runs mesh nodes on Linux and Mac that discover each other
# via bootstrap and communicate directly using the OmertaMesh library.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMERTA_DIR="${OMERTA_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MAC_HOST="${MAC_HOST:-user@mac.local}"
MAC_OMERTA_DIR="${MAC_OMERTA_DIR:-~/omerta}"

# Get IPs
LINUX_HOST_IP=$(hostname -I | awk '{print $1}')
MAC_HOST_IP=$(ssh $MAC_HOST "ipconfig getifaddr en0 2>/dev/null || echo unknown")

# Ports
LINUX_PORT=9000
MAC_PORT=9001

echo "============================================================"
echo "OmertaMesh E2E Test"
echo "============================================================"
echo "Linux: $LINUX_HOST_IP:$LINUX_PORT"
echo "Mac: $MAC_HOST_IP:$MAC_PORT"
echo ""

cleanup() {
    echo ""
    echo "Cleaning up..."
    [ -n "$LOCAL_MESH_PID" ] && kill $LOCAL_MESH_PID 2>/dev/null || true
    ssh $MAC_HOST "pkill -f omerta-mesh" 2>/dev/null || true
    echo "Done"
}

trap cleanup EXIT

# Build binaries
echo "Building on Linux..."
cd "$OMERTA_DIR"
swift build --product omerta-mesh 2>&1 | tail -5
MESH_BIN="$OMERTA_DIR/.build/debug/omerta-mesh"

echo ""
echo "Building on Mac..."
ssh $MAC_HOST "cd $MAC_OMERTA_DIR && swift build --product omerta-mesh 2>&1 | tail -5"
MAC_MESH_BIN="$MAC_OMERTA_DIR/.build/debug/omerta-mesh"

# Generate peer IDs
TEST_ID=$$
LINUX_PEER="linux-$TEST_ID"
MAC_PEER="mac-$TEST_ID"

# Start Linux mesh node first (as relay, waiting for Mac)
echo ""
echo "Starting Linux mesh node ($LINUX_PEER on port $LINUX_PORT)..."
echo "  Will wait for Mac peer and exchange messages"
$MESH_BIN \
    --peer-id "$LINUX_PEER" \
    --port $LINUX_PORT \
    --relay \
    --target "$MAC_PEER" \
    --wait-time 45 \
    --test-mode \
    --log-level info 2>&1 &
LOCAL_MESH_PID=$!
sleep 3

# Start Mac mesh node with bootstrap to Linux
echo ""
echo "Starting Mac mesh node ($MAC_PEER on port $MAC_PORT)..."
echo "  Bootstrapping to Linux at $LINUX_HOST_IP:$LINUX_PORT"
ssh $MAC_HOST "$MAC_MESH_BIN \
    --peer-id '$MAC_PEER' \
    --port $MAC_PORT \
    --bootstrap '$LINUX_PEER@$LINUX_HOST_IP:$LINUX_PORT' \
    --target '$LINUX_PEER' \
    --wait-time 45 \
    --test-mode \
    --log-level info" 2>&1 &
MAC_SSH_PID=$!

# Wait for results
echo ""
echo "Waiting for test to complete (up to 45 seconds)..."
echo ""

wait $LOCAL_MESH_PID 2>/dev/null
LINUX_EXIT=$?

wait $MAC_SSH_PID 2>/dev/null
MAC_EXIT=$?

echo ""
echo "============================================================"
echo "RESULTS"
echo "============================================================"
echo "Linux exit: $LINUX_EXIT"
echo "Mac exit: $MAC_EXIT"

if [ $LINUX_EXIT -eq 0 ] && [ $MAC_EXIT -eq 0 ]; then
    echo ""
    echo "SUCCESS: OmertaMesh nodes communicated!"
    exit 0
else
    echo ""
    echo "Test incomplete"
    exit 1
fi
