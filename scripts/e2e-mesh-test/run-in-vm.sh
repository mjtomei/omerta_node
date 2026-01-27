#!/bin/bash
# Run NAT tests inside an isolated VM
#
# This script launches an Ubuntu VM and runs the NAT simulation tests inside it,
# avoiding the need for sudo/root on the host machine.
#
# Usage:
#   ./run-in-vm.sh <nat-type-1> <nat-type-2> [relay]
#   ./run-in-vm.sh --all          # Run all NAT combinations
#   ./run-in-vm.sh --shell        # Start VM and get a shell
#
# Examples:
#   ./run-in-vm.sh full-cone full-cone
#   ./run-in-vm.sh symmetric symmetric relay
#   ./run-in-vm.sh --all

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMERTA_DIR="${OMERTA_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
VM_DIR="$OMERTA_DIR/.vm-test"
CLOUD_IMAGE="$VM_DIR/ubuntu-cloud.img"
VM_IMAGE="$VM_DIR/test-vm.qcow2"

# Detect architecture and set appropriate image URL
HOST_ARCH=$(uname -m)
if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
    CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img"
    QEMU_CMD="qemu-system-aarch64"
    EFI_CODE="/usr/share/AAVMF/AAVMF_CODE.fd"
    EFI_VARS_TEMPLATE="/usr/share/AAVMF/AAVMF_VARS.fd"
    EFI_VARS="$VM_DIR/AAVMF_VARS.fd"
else
    CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
    QEMU_CMD="qemu-system-x86_64"
    EFI_CODE=""
    EFI_VARS=""
fi

# VM settings
VM_RAM="2G"
VM_CPUS="2"
SSH_PORT="2222"
VM_USER="ubuntu"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <nat-type-1> <nat-type-2> [relay]"
    echo "       $0 --all"
    echo "       $0 --shell"
    echo ""
    echo "NAT Types: public, full-cone, addr-restrict, port-restrict, symmetric"
    echo ""
    echo "Options:"
    echo "  --all     Run all interesting NAT combinations"
    echo "  --shell   Start VM and provide interactive shell"
    echo "  --cleanup Remove VM images and temp files"
    exit 1
}

# Ensure VM directory exists
mkdir -p "$VM_DIR"

# Download cloud image if needed
download_image() {
    if [[ ! -f "$CLOUD_IMAGE" ]]; then
        echo -e "${CYAN}Downloading Ubuntu cloud image...${NC}"
        curl -L -o "$CLOUD_IMAGE" "$CLOUD_IMAGE_URL"
        echo "Download complete."
    fi
}

# Create cloud-init configuration
create_cloud_init() {
    local ssh_key
    ssh_key=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "")

    # User-data
    cat > "$VM_DIR/user-data" << EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $ssh_key

package_update: false
package_upgrade: false

packages:
  - iptables
  - iproute2

write_files:
  - path: /etc/sysctl.d/99-ip-forward.conf
    content: |
      net.ipv4.ip_forward=1

bootcmd:
  # Use VM's main IP so STUN servers are reachable from network namespaces
  - |
    PRIMARY_IP=\$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || echo "10.0.2.15")
    echo "\$PRIMARY_IP stun1.mesh.test stun2.mesh.test" >> /etc/hosts

runcmd:
  - sysctl -p /etc/sysctl.d/99-ip-forward.conf
  - mkdir -p /home/ubuntu/mesh-test
  - chown ubuntu:ubuntu /home/ubuntu/mesh-test
EOF

    # Meta-data
    cat > "$VM_DIR/meta-data" << EOF
instance-id: mesh-test-vm
local-hostname: mesh-test
EOF

    # Create cloud-init ISO
    if command -v genisoimage &> /dev/null; then
        genisoimage -output "$VM_DIR/cloud-init.iso" -volid cidata -joliet -rock \
            "$VM_DIR/user-data" "$VM_DIR/meta-data" 2>/dev/null
    elif command -v mkisofs &> /dev/null; then
        mkisofs -output "$VM_DIR/cloud-init.iso" -volid cidata -joliet -rock \
            "$VM_DIR/user-data" "$VM_DIR/meta-data" 2>/dev/null
    else
        echo -e "${RED}Error: genisoimage or mkisofs required${NC}"
        exit 1
    fi
}

# Create VM disk from cloud image
create_vm_disk() {
    if [[ ! -f "$VM_IMAGE" ]]; then
        echo -e "${CYAN}Creating VM disk...${NC}"
        qemu-img create -f qcow2 -b "$CLOUD_IMAGE" -F qcow2 "$VM_IMAGE" 10G
    fi
}

# Start the VM
start_vm() {
    echo -e "${CYAN}Starting VM...${NC}"

    local accel_opts=""
    local cpu_opts=""
    local machine_opts=""
    local efi_opts=""

    if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
        # ARM64 native - use virt machine with KVM if available
        machine_opts="-machine virt"

        if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
            echo "KVM acceleration available (native ARM64)"
            accel_opts="-accel kvm"
            cpu_opts="-cpu host"
        else
            echo "Using TCG emulation (KVM not accessible)"
            accel_opts="-accel tcg"
            cpu_opts="-cpu cortex-a72"
        fi

        # EFI firmware for ARM64
        if [[ ! -f "$EFI_VARS" ]]; then
            cp "$EFI_VARS_TEMPLATE" "$EFI_VARS"
        fi
        efi_opts="-drive if=pflash,format=raw,readonly=on,file=$EFI_CODE -drive if=pflash,format=raw,file=$EFI_VARS"
    else
        # x86_64
        machine_opts="-machine q35"

        if $QEMU_CMD -accel help 2>&1 | grep -q "kvm"; then
            if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
                echo "KVM acceleration available"
                accel_opts="-accel kvm"
                cpu_opts="-cpu host"
            else
                echo "KVM supported but /dev/kvm not accessible, using TCG"
                accel_opts="-accel tcg"
                cpu_opts="-cpu qemu64"
            fi
        else
            echo "Using TCG emulation (KVM not available in QEMU)"
            accel_opts="-accel tcg"
            cpu_opts="-cpu qemu64"
        fi
    fi

    $QEMU_CMD \
        -name mesh-test \
        $machine_opts \
        $accel_opts \
        $cpu_opts \
        -m "$VM_RAM" \
        -smp "$VM_CPUS" \
        $efi_opts \
        -drive file="$VM_IMAGE",format=qcow2,if=virtio \
        -drive file="$VM_DIR/cloud-init.iso",format=raw,if=virtio \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        -serial mon:stdio &

    VM_PID=$!
    echo $VM_PID > "$VM_DIR/vm.pid"

    # Wait for VM to boot
    echo "Waiting for VM to boot..."
    for i in {1..60}; do
        if ssh -q -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -p $SSH_PORT $VM_USER@localhost echo "ready" 2>/dev/null; then
            echo -e "${GREEN}VM is ready!${NC}"
            return 0
        fi
        sleep 2
        echo -n "."
    done

    echo -e "\n${RED}VM failed to boot in time${NC}"
    return 1
}

# Stop the VM
stop_vm() {
    if [[ -f "$VM_DIR/vm.pid" ]]; then
        local pid
        pid=$(cat "$VM_DIR/vm.pid")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping VM..."
            kill "$pid" 2>/dev/null || true
            sleep 2
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$VM_DIR/vm.pid"
    fi
}

# SSH into VM
vm_ssh() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p $SSH_PORT $VM_USER@localhost "$@"
}

# SCP files to VM
vm_scp() {
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -P $SSH_PORT "$@"
}

# Copy test files to VM
copy_test_files() {
    echo -e "${CYAN}Copying test files to VM...${NC}"

    # Wait for cloud-init to complete
    echo "Waiting for cloud-init to finish..."
    vm_ssh "cloud-init status --wait" || true

    # Create directories
    vm_ssh "mkdir -p /home/ubuntu/mesh-test/lib"

    # Build the mesh binary and rendezvous server
    echo "Building omerta-mesh and omerta-rendezvous..."
    (cd "$OMERTA_DIR" && swift build --product omerta-mesh --product omerta-rendezvous 2>&1 | tail -3)

    # Copy binaries and scripts
    vm_scp "$OMERTA_DIR/.build/debug/omerta-mesh" $VM_USER@localhost:/home/ubuntu/mesh-test/
    vm_scp "$OMERTA_DIR/.build/debug/omerta-rendezvous" $VM_USER@localhost:/home/ubuntu/mesh-test/
    vm_scp "$SCRIPT_DIR/nat-simulation.sh" $VM_USER@localhost:/home/ubuntu/mesh-test/
    vm_scp "$SCRIPT_DIR/run-nat-test.sh" $VM_USER@localhost:/home/ubuntu/mesh-test/

    # Copy Swift runtime libraries
    echo "Copying Swift runtime libraries..."
    local SWIFT_LIB_DIR
    if [[ -d "$HOME/.local/share/swiftly/toolchains" ]]; then
        SWIFT_LIB_DIR=$(find "$HOME/.local/share/swiftly/toolchains" -maxdepth 2 -type d -name "usr" -exec test -d "{}/lib/swift/linux" \; -print -quit 2>/dev/null)/lib/swift/linux
    elif [[ -d "/usr/lib/swift/linux" ]]; then
        SWIFT_LIB_DIR="/usr/lib/swift/linux"
    fi

    if [[ -n "$SWIFT_LIB_DIR" && -d "$SWIFT_LIB_DIR" ]]; then
        vm_scp "$SWIFT_LIB_DIR"/*.so* $VM_USER@localhost:/home/ubuntu/mesh-test/lib/ 2>/dev/null || true
    fi

    # Make executable and fix paths in scripts
    vm_ssh << 'REMOTE_SCRIPT'
chmod +x /home/ubuntu/mesh-test/*
cd /home/ubuntu/mesh-test

# Patch run-nat-test.sh to use local paths and set library path
sed -i 's|OMERTA_DIR="${OMERTA_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"|OMERTA_DIR="/home/ubuntu/mesh-test"|' run-nat-test.sh
sed -i 's|MESH_BIN="$OMERTA_DIR/.build/debug/omerta-mesh"|MESH_BIN="/home/ubuntu/mesh-test/omerta-mesh"\nexport LD_LIBRARY_PATH=/home/ubuntu/mesh-test/lib:\$LD_LIBRARY_PATH|' run-nat-test.sh

# Patch nat-simulation.sh for VM environment
sed -i 's|EXTERNAL_IF="eth0"|EXTERNAL_IF="enp0s2"|' nat-simulation.sh

# Detect the actual interface
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [[ -n "$IFACE" ]]; then
    sed -i "s|EXTERNAL_IF=\"enp0s2\"|EXTERNAL_IF=\"$IFACE\"|" nat-simulation.sh
fi
REMOTE_SCRIPT

    echo "Files copied and configured."
}

# Start STUN servers in VM
start_stun_servers() {
    echo -e "${CYAN}Starting STUN servers in VM...${NC}"
    vm_ssh << 'REMOTE_SCRIPT'
cd /home/ubuntu/mesh-test
export LD_LIBRARY_PATH=/home/ubuntu/mesh-test/lib:$LD_LIBRARY_PATH

# Kill any existing STUN servers
pkill -f omerta-rendezvous 2>/dev/null || true
sleep 1

# Start STUN server 1 on port 3478
./omerta-rendezvous --stun-port 3478 --port 8080 --no-relay --log-level warning &
sleep 1

# Start STUN server 2 on port 3479
./omerta-rendezvous --stun-port 3479 --port 8081 --no-relay --log-level warning &
sleep 1

echo "STUN servers started"
REMOTE_SCRIPT
}

# Stop STUN servers in VM
stop_stun_servers() {
    vm_ssh "pkill -f omerta-rendezvous 2>/dev/null || true"
}

# Run a single NAT test
run_nat_test() {
    local nat1=$1
    local nat2=$2
    local relay=${3:-}

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Testing: $nat1 <-> $nat2 ${relay:+(with relay)}${NC}"
    echo -e "${CYAN}============================================================${NC}"

    # Start STUN servers
    start_stun_servers

    # Pass LD_LIBRARY_PATH through sudo for Swift runtime libraries
    local cmd="cd /home/ubuntu/mesh-test && sudo LD_LIBRARY_PATH=/home/ubuntu/mesh-test/lib:\$LD_LIBRARY_PATH ./run-nat-test.sh $nat1 $nat2 $relay"
    vm_ssh "$cmd"
    local result=$?

    # Stop STUN servers
    stop_stun_servers

    return $result
}

# Run all NAT combinations
run_all_tests() {
    local results=()
    local passed=0
    local failed=0

    # Test combinations in order of expected difficulty
    local tests=(
        # Easy - should all work directly
        "public public"
        "public full-cone"
        "full-cone full-cone"

        # Medium - hole punching required
        "full-cone port-restrict"
        "addr-restrict addr-restrict"
        "port-restrict port-restrict"

        # Hard - need relay
        "symmetric public"
        "symmetric full-cone"
        "symmetric symmetric relay"
    )

    for test in "${tests[@]}"; do
        local nat1 nat2 relay
        read -r nat1 nat2 relay <<< "$test"

        if run_nat_test "$nat1" "$nat2" "$relay"; then
            results+=("${GREEN}PASS${NC}: $nat1 <-> $nat2 ${relay:+(relay)}")
            ((passed++))
        else
            results+=("${RED}FAIL${NC}: $nat1 <-> $nat2 ${relay:+(relay)}")
            ((failed++))
        fi
    done

    # Summary
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}TEST SUMMARY${NC}"
    echo -e "${CYAN}============================================================${NC}"
    for result in "${results[@]}"; do
        echo -e "  $result"
    done
    echo ""
    echo -e "Passed: ${GREEN}$passed${NC} / $((passed + failed))"
    echo -e "Failed: ${RED}$failed${NC} / $((passed + failed))"

    return $failed
}

# Cleanup
cleanup() {
    stop_vm
    if [[ "$1" == "--full" ]]; then
        echo "Removing VM files..."
        rm -rf "$VM_DIR"
    fi
}

# Main
trap 'stop_vm' EXIT

case "${1:-}" in
    --shell)
        download_image
        create_cloud_init
        create_vm_disk
        start_vm
        copy_test_files
        echo ""
        echo -e "${GREEN}VM is ready. Connecting to shell...${NC}"
        echo "Run tests with: sudo ./mesh-test/run-nat-test.sh <nat1> <nat2> [relay]"
        echo "Exit shell to stop VM."
        echo ""
        vm_ssh
        ;;
    --all)
        download_image
        create_cloud_init
        create_vm_disk
        start_vm
        copy_test_files
        run_all_tests
        ;;
    --cleanup)
        cleanup --full
        echo "Cleanup complete."
        exit 0
        ;;
    -h|--help)
        usage
        ;;
    *)
        [[ -z "${1:-}" || -z "${2:-}" ]] && usage

        download_image
        create_cloud_init
        create_vm_disk
        start_vm
        copy_test_files
        run_nat_test "$1" "$2" "${3:-}"
        ;;
esac
