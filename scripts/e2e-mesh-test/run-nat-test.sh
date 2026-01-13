#!/bin/bash
# NAT Combination Test Runner
#
# Tests mesh connectivity between nodes with different NAT types.
# Requires root for network namespace manipulation.
#
# Usage:
#   sudo ./run-nat-test.sh <nat-type-1> <nat-type-2> [relay]
#
# Examples:
#   sudo ./run-nat-test.sh symmetric public          # Symmetric behind NAT to public peer
#   sudo ./run-nat-test.sh symmetric symmetric relay # Two symmetric NATs with relay
#   sudo ./run-nat-test.sh full-cone port-restrict   # Test hole punching

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMERTA_DIR="${OMERTA_DIR}"
MESH_BIN="$OMERTA_DIR/.build/debug/omerta-mesh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check for root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   echo "Usage: sudo $0 <nat-type-1> <nat-type-2> [relay]"
   exit 1
fi

usage() {
    echo "Usage: sudo $0 <nat-type-1> <nat-type-2> [relay]"
    echo ""
    echo "NAT Types:"
    echo "  public        No NAT (direct public IP)"
    echo "  full-cone     Full Cone NAT (easiest traversal)"
    echo "  addr-restrict Address-Restricted Cone NAT"
    echo "  port-restrict Port-Restricted Cone NAT"
    echo "  symmetric     Symmetric NAT (hardest, usually needs relay)"
    echo ""
    echo "Options:"
    echo "  relay         Include a relay node for fallback"
    echo ""
    echo "Examples:"
    echo "  sudo $0 full-cone full-cone           # Should hole punch"
    echo "  sudo $0 symmetric public              # Should hole punch"
    echo "  sudo $0 symmetric symmetric relay     # Needs relay"
    exit 1
}

NAT1=${1:-}
NAT2=${2:-}
USE_RELAY=${3:-}

[[ -z "$NAT1" || -z "$NAT2" ]] && usage

# Validate NAT types
valid_nats="public full-cone addr-restrict port-restrict symmetric"
if ! echo "$valid_nats" | grep -qw "$NAT1"; then
    echo -e "${RED}Invalid NAT type: $NAT1${NC}"
    usage
fi
if ! echo "$valid_nats" | grep -qw "$NAT2"; then
    echo -e "${RED}Invalid NAT type: $NAT2${NC}"
    usage
fi

# Build if needed
if [[ ! -f "$MESH_BIN" ]]; then
    echo "Building omerta-mesh..."
    cd "$OMERTA_DIR"
    swift build --product omerta-mesh
fi

# Generate test IDs
TEST_ID=$$
NS1="peer1-${TEST_ID}"
NS2="peer2-${TEST_ID}"
NS_RELAY="relay-${TEST_ID}"
PEER1_ID="peer1-$NAT1"
PEER2_ID="peer2-$NAT2"
RELAY_ID="relay-node"

# Ports
PORT1=9001
PORT2=9002
RELAY_PORT=9000

# Get host IP
HOST_IP=$(hostname -I | awk '{print $1}')

cleanup() {
    echo ""
    echo "Cleaning up..."

    # Kill any running mesh processes
    pkill -f "omerta-mesh.*peer1-" 2>/dev/null || true
    pkill -f "omerta-mesh.*peer2-" 2>/dev/null || true
    pkill -f "omerta-mesh.*relay-" 2>/dev/null || true

    # Teardown namespaces
    "$SCRIPT_DIR/nat-simulation.sh" teardown "$NS1" 2>/dev/null || true
    "$SCRIPT_DIR/nat-simulation.sh" teardown "$NS2" 2>/dev/null || true
    [[ "$USE_RELAY" == "relay" ]] && "$SCRIPT_DIR/nat-simulation.sh" teardown "$NS_RELAY" 2>/dev/null || true

    echo "Done"
}

trap cleanup EXIT

echo "============================================================"
echo "OmertaMesh NAT Combination Test"
echo "============================================================"
echo "Peer 1: $NAT1"
echo "Peer 2: $NAT2"
[[ "$USE_RELAY" == "relay" ]] && echo "Relay: enabled"
echo ""

# Setup namespaces
echo "Setting up network namespaces..."
"$SCRIPT_DIR/nat-simulation.sh" setup "$NAT1" "$NS1"
"$SCRIPT_DIR/nat-simulation.sh" setup "$NAT2" "$NS2"

# Get internal IPs
NS1_IP="10.200.$(echo "$NS1" | cksum | cut -d' ' -f1 | awk '{print $1 % 253 + 1}').2"
NS2_IP="10.200.$(echo "$NS2" | cksum | cut -d' ' -f1 | awk '{print $1 % 253 + 1}').2"

echo ""
echo "Namespace IPs:"
echo "  Peer 1 ($NAT1): $NS1_IP"
echo "  Peer 2 ($NAT2): $NS2_IP"

# Setup relay if requested
if [[ "$USE_RELAY" == "relay" ]]; then
    "$SCRIPT_DIR/nat-simulation.sh" setup public "$NS_RELAY"
    RELAY_IP="10.200.$(echo "$NS_RELAY" | cksum | cut -d' ' -f1 | awk '{print $1 % 253 + 1}').2"
    echo "  Relay: $RELAY_IP"
fi

echo ""
echo "Starting mesh nodes..."

# Start relay first if enabled
if [[ "$USE_RELAY" == "relay" ]]; then
    echo "  Starting relay node..."
    ip netns exec "$NS_RELAY" "$MESH_BIN" \
        --peer-id "$RELAY_ID" \
        --port $RELAY_PORT \
        --relay \
        --wait-time 60 \
        --test-mode \
        --log-level info &
    RELAY_PID=$!
    sleep 2
fi

# Determine bootstrap configuration
if [[ "$USE_RELAY" == "relay" ]]; then
    BOOTSTRAP1="--bootstrap ${RELAY_ID}@${RELAY_IP}:${RELAY_PORT}"
    BOOTSTRAP2="--bootstrap ${RELAY_ID}@${RELAY_IP}:${RELAY_PORT}"
else
    # For direct tests, peer2 bootstraps from peer1
    BOOTSTRAP1=""
    BOOTSTRAP2="--bootstrap ${PEER1_ID}@${NS1_IP}:${PORT1}"
fi

# Start Peer 1
echo "  Starting Peer 1 ($NAT1)..."
ip netns exec "$NS1" "$MESH_BIN" \
    --peer-id "$PEER1_ID" \
    --port $PORT1 \
    $BOOTSTRAP1 \
    --target "$PEER2_ID" \
    --wait-time 45 \
    --test-mode \
    --log-level info &
PEER1_PID=$!
sleep 2

# Start Peer 2
echo "  Starting Peer 2 ($NAT2)..."
ip netns exec "$NS2" "$MESH_BIN" \
    --peer-id "$PEER2_ID" \
    --port $PORT2 \
    $BOOTSTRAP2 \
    --target "$PEER1_ID" \
    --wait-time 40 \
    --test-mode \
    --log-level info &
PEER2_PID=$!

echo ""
echo "Waiting for test to complete..."
echo ""

# Wait for results
wait $PEER2_PID 2>/dev/null
PEER2_EXIT=$?

wait $PEER1_PID 2>/dev/null
PEER1_EXIT=$?

[[ "$USE_RELAY" == "relay" ]] && kill $RELAY_PID 2>/dev/null

echo ""
echo "============================================================"
echo "RESULTS"
echo "============================================================"
echo "Configuration: $NAT1 <-> $NAT2"
[[ "$USE_RELAY" == "relay" ]] && echo "Relay: enabled"
echo ""

# Predict expected outcome
predict_outcome() {
    local n1=$1
    local n2=$2

    # Public to anything should work
    [[ "$n1" == "public" || "$n2" == "public" ]] && echo "DIRECT" && return

    # Full cone to anything should work
    [[ "$n1" == "full-cone" || "$n2" == "full-cone" ]] && echo "DIRECT" && return

    # Address restricted can hole punch with each other
    [[ "$n1" == "addr-restrict" && "$n2" == "addr-restrict" ]] && echo "HOLE_PUNCH" && return
    [[ "$n1" == "addr-restrict" && "$n2" == "port-restrict" ]] && echo "HOLE_PUNCH" && return
    [[ "$n1" == "port-restrict" && "$n2" == "addr-restrict" ]] && echo "HOLE_PUNCH" && return

    # Port restricted can hole punch with each other
    [[ "$n1" == "port-restrict" && "$n2" == "port-restrict" ]] && echo "HOLE_PUNCH" && return

    # Symmetric usually needs relay
    [[ "$n1" == "symmetric" || "$n2" == "symmetric" ]] && echo "RELAY_NEEDED" && return

    echo "UNKNOWN"
}

EXPECTED=$(predict_outcome "$NAT1" "$NAT2")

echo "Expected outcome: $EXPECTED"
echo ""

if [[ $PEER1_EXIT -eq 0 && $PEER2_EXIT -eq 0 ]]; then
    echo -e "${GREEN}TEST PASSED${NC}"
    echo "Both peers successfully communicated!"
elif [[ $PEER1_EXIT -eq 0 || $PEER2_EXIT -eq 0 ]]; then
    echo -e "${YELLOW}PARTIAL SUCCESS${NC}"
    echo "One peer received messages"
    echo "  Peer 1 exit: $PEER1_EXIT"
    echo "  Peer 2 exit: $PEER2_EXIT"
else
    echo -e "${RED}TEST FAILED${NC}"
    echo "No communication established"
    echo "  Peer 1 exit: $PEER1_EXIT"
    echo "  Peer 2 exit: $PEER2_EXIT"

    if [[ "$EXPECTED" == "RELAY_NEEDED" && "$USE_RELAY" != "relay" ]]; then
        echo ""
        echo -e "${YELLOW}Note: This NAT combination typically requires a relay.${NC}"
        echo "Try: sudo $0 $NAT1 $NAT2 relay"
    fi
fi

exit $(( PEER1_EXIT || PEER2_EXIT ))
