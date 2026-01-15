#!/bin/bash
# Inner test runner - runs inside the outer VM
# This script is called by run-nested-test.sh and should not be run directly.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# When running inside VM, paths are different
if [[ -f "$SCRIPT_DIR/vm-utils.sh" ]]; then
    source "$SCRIPT_DIR/vm-utils.sh"
elif [[ -f "$SCRIPT_DIR/../lib/vm-utils.sh" ]]; then
    source "$SCRIPT_DIR/../lib/vm-utils.sh"
else
    echo "Error: Cannot find vm-utils.sh"
    exit 1
fi

# Detect if we're in the outer VM test directory
if [[ -d "/home/ubuntu/nested-vm-test" ]]; then
    SCRIPT_DIR="/home/ubuntu/nested-vm-test"
    IMAGES_DIR="$SCRIPT_DIR/images"
    CLOUD_INIT_DIR="$SCRIPT_DIR/cloud-init"
    RUN_DIR="$SCRIPT_DIR/.run"
    MESH_BIN="$SCRIPT_DIR/omerta-mesh"
else
    IMAGES_DIR="$SCRIPT_DIR/../images"
    CLOUD_INIT_DIR="$SCRIPT_DIR/../cloud-init"
    RUN_DIR="$SCRIPT_DIR/../.run"
    MESH_BIN="$SCRIPT_DIR/../omerta-mesh"
fi

# Network configuration
BR_INTERNET="br-mesh-inet"
BR_LAN1="br-mesh-lan1"
BR_LAN2="br-mesh-lan2"

INET_SUBNET="192.168.100"
LAN1_SUBNET="10.0.1"
LAN2_SUBNET="10.0.2"

# VM IPs
NAT_GW1_INET_IP="${INET_SUBNET}.1"
NAT_GW1_LAN_IP="${LAN1_SUBNET}.1"
NAT_GW2_INET_IP="${INET_SUBNET}.2"
NAT_GW2_LAN_IP="${LAN2_SUBNET}.1"
RELAY_IP="${INET_SUBNET}.3"
PEER1_IP="${LAN1_SUBNET}.2"
PEER2_IP="${LAN2_SUBNET}.2"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <nat-type-1> <nat-type-2> [relay] [--serial]"
    echo ""
    echo "NAT Types: public, full-cone, addr-restrict, port-restrict, symmetric"
    echo ""
    echo "Options:"
    echo "  relay         Include a relay node"
    echo "  --serial      Use serial console instead of SSH"
    exit 1
}

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This inner script must be run as root${NC}"
    exit 1
fi

NAT1="${1:-}"
NAT2="${2:-}"
USE_RELAY=""
USE_SERIAL=""

# Parse arguments
shift 2 2>/dev/null || true
for arg in "$@"; do
    case "$arg" in
        relay) USE_RELAY="relay" ;;
        --serial) USE_SERIAL="serial" ;;
    esac
done

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

# Check prerequisites
check_prerequisites() {
    echo -e "${CYAN}Checking prerequisites...${NC}"

    # Check for bridges
    for br in "$BR_INTERNET" "$BR_LAN1" "$BR_LAN2"; do
        if ! ip link show "$br" &>/dev/null; then
            echo -e "${RED}Bridge $br not found. Run setup-infra.sh first.${NC}"
            exit 1
        fi
    done

    # Check for base images
    if [[ ! -f "$IMAGES_DIR/ubuntu-base.img" ]]; then
        echo -e "${RED}Ubuntu base image not found at $IMAGES_DIR/ubuntu-base.img${NC}"
        exit 1
    fi

    # Check for omerta-mesh binary
    if [[ ! -f "$MESH_BIN" ]]; then
        echo -e "${RED}omerta-mesh binary not found at $MESH_BIN${NC}"
        exit 1
    fi

    echo -e "${GREEN}Prerequisites OK${NC}"
}

# Cleanup function
cleanup() {
    echo ""
    echo -e "${CYAN}Cleaning up...${NC}"
    cleanup_all_vms
    echo -e "${GREEN}Cleanup complete${NC}"
}
trap cleanup EXIT

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

    ip tuntap del dev "$tap_inet" mode tap 2>/dev/null || true
    ip tuntap del dev "$tap_lan" mode tap 2>/dev/null || true

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
    echo "  Internet: $inet_ip, LAN: $lan_ip"
}

# Start peer VM
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

    ip tuntap del dev "$tap_name" mode tap 2>/dev/null || true

    ip tuntap add dev "$tap_name" mode tap
    ip link set "$tap_name" master "$lan_bridge"
    ip link set "$tap_name" up

    local pid
    pid=$(start_vm "$name" 512 1 "$disk" "$cloud_init" \
        "tap,ifname=$tap_name,script=no,downscript=no")

    echo "  Started $name (PID $pid)"
    echo "  IP: $ip, Gateway: $gateway_ip"
}

# Start relay VM
start_relay_vm() {
    echo -e "${CYAN}Starting relay VM${NC}"

    local name="relay"
    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 10G)

    local cloud_init
    cloud_init=$(create_cloud_init_iso "$name" "peer.yaml" \
        "PEER_IP=$RELAY_IP" \
        "GATEWAY_IP=$INET_SUBNET.254")

    local tap_name="tap-${name}"

    ip tuntap del dev "$tap_name" mode tap 2>/dev/null || true

    ip tuntap add dev "$tap_name" mode tap
    ip link set "$tap_name" master "$BR_INTERNET"
    ip link set "$tap_name" up

    local pid
    pid=$(start_vm "$name" 512 1 "$disk" "$cloud_init" \
        "tap,ifname=$tap_name,script=no,downscript=no")

    echo "  Started relay (PID $pid)"
    echo "  IP: $RELAY_IP"
}

# SSH helpers
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

# Wait for VM to be SSH-accessible
wait_for_ssh() {
    local ip="$1"
    local name="$2"
    local jump_ip="${3:-}"
    local timeout=180

    echo -n "  Waiting for $name..."

    local start_time=$(date +%s)
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

# Find Swift library directory
find_swift_lib_dir() {
    if [[ -d "$SCRIPT_DIR/lib" ]] && ls "$SCRIPT_DIR/lib"/*.so* &>/dev/null 2>&1; then
        echo "$SCRIPT_DIR/lib"
        return 0
    fi
    return 1
}

# Setup peer via SSH
setup_peer() {
    local name="$1"
    local jump_ip="$2"
    local target_ip="$3"

    echo "  Setting up $name..."

    lan_ssh "$jump_ip" "$target_ip" "mkdir -p /home/ubuntu/mesh-test/lib"

    lan_scp "$MESH_BIN" "$jump_ip" "$target_ip" "/home/ubuntu/mesh-test/"

    local swift_lib_dir
    if swift_lib_dir=$(find_swift_lib_dir); then
        echo "    Copying libs from $swift_lib_dir"
        local lib_count=0
        for lib in "$swift_lib_dir"/*.so*; do
            if [[ -f "$lib" ]]; then
                lan_scp "$lib" "$jump_ip" "$target_ip" "/home/ubuntu/mesh-test/lib/" 2>/dev/null && ((lib_count++)) || true
            fi
        done
        echo "    Copied $lib_count libraries"
    fi

    lan_ssh "$jump_ip" "$target_ip" "chmod +x /home/ubuntu/mesh-test/omerta-mesh"
    echo "    Done"
}

# Setup relay via SSH
setup_relay() {
    echo "  Setting up relay..."

    inet_ssh "$RELAY_IP" "mkdir -p /home/ubuntu/mesh-test/lib"

    inet_scp "$MESH_BIN" "$RELAY_IP" "/home/ubuntu/mesh-test/"

    local swift_lib_dir
    if swift_lib_dir=$(find_swift_lib_dir); then
        for lib in "$swift_lib_dir"/*.so*; do
            if [[ -f "$lib" ]]; then
                inet_scp "$lib" "$RELAY_IP" "/home/ubuntu/mesh-test/lib/" 2>/dev/null || true
            fi
        done
    fi

    inet_ssh "$RELAY_IP" "chmod +x /home/ubuntu/mesh-test/omerta-mesh"
    echo "    Done"
}

# Setup peer via serial console
setup_peer_serial() {
    local name="$1"
    local vm_name="$2"

    echo "  Setting up $name via serial..."

    serial_exec "$vm_name" "mkdir -p /home/ubuntu/mesh-test/lib" 5

    echo "    Transferring binary..."
    serial_put_file "$vm_name" "$MESH_BIN" "/home/ubuntu/mesh-test/omerta-mesh"

    local swift_lib_dir
    if swift_lib_dir=$(find_swift_lib_dir); then
        echo "    Transferring libraries..."
        for lib in "$swift_lib_dir"/libswiftCore.so "$swift_lib_dir"/libFoundation.so \
                   "$swift_lib_dir"/libswiftDispatch.so "$swift_lib_dir"/libdispatch.so; do
            if [[ -f "$lib" ]]; then
                serial_put_file "$vm_name" "$lib" "/home/ubuntu/mesh-test/lib/$(basename "$lib")" || true
            fi
        done
    fi

    echo "    Done"
}

# Run mesh via serial
run_mesh_serial() {
    local vm_name="$1"
    local peer_id="$2"
    local port="$3"
    local bootstrap="$4"

    echo "  Starting mesh on $vm_name..."

    local cmd="cd /home/ubuntu/mesh-test && LD_LIBRARY_PATH=./lib nohup ./omerta-mesh --peer-id $peer_id --port $port"
    [[ -n "$bootstrap" ]] && cmd="$cmd --bootstrap $bootstrap"
    cmd="$cmd > mesh.log 2>&1 &"

    serial_exec "$vm_name" "$cmd" 5
    sleep 2

    local pid=$(serial_exec "$vm_name" "pgrep -f omerta-mesh" 3)
    [[ -n "$pid" ]] && echo "    Started (PID $pid)" || echo "    WARNING: May not have started"
}

# Get mesh log via serial
get_mesh_log_serial() {
    local vm_name="$1"
    serial_exec "$vm_name" "cat /home/ubuntu/mesh-test/mesh.log 2>/dev/null" 10
}

# Run the test
run_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}NAT Test: $NAT1 <-> $NAT2 ${USE_RELAY:+(with relay)}${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    # Wait for VMs
    echo -e "${CYAN}Step 1: Waiting for VMs...${NC}"
    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$PEER1_IP" "peer1" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$PEER2_IP" "peer2" "$NAT_GW2_INET_IP" || return 1

    [[ "$USE_RELAY" == "relay" ]] && { wait_for_ssh "$RELAY_IP" "relay" || return 1; }

    echo ""

    # Verify NAT config
    echo -e "${CYAN}Step 2: Verifying NAT configuration...${NC}"

    for gw_ip in "$NAT_GW1_INET_IP" "$NAT_GW2_INET_IP"; do
        local fwd=$(inet_ssh "$gw_ip" 'cat /proc/sys/net/ipv4/ip_forward' 2>/dev/null)
        if [[ "$fwd" != "1" ]]; then
            echo "  Applying NAT config to $gw_ip..."
            inet_ssh "$gw_ip" 'sudo /usr/local/bin/configure-nat.sh' 2>/dev/null || true
        fi
    done

    echo "  NAT gateway 1: $(inet_ssh "$NAT_GW1_INET_IP" 'cat /etc/mesh-nat-type' 2>/dev/null)"
    echo "  NAT gateway 2: $(inet_ssh "$NAT_GW2_INET_IP" 'cat /etc/mesh-nat-type' 2>/dev/null)"

    echo ""

    # Test connectivity
    echo -e "${CYAN}Step 3: Testing connectivity...${NC}"

    echo -n "  peer1 -> NAT-GW2: "
    if lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$NAT_GW2_INET_IP', 22)); s.close()\"" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    echo -n "  peer2 -> NAT-GW1: "
    if lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$NAT_GW1_INET_IP', 22)); s.close()\"" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    echo ""

    # Copy test files
    echo -e "${CYAN}Step 4: Copying test files...${NC}"

    if [[ "$USE_SERIAL" == "serial" ]]; then
        setup_peer_serial "peer1" "peer1"
        setup_peer_serial "peer2" "peer2"
    else
        setup_peer "peer1" "$NAT_GW1_INET_IP" "$PEER1_IP"
        setup_peer "peer2" "$NAT_GW2_INET_IP" "$PEER2_IP"
    fi

    [[ "$USE_RELAY" == "relay" ]] && setup_relay

    echo ""

    # Start mesh
    echo -e "${CYAN}Step 5: Starting mesh network...${NC}"

    local peer1_id=$(cat /proc/sys/kernel/random/uuid)
    local peer2_id=$(cat /proc/sys/kernel/random/uuid)
    local relay_id=$(cat /proc/sys/kernel/random/uuid)

    local bootstrap_addr
    if [[ "$USE_RELAY" == "relay" ]]; then
        bootstrap_addr="$RELAY_IP:9000"

        echo "  Starting relay..."
        inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
            LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
            --peer-id $relay_id --port 9000 --relay \
            > mesh.log 2>&1 &"
        sleep 3
    else
        bootstrap_addr="$NAT_GW1_INET_IP:9000"
    fi

    if [[ "$USE_SERIAL" == "serial" ]]; then
        run_mesh_serial "peer1" "$peer1_id" "9000" "$bootstrap_addr"
        sleep 2
        run_mesh_serial "peer2" "$peer2_id" "9000" "$bootstrap_addr"
    else
        echo "  Starting peer1..."
        lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
            LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
            --peer-id $peer1_id --port 9000 --bootstrap $bootstrap_addr \
            > mesh.log 2>&1 &"
        sleep 2

        echo "  Starting peer2..."
        lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "cd /home/ubuntu/mesh-test && \
            LD_LIBRARY_PATH=./lib nohup ./omerta-mesh \
            --peer-id $peer2_id --port 9000 --bootstrap $bootstrap_addr \
            > mesh.log 2>&1 &"
    fi

    echo ""

    # Stream logs in real-time with prefixes
    echo -e "${CYAN}Step 6: Streaming mesh output (Ctrl+C to stop)...${NC}"
    echo ""
    echo -e "${YELLOW}[peer1]${NC} = Peer 1 (behind $NAT1)"
    echo -e "${GREEN}[peer2]${NC} = Peer 2 (behind $NAT2)"
    [[ "$USE_RELAY" == "relay" ]] && echo -e "${CYAN}[relay]${NC} = Relay node"
    echo ""
    echo "--- Live output ---"

    # Start background tail processes for each peer
    local tail_pids=()

    if [[ "$USE_SERIAL" == "serial" ]]; then
        # For serial mode, poll the logs periodically
        (
            while true; do
                serial_exec "peer1" "tail -n +1 /home/ubuntu/mesh-test/mesh.log 2>/dev/null" 3 | \
                    sed "s/^/$(printf '\033[1;33m')[peer1]$(printf '\033[0m') /"
                sleep 2
            done
        ) &
        tail_pids+=($!)

        (
            while true; do
                serial_exec "peer2" "tail -n +1 /home/ubuntu/mesh-test/mesh.log 2>/dev/null" 3 | \
                    sed "s/^/$(printf '\033[0;32m')[peer2]$(printf '\033[0m') /"
                sleep 2
            done
        ) &
        tail_pids+=($!)
    else
        # Poll-based log streaming (more reliable through nested SSH)
        # Track last line count to only show new lines
        local peer1_lines=0
        local peer2_lines=0
        local relay_lines=0

        for i in {1..12}; do  # 12 iterations * 5 seconds = 60 seconds
            # Get peer1 log
            local peer1_log
            peer1_log=$(lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cat /home/ubuntu/mesh-test/mesh.log 2>/dev/null" 2>/dev/null || true)
            if [[ -n "$peer1_log" ]]; then
                local new_lines
                new_lines=$(echo "$peer1_log" | tail -n +$((peer1_lines + 1)))
                if [[ -n "$new_lines" ]]; then
                    echo "$new_lines" | sed "s/^/$(printf '\033[1;33m')[peer1]$(printf '\033[0m') /"
                    peer1_lines=$(echo "$peer1_log" | wc -l)
                fi
            fi

            # Get peer2 log
            local peer2_log
            peer2_log=$(lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "cat /home/ubuntu/mesh-test/mesh.log 2>/dev/null" 2>/dev/null || true)
            if [[ -n "$peer2_log" ]]; then
                local new_lines
                new_lines=$(echo "$peer2_log" | tail -n +$((peer2_lines + 1)))
                if [[ -n "$new_lines" ]]; then
                    echo "$new_lines" | sed "s/^/$(printf '\033[0;32m')[peer2]$(printf '\033[0m') /"
                    peer2_lines=$(echo "$peer2_log" | wc -l)
                fi
            fi

            # Get relay log if enabled
            if [[ "$USE_RELAY" == "relay" ]]; then
                local relay_log
                relay_log=$(inet_ssh "$RELAY_IP" "cat /home/ubuntu/mesh-test/mesh.log 2>/dev/null" 2>/dev/null || true)
                if [[ -n "$relay_log" ]]; then
                    local new_lines
                    new_lines=$(echo "$relay_log" | tail -n +$((relay_lines + 1)))
                    if [[ -n "$new_lines" ]]; then
                        echo "$new_lines" | sed "s/^/$(printf '\033[0;36m')[relay]$(printf '\033[0m') /"
                        relay_lines=$(echo "$relay_log" | wc -l)
                    fi
                fi
            fi

            sleep 5
        done
    fi

    echo ""
    echo "--- End of live output ---"
    echo ""

    # Show final summary
    echo -e "${CYAN}Step 7: Summary${NC}"
    echo "  NAT types: $NAT1 <-> $NAT2"
    echo "  Relay: ${USE_RELAY:-disabled}"
    echo "  Serial mode: ${USE_SERIAL:-disabled}"
    echo "  Peer 1 ID: $peer1_id"
    echo "  Peer 2 ID: $peer2_id"
    [[ "$USE_RELAY" == "relay" ]] && echo "  Relay ID: $relay_id"
}

# Main
echo "============================================================"
echo "OmertaMesh Nested VM NAT Test (Inner)"
echo "============================================================"
echo "Peer 1 NAT: $NAT1"
echo "Peer 2 NAT: $NAT2"
[[ "$USE_RELAY" == "relay" ]] && echo "Relay: enabled"
[[ "$USE_SERIAL" == "serial" ]] && echo "Serial mode: enabled"
echo ""

check_prerequisites

echo ""
echo -e "${CYAN}Starting VMs...${NC}"
echo ""

start_nat_gateway "nat-gw1" "$NAT1" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
start_nat_gateway "nat-gw2" "$NAT2" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"
start_peer_vm "peer1" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1"
start_peer_vm "peer2" "$PEER2_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2"

[[ "$USE_RELAY" == "relay" ]] && start_relay_vm

echo ""
echo -e "${CYAN}Waiting for VMs to boot...${NC}"
sleep 30

run_test

echo ""
echo -e "${GREEN}Test complete${NC}"
echo "Press Ctrl+C to cleanup and exit."

while true; do sleep 10; done
