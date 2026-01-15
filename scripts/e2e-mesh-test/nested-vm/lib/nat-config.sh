#!/bin/bash
# NAT Configuration for Gateway VMs
#
# This script configures nftables rules for different NAT types.
# Run inside the NAT gateway VM.
#
# Usage:
#   ./nat-config.sh <nat-type> <wan-interface> <lan-interface>
#
# NAT Types:
#   public        - No NAT, just routing
#   full-cone     - Full Cone NAT (most permissive)
#   addr-restrict - Address-Restricted Cone NAT
#   port-restrict - Port-Restricted Cone NAT
#   symmetric     - Symmetric NAT (most restrictive)

set -e

NAT_TYPE="${1:-full-cone}"
WAN_IF="${2:-eth0}"
LAN_IF="${3:-eth1}"

echo "Configuring NAT type: $NAT_TYPE"
echo "  WAN interface: $WAN_IF"
echo "  LAN interface: $LAN_IF"

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Flush existing rules
nft flush ruleset 2>/dev/null || true

case "$NAT_TYPE" in
    public)
        # No NAT - just route traffic
        nft -f - <<EOF
table ip filter {
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
}
EOF
        echo "Configured: Public (no NAT, direct routing)"
        ;;

    full-cone)
        # Full Cone NAT: Once a mapping is created, any external host
        # can send packets to the internal host through the mapped port
        nft -f - <<EOF
table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "$WAN_IF" masquerade persistent
    }
}

table ip filter {
    chain forward {
        type filter hook forward priority 0; policy accept;
        # Allow all forwarding (full cone is permissive)
    }
}
EOF
        echo "Configured: Full Cone NAT"
        ;;

    addr-restrict)
        # Address-Restricted Cone NAT: External hosts can only send packets
        # to an internal host if the internal host has previously sent to
        # that external host's IP address (any port)
        nft -f - <<EOF
table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "$WAN_IF" masquerade persistent
    }
}

table ip filter {
    chain forward {
        type filter hook forward priority 0; policy drop;
        # Allow established/related (replies to our outbound)
        ct state established,related accept
        # Allow outbound from LAN
        iifname "$LAN_IF" oifname "$WAN_IF" accept
        # Drop unsolicited inbound
    }
}
EOF
        echo "Configured: Address-Restricted Cone NAT"
        ;;

    port-restrict)
        # Port-Restricted Cone NAT: External hosts can only send packets
        # to an internal host if the internal host has previously sent to
        # that exact external IP:port
        nft -f - <<EOF
table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "$WAN_IF" masquerade persistent
    }
}

table ip filter {
    chain forward {
        type filter hook forward priority 0; policy drop;
        # Strict: only established,related (exact IP:port must match)
        ct state established,related accept
        # Allow outbound from LAN
        iifname "$LAN_IF" oifname "$WAN_IF" accept
        # Drop everything else
    }
}
EOF
        # Make conntrack stricter about what constitutes "related"
        echo 1 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout 2>/dev/null || true
        echo 30 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream 2>/dev/null || true
        echo "Configured: Port-Restricted Cone NAT"
        ;;

    symmetric)
        # Symmetric NAT: Each unique destination gets a different external port mapping
        # This makes hole punching nearly impossible
        nft -f - <<EOF
table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        # Use random source port for each destination (symmetric behavior)
        oifname "$WAN_IF" masquerade random
    }
}

table ip filter {
    chain forward {
        type filter hook forward priority 0; policy drop;
        # Very strict: only exact established connections
        ct state established,related accept
        # Allow outbound from LAN
        iifname "$LAN_IF" oifname "$WAN_IF" accept
        # Drop all unsolicited inbound
    }
}
EOF
        # Very short conntrack timeout to ensure different mappings
        echo 1 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout 2>/dev/null || true
        echo 10 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream 2>/dev/null || true
        echo "Configured: Symmetric NAT"
        ;;

    *)
        echo "Unknown NAT type: $NAT_TYPE"
        echo "Valid types: public, full-cone, addr-restrict, port-restrict, symmetric"
        exit 1
        ;;
esac

echo ""
echo "Current nftables rules:"
nft list ruleset
