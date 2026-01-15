#!/bin/bash
# Cleanup nested VM test infrastructure
#
# Removes all running VMs, tap devices, and optionally bridges/images.
#
# Usage:
#   ./cleanup.sh          # Stop VMs, remove tap devices
#   ./cleanup.sh all      # Also remove bridges and images

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$SCRIPT_DIR/.run"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}Cleaning up nested VM test infrastructure...${NC}"

# Kill all test VMs
echo "Stopping VMs..."
pkill -f "qemu.*mesh-" 2>/dev/null || true
pkill -f "qemu.*nat-gw" 2>/dev/null || true
pkill -f "qemu.*peer" 2>/dev/null || true
pkill -f "qemu.*relay" 2>/dev/null || true

# Remove tap devices
echo "Removing tap devices..."
for tap in $(ip link show | grep "tap-" | cut -d: -f2 | tr -d ' '); do
    ip link del "$tap" 2>/dev/null || true
    echo "  Removed $tap"
done

# Remove run directory
if [[ -d "$RUN_DIR" ]]; then
    rm -rf "$RUN_DIR"
    echo "Removed $RUN_DIR"
fi

# Full cleanup if requested
if [[ "${1:-}" == "all" ]]; then
    echo ""
    echo -e "${CYAN}Full cleanup requested...${NC}"

    # Need root for bridge removal
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Full cleanup requires root${NC}"
        echo "Run: sudo $0 all"
        exit 1
    fi

    # Remove bridges
    for br in br-mesh-inet br-mesh-lan1 br-mesh-lan2; do
        if ip link show "$br" &>/dev/null; then
            ip link set "$br" down
            ip link del "$br"
            echo "  Removed bridge $br"
        fi
    done

    # Remove images
    if [[ -d "$SCRIPT_DIR/images" ]]; then
        rm -rf "$SCRIPT_DIR/images"
        echo "  Removed images directory"
    fi
fi

echo ""
echo -e "${GREEN}Cleanup complete${NC}"
