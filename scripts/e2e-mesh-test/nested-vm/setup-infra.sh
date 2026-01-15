#!/bin/bash
# Nested VM Test Infrastructure Setup
#
# Creates virtual network bridges and downloads base VM images
# for realistic NAT testing with isolated VMs.
#
# Usage:
#   ./setup-infra.sh          # Set up everything
#   ./setup-infra.sh bridges  # Create bridges only
#   ./setup-infra.sh images   # Download images only
#   ./setup-infra.sh clean    # Remove everything

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# fd00::/8 is reserved for local use
INET_SUBNET6="fd00:mesh:100"
LAN1_SUBNET6="fd00:mesh:1"
LAN2_SUBNET6="fd00:mesh:2"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Detect architecture
HOST_ARCH=$(uname -m)
if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
    ARCH="arm64"
    QEMU_CMD="qemu-system-aarch64"
    ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-virt-3.19.1-aarch64.iso"
    UBUNTU_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img"
else
    ARCH="amd64"
    QEMU_CMD="qemu-system-x86_64"
    ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-3.19.1-x86_64.iso"
    UBUNTU_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
fi

echo -e "${CYAN}Detected architecture: $HOST_ARCH ($ARCH)${NC}"

# Check for root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script requires root for network bridge creation${NC}"
        echo "Run with: sudo $0 $*"
        exit 1
    fi
}

# Create virtual network bridges
create_bridges() {
    echo -e "${CYAN}Creating virtual network bridges...${NC}"

    # Internet bridge (public network)
    if ! ip link show "$BR_INTERNET" &>/dev/null; then
        ip link add name "$BR_INTERNET" type bridge
        ip addr add "${INET_SUBNET}.254/24" dev "$BR_INTERNET"
        # Skip IPv6 for simplicity - focus on IPv4 NAT testing
        ip link set "$BR_INTERNET" up
        echo "  Created $BR_INTERNET (${INET_SUBNET}.0/24)"
    else
        echo "  $BR_INTERNET already exists"
    fi

    # LAN1 bridge (behind NAT gateway 1)
    if ! ip link show "$BR_LAN1" &>/dev/null; then
        ip link add name "$BR_LAN1" type bridge
        ip link set "$BR_LAN1" up
        echo "  Created $BR_LAN1 (${LAN1_SUBNET}.0/24)"
    else
        echo "  $BR_LAN1 already exists"
    fi

    # LAN2 bridge (behind NAT gateway 2)
    if ! ip link show "$BR_LAN2" &>/dev/null; then
        ip link add name "$BR_LAN2" type bridge
        ip link set "$BR_LAN2" up
        echo "  Created $BR_LAN2 (${LAN2_SUBNET}.0/24)"
    else
        echo "  $BR_LAN2 already exists"
    fi

    # Enable IP forwarding (IPv4)
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Add masquerade rule so VMs on the internet bridge can reach the real internet
    # through the outer VM's primary interface
    local primary_if
    primary_if=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -n "$primary_if" ]]; then
        iptables -t nat -C POSTROUTING -s ${INET_SUBNET}.0/24 -o "$primary_if" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s ${INET_SUBNET}.0/24 -o "$primary_if" -j MASQUERADE
        echo "  Added masquerade rule for ${INET_SUBNET}.0/24 -> $primary_if"
    fi

    echo -e "${GREEN}Bridges created successfully${NC}"
}

# Remove virtual network bridges
remove_bridges() {
    echo -e "${CYAN}Removing virtual network bridges...${NC}"

    for br in "$BR_INTERNET" "$BR_LAN1" "$BR_LAN2"; do
        if ip link show "$br" &>/dev/null; then
            ip link set "$br" down
            ip link del "$br"
            echo "  Removed $br"
        fi
    done

    echo -e "${GREEN}Bridges removed${NC}"
}

# Download base VM images
download_images() {
    echo -e "${CYAN}Downloading base VM images...${NC}"
    mkdir -p "$IMAGES_DIR"

    # Alpine Linux for NAT gateways (lightweight)
    if [[ ! -f "$IMAGES_DIR/alpine-base.iso" ]]; then
        echo "  Downloading Alpine Linux..."
        curl -L -o "$IMAGES_DIR/alpine-base.iso" "$ALPINE_URL"
    else
        echo "  Alpine image already exists"
    fi

    # Ubuntu for peer/relay VMs
    if [[ ! -f "$IMAGES_DIR/ubuntu-base.img" ]]; then
        echo "  Downloading Ubuntu minimal..."
        curl -L -o "$IMAGES_DIR/ubuntu-base.img" "$UBUNTU_URL"
    else
        echo "  Ubuntu image already exists"
    fi

    echo -e "${GREEN}Images downloaded to $IMAGES_DIR${NC}"
}

# Create NAT gateway disk image
create_nat_gateway_image() {
    echo -e "${CYAN}Creating NAT gateway base image...${NC}"

    if [[ -f "$IMAGES_DIR/nat-gateway.qcow2" ]]; then
        echo "  NAT gateway image already exists"
        return
    fi

    # Create a small disk for the NAT gateway
    qemu-img create -f qcow2 "$IMAGES_DIR/nat-gateway.qcow2" 1G

    echo -e "${GREEN}NAT gateway image created${NC}"
    echo -e "${CYAN}Note: NAT gateway will be configured at boot via cloud-init${NC}"
}

# Create peer VM disk image (copy-on-write from Ubuntu base)
create_peer_image() {
    echo -e "${CYAN}Creating peer VM base image...${NC}"

    if [[ -f "$IMAGES_DIR/peer-base.qcow2" ]]; then
        echo "  Peer base image already exists"
        return
    fi

    # Create overlay image based on Ubuntu
    qemu-img create -f qcow2 -F qcow2 -b "$IMAGES_DIR/ubuntu-base.img" "$IMAGES_DIR/peer-base.qcow2" 10G

    echo -e "${GREEN}Peer base image created${NC}"
}

# Show status
show_status() {
    echo -e "${CYAN}=== Infrastructure Status ===${NC}"
    echo ""
    echo "Network Bridges:"
    for br in "$BR_INTERNET" "$BR_LAN1" "$BR_LAN2"; do
        if ip link show "$br" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $br"
        else
            echo -e "  ${RED}✗${NC} $br (not created)"
        fi
    done

    echo ""
    echo "VM Images:"
    for img in "alpine-base.iso" "ubuntu-base.img" "nat-gateway.qcow2" "peer-base.qcow2"; do
        if [[ -f "$IMAGES_DIR/$img" ]]; then
            size=$(du -h "$IMAGES_DIR/$img" | cut -f1)
            echo -e "  ${GREEN}✓${NC} $img ($size)"
        else
            echo -e "  ${RED}✗${NC} $img (not downloaded)"
        fi
    done

    echo ""
    echo "Architecture: $HOST_ARCH"
    echo "QEMU command: $QEMU_CMD"
}

# Clean everything
clean_all() {
    echo -e "${CYAN}Cleaning up all infrastructure...${NC}"

    # Kill any running test VMs
    pkill -f "qemu.*mesh-" 2>/dev/null || true

    # Remove bridges (requires root)
    if [[ $EUID -eq 0 ]]; then
        remove_bridges
    else
        echo "  Skipping bridge removal (requires root)"
    fi

    # Remove images
    if [[ -d "$IMAGES_DIR" ]]; then
        rm -rf "$IMAGES_DIR"
        echo "  Removed $IMAGES_DIR"
    fi

    echo -e "${GREEN}Cleanup complete${NC}"
}

# Main
case "${1:-all}" in
    bridges)
        check_root
        create_bridges
        ;;
    images)
        download_images
        create_nat_gateway_image
        create_peer_image
        ;;
    status)
        show_status
        ;;
    clean)
        clean_all
        ;;
    all)
        check_root
        create_bridges
        download_images
        create_nat_gateway_image
        create_peer_image
        show_status
        ;;
    *)
        echo "Usage: $0 [bridges|images|status|clean|all]"
        exit 1
        ;;
esac
