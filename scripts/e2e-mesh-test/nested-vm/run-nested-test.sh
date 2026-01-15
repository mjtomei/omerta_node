#!/bin/bash
# Nested VM NAT Test Runner
#
# Runs realistic NAT traversal tests using nested VMs with proper
# network isolation and NAT behavior.
#
# Usage:
#   sudo ./run-nested-test.sh <nat-type-1> <nat-type-2> [relay]
#
# Examples:
#   sudo ./run-nested-test.sh full-cone full-cone
#   sudo ./run-nested-test.sh symmetric symmetric relay
#   sudo ./run-nested-test.sh port-restrict symmetric

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/vm-utils.sh"

OMERTA_DIR="${OMERTA_DIR}"
IMAGES_DIR="$SCRIPT_DIR/images"

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

# SSH ports (forwarded through NAT gateways for access)
NAT_GW1_SSH=2201
NAT_GW2_SSH=2202
RELAY_SSH=2203
PEER1_SSH=2211
PEER2_SSH=2212

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# TCP connectivity test using Python (bash /dev/tcp not available on minimal Ubuntu)
# Usage: check_tcp <ip> <port> [timeout_seconds]
check_tcp() {
    local ip="$1"
    local port="$2"
    local timeout="${3:-3}"
    python3 -c "
import socket
import sys
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout($timeout)
    s.connect(('$ip', $port))
    s.close()
    sys.exit(0)
except:
    sys.exit(1)
" 2>/dev/null
}

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
    echo "  relay         Include a relay node on the public network"
    echo ""
    echo "Examples:"
    echo "  sudo $0 full-cone full-cone           # Direct should work"
    echo "  sudo $0 symmetric symmetric relay     # Must use relay"
    exit 1
}

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    usage
fi

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
        echo -e "${RED}Ubuntu base image not found. Run setup-infra.sh images first.${NC}"
        exit 1
    fi

    # Check for omerta-mesh binary (check both build location and local script dir)
    if [[ -f "$SCRIPT_DIR/omerta-mesh" ]]; then
        MESH_BIN="$SCRIPT_DIR/omerta-mesh"
    elif [[ -f "$OMERTA_DIR/.build/debug/omerta-mesh" ]]; then
        MESH_BIN="$OMERTA_DIR/.build/debug/omerta-mesh"
    else
        echo -e "${RED}omerta-mesh binary not found${NC}"
        exit 1
    fi
    export MESH_BIN

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
    local ssh_port="$6"

    echo -e "${CYAN}Starting NAT gateway: $name ($nat_type)${NC}"

    # Create disk
    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 5G)

    # Create cloud-init with all network config
    local cloud_init
    cloud_init=$(create_cloud_init_iso "$name" "nat-gateway.yaml" \
        "INET_IP=$inet_ip" \
        "LAN_IP=$lan_ip" \
        "NAT_TYPE=$nat_type")

    # Network: eth0=internet bridge, eth1=LAN bridge
    # Use tap devices connected to bridges
    local tap_inet="tap-${name}-i"
    local tap_lan="tap-${name}-l"

    # Clean up any existing tap devices first
    ip tuntap del dev "$tap_inet" mode tap 2>/dev/null || true
    ip tuntap del dev "$tap_lan" mode tap 2>/dev/null || true

    # Create tap devices
    ip tuntap add dev "$tap_inet" mode tap
    ip link set "$tap_inet" master "$BR_INTERNET"
    ip link set "$tap_inet" up

    ip tuntap add dev "$tap_lan" mode tap
    ip link set "$tap_lan" master "$lan_bridge"
    ip link set "$tap_lan" up

    # Start VM with two network interfaces
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
    local ssh_port="$5"

    echo -e "${CYAN}Starting peer VM: $name${NC}"

    # Create disk
    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 10G)

    # Create cloud-init with network config
    local cloud_init
    cloud_init=$(create_cloud_init_iso "$name" "peer.yaml" \
        "PEER_IP=$ip" \
        "GATEWAY_IP=$gateway_ip")

    # Network: single interface on LAN bridge
    local tap_name="tap-${name}"

    # Clean up any existing tap device first
    ip tuntap del dev "$tap_name" mode tap 2>/dev/null || true

    ip tuntap add dev "$tap_name" mode tap
    ip link set "$tap_name" master "$lan_bridge"
    ip link set "$tap_name" up

    # Start VM
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

    # Create disk
    local disk
    disk=$(create_vm_disk "$name" "$IMAGES_DIR/ubuntu-base.img" 10G)

    # Create cloud-init with network config
    local cloud_init
    cloud_init=$(create_cloud_init_iso "$name" "relay.yaml" \
        "RELAY_IP=$RELAY_IP")

    # Network: single interface on internet bridge
    local tap_name="tap-${name}"

    # Clean up any existing tap device first
    ip tuntap del dev "$tap_name" mode tap 2>/dev/null || true

    ip tuntap add dev "$tap_name" mode tap
    ip link set "$tap_name" master "$BR_INTERNET"
    ip link set "$tap_name" up

    # Start VM with SSH port forwarding
    local pid
    pid=$(start_vm "$name" 512 1 "$disk" "$cloud_init" \
        "tap,ifname=$tap_name,script=no,downscript=no")

    echo "  Started relay (PID $pid)"
    echo "  IP: $RELAY_IP"
}

# SSH helper for VMs on the internet bridge
inet_ssh() {
    local ip="$1"
    shift
    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 ubuntu@"$ip" "$@"
}

# SSH helper for VMs behind NAT (via jump host)
lan_ssh() {
    local jump_ip="$1"
    local target_ip="$2"
    shift 2
    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o "ProxyCommand ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p ubuntu@$jump_ip" \
        ubuntu@"$target_ip" "$@"
}

# SCP helper for VMs on the internet bridge
inet_scp() {
    local src="$1"
    local ip="$2"
    local dst="$3"
    scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$src" ubuntu@"$ip":"$dst"
}

# SCP helper for VMs behind NAT (via jump host)
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
    # Use shorter timeout with KVM, longer for TCG emulation
    local timeout=180
    if [[ ! -e /dev/kvm ]] || [[ ! -r /dev/kvm ]]; then
        timeout=600  # 10 minutes for TCG emulation
    fi
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

# Find Swift runtime library directory
find_swift_lib_dir() {
    # Check various locations for Swift libraries
    local lib_dirs=(
        "$SCRIPT_DIR/lib"
        "$SCRIPT_DIR/../lib"
        "/usr/lib/swift/linux"
    )

    # Add swiftly toolchain paths
    if [[ -d "$HOME/.local/share/swiftly/toolchains" ]]; then
        for toolchain in "$HOME/.local/share/swiftly/toolchains"/*/usr/lib/swift/linux; do
            if [[ -d "$toolchain" ]]; then
                lib_dirs+=("$toolchain")
            fi
        done
    fi

    # Find a directory that contains Swift runtime libs
    for dir in "${lib_dirs[@]}"; do
        if [[ -d "$dir" ]] && ls "$dir"/libswift*.so* &>/dev/null; then
            echo "$dir"
            return 0
        fi
    done

    return 1
}

# Copy test files to a peer VM
setup_peer() {
    local name="$1"
    local jump_ip="$2"
    local target_ip="$3"

    echo "  Setting up $name..."

    # Create test directory
    lan_ssh "$jump_ip" "$target_ip" "mkdir -p /home/ubuntu/mesh-test/lib"

    # Copy binary
    lan_scp "$MESH_BIN" "$jump_ip" "$target_ip" "/home/ubuntu/mesh-test/"

    # Find and copy Swift runtime libraries
    local swift_lib_dir
    if swift_lib_dir=$(find_swift_lib_dir); then
        echo "    Copying Swift libs from $swift_lib_dir"
        local lib_count=0
        # Copy all .so files - includes libswift*, libFoundation*, libdispatch, etc.
        for lib in "$swift_lib_dir"/*.so*; do
            if [[ -f "$lib" ]]; then
                lan_scp "$lib" "$jump_ip" "$target_ip" "/home/ubuntu/mesh-test/lib/" 2>/dev/null && ((lib_count++)) || true
            fi
        done
        echo "    Copied $lib_count libraries"
    else
        echo "    WARNING: Could not find Swift runtime libraries"
    fi

    # Make executable
    lan_ssh "$jump_ip" "$target_ip" "chmod +x /home/ubuntu/mesh-test/omerta-mesh"

    echo "    Done"
}

# Setup relay VM
setup_relay() {
    echo "  Setting up relay..."

    # Create test directory
    inet_ssh "$RELAY_IP" "mkdir -p /home/ubuntu/mesh-test/lib"

    # Copy binary
    inet_scp "$MESH_BIN" "$RELAY_IP" "/home/ubuntu/mesh-test/"

    # Find and copy Swift runtime libraries
    local swift_lib_dir
    if swift_lib_dir=$(find_swift_lib_dir); then
        echo "    Copying Swift libs from $swift_lib_dir"
        local lib_count=0
        # Copy all .so files - includes libswift*, libFoundation*, libdispatch, etc.
        for lib in "$swift_lib_dir"/*.so*; do
            if [[ -f "$lib" ]]; then
                inet_scp "$lib" "$RELAY_IP" "/home/ubuntu/mesh-test/lib/" 2>/dev/null && ((lib_count++)) || true
            fi
        done
        echo "    Copied $lib_count libraries"
    else
        echo "    WARNING: Could not find Swift runtime libraries"
    fi

    # Make executable
    inet_ssh "$RELAY_IP" "chmod +x /home/ubuntu/mesh-test/omerta-mesh"

    echo "    Done"
}

# Run the test
run_test() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Running NAT Test: $NAT1 <-> $NAT2 ${USE_RELAY:+(with relay)}${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    # Step 1: Wait for all VMs to be ready
    echo -e "${CYAN}Step 1: Waiting for VMs to be SSH-accessible...${NC}"

    wait_for_ssh "$NAT_GW1_INET_IP" "nat-gw1" || return 1
    wait_for_ssh "$NAT_GW2_INET_IP" "nat-gw2" || return 1
    wait_for_ssh "$PEER1_IP" "peer1" "$NAT_GW1_INET_IP" || return 1
    wait_for_ssh "$PEER2_IP" "peer2" "$NAT_GW2_INET_IP" || return 1

    if [[ "$USE_RELAY" == "relay" ]]; then
        wait_for_ssh "$RELAY_IP" "relay" || return 1
    fi

    echo ""

    # Step 2: Verify NAT gateway configuration and network connectivity
    echo -e "${CYAN}Step 2: Verifying NAT gateway configuration...${NC}"

    # Check NAT gateway 1 config
    echo "  Checking NAT gateway 1..."
    echo "    IP forwarding: $(inet_ssh "$NAT_GW1_INET_IP" 'cat /proc/sys/net/ipv4/ip_forward' 2>/dev/null || echo 'unknown')"
    echo "    enp0s2 (WAN): $(inet_ssh "$NAT_GW1_INET_IP" 'ip -4 addr show enp0s2 | grep inet | awk "{print \$2}"' 2>/dev/null || echo 'not configured')"
    echo "    enp0s3 (LAN): $(inet_ssh "$NAT_GW1_INET_IP" 'ip -4 addr show enp0s3 | grep inet | awk "{print \$2}"' 2>/dev/null || echo 'not configured')"
    echo "    NAT type: $(inet_ssh "$NAT_GW1_INET_IP" 'cat /etc/mesh-nat-type' 2>/dev/null || echo 'unknown')"

    # Check NAT gateway 2 config
    echo "  Checking NAT gateway 2..."
    echo "    IP forwarding: $(inet_ssh "$NAT_GW2_INET_IP" 'cat /proc/sys/net/ipv4/ip_forward' 2>/dev/null || echo 'unknown')"
    echo "    enp0s2 (WAN): $(inet_ssh "$NAT_GW2_INET_IP" 'ip -4 addr show enp0s2 | grep inet | awk "{print \$2}"' 2>/dev/null || echo 'not configured')"
    echo "    enp0s3 (LAN): $(inet_ssh "$NAT_GW2_INET_IP" 'ip -4 addr show enp0s3 | grep inet | awk "{print \$2}"' 2>/dev/null || echo 'not configured')"
    echo "    NAT type: $(inet_ssh "$NAT_GW2_INET_IP" 'cat /etc/mesh-nat-type' 2>/dev/null || echo 'unknown')"

    # Ensure NAT gateways have IP forwarding enabled (cloud-init race condition workaround)
    echo "  Ensuring NAT configuration is applied..."
    for gw_ip in "$NAT_GW1_INET_IP" "$NAT_GW2_INET_IP"; do
        local fwd=$(inet_ssh "$gw_ip" 'cat /proc/sys/net/ipv4/ip_forward' 2>/dev/null)
        if [[ "$fwd" != "1" ]]; then
            echo "    Applying NAT config to $gw_ip..."
            inet_ssh "$gw_ip" 'sudo /usr/local/bin/configure-nat.sh' 2>/dev/null || true
        fi
    done

    # Check peer network config
    echo "  Checking peer1 network..."
    echo "    IP: $(lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" 'ip -4 addr show enp0s2 | grep inet | awk "{print \$2}"' 2>/dev/null || echo 'not configured')"
    echo "    Default route: $(lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" 'ip route show default | head -1' 2>/dev/null || echo 'none')"

    echo "  Checking peer2 network..."
    echo "    IP: $(lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" 'ip -4 addr show enp0s2 | grep inet | awk "{print \$2}"' 2>/dev/null || echo 'not configured')"
    echo "    Default route: $(lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" 'ip route show default | head -1' 2>/dev/null || echo 'none')"

    echo ""
    echo -e "${CYAN}Step 3: Testing network connectivity...${NC}"

    # Python-based TCP test function (bash /dev/tcp not available on minimal Ubuntu)
    # Use timeout to prevent hanging
    py_check_tcp='timeout 5 python3 -c "import socket,sys; s=socket.socket(); s.settimeout(3); s.connect((sys.argv[1], int(sys.argv[2]))); s.close()"'

    # First test if NAT gateways can reach each other directly (on the internet bridge)
    echo -n "  nat-gw1 -> nat-gw2 (direct): "
    if inet_ssh "$NAT_GW1_INET_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$NAT_GW2_INET_IP', 22)); s.close()\"" 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        # Debug: check ARP and routes
        echo "    ARP for $NAT_GW2_INET_IP:"
        inet_ssh "$NAT_GW1_INET_IP" "ip neigh show | grep $NAT_GW2_INET_IP" 2>/dev/null | sed 's/^/      /' || echo "      (no entry)"
        echo "    Route to $NAT_GW2_INET_IP:"
        inet_ssh "$NAT_GW1_INET_IP" "ip route get $NAT_GW2_INET_IP" 2>/dev/null | sed 's/^/      /'
    fi

    echo -n "  nat-gw2 -> nat-gw1 (direct): "
    if inet_ssh "$NAT_GW2_INET_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$NAT_GW1_INET_IP', 22)); s.close()\"" 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    # Helper for inline Python TCP test with timeout
    run_tcp_test() {
        local ip="$1"
        local port="$2"
        timeout 5 python3 -c "import socket; s=socket.socket(); s.settimeout(3); s.connect(('$ip', $port)); s.close()" 2>/dev/null
    }

    # Test peer1 -> gateway (should always work since SSH jump works)
    echo -n "  peer1 -> gateway ($NAT_GW1_LAN_IP): "
    if lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$NAT_GW1_LAN_IP', 22)); s.close()\"" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    # Test peer1 -> internet (NAT gateway's external IP)
    echo -n "  peer1 -> internet ($NAT_GW1_INET_IP): "
    if lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$NAT_GW1_INET_IP', 22)); s.close()\"" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    # Test peer1 -> other NAT gateway (true NAT traversal test)
    echo -n "  peer1 -> NAT-GW2 ($NAT_GW2_INET_IP) via NAT: "
    if lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$NAT_GW2_INET_IP', 22)); s.close()\"" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    # Test peer2 -> gateway
    echo -n "  peer2 -> gateway ($NAT_GW2_LAN_IP): "
    if lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$NAT_GW2_LAN_IP', 22)); s.close()\"" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    # Test peer2 -> internet (NAT gateway's external IP)
    echo -n "  peer2 -> internet ($NAT_GW2_INET_IP): "
    if lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$NAT_GW2_INET_IP', 22)); s.close()\"" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    # Test peer2 -> other NAT gateway (true NAT traversal test)
    echo -n "  peer2 -> NAT-GW1 ($NAT_GW1_INET_IP) via NAT: "
    if lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$NAT_GW1_INET_IP', 22)); s.close()\"" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    # If relay is enabled, peers should be able to reach it
    if [[ "$USE_RELAY" == "relay" ]]; then
        echo -n "  peer1 -> relay ($RELAY_IP): "
        if lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$RELAY_IP', 22)); s.close()\"" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
        fi

        echo -n "  peer2 -> relay ($RELAY_IP): "
        if lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "timeout 5 python3 -c \"import socket; s=socket.socket(); s.settimeout(3); s.connect(('$RELAY_IP', 22)); s.close()\"" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
        fi
    fi

    echo ""

    # Step 4: Copy test files
    echo -e "${CYAN}Step 4: Copying test files...${NC}"

    setup_peer "peer1" "$NAT_GW1_INET_IP" "$PEER1_IP"
    setup_peer "peer2" "$NAT_GW2_INET_IP" "$PEER2_IP"

    if [[ "$USE_RELAY" == "relay" ]]; then
        setup_relay
    fi

    echo ""

    # Step 5: Start the mesh network
    echo -e "${CYAN}Step 5: Starting mesh network...${NC}"

    # Generate peer IDs (use kernel random UUID instead of uuidgen which may not be installed)
    local peer1_id=$(cat /proc/sys/kernel/random/uuid)
    local peer2_id=$(cat /proc/sys/kernel/random/uuid)
    local relay_id=$(cat /proc/sys/kernel/random/uuid)

    # Determine bootstrap node
    local bootstrap_addr
    if [[ "$USE_RELAY" == "relay" ]]; then
        bootstrap_addr="$RELAY_IP:9000"

        # Start relay first
        echo "  Starting relay..."
        inet_ssh "$RELAY_IP" "cd /home/ubuntu/mesh-test && \
            LD_LIBRARY_PATH=/home/ubuntu/mesh-test/lib nohup ./omerta-mesh \
            --peer-id $relay_id \
            --port 9000 \
            --relay \
            > relay.log 2>&1 &"
        sleep 3
    else
        # Use peer1 as bootstrap
        bootstrap_addr="$NAT_GW1_INET_IP:9000"
    fi

    # Start peer1
    echo "  Starting peer1..."
    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=/home/ubuntu/mesh-test/lib nohup ./omerta-mesh \
        --peer-id $peer1_id \
        --port 9000 \
        --bootstrap $bootstrap_addr \
        > peer.log 2>&1 &"
    sleep 2

    # Start peer2
    echo "  Starting peer2..."
    lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "cd /home/ubuntu/mesh-test && \
        LD_LIBRARY_PATH=/home/ubuntu/mesh-test/lib nohup ./omerta-mesh \
        --peer-id $peer2_id \
        --port 9000 \
        --bootstrap $bootstrap_addr \
        > peer.log 2>&1 &"

    echo ""

    # Step 6: Wait for connection and verify
    echo -e "${CYAN}Step 6: Waiting for peers to connect (30s)...${NC}"
    sleep 30

    # Step 7: Check results
    echo -e "${CYAN}Step 7: Checking results...${NC}"

    echo ""
    echo "Peer 1 log:"
    echo "---"
    lan_ssh "$NAT_GW1_INET_IP" "$PEER1_IP" "cat /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"

    echo ""
    echo "Peer 2 log:"
    echo "---"
    lan_ssh "$NAT_GW2_INET_IP" "$PEER2_IP" "cat /home/ubuntu/mesh-test/peer.log" 2>/dev/null || echo "(no log)"
    echo "---"

    if [[ "$USE_RELAY" == "relay" ]]; then
        echo ""
        echo "Relay log:"
        echo "---"
        inet_ssh "$RELAY_IP" "cat /home/ubuntu/mesh-test/relay.log" 2>/dev/null || echo "(no log)"
        echo "---"
    fi

    echo ""
    echo -e "${CYAN}Test Summary${NC}"
    echo "  NAT types: $NAT1 <-> $NAT2"
    echo "  Relay: ${USE_RELAY:-disabled}"
    echo ""
    echo "Infrastructure:"
    echo "  NAT Gateway 1: $NAT1 at $NAT_GW1_INET_IP (LAN: $NAT_GW1_LAN_IP)"
    echo "  NAT Gateway 2: $NAT2 at $NAT_GW2_INET_IP (LAN: $NAT_GW2_LAN_IP)"
    echo "  Peer 1: $PEER1_IP (behind NAT1)"
    echo "  Peer 2: $PEER2_IP (behind NAT2)"
    [[ "$USE_RELAY" == "relay" ]] && echo "  Relay: $RELAY_IP"
}

# Main
echo "============================================================"
echo "OmertaMesh Nested VM NAT Test"
echo "============================================================"
echo "Peer 1 NAT: $NAT1"
echo "Peer 2 NAT: $NAT2"
[[ "$USE_RELAY" == "relay" ]] && echo "Relay: enabled"
echo ""

check_prerequisites

echo ""
echo -e "${CYAN}Starting VMs...${NC}"
echo ""

# Start NAT gateways
start_nat_gateway "nat-gw1" "$NAT1" "$NAT_GW1_INET_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1" "$NAT_GW1_SSH"
start_nat_gateway "nat-gw2" "$NAT2" "$NAT_GW2_INET_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2" "$NAT_GW2_SSH"

# Start peer VMs
start_peer_vm "peer1" "$PEER1_IP" "$NAT_GW1_LAN_IP" "$BR_LAN1" "$PEER1_SSH"
start_peer_vm "peer2" "$PEER2_IP" "$NAT_GW2_LAN_IP" "$BR_LAN2" "$PEER2_SSH"

# Start relay if requested
if [[ "$USE_RELAY" == "relay" ]]; then
    start_relay_vm
fi

# Wait a bit for VMs to boot
echo ""
if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]]; then
    echo -e "${CYAN}Waiting for VMs to boot (KVM acceleration enabled)...${NC}"
    sleep 30
else
    echo -e "${CYAN}Waiting for VMs to boot (TCG emulation - this will be slow)...${NC}"
    sleep 60
fi

# Run the test
run_test

echo ""
echo -e "${GREEN}Test infrastructure created successfully${NC}"
echo "VMs are running. Press Ctrl+C to cleanup and exit."
echo ""

# Keep running until interrupted
while true; do
    sleep 10
done
