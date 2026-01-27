#!/bin/bash
# IPv6 Mesh Network Tests
#
# Tests mesh network connectivity over IPv6 in various configurations:
#   - IPv6-only peers
#   - Dual-stack (IPv4 + IPv6) peers
#   - IPv6 with NAT64 simulation
#   - Mixed IPv4/IPv6 environments
#
# Usage:
#   sudo ./run-ipv6-test.sh <scenario>
#
# Scenarios:
#   ipv6-only       - Two peers communicating over IPv6 only
#   dual-stack      - Peers with both IPv4 and IPv6
#   mixed           - IPv4-only peer connecting to IPv6-only peer via relay
#   ipv6-nat        - IPv6 peers behind NAT66 (rare but exists)
#   prefer-ipv6     - Dual-stack preferring IPv6 over IPv4

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/vm-utils.sh"

OMERTA_DIR="${OMERTA_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
IMAGES_DIR="$SCRIPT_DIR/images"

# Network configuration
BR_INTERNET="br-mesh-inet"
BR_LAN1="br-mesh-lan1"
BR_LAN2="br-mesh-lan2"

# IPv4 subnets
INET_SUBNET="192.168.100"
LAN1_SUBNET="10.0.1"
LAN2_SUBNET="10.0.2"

# IPv6 subnets (ULA - Unique Local Addresses)
INET_SUBNET6="fd00:mesh:100"
LAN1_SUBNET6="fd00:mesh:1"
LAN2_SUBNET6="fd00:mesh:2"

# VM IPs (IPv4)
NAT_GW1_INET_IP="${INET_SUBNET}.1"
NAT_GW1_LAN_IP="${LAN1_SUBNET}.1"
NAT_GW2_INET_IP="${INET_SUBNET}.2"
NAT_GW2_LAN_IP="${LAN2_SUBNET}.1"
RELAY_IP="${INET_SUBNET}.3"
PEER1_IP="${LAN1_SUBNET}.2"
PEER2_IP="${LAN2_SUBNET}.2"

# VM IPs (IPv6)
NAT_GW1_INET_IP6="${INET_SUBNET6}::1"
NAT_GW1_LAN_IP6="${LAN1_SUBNET6}::1"
NAT_GW2_INET_IP6="${INET_SUBNET6}::2"
NAT_GW2_LAN_IP6="${LAN2_SUBNET6}::1"
RELAY_IP6="${INET_SUBNET6}::3"
PEER1_IP6="${LAN1_SUBNET6}::2"
PEER2_IP6="${LAN2_SUBNET6}::2"

# Public IPv6 peers (on internet bridge directly)
PUBLIC_PEER1_IP6="${INET_SUBNET6}::10"
PUBLIC_PEER2_IP6="${INET_SUBNET6}::11"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: sudo $0 <scenario>"
    echo ""
    echo "Scenarios:"
    echo "  ipv6-only       Two peers with IPv6 addresses only (no IPv4)"
    echo "  dual-stack      Peers with both IPv4 and IPv6 addresses"
    echo "  mixed           IPv4-only peer + IPv6-only peer via dual-stack relay"
    echo "  ipv6-nat        IPv6 peers behind NAT66 gateways"
    echo "  prefer-ipv6     Dual-stack peers preferring IPv6 transport"
    echo ""
    echo "All scenarios test that the mesh properly handles IPv6:"
    echo "  1. Peer discovery works over IPv6"
    echo "  2. Direct connections work over IPv6"
    echo "  3. Relay connections work over IPv6"
    echo "  4. Mixed IPv4/IPv6 environments are handled correctly"
    exit 1
}

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    usage
fi

SCENARIO="${1:-}"
[[ -z "$SCENARIO" ]] && usage

valid_scenarios="ipv6-only dual-stack mixed ipv6-nat prefer-ipv6"
if ! echo "$valid_scenarios" | grep -qw "$SCENARIO"; then
    echo -e "${RED}Invalid scenario: $SCENARIO${NC}"
    usage
fi

# SSH helpers
inet_ssh() {
    local ip="$1"
    shift
    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 ubuntu@"$ip" "$@"
}

inet_ssh6() {
    local ip="$1"
    shift
    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 ubuntu@"[$ip]" "$@"
}

lan_ssh() {
    local jump_ip="$1"
    local target_ip="$2"
    shift 2
    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o "ProxyCommand ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p ubuntu@$jump_ip" \
        ubuntu@"$target_ip" "$@"
}

inet_scp() {
    local src="$1"
    local ip="$2"
    local dst="$3"
    scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$src" ubuntu@"$ip":"$dst"
}

inet_scp6() {
    local src="$1"
    local ip="$2"
    local dst="$3"
    scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$src" ubuntu@"[$ip]":"$dst"
}

lan_scp() {
    local src="$1"
    local jump_ip="$2"
    local target_ip="$3"
    local dst="$4"
    scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o "ProxyCommand ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p ubuntu@$jump_ip" \
        "$src" ubuntu@"$target_ip":"$dst"
}

wait_for_ssh() {
    local ip="$1"
    local name="$2"
    local is_ipv6="${3:-false}"
    local timeout=120
    local start_time=$(date +%s)

    echo -n "  Waiting for $name..."

    while true; do
        local result
        if [[ "$is_ipv6" == "true" ]]; then
            result=$(inet_ssh6 "$ip" "echo ready" 2>/dev/null) || true
        else
            result=$(inet_ssh "$ip" "echo ready" 2>/dev/null) || true
        fi

        if [[ "$result" == "ready" ]]; then
            echo -e " ${GREEN}ready${NC}"
            return 0
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            echo -e " ${RED}timeout${NC}"
            return 1
        fi

        sleep 2
        echo -n "."
    done
}

# Cleanup function
cleanup() {
    echo ""
    echo -e "${CYAN}Cleaning up...${NC}"
    cleanup_all_vms
    echo -e "${GREEN}Cleanup complete${NC}"
}
trap cleanup EXIT

# Start public peer VM (directly on internet bridge with IPv6)
start_public_peer_ipv6() {
    local name="$1"
    local ipv4="${2:-}"
    local ipv6="$3"

    echo -e "${CYAN}Starting public peer: $name (IPv6: $ipv6)${NC}"

    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 10G)

    local cloud_init
    if [[ -n "$ipv4" ]]; then
        cloud_init=$(create_cloud_init_iso "$name" "ipv6-peer-dual.yaml" \
            "PEER_IP=$ipv4" \
            "PEER_IP6=$ipv6")
    else
        cloud_init=$(create_cloud_init_iso "$name" "ipv6-peer-only.yaml" \
            "PEER_IP6=$ipv6")
    fi

    local tap_name="tap-${name}"
    ip tuntap add dev "$tap_name" mode tap
    ip link set "$tap_name" master "$BR_INTERNET"
    ip link set "$tap_name" up

    local pid
    pid=$(start_vm "$name" 512 1 "$disk" "$cloud_init" \
        "tap,ifname=$tap_name,script=no,downscript=no")

    echo "  Started $name (PID $pid)"
}

# Start relay VM with dual-stack
start_relay_dual_stack() {
    echo -e "${CYAN}Starting dual-stack relay VM${NC}"

    local name="relay"
    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 10G)

    local cloud_init
    cloud_init=$(create_cloud_init_iso "$name" "ipv6-relay.yaml" \
        "RELAY_IP=$RELAY_IP" \
        "RELAY_IP6=$RELAY_IP6")

    local tap_name="tap-${name}"
    ip tuntap add dev "$tap_name" mode tap
    ip link set "$tap_name" master "$BR_INTERNET"
    ip link set "$tap_name" up

    local pid
    pid=$(start_vm "$name" 512 1 "$disk" "$cloud_init" \
        "tap,ifname=$tap_name,script=no,downscript=no")

    echo "  Started relay (PID $pid)"
    echo "  IPv4: $RELAY_IP, IPv6: $RELAY_IP6"
}

# Start NAT66 gateway (IPv6 NAT)
start_nat66_gateway() {
    local name="$1"
    local inet_ip6="$2"
    local lan_ip6="$3"
    local lan_bridge="$4"

    echo -e "${CYAN}Starting NAT66 gateway: $name${NC}"

    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 5G)

    local cloud_init
    cloud_init=$(create_cloud_init_iso "$name" "nat66-gateway.yaml" \
        "INET_IP6=$inet_ip6" \
        "LAN_IP6=$lan_ip6")

    local tap_inet="tap-${name}-i"
    local tap_lan="tap-${name}-l"

    ip tuntap add dev "$tap_inet" mode tap
    ip link set "$tap_inet" master "$BR_INTERNET"
    ip link set "$tap_inet" up

    ip tuntap add dev "$tap_lan" mode tap
    ip link set "$tap_lan" master "$lan_bridge"
    ip link set "$tap_lan" up

    local pid
    pid=$(start_vm "$name" 512 1 "$disk" "$cloud_init" \
        "tap,ifname=$tap_inet,script=no,downscript=no" \
        "tap,ifname=$tap_lan,script=no,downscript=no")

    echo "  Started $name (PID $pid)"
}

# Setup test files
setup_peer_files_ipv6() {
    local name="$1"
    local ip="$2"
    local is_ipv6="${3:-false}"

    echo "  Setting up $name..."

    if [[ "$is_ipv6" == "true" ]]; then
        inet_ssh6 "$ip" "mkdir -p /home/ubuntu/mesh-test/lib"
        inet_scp6 "$OMERTA_DIR/.build/debug/omerta-mesh" "$ip" "/home/ubuntu/mesh-test/"

        local swift_lib_dir
        swift_lib_dir=$(find "$HOME/.local/share/swiftly/toolchains" -maxdepth 2 -type d -name "usr" -exec test -d "{}/lib/swift/linux" \; -print -quit 2>/dev/null)/lib/swift/linux
        if [[ -d "$swift_lib_dir" ]]; then
            for lib in "$swift_lib_dir"/*.so*; do
                inet_scp6 "$lib" "$ip" "/home/ubuntu/mesh-test/lib/" 2>/dev/null || true
            done
        fi

        inet_ssh6 "$ip" "chmod +x /home/ubuntu/mesh-test/omerta-mesh"
    else
        inet_ssh "$ip" "mkdir -p /home/ubuntu/mesh-test/lib"
        inet_scp "$OMERTA_DIR/.build/debug/omerta-mesh" "$ip" "/home/ubuntu/mesh-test/"

        local swift_lib_dir
        swift_lib_dir=$(find "$HOME/.local/share/swiftly/toolchains" -maxdepth 2 -type d -name "usr" -exec test -d "{}/lib/swift/linux" \; -print -quit 2>/dev/null)/lib/swift/linux
        if [[ -d "$swift_lib_dir" ]]; then
            for lib in "$swift_lib_dir"/*.so*; do
                inet_scp "$lib" "$ip" "/home/ubuntu/mesh-test/lib/" 2>/dev/null || true
            done
        fi

        inet_ssh "$ip" "chmod +x /home/ubuntu/mesh-test/omerta-mesh"
    fi
}

# Check mesh connectivity
check_mesh_connectivity() {
    local ip="$1"
    local peer_name="$2"
    local is_ipv6="${3:-false}"

    echo -n "  Checking $peer_name mesh status..."

    local status
    if [[ "$is_ipv6" == "true" ]]; then
        status=$(inet_ssh6 "$ip" "cat /home/ubuntu/mesh-test/peer.log 2>/dev/null | tail -20" 2>/dev/null)
    else
        status=$(inet_ssh "$ip" "cat /home/ubuntu/mesh-test/peer.log 2>/dev/null | tail -20" 2>/dev/null)
    fi

    if echo "$status" | grep -q "connected\|established\|peer joined"; then
        echo -e " ${GREEN}connected${NC}"
        return 0
    else
        echo -e " ${YELLOW}not connected${NC}"
        return 1
    fi
}

# ============================================================
# Test Scenarios
# ============================================================

# Scenario: IPv6-only
run_ipv6_only_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}IPv6 Test: IPv6-Only Peers${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "Testing mesh connectivity between peers with only IPv6 addresses."
    echo "No IPv4 addresses are configured on these peers."
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"
    start_public_peer_ipv6 "peer1" "" "$PUBLIC_PEER1_IP6"
    start_public_peer_ipv6 "peer2" "" "$PUBLIC_PEER2_IP6"

    # Also start relay with IPv6 for bootstrap
    start_relay_dual_stack

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$PUBLIC_PEER1_IP6" "peer1" "true" || return 1
    wait_for_ssh "$PUBLIC_PEER2_IP6" "peer2" "true" || return 1
    wait_for_ssh "$RELAY_IP" "relay" "false" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Verifying IPv6 connectivity...${NC}"

    if inet_ssh6 "$PUBLIC_PEER1_IP6" "ping6 -c1 -W2 $PUBLIC_PEER2_IP6" &>/dev/null; then
        echo "  peer1 -> peer2 (IPv6): OK"
    else
        echo -e "  peer1 -> peer2 (IPv6): ${RED}FAILED${NC}"
    fi

    if inet_ssh6 "$PUBLIC_PEER1_IP6" "ping6 -c1 -W2 $RELAY_IP6" &>/dev/null; then
        echo "  peer1 -> relay (IPv6): OK"
    else
        echo -e "  peer1 -> relay (IPv6): ${RED}FAILED${NC}"
    fi

    echo ""
    echo -e "${CYAN}Step 4: Setting up test files...${NC}"
    setup_peer_files_ipv6 "peer1" "$PUBLIC_PEER1_IP6" "true"
    setup_peer_files_ipv6 "peer2" "$PUBLIC_PEER2_IP6" "true"
    setup_peer_files_ipv6 "relay" "$RELAY_IP" "false"

    echo ""
    echo -e "${CYAN}Step 5: Starting mesh network (IPv6)...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer1_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer2_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Start relay (listening on IPv6)
    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen [::]:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    # Start peer1 (IPv6 only, bootstrap to relay via IPv6)
    inet_ssh6 "$PUBLIC_PEER1_IP6" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer1_id --listen [::]:9000 --bootstrap [$RELAY_IP6]:9000 \
        > peer.log 2>&1 &"
    sleep 2

    # Start peer2 (IPv6 only, bootstrap to relay via IPv6)
    inet_ssh6 "$PUBLIC_PEER2_IP6" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer2_id --listen [::]:9000 --bootstrap [$RELAY_IP6]:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 6: Waiting for connection (30s)...${NC}"
    sleep 30

    echo ""
    echo -e "${CYAN}Step 7: Checking results...${NC}"
    check_mesh_connectivity "$PUBLIC_PEER1_IP6" "peer1" "true"
    check_mesh_connectivity "$PUBLIC_PEER2_IP6" "peer2" "true"

    echo ""
    echo "Peer 1 log:"
    echo "---"
    inet_ssh6 "$PUBLIC_PEER1_IP6" "cat /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"

    echo ""
    echo "Peer 2 log:"
    echo "---"
    inet_ssh6 "$PUBLIC_PEER2_IP6" "cat /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"
}

# Scenario: Dual-stack
run_dual_stack_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}IPv6 Test: Dual-Stack Peers${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "Testing mesh connectivity between peers with both IPv4 and IPv6."
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"

    # Use different IPs for dual-stack public peers
    local peer1_ipv4="${INET_SUBNET}.10"
    local peer2_ipv4="${INET_SUBNET}.11"

    start_public_peer_ipv6 "peer1" "$peer1_ipv4" "$PUBLIC_PEER1_IP6"
    start_public_peer_ipv6 "peer2" "$peer2_ipv4" "$PUBLIC_PEER2_IP6"
    start_relay_dual_stack

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$peer1_ipv4" "peer1" "false" || return 1
    wait_for_ssh "$peer2_ipv4" "peer2" "false" || return 1
    wait_for_ssh "$RELAY_IP" "relay" "false" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Verifying dual-stack connectivity...${NC}"

    # IPv4 connectivity
    if inet_ssh "$peer1_ipv4" "ping -c1 -W2 $peer2_ipv4" &>/dev/null; then
        echo "  peer1 -> peer2 (IPv4): OK"
    else
        echo -e "  peer1 -> peer2 (IPv4): ${RED}FAILED${NC}"
    fi

    # IPv6 connectivity
    if inet_ssh "$peer1_ipv4" "ping6 -c1 -W2 $PUBLIC_PEER2_IP6" &>/dev/null; then
        echo "  peer1 -> peer2 (IPv6): OK"
    else
        echo -e "  peer1 -> peer2 (IPv6): ${RED}FAILED${NC}"
    fi

    echo ""
    echo -e "${CYAN}Step 4: Setting up test files...${NC}"
    setup_peer_files_ipv6 "peer1" "$peer1_ipv4" "false"
    setup_peer_files_ipv6 "peer2" "$peer2_ipv4" "false"
    setup_peer_files_ipv6 "relay" "$RELAY_IP" "false"

    echo ""
    echo -e "${CYAN}Step 5: Starting mesh network (dual-stack)...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer1_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer2_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Start relay (listening on both)
    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --listen6 [::]:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    # Start peer1 (dual-stack)
    inet_ssh "$peer1_ipv4" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer1_id --listen 0.0.0.0:9000 --listen6 [::]:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    # Start peer2 (dual-stack)
    inet_ssh "$peer2_ipv4" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer2_id --listen 0.0.0.0:9000 --listen6 [::]:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 6: Waiting for connection (30s)...${NC}"
    sleep 30

    echo ""
    echo -e "${CYAN}Step 7: Checking results...${NC}"
    check_mesh_connectivity "$peer1_ipv4" "peer1" "false"
    check_mesh_connectivity "$peer2_ipv4" "peer2" "false"

    echo ""
    echo "Peer 1 log:"
    echo "---"
    inet_ssh "$peer1_ipv4" "cat /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"
}

# Scenario: Mixed IPv4/IPv6
run_mixed_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}IPv6 Test: Mixed IPv4/IPv6 Environment${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "Testing mesh connectivity between:"
    echo "  - Peer 1: IPv4 only"
    echo "  - Peer 2: IPv6 only"
    echo "  - Relay: Dual-stack (bridges the two)"
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"

    local ipv4_peer_ip="${INET_SUBNET}.10"

    # IPv4-only peer
    start_public_peer_ipv6 "peer-ipv4" "$ipv4_peer_ip" ""

    # IPv6-only peer
    start_public_peer_ipv6 "peer-ipv6" "" "$PUBLIC_PEER2_IP6"

    # Dual-stack relay
    start_relay_dual_stack

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$ipv4_peer_ip" "peer-ipv4" "false" || return 1
    wait_for_ssh "$PUBLIC_PEER2_IP6" "peer-ipv6" "true" || return 1
    wait_for_ssh "$RELAY_IP" "relay" "false" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Verifying connectivity...${NC}"

    # IPv4 peer can reach relay via IPv4
    if inet_ssh "$ipv4_peer_ip" "ping -c1 -W2 $RELAY_IP" &>/dev/null; then
        echo "  peer-ipv4 -> relay (IPv4): OK"
    else
        echo -e "  peer-ipv4 -> relay (IPv4): ${RED}FAILED${NC}"
    fi

    # IPv6 peer can reach relay via IPv6
    if inet_ssh6 "$PUBLIC_PEER2_IP6" "ping6 -c1 -W2 $RELAY_IP6" &>/dev/null; then
        echo "  peer-ipv6 -> relay (IPv6): OK"
    else
        echo -e "  peer-ipv6 -> relay (IPv6): ${RED}FAILED${NC}"
    fi

    echo ""
    echo -e "${CYAN}Step 4: Setting up test files...${NC}"
    setup_peer_files_ipv6 "peer-ipv4" "$ipv4_peer_ip" "false"
    setup_peer_files_ipv6 "peer-ipv6" "$PUBLIC_PEER2_IP6" "true"
    setup_peer_files_ipv6 "relay" "$RELAY_IP" "false"

    echo ""
    echo -e "${CYAN}Step 5: Starting mesh network (mixed)...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer_ipv4_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer_ipv6_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Start relay (dual-stack)
    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --listen6 [::]:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    # Start IPv4-only peer
    inet_ssh "$ipv4_peer_ip" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer_ipv4_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    # Start IPv6-only peer
    inet_ssh6 "$PUBLIC_PEER2_IP6" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer_ipv6_id --listen [::]:9000 --bootstrap [$RELAY_IP6]:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 6: Waiting for connection (30s)...${NC}"
    sleep 30

    echo ""
    echo -e "${CYAN}Step 7: Checking results...${NC}"
    check_mesh_connectivity "$ipv4_peer_ip" "peer-ipv4" "false"
    check_mesh_connectivity "$PUBLIC_PEER2_IP6" "peer-ipv6" "true"

    echo ""
    echo -e "${YELLOW}Note: Direct connection between IPv4-only and IPv6-only peers${NC}"
    echo -e "${YELLOW}should fail. They should communicate via the dual-stack relay.${NC}"

    echo ""
    echo "Peer IPv4 log:"
    echo "---"
    inet_ssh "$ipv4_peer_ip" "cat /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"

    echo ""
    echo "Peer IPv6 log:"
    echo "---"
    inet_ssh6 "$PUBLIC_PEER2_IP6" "cat /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"

    echo ""
    echo "Relay log:"
    echo "---"
    inet_ssh "$RELAY_IP" "cat /home/ubuntu/mesh-test/relay.log" 2>/dev/null || echo "(no log)"
    echo "---"
}

# Scenario: IPv6 NAT (NAT66)
run_ipv6_nat_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}IPv6 Test: NAT66 (IPv6 NAT)${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "Testing mesh connectivity with IPv6 peers behind NAT66 gateways."
    echo "NAT66 is rare but exists in some enterprise/carrier networks."
    echo ""

    echo -e "${YELLOW}Note: NAT66 test requires additional infrastructure.${NC}"
    echo -e "${YELLOW}This scenario tests connectivity similar to IPv4 NAT but with IPv6.${NC}"
    echo ""

    # This would require NAT66 gateway VMs
    # For now, provide a placeholder that explains the test

    echo "NAT66 test infrastructure:"
    echo "  - NAT66 Gateway 1: ${NAT_GW1_INET_IP6} (external) / ${NAT_GW1_LAN_IP6} (internal)"
    echo "  - NAT66 Gateway 2: ${NAT_GW2_INET_IP6} (external) / ${NAT_GW2_LAN_IP6} (internal)"
    echo "  - Peer 1: ${PEER1_IP6} (behind NAT66 GW1)"
    echo "  - Peer 2: ${PEER2_IP6} (behind NAT66 GW2)"
    echo ""
    echo -e "${YELLOW}Full NAT66 implementation pending cloud-init template.${NC}"
}

# Scenario: Prefer IPv6
run_prefer_ipv6_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}IPv6 Test: Prefer IPv6${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "Testing that dual-stack peers prefer IPv6 when both are available."
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"

    local peer1_ipv4="${INET_SUBNET}.10"
    local peer2_ipv4="${INET_SUBNET}.11"

    start_public_peer_ipv6 "peer1" "$peer1_ipv4" "$PUBLIC_PEER1_IP6"
    start_public_peer_ipv6 "peer2" "$peer2_ipv4" "$PUBLIC_PEER2_IP6"
    start_relay_dual_stack

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$peer1_ipv4" "peer1" "false" || return 1
    wait_for_ssh "$peer2_ipv4" "peer2" "false" || return 1
    wait_for_ssh "$RELAY_IP" "relay" "false" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Setting up test files...${NC}"
    setup_peer_files_ipv6 "peer1" "$peer1_ipv4" "false"
    setup_peer_files_ipv6 "peer2" "$peer2_ipv4" "false"
    setup_peer_files_ipv6 "relay" "$RELAY_IP" "false"

    echo ""
    echo -e "${CYAN}Step 4: Starting mesh network (prefer IPv6)...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer1_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer2_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Start with IPv6 preference flag (if supported by omerta-mesh)
    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --listen6 [::]:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    inet_ssh "$peer1_ipv4" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer1_id --listen 0.0.0.0:9000 --listen6 [::]:9000 \
        --bootstrap [$RELAY_IP6]:9000 \
        > peer.log 2>&1 &"
    sleep 2

    inet_ssh "$peer2_ipv4" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer2_id --listen 0.0.0.0:9000 --listen6 [::]:9000 \
        --bootstrap [$RELAY_IP6]:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 5: Waiting for connection (30s)...${NC}"
    sleep 30

    echo ""
    echo -e "${CYAN}Step 6: Checking results...${NC}"

    # Check if connections are using IPv6
    echo ""
    echo "Checking connection types in logs..."
    echo ""

    echo "Peer 1 connections:"
    inet_ssh "$peer1_ipv4" "grep -E 'connected|established' /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no connections logged)"

    echo ""
    echo "Peer 2 connections:"
    inet_ssh "$peer2_ipv4" "grep -E 'connected|established' /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no connections logged)"

    echo ""
    echo -e "${YELLOW}Look for IPv6 addresses (containing ':') in connection logs${NC}"
    echo -e "${YELLOW}to verify IPv6 is preferred over IPv4.${NC}"
}

# ============================================================
# Main
# ============================================================

echo "============================================================"
echo "OmertaMesh IPv6 Test"
echo "============================================================"
echo "Scenario: $SCENARIO"
echo ""

# Check prerequisites
echo -e "${CYAN}Checking prerequisites...${NC}"

if ! ip link show "$BR_INTERNET" &>/dev/null; then
    echo -e "${RED}Bridge $BR_INTERNET not found. Run setup-infra.sh first.${NC}"
    exit 1
fi

if [[ ! -f "$IMAGES_DIR/ubuntu-base.img" ]]; then
    echo -e "${RED}Ubuntu base image not found. Run setup-infra.sh images first.${NC}"
    exit 1
fi

if [[ ! -f "$OMERTA_DIR/.build/debug/omerta-mesh" ]]; then
    echo "Building omerta-mesh..."
    (cd "$OMERTA_DIR" && swift build --product omerta-mesh)
fi

# Check for IPv6 support on host
if ! ip -6 addr show dev "$BR_INTERNET" | grep -q "fd00:mesh"; then
    echo -e "${YELLOW}Warning: Bridge may not have IPv6 configured.${NC}"
    echo -e "${YELLOW}Run 'sudo ip -6 addr add fd00:mesh:100::fe/64 dev $BR_INTERNET'${NC}"
fi

echo -e "${GREEN}Prerequisites OK${NC}"

# Create IPv6 cloud-init templates if they don't exist
create_ipv6_templates() {
    # IPv6-only peer template
    if [[ ! -f "$SCRIPT_DIR/cloud-init/ipv6-peer-only.yaml" ]]; then
        cat > "$SCRIPT_DIR/cloud-init/ipv6-peer-only.yaml" << 'EOFTEMPLATE'
#cloud-config
# IPv6-only Peer VM Configuration

hostname: ${PEER_NAME}

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

package_update: false

write_files:
  - path: /etc/netplan/99-mesh-test.yaml
    permissions: '0644'
    content: |
      network:
        version: 2
        ethernets:
          enp0s2:
            accept-ra: false
            addresses:
              - ${PEER_IP6}/64
            routes:
              - to: default
                via: fd00:mesh:100::fe

  - path: /etc/sysctl.d/99-mesh.conf
    content: |
      net.ipv6.conf.all.forwarding=1

runcmd:
  - netplan apply
  - sleep 2
  - mkdir -p /home/ubuntu/mesh-test
  - chown ubuntu:ubuntu /home/ubuntu/mesh-test
  - echo "IPv6-only Peer VM ready"
EOFTEMPLATE
    fi

    # Dual-stack peer template
    if [[ ! -f "$SCRIPT_DIR/cloud-init/ipv6-peer-dual.yaml" ]]; then
        cat > "$SCRIPT_DIR/cloud-init/ipv6-peer-dual.yaml" << 'EOFTEMPLATE'
#cloud-config
# Dual-stack Peer VM Configuration

hostname: ${PEER_NAME}

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

package_update: false

write_files:
  - path: /etc/netplan/99-mesh-test.yaml
    permissions: '0644'
    content: |
      network:
        version: 2
        ethernets:
          enp0s2:
            accept-ra: false
            addresses:
              - ${PEER_IP}/24
              - ${PEER_IP6}/64
            routes:
              - to: default
                via: 192.168.100.254
              - to: ::/0
                via: fd00:mesh:100::fe

  - path: /etc/sysctl.d/99-mesh.conf
    content: |
      net.ipv4.ip_forward=1
      net.ipv6.conf.all.forwarding=1

runcmd:
  - netplan apply
  - sleep 2
  - mkdir -p /home/ubuntu/mesh-test
  - chown ubuntu:ubuntu /home/ubuntu/mesh-test
  - echo "Dual-stack Peer VM ready"
EOFTEMPLATE
    fi

    # Dual-stack relay template
    if [[ ! -f "$SCRIPT_DIR/cloud-init/ipv6-relay.yaml" ]]; then
        cat > "$SCRIPT_DIR/cloud-init/ipv6-relay.yaml" << 'EOFTEMPLATE'
#cloud-config
# Dual-stack Relay VM Configuration

hostname: relay

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

package_update: false

write_files:
  - path: /etc/netplan/99-mesh-test.yaml
    permissions: '0644'
    content: |
      network:
        version: 2
        ethernets:
          enp0s2:
            accept-ra: false
            addresses:
              - ${RELAY_IP}/24
              - ${RELAY_IP6}/64
            routes:
              - to: default
                via: 192.168.100.254
              - to: ::/0
                via: fd00:mesh:100::fe

  - path: /etc/sysctl.d/99-mesh.conf
    content: |
      net.ipv4.ip_forward=1
      net.ipv6.conf.all.forwarding=1

runcmd:
  - netplan apply
  - sleep 2
  - mkdir -p /home/ubuntu/mesh-test
  - chown ubuntu:ubuntu /home/ubuntu/mesh-test
  - echo "Dual-stack Relay VM ready"
EOFTEMPLATE
    fi

    # NAT66 gateway template
    if [[ ! -f "$SCRIPT_DIR/cloud-init/nat66-gateway.yaml" ]]; then
        cat > "$SCRIPT_DIR/cloud-init/nat66-gateway.yaml" << 'EOFTEMPLATE'
#cloud-config
# NAT66 Gateway VM Configuration

hostname: ${PEER_NAME}

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

package_update: true
packages:
  - nftables
  - iproute2

write_files:
  - path: /etc/netplan/99-mesh-test.yaml
    permissions: '0644'
    content: |
      network:
        version: 2
        ethernets:
          enp0s2:
            accept-ra: false
            addresses:
              - ${INET_IP6}/64
            routes:
              - to: ::/0
                via: fd00:mesh:100::fe
          enp0s3:
            accept-ra: false
            addresses:
              - ${LAN_IP6}/64

  - path: /usr/local/bin/configure-nat66.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
      nft flush ruleset 2>/dev/null || true
      nft add table ip6 nat
      nft add chain ip6 nat postrouting '{ type nat hook postrouting priority 100; }'
      nft add rule ip6 nat postrouting oifname "enp0s2" masquerade
      nft add table ip6 filter
      nft add chain ip6 filter forward '{ type filter hook forward priority 0; policy drop; }'
      nft add rule ip6 filter forward ct state established,related accept
      nft add rule ip6 filter forward iifname "enp0s3" oifname "enp0s2" accept
      echo "NAT66 configured"

runcmd:
  - netplan apply
  - sleep 2
  - systemctl enable nftables
  - /usr/local/bin/configure-nat66.sh
  - echo "NAT66 Gateway ready"
EOFTEMPLATE
    fi
}

create_ipv6_templates

# Run the selected scenario
case "$SCENARIO" in
    ipv6-only)
        run_ipv6_only_test
        ;;
    dual-stack)
        run_dual_stack_test
        ;;
    mixed)
        run_mixed_test
        ;;
    ipv6-nat)
        run_ipv6_nat_test
        ;;
    prefer-ipv6)
        run_prefer_ipv6_test
        ;;
esac

echo ""
echo -e "${GREEN}IPv6 test complete${NC}"
echo "Press Ctrl+C to cleanup and exit."
echo ""

while true; do
    sleep 10
done
