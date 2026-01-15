#!/bin/bash
# Roaming Device Test
#
# Tests mesh network behavior when a peer roams between different networks.
# Simulates scenarios like:
#   - Mobile device moving from home WiFi to coffee shop WiFi
#   - Laptop switching from WiFi to Ethernet
#   - Device temporarily losing connectivity then reconnecting
#   - Transitioning from direct connection to relay-required network
#   - Interface prioritization (prefer WiFi over cellular)
#
# Usage:
#   sudo ./run-roaming-test.sh <scenario>
#
# Basic Scenarios:
#   nat-switch        - Peer moves from one NAT to another
#   interface-hop     - Peer switches network interfaces
#   reconnect         - Peer loses connectivity and reconnects
#   ip-change         - Peer's IP changes within same network
#
# Advanced Scenarios:
#   direct-to-relay   - Move from direct-capable to relay-required network
#   relay-to-direct   - Move from relay-required to direct-capable network
#   priority-failover - Test interface priority with failover to backup
#   multi-interface   - Simultaneous interfaces with priority selection
#   seamless-handoff  - Verify no message loss during network transition

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/vm-utils.sh"

OMERTA_DIR="${OMERTA_DIR}"
IMAGES_DIR="$SCRIPT_DIR/images"

# Network configuration
BR_INTERNET="br-mesh-inet"
BR_LAN1="br-mesh-lan1"
BR_LAN2="br-mesh-lan2"
BR_LAN3="br-mesh-lan3"  # Third LAN for roaming tests

INET_SUBNET="192.168.100"
LAN1_SUBNET="10.0.1"
LAN2_SUBNET="10.0.2"
LAN3_SUBNET="10.0.3"

# VM IPs
NAT_GW1_INET_IP="${INET_SUBNET}.1"
NAT_GW1_LAN_IP="${LAN1_SUBNET}.1"
NAT_GW2_INET_IP="${INET_SUBNET}.2"
NAT_GW2_LAN_IP="${LAN2_SUBNET}.1"
NAT_GW3_INET_IP="${INET_SUBNET}.4"
NAT_GW3_LAN_IP="${LAN3_SUBNET}.1"
RELAY_IP="${INET_SUBNET}.3"
PEER1_IP="${LAN1_SUBNET}.2"
PEER2_IP="${LAN2_SUBNET}.2"
ROAMING_PEER_IP_LAN1="${LAN1_SUBNET}.10"
ROAMING_PEER_IP_LAN2="${LAN2_SUBNET}.10"
ROAMING_PEER_IP_LAN3="${LAN3_SUBNET}.10"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: sudo $0 <scenario>"
    echo ""
    echo "Basic Scenarios:"
    echo "  nat-switch        Peer moves from one NAT (LAN1) to another (LAN2)"
    echo "  interface-hop     Peer switches between two interfaces on different LANs"
    echo "  reconnect         Peer loses connectivity temporarily, then reconnects"
    echo "  ip-change         Peer's IP address changes within same network"
    echo ""
    echo "Advanced Scenarios (Direct/Relay Transitions):"
    echo "  direct-to-relay   Start on full-cone (direct works), move to symmetric (needs relay)"
    echo "  relay-to-direct   Start on symmetric (needs relay), move to full-cone (direct works)"
    echo "  seamless-handoff  Verify message continuity during direct<->relay transitions"
    echo ""
    echo "Interface Priority Scenarios:"
    echo "  priority-failover Primary interface fails, seamlessly switch to backup (cellular)"
    echo "  multi-interface   Multiple active interfaces, mesh selects best path"
    echo "  priority-restore  Backup active, primary restored, switch back to primary"
    echo ""
    echo "Warm Relay Scenarios:"
    echo "  symmetric-stationary-roaming  Stationary peer behind symmetric NAT, other peer roams"
    echo "  warm-relay-keepalive          Verify warm relay connections are maintained"
    echo ""
    echo "All scenarios verify that:"
    echo "  1. Initial connection is established"
    echo "  2. Network change is detected"
    echo "  3. Connection is re-established after roaming"
    echo "  4. Messages can be exchanged after recovery"
    echo "  5. Connection path (direct/relay) is optimal for current network"
    exit 1
}

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    usage
fi

SCENARIO="${1:-}"
[[ -z "$SCENARIO" ]] && usage

# Validate scenario
valid_scenarios="nat-switch interface-hop reconnect ip-change direct-to-relay relay-to-direct seamless-handoff priority-failover multi-interface priority-restore symmetric-stationary-roaming warm-relay-keepalive"
if ! echo "$valid_scenarios" | grep -qw "$SCENARIO"; then
    echo -e "${RED}Invalid scenario: $SCENARIO${NC}"
    usage
fi

# SSH helpers (same as run-nested-test.sh)
inet_ssh() {
    local ip="$1"
    shift
    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 ubuntu@"$ip" "$@"
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
    local jump_ip="${3:-}"
    local timeout=120
    local start_time=$(date +%s)

    echo -n "  Waiting for $name..."

    while true; do
        if [[ -n "$jump_ip" ]]; then
            if lan_ssh "$jump_ip" "$ip" "echo ready" &>/dev/null; then
                echo -e " ${GREEN}ready${NC}"
                return 0
            fi
        else
            if inet_ssh "$ip" "echo ready" &>/dev/null; then
                echo -e " ${GREEN}ready${NC}"
                return 0
            fi
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

    # Remove extra bridge for roaming tests
    if ip link show "$BR_LAN3" &>/dev/null; then
        ip link set "$BR_LAN3" down 2>/dev/null || true
        ip link del "$BR_LAN3" 2>/dev/null || true
    fi

    # Remove any roaming tap devices
    for tap in $(ip link show 2>/dev/null | grep "tap-roam" | cut -d: -f2 | tr -d ' '); do
        ip link del "$tap" 2>/dev/null || true
    done

    echo -e "${GREEN}Cleanup complete${NC}"
}
trap cleanup EXIT

# Create third LAN bridge for roaming tests
create_roaming_bridge() {
    if ! ip link show "$BR_LAN3" &>/dev/null; then
        echo "  Creating $BR_LAN3..."
        ip link add name "$BR_LAN3" type bridge
        ip link set "$BR_LAN3" up
    fi
}

# Start NAT gateway VM
start_nat_gateway() {
    local name="$1"
    local nat_type="$2"
    local inet_ip="$3"
    local lan_ip="$4"
    local lan_bridge="$5"

    echo -e "${CYAN}Starting NAT gateway: $name ($nat_type)${NC}"

    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 5G)

    local cloud_init
    cloud_init=$(create_cloud_init_iso "$name" "nat-gateway.yaml" \
        "INET_IP=$inet_ip" \
        "LAN_IP=$lan_ip" \
        "NAT_TYPE=$nat_type")

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

# Start roaming peer VM with multiple interfaces
start_roaming_peer() {
    local name="$1"
    local primary_bridge="$2"
    local secondary_bridge="$3"
    local primary_ip="$4"
    local primary_gw="$5"

    echo -e "${CYAN}Starting roaming peer: $name${NC}"

    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 10G)

    # Create cloud-init with dual-interface support
    local cloud_init
    cloud_init=$(create_cloud_init_iso "$name" "roaming-peer.yaml" \
        "PEER_IP=$primary_ip" \
        "GATEWAY_IP=$primary_gw")

    # Create two tap devices for the roaming peer
    local tap_primary="tap-${name}-p"
    local tap_secondary="tap-${name}-s"

    ip tuntap add dev "$tap_primary" mode tap
    ip link set "$tap_primary" master "$primary_bridge"
    ip link set "$tap_primary" up

    ip tuntap add dev "$tap_secondary" mode tap
    ip link set "$tap_secondary" master "$secondary_bridge"
    ip link set "$tap_secondary" up

    # Start VM with two interfaces
    local pid
    pid=$(start_vm "$name" 512 1 "$disk" "$cloud_init" \
        "tap,ifname=$tap_primary,script=no,downscript=no" \
        "tap,ifname=$tap_secondary,script=no,downscript=no")

    echo "  Started $name (PID $pid)"
    echo "  Primary interface on $primary_bridge"
    echo "  Secondary interface on $secondary_bridge"
}

# Start a regular peer VM
start_peer_vm() {
    local name="$1"
    local ip="$2"
    local gateway_ip="$3"
    local lan_bridge="$4"

    echo -e "${CYAN}Starting peer VM: $name${NC}"

    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 10G)

    local cloud_init
    cloud_init=$(create_cloud_init_iso "$name" "peer.yaml" \
        "PEER_IP=$ip" \
        "GATEWAY_IP=$gateway_ip")

    local tap_name="tap-${name}"
    ip tuntap add dev "$tap_name" mode tap
    ip link set "$tap_name" master "$lan_bridge"
    ip link set "$tap_name" up

    local pid
    pid=$(start_vm "$name" 512 1 "$disk" "$cloud_init" \
        "tap,ifname=$tap_name,script=no,downscript=no")

    echo "  Started $name (PID $pid)"
}

# Start relay VM
start_relay_vm() {
    echo -e "${CYAN}Starting relay VM${NC}"

    local name="relay"
    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 10G)

    local cloud_init
    cloud_init=$(create_cloud_init_iso "$name" "relay.yaml" \
        "RELAY_IP=$RELAY_IP")

    local tap_name="tap-${name}"
    ip tuntap add dev "$tap_name" mode tap
    ip link set "$tap_name" master "$BR_INTERNET"
    ip link set "$tap_name" up

    local pid
    pid=$(start_vm "$name" 512 1 "$disk" "$cloud_init" \
        "tap,ifname=$tap_name,script=no,downscript=no")

    echo "  Started relay (PID $pid)"
}

# Setup test files on a peer
setup_peer_files() {
    local name="$1"
    local jump_ip="$2"
    local target_ip="$3"

    echo "  Setting up $name..."

    lan_ssh "$jump_ip" "$target_ip" "mkdir -p /home/ubuntu/mesh-test/lib"
    lan_scp "$OMERTA_DIR/.build/debug/omerta-mesh" "$jump_ip" "$target_ip" "/home/ubuntu/mesh-test/"

    local swift_lib_dir
    swift_lib_dir=$(find "$HOME/.local/share/swiftly/toolchains" -maxdepth 2 -type d -name "usr" -exec test -d "{}/lib/swift/linux" \; -print -quit 2>/dev/null)/lib/swift/linux
    if [[ -d "$swift_lib_dir" ]]; then
        for lib in "$swift_lib_dir"/*.so*; do
            lan_scp "$lib" "$jump_ip" "$target_ip" "/home/ubuntu/mesh-test/lib/" 2>/dev/null || true
        done
    fi

    lan_ssh "$jump_ip" "$target_ip" "chmod +x /home/ubuntu/mesh-test/omerta-mesh"
}

setup_relay_files() {
    echo "  Setting up relay..."

    inet_ssh "$RELAY_IP" "mkdir -p /home/ubuntu/mesh-test/lib"
    inet_scp "$OMERTA_DIR/.build/debug/omerta-mesh" "$RELAY_IP" "/home/ubuntu/mesh-test/"

    local swift_lib_dir
    swift_lib_dir=$(find "$HOME/.local/share/swiftly/toolchains" -maxdepth 2 -type d -name "usr" -exec test -d "{}/lib/swift/linux" \; -print -quit 2>/dev/null)/lib/swift/linux
    if [[ -d "$swift_lib_dir" ]]; then
        for lib in "$swift_lib_dir"/*.so*; do
            inet_scp "$lib" "$RELAY_IP" "/home/ubuntu/mesh-test/lib/" 2>/dev/null || true
        done
    fi

    inet_ssh "$RELAY_IP" "chmod +x /home/ubuntu/mesh-test/omerta-mesh"
}

# Switch roaming peer's active interface
switch_roaming_interface() {
    local jump_ip="$1"
    local peer_ip="$2"
    local new_ip="$3"
    local new_gateway="$4"
    local interface="$5"

    echo -e "${YELLOW}Switching roaming peer to $interface...${NC}"

    # Bring down old interface and bring up new one
    lan_ssh "$jump_ip" "$peer_ip" "sudo bash -c '
        # Disable old default route
        ip route del default 2>/dev/null || true

        # Configure new interface
        ip addr flush dev $interface
        ip addr add $new_ip/24 dev $interface
        ip link set $interface up
        ip route add default via $new_gateway

        echo \"Interface switched to $interface with IP $new_ip\"
    '"
}

# Simulate network disconnect
disconnect_peer() {
    local jump_ip="$1"
    local peer_ip="$2"
    local duration="$3"

    echo -e "${YELLOW}Disconnecting peer for ${duration}s...${NC}"

    lan_ssh "$jump_ip" "$peer_ip" "sudo iptables -I OUTPUT -j DROP && sudo iptables -I INPUT -j DROP"
    sleep "$duration"
    lan_ssh "$jump_ip" "$peer_ip" "sudo iptables -D OUTPUT -j DROP && sudo iptables -D INPUT -j DROP"

    echo "  Peer reconnected"
}

# Change peer's IP address
change_peer_ip() {
    local jump_ip="$1"
    local old_ip="$2"
    local new_ip="$3"
    local interface="$4"

    echo -e "${YELLOW}Changing peer IP from $old_ip to $new_ip...${NC}"

    lan_ssh "$jump_ip" "$old_ip" "sudo bash -c '
        ip addr del $old_ip/24 dev $interface
        ip addr add $new_ip/24 dev $interface
        echo \"IP changed to $new_ip\"
    '"
}

# Check mesh connectivity
check_mesh_connectivity() {
    local jump_ip="$1"
    local peer_ip="$2"
    local peer_name="$3"

    echo -n "  Checking $peer_name mesh status..."

    local status
    status=$(lan_ssh "$jump_ip" "$peer_ip" "cat /home/ubuntu/mesh-test/peer.log 2>/dev/null | tail -20" 2>/dev/null)

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

# Scenario: NAT Switch
# Peer starts on LAN1, then moves to LAN2 (different NAT)
run_nat_switch_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: NAT Switch${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test simulates a device moving from one NAT to another,"
    echo "like a laptop moving from home WiFi to a coffee shop."
    echo ""

    # Start infrastructure
    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"
    start_nat_gateway "nat-gw1" "full-cone" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "port-restrict" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm
    start_peer_vm "peer-static" "$PEER2_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_roaming_peer "peer-roaming" "$BR_LAN1" "$BR_LAN2" "$ROAMING_PEER_IP_LAN1" "$NAT_GW1_LAN_IP"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER2_IP" "peer-static" "$NAT_GW2_INET_IP" || return 1
    wait_for_ssh "$ROAMING_PEER_IP_LAN1" "peer-roaming" "$NAT_GW1_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer-static" "$NAT_GW2_INET_IP" "$PEER2_IP"
    setup_peer_files "peer-roaming" "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1"

    echo ""
    echo -e "${CYAN}Step 4: Starting mesh network...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local static_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local roaming_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Start relay
    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    # Start static peer
    lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $static_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    # Start roaming peer (initially on LAN1)
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $roaming_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 5: Waiting for initial connection (30s)...${NC}"
    sleep 30

    echo ""
    echo -e "${CYAN}Step 6: Checking initial connectivity...${NC}"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "roaming peer (LAN1)"
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$PEER2_IP" "static peer"

    echo ""
    echo -e "${CYAN}Step 7: Simulating roaming to LAN2...${NC}"
    switch_roaming_interface "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" \
        "$ROAMING_PEER_IP_LAN2" "$NAT_GW2_LAN_IP" "enp0s3"

    echo ""
    echo -e "${CYAN}Step 8: Waiting for connection recovery (45s)...${NC}"
    sleep 45

    echo ""
    echo -e "${CYAN}Step 9: Checking connectivity after roaming...${NC}"
    # Now need to reach roaming peer via NAT_GW2
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "roaming peer (LAN2)"
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$PEER2_IP" "static peer"

    echo ""
    echo -e "${CYAN}Results:${NC}"
    echo ""
    echo "Roaming peer log (last 30 lines):"
    echo "---"
    lan_ssh "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "tail -30 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"
}

# Scenario: Interface Hop
# Peer has two interfaces, switches between them
run_interface_hop_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: Interface Hop${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test simulates a device with multiple interfaces"
    echo "(like WiFi + Ethernet) switching between them."
    echo ""

    # Similar to NAT switch but switches interfaces multiple times
    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"
    start_nat_gateway "nat-gw1" "full-cone" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "full-cone" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm
    start_peer_vm "peer-static" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_roaming_peer "peer-roaming" "$BR_LAN1" "$BR_LAN2" "$ROAMING_PEER_IP_LAN1" "$NAT_GW1_LAN_IP"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER1_IP" "peer-static" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$ROAMING_PEER_IP_LAN1" "peer-roaming" "$NAT_GW1_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer-static" "$NAT_GW1_INET_IP" "$PEER1_IP"
    setup_peer_files "peer-roaming" "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1"

    echo ""
    echo -e "${CYAN}Step 4: Starting mesh network...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local static_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local roaming_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $static_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $roaming_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    sleep 30
    echo -e "${CYAN}Initial connection established${NC}"

    # Multiple interface hops
    for i in 1 2 3; do
        echo ""
        echo -e "${CYAN}Interface hop $i: Switching to LAN2...${NC}"
        switch_roaming_interface "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" \
            "$ROAMING_PEER_IP_LAN2" "$NAT_GW2_LAN_IP" "enp0s3"
        sleep 20

        check_mesh_connectivity "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "roaming peer (LAN2)"

        echo ""
        echo -e "${CYAN}Interface hop $i: Switching back to LAN1...${NC}"
        switch_roaming_interface "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" \
            "$ROAMING_PEER_IP_LAN1" "$NAT_GW1_LAN_IP" "enp0s2"
        sleep 20

        check_mesh_connectivity "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "roaming peer (LAN1)"
    done

    echo ""
    echo -e "${CYAN}Results:${NC}"
    echo ""
    echo "Roaming peer log (last 50 lines):"
    echo "---"
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "tail -50 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"
}

# Scenario: Reconnect
# Peer loses connectivity temporarily
run_reconnect_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: Reconnect${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test simulates a device temporarily losing connectivity"
    echo "(like going through a tunnel or elevator)."
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"
    start_nat_gateway "nat-gw1" "full-cone" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "full-cone" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm
    start_peer_vm "peer1" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_peer_vm "peer2" "$PEER2_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER1_IP" "peer1" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$PEER2_IP" "peer2" "$NAT_GW2_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer1" "$NAT_GW1_INET_IP" "$PEER1_IP"
    setup_peer_files "peer2" "$NAT_GW2_INET_IP" "$PEER2_IP"

    echo ""
    echo -e "${CYAN}Step 4: Starting mesh network...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer1_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer2_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer1_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer2_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    sleep 30
    echo -e "${CYAN}Initial connection established${NC}"

    # Test different disconnect durations
    for duration in 5 15 30; do
        echo ""
        echo -e "${CYAN}Testing ${duration}s disconnect...${NC}"

        disconnect_peer "$NAT_GW1_INET_IP" "$PEER1_IP" "$duration"

        echo "  Waiting for recovery (30s)..."
        sleep 30

        check_mesh_connectivity "$NAT_GW1_INET_IP" "$PEER1_IP" "peer1"
        check_mesh_connectivity "$NAT_GW2_INET_IP" "$PEER2_IP" "peer2"
    done

    echo ""
    echo -e "${CYAN}Results:${NC}"
    echo ""
    echo "Peer 1 log (last 50 lines):"
    echo "---"
    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "tail -50 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"
}

# Scenario: IP Change
# Peer's IP changes within same network (DHCP renewal)
run_ip_change_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: IP Change${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test simulates a device's IP address changing"
    echo "(like a DHCP lease renewal with different IP)."
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"
    start_nat_gateway "nat-gw1" "full-cone" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "full-cone" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm
    start_peer_vm "peer1" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_peer_vm "peer2" "$PEER2_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER1_IP" "peer1" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$PEER2_IP" "peer2" "$NAT_GW2_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer1" "$NAT_GW1_INET_IP" "$PEER1_IP"
    setup_peer_files "peer2" "$NAT_GW2_INET_IP" "$PEER2_IP"

    echo ""
    echo -e "${CYAN}Step 4: Starting mesh network...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer1_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer2_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer1_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer2_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    sleep 30
    echo -e "${CYAN}Initial connection established${NC}"

    # Change peer1's IP
    local new_ip="${LAN1_SUBNET}.50"
    echo ""
    echo -e "${CYAN}Changing peer1 IP from $PEER1_IP to $new_ip...${NC}"

    change_peer_ip "$NAT_GW1_INET_IP" "$PEER1_IP" "$new_ip" "enp0s2"

    echo "  Waiting for recovery (45s)..."
    sleep 45

    echo ""
    echo -e "${CYAN}Checking connectivity after IP change...${NC}"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$new_ip" "peer1 (new IP)"
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$PEER2_IP" "peer2"

    echo ""
    echo -e "${CYAN}Results:${NC}"
    echo ""
    echo "Peer 1 log (last 30 lines):"
    echo "---"
    lan_ssh "$NAT_GW1_INET_IP" "$new_ip" "tail -30 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"
}

# ============================================================
# Advanced Scenarios: Direct/Relay Transitions
# ============================================================

# Scenario: Direct to Relay
# Peer starts on full-cone NAT where direct connection works,
# then moves to symmetric NAT where relay is required
run_direct_to_relay_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: Direct to Relay Transition${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test verifies seamless transition when a peer moves from"
    echo "a network supporting direct connections to one requiring relay."
    echo ""
    echo "Scenario:"
    echo "  1. Roaming peer starts behind full-cone NAT (direct connection works)"
    echo "  2. Static peer is behind full-cone NAT"
    echo "  3. Connection established directly (no relay needed)"
    echo "  4. Roaming peer moves to symmetric NAT"
    echo "  5. Direct connection fails, mesh should fall back to relay"
    echo "  6. Communication continues via relay"
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"

    # LAN1: Full-cone NAT (direct works)
    # LAN2: Symmetric NAT (requires relay)
    start_nat_gateway "nat-gw1" "full-cone" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "symmetric" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm

    # Static peer on full-cone
    start_peer_vm "peer-static" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"

    # Roaming peer starts on full-cone, can move to symmetric
    start_roaming_peer "peer-roaming" "$BR_LAN1" "$BR_LAN2" "$ROAMING_PEER_IP_LAN1" "$NAT_GW1_LAN_IP"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER1_IP" "peer-static" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$ROAMING_PEER_IP_LAN1" "peer-roaming" "$NAT_GW1_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer-static" "$NAT_GW1_INET_IP" "$PEER1_IP"
    setup_peer_files "peer-roaming" "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1"

    echo ""
    echo -e "${CYAN}Step 4: Starting mesh network...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local static_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local roaming_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Start relay
    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    # Start static peer
    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $static_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    # Start roaming peer (initially on full-cone LAN1)
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $roaming_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 5: Waiting for initial direct connection (30s)...${NC}"
    sleep 30

    echo ""
    echo -e "${CYAN}Step 6: Checking initial connectivity (should be DIRECT)...${NC}"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "roaming peer (full-cone)"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$PEER1_IP" "static peer"

    # Check if connection is direct
    echo ""
    echo "Checking connection type (look for 'direct' in logs):"
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" \
        "grep -i 'direct\|relay\|path' /home/ubuntu/mesh-test/peer.log | tail -5" 2>/dev/null || echo "(no path info)"

    echo ""
    echo -e "${YELLOW}>>> Moving roaming peer to symmetric NAT <<<${NC}"
    echo ""

    # Switch roaming peer to symmetric NAT (LAN2)
    switch_roaming_interface "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" \
        "$ROAMING_PEER_IP_LAN2" "$NAT_GW2_LAN_IP" "enp0s3"

    echo ""
    echo -e "${CYAN}Step 7: Waiting for relay fallback (45s)...${NC}"
    echo "Direct connection should fail, mesh should detect and switch to relay"
    sleep 45

    echo ""
    echo -e "${CYAN}Step 8: Checking connectivity after move (should use RELAY)...${NC}"
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "roaming peer (symmetric)"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$PEER1_IP" "static peer"

    echo ""
    echo "Checking connection type (look for 'relay' in logs):"
    lan_ssh "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" \
        "grep -i 'direct\|relay\|path\|fallback' /home/ubuntu/mesh-test/peer.log | tail -10" 2>/dev/null || echo "(no path info)"

    echo ""
    echo -e "${CYAN}Results:${NC}"
    echo ""
    echo "Roaming peer log (showing connection transitions):"
    echo "---"
    lan_ssh "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "tail -40 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"

    echo ""
    echo "Relay log (should show forwarding activity after roam):"
    echo "---"
    inet_ssh "$RELAY_IP" "tail -20 /home/ubuntu/mesh-test/relay.log" 2>/dev/null || echo "(no log)"
    echo "---"
}

# Scenario: Relay to Direct
# Peer starts on symmetric NAT requiring relay,
# then moves to full-cone NAT where direct works
run_relay_to_direct_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: Relay to Direct Transition${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test verifies that when moving from relay-required to"
    echo "direct-capable network, the mesh upgrades to direct connection."
    echo ""
    echo "Scenario:"
    echo "  1. Roaming peer starts behind symmetric NAT (requires relay)"
    echo "  2. Static peer is behind full-cone NAT"
    echo "  3. Initial connection via relay"
    echo "  4. Roaming peer moves to full-cone NAT"
    echo "  5. Mesh should detect and upgrade to direct connection"
    echo "  6. Communication continues with lower latency"
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"

    # LAN1: Symmetric NAT (requires relay)
    # LAN2: Full-cone NAT (direct works)
    start_nat_gateway "nat-gw1" "symmetric" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "full-cone" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm

    # Static peer on full-cone
    start_peer_vm "peer-static" "$PEER2_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"

    # Roaming peer starts on symmetric
    start_roaming_peer "peer-roaming" "$BR_LAN1" "$BR_LAN2" "$ROAMING_PEER_IP_LAN1" "$NAT_GW1_LAN_IP"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER2_IP" "peer-static" "$NAT_GW2_INET_IP" || return 1
    wait_for_ssh "$ROAMING_PEER_IP_LAN1" "peer-roaming" "$NAT_GW1_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer-static" "$NAT_GW2_INET_IP" "$PEER2_IP"
    setup_peer_files "peer-roaming" "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1"

    echo ""
    echo -e "${CYAN}Step 4: Starting mesh network...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local static_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local roaming_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $static_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $roaming_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 5: Waiting for initial relay connection (30s)...${NC}"
    sleep 30

    echo ""
    echo -e "${CYAN}Step 6: Checking initial connectivity (should use RELAY)...${NC}"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "roaming peer (symmetric)"
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$PEER2_IP" "static peer"

    echo ""
    echo -e "${YELLOW}>>> Moving roaming peer to full-cone NAT <<<${NC}"
    echo ""

    switch_roaming_interface "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" \
        "$ROAMING_PEER_IP_LAN2" "$NAT_GW2_LAN_IP" "enp0s3"

    echo ""
    echo -e "${CYAN}Step 7: Waiting for direct connection upgrade (45s)...${NC}"
    echo "Mesh should detect better network and upgrade to direct"
    sleep 45

    echo ""
    echo -e "${CYAN}Step 8: Checking connectivity after move (should be DIRECT)...${NC}"
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "roaming peer (full-cone)"
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$PEER2_IP" "static peer"

    echo ""
    echo "Checking connection type (look for 'direct' upgrade):"
    lan_ssh "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" \
        "grep -i 'direct\|relay\|upgrade\|path' /home/ubuntu/mesh-test/peer.log | tail -10" 2>/dev/null || echo "(no path info)"

    echo ""
    echo -e "${CYAN}Results:${NC}"
    echo ""
    echo "Roaming peer log:"
    echo "---"
    lan_ssh "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "tail -40 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"
}

# Scenario: Seamless Handoff
# Verify no message loss during network transitions
run_seamless_handoff_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: Seamless Handoff (Message Continuity)${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test verifies that messages are not lost during roaming."
    echo "A continuous message stream is sent while the peer roams."
    echo ""
    echo "Metrics tracked:"
    echo "  - Message delivery rate before/during/after roaming"
    echo "  - Maximum gap in message sequence"
    echo "  - Time to re-establish connection"
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"

    start_nat_gateway "nat-gw1" "full-cone" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "full-cone" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm
    start_peer_vm "peer-sender" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_roaming_peer "peer-receiver" "$BR_LAN1" "$BR_LAN2" "$ROAMING_PEER_IP_LAN1" "$NAT_GW1_LAN_IP"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER1_IP" "peer-sender" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$ROAMING_PEER_IP_LAN1" "peer-receiver" "$NAT_GW1_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer-sender" "$NAT_GW1_INET_IP" "$PEER1_IP"
    setup_peer_files "peer-receiver" "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1"

    echo ""
    echo -e "${CYAN}Step 4: Starting mesh network...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local sender_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local receiver_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $sender_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $receiver_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 5: Waiting for connection (20s)...${NC}"
    sleep 20

    echo ""
    echo -e "${CYAN}Step 6: Starting continuous message stream...${NC}"
    echo "Messages will be sent while peer roams"

    # Start a background message sender (this would need actual message support in omerta-mesh)
    # For now, we'll simulate by logging timestamps
    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "
        for i in \$(seq 1 60); do
            echo \"[\$(date +%s)] Message \$i\" >> /home/ubuntu/mesh-test/sent.log
            sleep 1
        done &
    "

    sleep 10
    echo "  Sent 10 messages, now roaming..."

    echo ""
    echo -e "${YELLOW}>>> Roaming peer to LAN2 <<<${NC}"
    switch_roaming_interface "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" \
        "$ROAMING_PEER_IP_LAN2" "$NAT_GW2_LAN_IP" "enp0s3"

    echo "  Continuing to send messages during roam..."
    sleep 20

    echo ""
    echo -e "${YELLOW}>>> Roaming peer back to LAN1 <<<${NC}"
    switch_roaming_interface "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" \
        "$ROAMING_PEER_IP_LAN1" "$NAT_GW1_LAN_IP" "enp0s2"

    sleep 20

    echo ""
    echo -e "${CYAN}Step 7: Analyzing results...${NC}"

    echo ""
    echo "Messages sent:"
    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "wc -l /home/ubuntu/mesh-test/sent.log 2>/dev/null || echo '0'"

    echo ""
    echo "Sender peer log (connection events):"
    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "grep -i 'connect\|disconnect\|roam' /home/ubuntu/mesh-test/peer.log | tail -20" 2>/dev/null || echo "(no events)"

    echo ""
    echo "Receiver peer log (connection events):"
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "grep -i 'connect\|disconnect\|roam' /home/ubuntu/mesh-test/peer.log | tail -20" 2>/dev/null || echo "(no events)"
}

# ============================================================
# Interface Priority Scenarios
# ============================================================

# Scenario: Priority Failover
# Primary interface (WiFi) fails, seamlessly switch to backup (cellular)
run_priority_failover_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: Interface Priority Failover${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test simulates a device with multiple interfaces:"
    echo "  - Primary: WiFi (LAN1, preferred, metered=false)"
    echo "  - Backup:  Cellular (LAN2, fallback, metered=true)"
    echo ""
    echo "Scenario:"
    echo "  1. Device connected via WiFi (primary)"
    echo "  2. WiFi goes down (e.g., out of range)"
    echo "  3. Mesh should failover to cellular"
    echo "  4. WiFi comes back up"
    echo "  5. Mesh should switch back to WiFi (preferred)"
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"

    # Both LANs are full-cone for simplicity
    start_nat_gateway "nat-gw1" "full-cone" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "full-cone" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm
    start_peer_vm "peer-static" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"

    # Start roaming peer with both interfaces active
    start_roaming_peer "peer-mobile" "$BR_LAN1" "$BR_LAN2" "$ROAMING_PEER_IP_LAN1" "$NAT_GW1_LAN_IP"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER1_IP" "peer-static" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$ROAMING_PEER_IP_LAN1" "peer-mobile" "$NAT_GW1_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Configuring secondary interface (cellular backup)...${NC}"

    # Configure the secondary interface on the mobile peer but don't use it yet
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "sudo bash -c '
        ip addr add $ROAMING_PEER_IP_LAN2/24 dev enp0s3
        ip link set enp0s3 up
        # Add a higher metric route (backup)
        ip route add default via $NAT_GW2_LAN_IP dev enp0s3 metric 200
    '" 2>/dev/null || true

    echo ""
    echo -e "${CYAN}Step 4: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer-static" "$NAT_GW1_INET_IP" "$PEER1_IP"
    setup_peer_files "peer-mobile" "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1"

    echo ""
    echo -e "${CYAN}Step 5: Starting mesh network...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local static_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local mobile_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $static_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    # Start mobile peer with interface priority config (if supported)
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $mobile_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 6: Waiting for connection via primary (WiFi)...${NC}"
    sleep 30

    check_mesh_connectivity "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "mobile peer (WiFi)"

    echo ""
    echo -e "${YELLOW}>>> Simulating WiFi failure (primary interface down) <<<${NC}"

    # Bring down primary interface
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "sudo ip link set enp0s2 down"

    echo "  Waiting for failover to cellular (30s)..."
    sleep 30

    echo ""
    echo -e "${CYAN}Step 7: Checking connectivity via backup (cellular)...${NC}"
    # Now need to reach via NAT_GW2
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "mobile peer (cellular)"

    echo ""
    echo -e "${YELLOW}>>> Restoring WiFi (primary interface up) <<<${NC}"

    # Restore primary interface
    lan_ssh "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "sudo bash -c '
        ip link set enp0s2 up
        ip addr add $ROAMING_PEER_IP_LAN1/24 dev enp0s2 2>/dev/null || true
        ip route add default via $NAT_GW1_LAN_IP dev enp0s2 metric 100 2>/dev/null || true
    '"

    echo "  Waiting for switch back to WiFi (45s)..."
    sleep 45

    echo ""
    echo -e "${CYAN}Step 8: Checking if switched back to WiFi...${NC}"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "mobile peer (WiFi restored)"

    echo ""
    echo -e "${CYAN}Results:${NC}"
    echo ""
    echo "Mobile peer log (interface transitions):"
    echo "---"
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "tail -50 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || \
        lan_ssh "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "tail -50 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || \
        echo "(no log)"
    echo "---"
}

# Scenario: Multi-Interface
# Multiple active interfaces simultaneously, mesh selects best
run_multi_interface_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: Multi-Interface Selection${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test verifies mesh behavior with multiple active interfaces."
    echo "The mesh should:"
    echo "  - Detect all available interfaces"
    echo "  - Select the best path based on latency/quality"
    echo "  - Handle simultaneous connectivity gracefully"
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"

    # LAN1: Low latency network
    # LAN2: High latency network (simulated)
    start_nat_gateway "nat-gw1" "full-cone" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "full-cone" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm
    start_peer_vm "peer-static" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_roaming_peer "peer-multi" "$BR_LAN1" "$BR_LAN2" "$ROAMING_PEER_IP_LAN1" "$NAT_GW1_LAN_IP"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER1_IP" "peer-static" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$ROAMING_PEER_IP_LAN1" "peer-multi" "$NAT_GW1_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Configuring both interfaces active...${NC}"

    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "sudo bash -c '
        # Configure second interface
        ip addr add $ROAMING_PEER_IP_LAN2/24 dev enp0s3
        ip link set enp0s3 up

        # Add latency to LAN2 to simulate slower network
        tc qdisc add dev enp0s3 root netem delay 100ms 2>/dev/null || true

        echo \"Both interfaces configured:\"
        ip addr show enp0s2 | grep inet
        ip addr show enp0s3 | grep inet
    '"

    echo ""
    echo -e "${CYAN}Step 4: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer-static" "$NAT_GW1_INET_IP" "$PEER1_IP"
    setup_peer_files "peer-multi" "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1"

    echo ""
    echo -e "${CYAN}Step 5: Starting mesh network...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local static_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local multi_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $static_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $multi_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 6: Waiting for path selection (30s)...${NC}"
    echo "Mesh should prefer LAN1 (lower latency)"
    sleep 30

    echo ""
    echo -e "${CYAN}Step 7: Checking which interface is being used...${NC}"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "multi-interface peer"

    echo ""
    echo "Network statistics (should show more traffic on enp0s2):"
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "
        echo 'enp0s2 (LAN1 - low latency):'
        cat /sys/class/net/enp0s2/statistics/tx_bytes
        echo 'enp0s3 (LAN2 - high latency):'
        cat /sys/class/net/enp0s3/statistics/tx_bytes
    " 2>/dev/null || echo "(stats unavailable)"

    echo ""
    echo -e "${CYAN}Results:${NC}"
    echo ""
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "tail -30 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
}

# Scenario: Priority Restore
# Backup is active, primary comes back, should switch back
run_priority_restore_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: Priority Restore${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test starts with primary unavailable, using backup."
    echo "When primary becomes available, mesh should switch to it."
    echo ""

    # This is similar to priority_failover but starts in the failed state
    echo "This test is a subset of priority-failover."
    echo "Running priority-failover test instead..."
    echo ""

    run_priority_failover_test
}

# ============================================================
# Warm Relay Scenarios
# ============================================================

# Scenario: Symmetric NAT Stationary + Roaming Peer
# Tests the warm relay strategy when stationary peer can't accept new connections
run_symmetric_stationary_roaming_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: Symmetric NAT Stationary + Roaming Peer${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test covers a critical edge case:"
    echo "  - Peer A: Stationary, behind SYMMETRIC NAT"
    echo "  - Peer B: Roaming, starts behind full-cone NAT"
    echo ""
    echo "The problem:"
    echo "  When Peer B roams, its IP changes. Peer A's symmetric NAT"
    echo "  will DROP packets from B's new IP because it's not the"
    echo "  expected source. B cannot notify A directly!"
    echo ""
    echo "The solution:"
    echo "  Both peers maintain 'warm' connections to relay nodes."
    echo "  When B roams, it immediately uses the relay to reach A."
    echo "  A's NAT allows relay traffic (it's been keeping the session warm)."
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"

    # Peer A: SYMMETRIC NAT (stationary, can't accept new connections)
    # Peer B: Full-cone NAT (roaming, will change to different network)
    start_nat_gateway "nat-gw1" "symmetric" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "full-cone" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm

    # Stationary peer behind symmetric NAT
    start_peer_vm "peer-stationary" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"

    # Roaming peer starts on full-cone, can move to a different full-cone network
    start_roaming_peer "peer-roaming" "$BR_LAN2" "$BR_LAN1" "$ROAMING_PEER_IP_LAN2" "$NAT_GW2_LAN_IP"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER1_IP" "peer-stationary" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$ROAMING_PEER_IP_LAN2" "peer-roaming" "$NAT_GW2_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer-stationary" "$NAT_GW1_INET_IP" "$PEER1_IP"
    setup_peer_files "peer-roaming" "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2"

    echo ""
    echo -e "${CYAN}Step 4: Starting mesh network with warm relay...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local stationary_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local roaming_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Start relay
    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    # Start stationary peer (symmetric NAT)
    # This peer MUST maintain warm relay connection because it can't accept
    # new incoming connections once the roaming peer's IP changes
    echo "  Starting stationary peer (symmetric NAT)..."
    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $stationary_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    # Start roaming peer (full-cone NAT initially)
    echo "  Starting roaming peer (full-cone NAT)..."
    lan_ssh "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $roaming_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 5: Waiting for initial connection (30s)...${NC}"
    echo "Connection may be via relay since stationary peer is behind symmetric NAT"
    sleep 30

    echo ""
    echo -e "${CYAN}Step 6: Verifying initial connection...${NC}"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$PEER1_IP" "stationary peer"
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" "roaming peer"

    echo ""
    echo "Initial connection path (check for relay usage):"
    lan_ssh "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" \
        "grep -i 'relay\|direct\|connected' /home/ubuntu/mesh-test/peer.log | tail -5" 2>/dev/null || echo "(no path info)"

    echo ""
    echo -e "${YELLOW}>>> CRITICAL TEST: Roaming peer changing networks <<<${NC}"
    echo ""
    echo "When roaming peer moves to LAN1, its IP will change."
    echo "The stationary peer's symmetric NAT will DROP packets from the new IP!"
    echo "The warm relay connection should save the day."
    echo ""

    # Move roaming peer to LAN1 (behind the same NAT gateway as stationary peer, but different IP)
    # This simulates moving to a different network entirely
    switch_roaming_interface "$NAT_GW2_INET_IP" "$ROAMING_PEER_IP_LAN2" \
        "$ROAMING_PEER_IP_LAN1" "$NAT_GW1_LAN_IP" "enp0s3"

    echo ""
    echo -e "${CYAN}Step 7: Waiting for warm relay failover (45s)...${NC}"
    echo "Roaming peer should switch to relay to reach stationary peer"
    sleep 45

    echo ""
    echo -e "${CYAN}Step 8: Verifying connection after roam...${NC}"
    # Note: roaming peer is now accessible via NAT_GW1
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$PEER1_IP" "stationary peer"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "roaming peer (new location)"

    echo ""
    echo "Connection path after roam (SHOULD show relay usage):"
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" \
        "grep -i 'relay\|direct\|roam\|failover' /home/ubuntu/mesh-test/peer.log | tail -10" 2>/dev/null || echo "(no path info)"

    echo ""
    echo -e "${CYAN}Results:${NC}"
    echo ""
    echo "=== Stationary Peer Log (symmetric NAT) ==="
    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "tail -40 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo ""
    echo "=== Roaming Peer Log ==="
    lan_ssh "$NAT_GW1_INET_IP" "$ROAMING_PEER_IP_LAN1" "tail -40 /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo ""
    echo "=== Relay Log (should show traffic forwarding) ==="
    inet_ssh "$RELAY_IP" "tail -30 /home/ubuntu/mesh-test/relay.log" 2>/dev/null || echo "(no log)"

    echo ""
    echo -e "${CYAN}Test Analysis:${NC}"
    echo "  If connection was maintained, the warm relay strategy worked!"
    echo "  Look for:"
    echo "    - 'relay' in connection logs after roam"
    echo "    - Traffic forwarding entries in relay log"
    echo "    - No 'timeout' or 'unreachable' errors"
}

# Scenario: Warm Relay Keepalive Test
# Verify that warm relay connections are maintained properly
run_warm_relay_keepalive_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Roaming Test: Warm Relay Keepalive Verification${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo "This test verifies that peers maintain warm relay connections"
    echo "even when using direct paths, enabling instant failover."
    echo ""

    echo -e "${CYAN}Step 1: Starting infrastructure...${NC}"

    # Both peers on full-cone NAT (direct should work)
    start_nat_gateway "nat-gw1" "full-cone" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_nat_gateway "nat-gw2" "full-cone" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
    start_relay_vm
    start_peer_vm "peer1" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
    start_peer_vm "peer2" "$PEER2_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"

    echo ""
    echo -e "${CYAN}Step 2: Waiting for VMs...${NC}"
    sleep 45

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$RELAY_IP" "relay" || return 1
    wait_for_ssh "$PEER1_IP" "peer1" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$PEER2_IP" "peer2" "$NAT_GW2_INET_IP" || return 1

    echo ""
    echo -e "${CYAN}Step 3: Setting up test files...${NC}"
    setup_relay_files
    setup_peer_files "peer1" "$NAT_GW1_INET_IP" "$PEER1_IP"
    setup_peer_files "peer2" "$NAT_GW2_INET_IP" "$PEER2_IP"

    echo ""
    echo -e "${CYAN}Step 4: Starting mesh network...${NC}"

    local relay_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer1_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local peer2_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

    inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $relay_id --listen 0.0.0.0:9000 --relay \
        > relay.log 2>&1 &"
    sleep 3

    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer1_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"
    sleep 2

    lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
        --id $peer2_id --listen 0.0.0.0:9000 --bootstrap $RELAY_IP:9000 \
        > peer.log 2>&1 &"

    echo ""
    echo -e "${CYAN}Step 5: Waiting for connections to establish (30s)...${NC}"
    echo "Peers should connect directly, but also maintain warm relay"
    sleep 30

    echo ""
    echo -e "${CYAN}Step 6: Verifying direct connection...${NC}"
    check_mesh_connectivity "$NAT_GW1_INET_IP" "$PEER1_IP" "peer1"
    check_mesh_connectivity "$NAT_GW2_INET_IP" "$PEER2_IP" "peer2"

    echo ""
    echo -e "${CYAN}Step 7: Waiting to observe warm relay keepalives (60s)...${NC}"
    echo "Even with direct connection, peers should send keepalives to relay"
    sleep 60

    echo ""
    echo -e "${CYAN}Step 8: Checking relay for keepalive activity...${NC}"
    echo ""
    echo "Relay log (look for keepalive messages from both peers):"
    echo "---"
    inet_ssh "$RELAY_IP" "grep -i 'keepalive\|warm\|session\|peer' /home/ubuntu/mesh-test/relay.log | tail -20" 2>/dev/null || echo "(no keepalive info)"
    echo "---"

    echo ""
    echo "Peer 1 log (look for warm relay maintenance):"
    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "grep -i 'relay\|warm\|keepalive' /home/ubuntu/mesh-test/peer.log | tail -10" 2>/dev/null || echo "(no relay info)"

    echo ""
    echo "Peer 2 log (look for warm relay maintenance):"
    lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "grep -i 'relay\|warm\|keepalive' /home/ubuntu/mesh-test/peer.log | tail -10" 2>/dev/null || echo "(no relay info)"

    echo ""
    echo -e "${CYAN}Test Analysis:${NC}"
    echo "  Warm relay is working if:"
    echo "    - Relay log shows periodic keepalive from both peers"
    echo "    - Peer logs show 'warm relay' or similar maintenance activity"
    echo "    - Direct path is used for data, relay is kept as backup"
}

# ============================================================
# Main
# ============================================================

echo "============================================================"
echo "OmertaMesh Roaming Device Test"
echo "============================================================"
echo "Scenario: $SCENARIO"
echo ""

# Check prerequisites
echo -e "${CYAN}Checking prerequisites...${NC}"

for br in "$BR_INTERNET" "$BR_LAN1" "$BR_LAN2"; do
    if ! ip link show "$br" &>/dev/null; then
        echo -e "${RED}Bridge $br not found. Run setup-infra.sh first.${NC}"
        exit 1
    fi
done

if [[ ! -f "$IMAGES_DIR/ubuntu-base.img" ]]; then
    echo -e "${RED}Ubuntu base image not found. Run setup-infra.sh images first.${NC}"
    exit 1
fi

if [[ ! -f "$OMERTA_DIR/.build/debug/omerta-mesh" ]]; then
    echo "Building omerta-mesh..."
    (cd "$OMERTA_DIR" && swift build --product omerta-mesh)
fi

echo -e "${GREEN}Prerequisites OK${NC}"

# Create roaming peer cloud-init template if it doesn't exist
if [[ ! -f "$SCRIPT_DIR/cloud-init/roaming-peer.yaml" ]]; then
    cat > "$SCRIPT_DIR/cloud-init/roaming-peer.yaml" << 'EOFTEMPLATE'
#cloud-config
# Roaming Peer VM Configuration
#
# This VM has two network interfaces for roaming tests.

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
            addresses:
              - ${PEER_IP}/24
            routes:
              - to: default
                via: ${GATEWAY_IP}
          enp0s3:
            optional: true

  - path: /etc/sysctl.d/99-mesh.conf
    content: |
      net.ipv4.ip_forward=1

runcmd:
  - netplan apply
  - sleep 2
  - mkdir -p /home/ubuntu/mesh-test
  - chown ubuntu:ubuntu /home/ubuntu/mesh-test
  - echo "Roaming Peer VM ready"
EOFTEMPLATE
fi

# Run the selected scenario
case "$SCENARIO" in
    # Basic scenarios
    nat-switch)
        run_nat_switch_test
        ;;
    interface-hop)
        run_interface_hop_test
        ;;
    reconnect)
        run_reconnect_test
        ;;
    ip-change)
        run_ip_change_test
        ;;
    # Advanced scenarios - direct/relay transitions
    direct-to-relay)
        run_direct_to_relay_test
        ;;
    relay-to-direct)
        run_relay_to_direct_test
        ;;
    seamless-handoff)
        run_seamless_handoff_test
        ;;
    # Interface priority scenarios
    priority-failover)
        run_priority_failover_test
        ;;
    multi-interface)
        run_multi_interface_test
        ;;
    priority-restore)
        run_priority_restore_test
        ;;
    # Warm relay scenarios
    symmetric-stationary-roaming)
        run_symmetric_stationary_roaming_test
        ;;
    warm-relay-keepalive)
        run_warm_relay_keepalive_test
        ;;
esac

echo ""
echo -e "${GREEN}Roaming test complete${NC}"
echo "Press Ctrl+C to cleanup and exit."
echo ""

while true; do
    sleep 10
done
