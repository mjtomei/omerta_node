#!/bin/bash
# Isolated Namespace NAT Test
#
# This script creates a realistic NAT test environment using network namespaces
# with proper isolation - peers can ONLY communicate through the NAT gateways.
#
# Architecture:
#
#   ┌─────────────────────────────────────────────────────────────────┐
#   │                          Host                                    │
#   │                                                                  │
#   │  ┌──────────────────────────────────────────────────────────┐   │
#   │  │               "Internet" namespace                        │   │
#   │  │             (192.168.100.0/24)                           │   │
#   │  │                                                          │   │
#   │  │    STUN1:3478    STUN2:3479    Relay:9000               │   │
#   │  │                                                          │   │
#   │  └─────┬───────────────────────────────────┬────────────────┘   │
#   │        │                                   │                     │
#   │   ┌────┴────┐                         ┌────┴────┐               │
#   │   │ NAT GW 1│                         │ NAT GW 2│               │
#   │   │  .100.1 │                         │  .100.2 │               │
#   │   └────┬────┘                         └────┬────┘               │
#   │        │10.0.1.1                           │10.0.2.1            │
#   │   ┌────┴────┐                         ┌────┴────┐               │
#   │   │ Peer 1  │                         │ Peer 2  │               │
#   │   │10.0.1.2 │                         │10.0.2.2 │               │
#   │   └─────────┘                         └─────────┘               │
#   │                                                                  │
#   └──────────────────────────────────────────────────────────────────┘
#
# Usage:
#   sudo ./run-isolated-test.sh <nat-type-1> <nat-type-2> [relay]
#
# NAT Types: public, full-cone, addr-restrict, port-restrict, symmetric

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMERTA_DIR="${OMERTA_DIR}"
MESH_BIN="$OMERTA_DIR/.build/debug/omerta-mesh"
RENDEZVOUS_BIN="$OMERTA_DIR/.build/debug/omerta-rendezvous"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Network configuration
INET_SUBNET="192.168.100"
LAN1_SUBNET="10.0.1"
LAN2_SUBNET="10.0.2"

# Test ID for unique naming
TEST_ID="$$"

# Namespace names
NS_INET="inet-${TEST_ID}"
NS_NAT1="nat1-${TEST_ID}"
NS_NAT2="nat2-${TEST_ID}"
NS_PEER1="peer1-${TEST_ID}"
NS_PEER2="peer2-${TEST_ID}"

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

usage() {
    echo "Usage: sudo $0 <nat-type-1> <nat-type-2> [relay]"
    echo ""
    echo "NAT Types:"
    echo "  public        No NAT (direct)"
    echo "  full-cone     Full Cone NAT"
    echo "  addr-restrict Address-Restricted Cone NAT"
    echo "  port-restrict Port-Restricted Cone NAT"
    echo "  symmetric     Symmetric NAT (hardest)"
    echo ""
    echo "Options:"
    echo "  relay         Enable relay server"
    exit 1
}

NAT1="${1:-}"
NAT2="${2:-}"
USE_RELAY="${3:-}"

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

# Build binaries
if [[ ! -f "$MESH_BIN" ]] || [[ ! -f "$RENDEZVOUS_BIN" ]]; then
    echo "Building binaries..."
    (cd "$OMERTA_DIR" && swift build --product omerta-mesh --product omerta-rendezvous)
fi

cleanup() {
    echo ""
    echo -e "${CYAN}Cleaning up...${NC}"

    # Kill processes
    pkill -f "omerta-mesh.*${TEST_ID}" 2>/dev/null || true
    pkill -f "omerta-rendezvous.*${TEST_ID}" 2>/dev/null || true

    # Delete namespaces (this also removes veth pairs)
    for ns in "$NS_INET" "$NS_NAT1" "$NS_NAT2" "$NS_PEER1" "$NS_PEER2"; do
        ip netns del "$ns" 2>/dev/null || true
    done

    echo "Done"
}
trap cleanup EXIT

echo "============================================================"
echo "Isolated Namespace NAT Test"
echo "============================================================"
echo "Peer 1 NAT: $NAT1"
echo "Peer 2 NAT: $NAT2"
[[ "$USE_RELAY" == "relay" ]] && echo "Relay: enabled"
echo ""

# Create namespaces
echo -e "${CYAN}Creating network namespaces...${NC}"

ip netns add "$NS_INET"
ip netns add "$NS_NAT1"
ip netns add "$NS_NAT2"
ip netns add "$NS_PEER1"
ip netns add "$NS_PEER2"

# Enable loopback in all namespaces
for ns in "$NS_INET" "$NS_NAT1" "$NS_NAT2" "$NS_PEER1" "$NS_PEER2"; do
    ip netns exec "$ns" ip link set lo up
done

# Create veth pairs and connect namespaces
echo -e "${CYAN}Creating network topology...${NC}"

# Internet <-> NAT1 (external side)
ip link add veth-inet-nat1 type veth peer name veth-nat1-inet
ip link set veth-inet-nat1 netns "$NS_INET"
ip link set veth-nat1-inet netns "$NS_NAT1"

ip netns exec "$NS_INET" ip addr add "${INET_SUBNET}.254/24" dev veth-inet-nat1
ip netns exec "$NS_INET" ip link set veth-inet-nat1 up
ip netns exec "$NS_NAT1" ip addr add "${INET_SUBNET}.1/24" dev veth-nat1-inet
ip netns exec "$NS_NAT1" ip link set veth-nat1-inet up
ip netns exec "$NS_NAT1" ip route add default via "${INET_SUBNET}.254"

# Internet <-> NAT2 (external side)
ip link add veth-inet-nat2 type veth peer name veth-nat2-inet
ip link set veth-inet-nat2 netns "$NS_INET"
ip link set veth-nat2-inet netns "$NS_NAT2"

ip netns exec "$NS_INET" ip addr add "${INET_SUBNET}.253/24" dev veth-inet-nat2
ip netns exec "$NS_INET" ip link set veth-inet-nat2 up
ip netns exec "$NS_NAT2" ip addr add "${INET_SUBNET}.2/24" dev veth-nat2-inet
ip netns exec "$NS_NAT2" ip link set veth-nat2-inet up
ip netns exec "$NS_NAT2" ip route add default via "${INET_SUBNET}.253"

# NAT1 <-> Peer1 (LAN side)
ip link add veth-nat1-lan type veth peer name veth-peer1
ip link set veth-nat1-lan netns "$NS_NAT1"
ip link set veth-peer1 netns "$NS_PEER1"

ip netns exec "$NS_NAT1" ip addr add "${LAN1_SUBNET}.1/24" dev veth-nat1-lan
ip netns exec "$NS_NAT1" ip link set veth-nat1-lan up
ip netns exec "$NS_PEER1" ip addr add "${LAN1_SUBNET}.2/24" dev veth-peer1
ip netns exec "$NS_PEER1" ip link set veth-peer1 up
ip netns exec "$NS_PEER1" ip route add default via "${LAN1_SUBNET}.1"

# NAT2 <-> Peer2 (LAN side)
ip link add veth-nat2-lan type veth peer name veth-peer2
ip link set veth-nat2-lan netns "$NS_NAT2"
ip link set veth-peer2 netns "$NS_PEER2"

ip netns exec "$NS_NAT2" ip addr add "${LAN2_SUBNET}.1/24" dev veth-nat2-lan
ip netns exec "$NS_NAT2" ip link set veth-nat2-lan up
ip netns exec "$NS_PEER2" ip addr add "${LAN2_SUBNET}.2/24" dev veth-peer2
ip netns exec "$NS_PEER2" ip link set veth-peer2 up
ip netns exec "$NS_PEER2" ip route add default via "${LAN2_SUBNET}.1"

# Enable IP forwarding in NAT namespaces
ip netns exec "$NS_NAT1" sysctl -q -w net.ipv4.ip_forward=1
ip netns exec "$NS_NAT2" sysctl -q -w net.ipv4.ip_forward=1
ip netns exec "$NS_INET" sysctl -q -w net.ipv4.ip_forward=1

# Add routes in internet namespace for return traffic
ip netns exec "$NS_INET" ip route add "${LAN1_SUBNET}.0/24" via "${INET_SUBNET}.1" 2>/dev/null || true
ip netns exec "$NS_INET" ip route add "${LAN2_SUBNET}.0/24" via "${INET_SUBNET}.2" 2>/dev/null || true

echo "  Internet namespace: ${INET_SUBNET}.0/24"
echo "  NAT1: ${INET_SUBNET}.1 (WAN) / ${LAN1_SUBNET}.1 (LAN)"
echo "  NAT2: ${INET_SUBNET}.2 (WAN) / ${LAN2_SUBNET}.1 (LAN)"
echo "  Peer1: ${LAN1_SUBNET}.2 (behind NAT1)"
echo "  Peer2: ${LAN2_SUBNET}.2 (behind NAT2)"

# Configure NAT rules
configure_nat() {
    local ns="$1"
    local nat_type="$2"
    local wan_if="$3"
    local lan_if="$4"

    echo -e "  Configuring ${CYAN}$nat_type${NC} NAT in $ns..."

    ip netns exec "$ns" nft flush ruleset 2>/dev/null || true

    case "$nat_type" in
        public)
            # No NAT, just forward
            ip netns exec "$ns" nft add table ip filter
            ip netns exec "$ns" nft add chain ip filter forward '{ type filter hook forward priority 0; policy accept; }'
            ;;
        full-cone)
            ip netns exec "$ns" nft add table ip nat
            ip netns exec "$ns" nft add chain ip nat postrouting '{ type nat hook postrouting priority 100; }'
            ip netns exec "$ns" nft add rule ip nat postrouting oifname "$wan_if" masquerade persistent
            ip netns exec "$ns" nft add table ip filter
            ip netns exec "$ns" nft add chain ip filter forward '{ type filter hook forward priority 0; policy accept; }'
            ;;
        addr-restrict|port-restrict)
            ip netns exec "$ns" nft add table ip nat
            ip netns exec "$ns" nft add chain ip nat postrouting '{ type nat hook postrouting priority 100; }'
            ip netns exec "$ns" nft add rule ip nat postrouting oifname "$wan_if" masquerade persistent
            ip netns exec "$ns" nft add table ip filter
            ip netns exec "$ns" nft add chain ip filter forward '{ type filter hook forward priority 0; policy drop; }'
            ip netns exec "$ns" nft add rule ip filter forward ct state established,related accept
            ip netns exec "$ns" nft add rule ip filter forward iifname "$lan_if" oifname "$wan_if" accept
            ;;
        symmetric)
            ip netns exec "$ns" nft add table ip nat
            ip netns exec "$ns" nft add chain ip nat postrouting '{ type nat hook postrouting priority 100; }'
            ip netns exec "$ns" nft add rule ip nat postrouting oifname "$wan_if" masquerade random
            ip netns exec "$ns" nft add table ip filter
            ip netns exec "$ns" nft add chain ip filter forward '{ type filter hook forward priority 0; policy drop; }'
            ip netns exec "$ns" nft add rule ip filter forward ct state established,related accept
            ip netns exec "$ns" nft add rule ip filter forward iifname "$lan_if" oifname "$wan_if" accept
            ;;
    esac
}

echo ""
echo -e "${CYAN}Configuring NAT rules...${NC}"
configure_nat "$NS_NAT1" "$NAT1" "veth-nat1-inet" "veth-nat1-lan"
configure_nat "$NS_NAT2" "$NAT2" "veth-nat2-inet" "veth-nat2-lan"

# Verify isolation - peers should NOT be able to ping each other directly
echo ""
echo -e "${CYAN}Verifying network isolation...${NC}"

# Peer1 should reach its NAT gateway
if ip netns exec "$NS_PEER1" ping -c1 -W1 "${LAN1_SUBNET}.1" &>/dev/null; then
    echo -e "  Peer1 -> NAT1 gateway: ${GREEN}OK${NC}"
else
    echo -e "  Peer1 -> NAT1 gateway: ${RED}FAIL${NC}"
fi

# Peer2 should reach its NAT gateway
if ip netns exec "$NS_PEER2" ping -c1 -W1 "${LAN2_SUBNET}.1" &>/dev/null; then
    echo -e "  Peer2 -> NAT2 gateway: ${GREEN}OK${NC}"
else
    echo -e "  Peer2 -> NAT2 gateway: ${RED}FAIL${NC}"
fi

# Peer1 should reach internet (via NAT)
if ip netns exec "$NS_PEER1" ping -c1 -W2 "${INET_SUBNET}.254" &>/dev/null; then
    echo -e "  Peer1 -> Internet: ${GREEN}OK${NC}"
else
    echo -e "  Peer1 -> Internet: ${RED}FAIL${NC}"
fi

# Peer1 should NOT directly reach Peer2's LAN IP
if ip netns exec "$NS_PEER1" ping -c1 -W1 "${LAN2_SUBNET}.2" &>/dev/null; then
    echo -e "  Peer1 -> Peer2 (direct): ${RED}REACHABLE (isolation broken!)${NC}"
else
    echo -e "  Peer1 -> Peer2 (direct): ${GREEN}BLOCKED (good!)${NC}"
fi

# Start STUN servers in internet namespace
echo ""
echo -e "${CYAN}Starting STUN servers...${NC}"

ip netns exec "$NS_INET" "$RENDEZVOUS_BIN" --stun-port 3478 --port 8080 --no-relay --log-level warning &
STUN1_PID=$!
sleep 1

ip netns exec "$NS_INET" "$RENDEZVOUS_BIN" --stun-port 3479 --port 8081 --no-relay --log-level warning &
STUN2_PID=$!
sleep 1

echo "  STUN1 on ${INET_SUBNET}.254:3478 (PID $STUN1_PID)"
echo "  STUN2 on ${INET_SUBNET}.254:3479 (PID $STUN2_PID)"

# Start relay if needed
if [[ "$USE_RELAY" == "relay" ]]; then
    echo ""
    echo -e "${CYAN}Starting relay server...${NC}"
    ip netns exec "$NS_INET" "$MESH_BIN" \
        --peer-id "relay-${TEST_ID}" \
        --port 9000 \
        --relay \
        --stun-servers "${INET_SUBNET}.254:3478,${INET_SUBNET}.254:3479" \
        --log-level info &
    RELAY_PID=$!
    sleep 2
    echo "  Relay on ${INET_SUBNET}.254:9000 (PID $RELAY_PID)"
fi

# Generate peer IDs
PEER1_ID="peer1-${TEST_ID}"
PEER2_ID="peer2-${TEST_ID}"

# Start peers
echo ""
echo -e "${CYAN}Starting mesh peers...${NC}"

# Determine bootstrap
if [[ "$USE_RELAY" == "relay" ]]; then
    BOOTSTRAP="relay-${TEST_ID}@${INET_SUBNET}.254:9000"
else
    BOOTSTRAP=""
fi

# Peer 1
echo "  Starting Peer 1 ($NAT1)..."
ip netns exec "$NS_PEER1" "$MESH_BIN" \
    --peer-id "$PEER1_ID" \
    --port 9001 \
    ${BOOTSTRAP:+--bootstrap "$BOOTSTRAP"} \
    --target "$PEER2_ID" \
    --stun-servers "${INET_SUBNET}.254:3478,${INET_SUBNET}.254:3479" \
    --wait-time 45 \
    --test-mode \
    --log-level info &
PEER1_PID=$!
sleep 2

# Peer 2
echo "  Starting Peer 2 ($NAT2)..."
if [[ -z "$BOOTSTRAP" ]]; then
    # Bootstrap from peer1's NAT external address
    BOOTSTRAP2="${PEER1_ID}@${INET_SUBNET}.1:9001"
else
    BOOTSTRAP2="$BOOTSTRAP"
fi

ip netns exec "$NS_PEER2" "$MESH_BIN" \
    --peer-id "$PEER2_ID" \
    --port 9002 \
    --bootstrap "$BOOTSTRAP2" \
    --target "$PEER1_ID" \
    --stun-servers "${INET_SUBNET}.254:3478,${INET_SUBNET}.254:3479" \
    --wait-time 40 \
    --test-mode \
    --log-level info &
PEER2_PID=$!

echo ""
echo -e "${CYAN}Waiting for test to complete...${NC}"
echo ""

# Wait for results
wait $PEER2_PID 2>/dev/null
PEER2_EXIT=$?

wait $PEER1_PID 2>/dev/null
PEER1_EXIT=$?

# Kill servers
kill $STUN1_PID $STUN2_PID 2>/dev/null || true
[[ -n "${RELAY_PID:-}" ]] && kill $RELAY_PID 2>/dev/null || true

echo ""
echo "============================================================"
echo "RESULTS"
echo "============================================================"
echo "Configuration: $NAT1 <-> $NAT2"
[[ "$USE_RELAY" == "relay" ]] && echo "Relay: enabled"
echo ""

# Predict outcome
predict_outcome() {
    local n1=$1
    local n2=$2

    [[ "$n1" == "public" || "$n2" == "public" ]] && echo "DIRECT" && return
    [[ "$n1" == "full-cone" || "$n2" == "full-cone" ]] && echo "DIRECT" && return
    [[ "$n1" == "symmetric" && "$n2" == "symmetric" ]] && echo "RELAY_REQUIRED" && return
    [[ "$n1" == "symmetric" || "$n2" == "symmetric" ]] && echo "HOLE_PUNCH_UNLIKELY" && return
    echo "HOLE_PUNCH"
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

    if [[ "$EXPECTED" == "RELAY_REQUIRED" && "$USE_RELAY" != "relay" ]]; then
        echo ""
        echo -e "${YELLOW}Note: This NAT combination requires a relay.${NC}"
        echo "Try: sudo $0 $NAT1 $NAT2 relay"
    fi
fi

exit $(( PEER1_EXIT || PEER2_EXIT ))
