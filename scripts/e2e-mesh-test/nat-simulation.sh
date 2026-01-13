#!/bin/bash
# NAT Simulation for Mesh Protocol Testing
#
# This script creates network namespaces with different NAT types
# to test hole punching and relay fallback scenarios.
#
# Usage:
#   ./nat-simulation.sh setup <nat-type> <namespace-name>
#   ./nat-simulation.sh teardown <namespace-name>
#   ./nat-simulation.sh run <namespace-name> <command>
#
# NAT Types:
#   public       - No NAT, direct connectivity
#   full-cone    - Full Cone NAT (easiest to traverse)
#   addr-restrict - Address-Restricted Cone NAT
#   port-restrict - Port-Restricted Cone NAT
#   symmetric    - Symmetric NAT (hardest, usually needs relay)

set -e

# Configuration
BASE_SUBNET="10.200"
EXTERNAL_IF="eth0"  # Host's external interface

usage() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  setup <nat-type> <name>    Create namespace with NAT type"
    echo "  teardown <name>            Remove namespace"
    echo "  run <name> <cmd>           Run command in namespace"
    echo "  list                       List active namespaces"
    echo ""
    echo "NAT Types: public, full-cone, addr-restrict, port-restrict, symmetric"
    exit 1
}

# Get unique subnet ID based on namespace name
get_subnet_id() {
    local name=$1
    # Hash the name to get a number 1-254
    echo $(($(echo "$name" | cksum | cut -d' ' -f1) % 253 + 1))
}

setup_namespace() {
    local nat_type=$1
    local name=$2
    local subnet_id=$(get_subnet_id "$name")
    local internal_net="${BASE_SUBNET}.${subnet_id}"
    local veth_host="veth-${name}-h"
    local veth_ns="veth-${name}-n"

    echo "Creating namespace '$name' with $nat_type NAT..."
    echo "  Internal network: ${internal_net}.0/24"

    # Create namespace
    ip netns add "$name" 2>/dev/null || true

    # Create veth pair
    ip link add "$veth_host" type veth peer name "$veth_ns" 2>/dev/null || true

    # Move one end to namespace
    ip link set "$veth_ns" netns "$name"

    # Configure host side
    ip addr add "${internal_net}.1/24" dev "$veth_host" 2>/dev/null || true
    ip link set "$veth_host" up

    # Configure namespace side
    ip netns exec "$name" ip addr add "${internal_net}.2/24" dev "$veth_ns"
    ip netns exec "$name" ip link set "$veth_ns" up
    ip netns exec "$name" ip link set lo up
    ip netns exec "$name" ip route add default via "${internal_net}.1"

    # Enable IP forwarding on host
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Apply NAT rules based on type
    case "$nat_type" in
        public)
            setup_public "$name" "$internal_net" "$veth_host"
            ;;
        full-cone)
            setup_full_cone "$name" "$internal_net" "$veth_host"
            ;;
        addr-restrict)
            setup_addr_restrict "$name" "$internal_net" "$veth_host"
            ;;
        port-restrict)
            setup_port_restrict "$name" "$internal_net" "$veth_host"
            ;;
        symmetric)
            setup_symmetric "$name" "$internal_net" "$veth_host"
            ;;
        *)
            echo "Unknown NAT type: $nat_type"
            exit 1
            ;;
    esac

    echo "Namespace '$name' created with $nat_type NAT"
    echo "  Internal IP: ${internal_net}.2"
    echo "  Run commands with: $0 run $name <command>"
}

# Public - No NAT, direct routing
setup_public() {
    local name=$1
    local internal_net=$2
    local veth=$3

    echo "  Setting up: No NAT (public)"

    # Just forward traffic, no NAT
    iptables -t nat -A POSTROUTING -s "${internal_net}.0/24" -o "$EXTERNAL_IF" -j ACCEPT
    iptables -A FORWARD -i "$veth" -o "$EXTERNAL_IF" -j ACCEPT
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$veth" -j ACCEPT
}

# Full Cone NAT - Most permissive, any external host can send to mapped port
setup_full_cone() {
    local name=$1
    local internal_net=$2
    local veth=$3

    echo "  Setting up: Full Cone NAT"

    # Standard SNAT - external port remains constant
    iptables -t nat -A POSTROUTING -s "${internal_net}.0/24" -o "$EXTERNAL_IF" -j MASQUERADE
    iptables -A FORWARD -i "$veth" -o "$EXTERNAL_IF" -j ACCEPT
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$veth" -j ACCEPT

    # Allow any inbound once we've sent outbound
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$veth" -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Full cone: allow NEW inbound to ports we've used outbound
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$veth" -j ACCEPT
}

# Address-Restricted Cone NAT - Only hosts we've sent to can reply
setup_addr_restrict() {
    local name=$1
    local internal_net=$2
    local veth=$3

    echo "  Setting up: Address-Restricted Cone NAT"

    iptables -t nat -A POSTROUTING -s "${internal_net}.0/24" -o "$EXTERNAL_IF" -j MASQUERADE
    iptables -A FORWARD -i "$veth" -o "$EXTERNAL_IF" -j ACCEPT

    # Only allow replies from IPs we've contacted
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$veth" -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Drop everything else
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$veth" -j DROP
}

# Port-Restricted Cone NAT - Only exact IP:port we sent to can reply
setup_port_restrict() {
    local name=$1
    local internal_net=$2
    local veth=$3

    echo "  Setting up: Port-Restricted Cone NAT"

    iptables -t nat -A POSTROUTING -s "${internal_net}.0/24" -o "$EXTERNAL_IF" -j MASQUERADE
    iptables -A FORWARD -i "$veth" -o "$EXTERNAL_IF" -j ACCEPT

    # Only allow replies from exact IP:port we contacted
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$veth" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$veth" -j DROP
}

# Symmetric NAT - Different external port for each destination
setup_symmetric() {
    local name=$1
    local internal_net=$2
    local veth=$3

    echo "  Setting up: Symmetric NAT"

    # Use random source ports (--random makes it symmetric-like)
    iptables -t nat -A POSTROUTING -s "${internal_net}.0/24" -o "$EXTERNAL_IF" -j MASQUERADE --random
    iptables -A FORWARD -i "$veth" -o "$EXTERNAL_IF" -j ACCEPT

    # Strict: only established connections allowed back
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$veth" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -i "$EXTERNAL_IF" -o "$veth" -j DROP
}

teardown_namespace() {
    local name=$1
    local subnet_id=$(get_subnet_id "$name")
    local internal_net="${BASE_SUBNET}.${subnet_id}"
    local veth_host="veth-${name}-h"

    echo "Tearing down namespace '$name'..."

    # Remove iptables rules (cleanup - may show errors if rules don't exist)
    iptables -t nat -D POSTROUTING -s "${internal_net}.0/24" -o "$EXTERNAL_IF" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "${internal_net}.0/24" -o "$EXTERNAL_IF" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$veth_host" -o "$EXTERNAL_IF" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$EXTERNAL_IF" -o "$veth_host" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$EXTERNAL_IF" -o "$veth_host" -j DROP 2>/dev/null || true
    iptables -D FORWARD -i "$EXTERNAL_IF" -o "$veth_host" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$EXTERNAL_IF" -o "$veth_host" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    # Delete veth pair
    ip link del "$veth_host" 2>/dev/null || true

    # Delete namespace
    ip netns del "$name" 2>/dev/null || true

    echo "Namespace '$name' removed"
}

run_in_namespace() {
    local name=$1
    shift
    ip netns exec "$name" "$@"
}

list_namespaces() {
    echo "Active mesh test namespaces:"
    ip netns list | grep -E "^(public|full-cone|addr-restrict|port-restrict|symmetric)-" || echo "  (none)"
}

# Main
case "${1:-}" in
    setup)
        [[ -z "${2:-}" || -z "${3:-}" ]] && usage
        setup_namespace "$2" "$3"
        ;;
    teardown)
        [[ -z "${2:-}" ]] && usage
        teardown_namespace "$2"
        ;;
    run)
        [[ -z "${2:-}" || -z "${3:-}" ]] && usage
        name=$2
        shift 2
        run_in_namespace "$name" "$@"
        ;;
    list)
        list_namespaces
        ;;
    *)
        usage
        ;;
esac
