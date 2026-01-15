#!/bin/bash
# Run nested VM NAT tests inside an outer VM
#
# This script launches an outer Ubuntu VM and runs the nested VM NAT tests inside it,
# avoiding the need for sudo/root on the host machine. The outer VM has full root access
# and can create the nested VMs with proper network isolation.
#
# Usage:
#   ./run-in-outer-vm.sh <nat-type-1> <nat-type-2> [relay]
#   ./run-in-outer-vm.sh --shell        # Start outer VM and get a shell
#   ./run-in-outer-vm.sh --cleanup      # Remove VM images
#
# Examples:
#   ./run-in-outer-vm.sh full-cone full-cone
#   ./run-in-outer-vm.sh symmetric symmetric relay

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Auto-detect OMERTA_DIR from script location (script is in scripts/e2e-mesh-test/nested-vm/)
OMERTA_DIR="${OMERTA_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
VM_DIR="$OMERTA_DIR/.nested-vm-test"
CLOUD_IMAGE="$VM_DIR/ubuntu-cloud.img"
VM_IMAGE="$VM_DIR/outer-vm.qcow2"

# Detect architecture
HOST_ARCH=$(uname -m)
if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
    CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img"
    QEMU_CMD="qemu-system-aarch64"
    MACHINE_OPTS="-machine virt"
    EFI_CODE="/usr/share/AAVMF/AAVMF_CODE.fd"
    EFI_VARS_TEMPLATE="/usr/share/AAVMF/AAVMF_VARS.fd"
    EFI_VARS="$VM_DIR/AAVMF_VARS.fd"
else
    CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
    QEMU_CMD="qemu-system-x86_64"
    MACHINE_OPTS="-machine q35"
    EFI_CODE=""
    EFI_VARS=""
fi

# Outer VM needs more resources for running nested VMs
VM_RAM="4G"
VM_CPUS="4"
VM_DISK="20G"
SSH_PORT="2223"
VM_USER="ubuntu"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <nat-type-1> <nat-type-2> [relay]"
    echo "       $0 --shell"
    echo "       $0 --cleanup"
    echo ""
    echo "NAT Types: public, full-cone, addr-restrict, port-restrict, symmetric"
    echo ""
    echo "This script runs nested VM NAT tests inside an outer VM, eliminating"
    echo "the need for root/sudo on the host machine."
    exit 1
}

mkdir -p "$VM_DIR"

download_image() {
    if [[ ! -f "$CLOUD_IMAGE" ]]; then
        echo -e "${CYAN}Downloading Ubuntu cloud image...${NC}"
        curl -L -o "$CLOUD_IMAGE" "$CLOUD_IMAGE_URL"
    fi
}

create_cloud_init() {
    local ssh_key
    ssh_key=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "")

    cat > "$VM_DIR/user-data" << EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $ssh_key

package_update: true

packages:
  - qemu-system-x86
  - qemu-kvm
  - qemu-utils
  - cloud-image-utils
  - iptables
  - iproute2
  - bridge-utils
  - nftables
  - curl
  - wget
  - genisoimage
  - git
  - clang
  - libcurl4-openssl-dev
  - libxml2-dev
  - rsync

runcmd:
  - sysctl -p /etc/sysctl.d/99-nested-vm.conf 2>/dev/null || true
  - modprobe br_netfilter 2>/dev/null || true
  - modprobe kvm
  - modprobe kvm_intel || modprobe kvm_amd || true
  - chmod 666 /dev/kvm 2>/dev/null || true
  - mkdir -p /home/ubuntu/nested-vm-test
  - chown ubuntu:ubuntu /home/ubuntu/nested-vm-test

write_files:
  - path: /etc/sysctl.d/99-nested-vm.conf
    content: |
      net.ipv4.ip_forward=1
      net.bridge.bridge-nf-call-iptables=0
      net.bridge.bridge-nf-call-ip6tables=0

EOF

    cat > "$VM_DIR/meta-data" << EOF
instance-id: nested-vm-outer
local-hostname: nested-vm-outer
EOF

    # Create cloud-init ISO
    if command -v cloud-localds &> /dev/null; then
        cloud-localds "$VM_DIR/cloud-init.iso" "$VM_DIR/user-data" "$VM_DIR/meta-data"
    elif command -v genisoimage &> /dev/null; then
        genisoimage -output "$VM_DIR/cloud-init.iso" -volid cidata -joliet -rock \
            "$VM_DIR/user-data" "$VM_DIR/meta-data" 2>/dev/null
    elif command -v mkisofs &> /dev/null; then
        mkisofs -output "$VM_DIR/cloud-init.iso" -volid cidata -joliet -rock \
            "$VM_DIR/user-data" "$VM_DIR/meta-data" 2>/dev/null
    else
        echo -e "${RED}Error: cloud-localds, genisoimage, or mkisofs required${NC}"
        exit 1
    fi
}

create_vm_disk() {
    if [[ ! -f "$VM_IMAGE" ]]; then
        echo -e "${CYAN}Creating VM disk ($VM_DISK)...${NC}"
        qemu-img create -f qcow2 -b "$CLOUD_IMAGE" -F qcow2 "$VM_IMAGE" "$VM_DISK"
    fi
}

start_vm() {
    echo -e "${CYAN}Starting outer VM for nested tests...${NC}"

    local accel_opts=""
    local cpu_opts=""
    local efi_opts=""
    local nested_opts=""

    if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
        if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
            echo "KVM acceleration available (ARM64)"
            accel_opts="-accel kvm"
            cpu_opts="-cpu host"
        else
            echo -e "${YELLOW}Warning: KVM not available, nested VMs will be slow${NC}"
            accel_opts="-accel tcg"
            cpu_opts="-cpu cortex-a72"
        fi

        if [[ -f "$EFI_CODE" ]]; then
            [[ ! -f "$EFI_VARS" ]] && cp "$EFI_VARS_TEMPLATE" "$EFI_VARS"
            efi_opts="-drive if=pflash,format=raw,readonly=on,file=$EFI_CODE -drive if=pflash,format=raw,file=$EFI_VARS"
        fi
    else
        # x86_64 - enable nested virtualization
        if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
            echo "KVM acceleration available (x86_64)"
            accel_opts="-accel kvm"
            # Enable nested virtualization in guest - expose VMX to the guest
            cpu_opts="-cpu host,+vmx"
        else
            echo -e "${YELLOW}Warning: KVM not available, nested VMs will be slow${NC}"
            accel_opts="-accel tcg"
            cpu_opts="-cpu qemu64"
        fi
    fi

    $QEMU_CMD \
        -name nested-vm-outer \
        $MACHINE_OPTS \
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

    echo "Waiting for VM to boot..."
    for i in {1..90}; do
        if ssh -q -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -p $SSH_PORT $VM_USER@localhost echo "ready" 2>/dev/null; then
            echo -e "${GREEN}Outer VM is ready!${NC}"
            return 0
        fi
        sleep 2
        echo -n "."
    done

    echo -e "\n${RED}VM failed to boot in time${NC}"
    return 1
}

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

vm_ssh() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p $SSH_PORT $VM_USER@localhost "$@"
}

vm_scp() {
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -P $SSH_PORT "$@"
}

copy_test_files() {
    echo -e "${CYAN}Copying nested VM test files to outer VM...${NC}"

    # Build on host first (uses locally installed Swift)
    echo -e "${CYAN}Building omerta-mesh and omerta-rendezvous on host...${NC}"
    if ! command -v swift &> /dev/null; then
        echo -e "${RED}Error: Swift not installed on host. Install Swift first.${NC}"
        exit 1
    fi

    echo "Swift version: $(swift --version | head -1)"

    (cd "$OMERTA_DIR" && swift build --product omerta-mesh 2>&1 | tail -5)
    (cd "$OMERTA_DIR" && swift build --product omerta-rendezvous 2>&1 | tail -5)

    if [[ ! -f "$OMERTA_DIR/.build/debug/omerta-mesh" ]]; then
        echo -e "${RED}Error: omerta-mesh build failed${NC}"
        exit 1
    fi
    if [[ ! -f "$OMERTA_DIR/.build/debug/omerta-rendezvous" ]]; then
        echo -e "${RED}Error: omerta-rendezvous build failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}Build complete${NC}"

    # Wait for cloud-init
    echo "Waiting for cloud-init to finish..."
    vm_ssh "cloud-init status --wait" || true

    # Create directory structure
    vm_ssh "mkdir -p /home/ubuntu/nested-vm-test/{lib,images,cloud-init,scenarios}"

    # Copy pre-built binaries
    echo "Copying binaries to VM..."
    vm_scp "$OMERTA_DIR/.build/debug/omerta-mesh" $VM_USER@localhost:/home/ubuntu/nested-vm-test/
    vm_scp "$OMERTA_DIR/.build/debug/omerta-rendezvous" $VM_USER@localhost:/home/ubuntu/nested-vm-test/

    # Copy Swift runtime libraries from host
    echo "Copying Swift runtime libraries..."
    local SWIFT_LIB_DIR=""
    if [[ -d "$HOME/.local/share/swiftly/toolchains" ]]; then
        SWIFT_LIB_DIR=$(find "$HOME/.local/share/swiftly/toolchains" -maxdepth 2 -type d -name "usr" -exec test -d "{}/lib/swift/linux" \; -print -quit 2>/dev/null)/lib/swift/linux
    fi
    if [[ -z "$SWIFT_LIB_DIR" ]] || [[ ! -d "$SWIFT_LIB_DIR" ]]; then
        # Try common locations
        for dir in /usr/lib/swift/linux /opt/swift/usr/lib/swift/linux; do
            if [[ -d "$dir" ]]; then
                SWIFT_LIB_DIR="$dir"
                break
            fi
        done
    fi
    # Also check relative to swift binary
    if [[ -z "$SWIFT_LIB_DIR" ]] || [[ ! -d "$SWIFT_LIB_DIR" ]]; then
        local swift_bin=$(which swift 2>/dev/null)
        if [[ -n "$swift_bin" ]]; then
            local swift_root=$(dirname $(dirname $(readlink -f "$swift_bin")))
            if [[ -d "$swift_root/lib/swift/linux" ]]; then
                SWIFT_LIB_DIR="$swift_root/lib/swift/linux"
            fi
        fi
    fi

    if [[ -n "$SWIFT_LIB_DIR" ]] && [[ -d "$SWIFT_LIB_DIR" ]]; then
        echo "Using Swift libraries from: $SWIFT_LIB_DIR"
        vm_scp "$SWIFT_LIB_DIR"/*.so* $VM_USER@localhost:/home/ubuntu/nested-vm-test/lib/ 2>/dev/null || true
    else
        echo -e "${YELLOW}Warning: Could not find Swift runtime libraries${NC}"
    fi

    # Copy nested VM scripts
    vm_scp "$SCRIPT_DIR/run-nested-test.sh" $VM_USER@localhost:/home/ubuntu/nested-vm-test/
    vm_scp "$SCRIPT_DIR/setup-infra.sh" $VM_USER@localhost:/home/ubuntu/nested-vm-test/
    vm_scp "$SCRIPT_DIR/cleanup.sh" $VM_USER@localhost:/home/ubuntu/nested-vm-test/
    vm_scp -r "$SCRIPT_DIR/lib" $VM_USER@localhost:/home/ubuntu/nested-vm-test/
    vm_scp -r "$SCRIPT_DIR/cloud-init" $VM_USER@localhost:/home/ubuntu/nested-vm-test/
    vm_scp -r "$SCRIPT_DIR/scenarios" $VM_USER@localhost:/home/ubuntu/nested-vm-test/

    # Configure inside VM (no Swift needed)
    echo -e "${CYAN}Configuring test environment inside VM...${NC}"
    vm_ssh << 'REMOTE_SCRIPT'
set -e

# Configure scripts
chmod +x /home/ubuntu/nested-vm-test/*.sh
cd /home/ubuntu/nested-vm-test

# Patch paths in scripts
sed -i 's|OMERTA_DIR="${OMERTA_DIR}"|OMERTA_DIR="/home/ubuntu/omerta"|g' run-nested-test.sh setup-infra.sh lib/*.sh 2>/dev/null || true

# Set up library path
echo 'export LD_LIBRARY_PATH=/home/ubuntu/nested-vm-test/lib:$LD_LIBRARY_PATH' >> ~/.bashrc

# Download nested VM images
echo "Downloading nested VM images..."
cd /home/ubuntu/nested-vm-test
sudo ./setup-infra.sh 2>&1 | tail -10

echo "Build and setup complete!"
REMOTE_SCRIPT

    echo "Files copied and configured."
}

run_nested_test() {
    local nat1=$1
    local nat2=$2
    local relay=${3:-}

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Running nested VM test: $nat1 <-> $nat2 ${relay:+(with relay)}${NC}"
    echo -e "${CYAN}============================================================${NC}"

    local cmd="cd /home/ubuntu/nested-vm-test && sudo LD_LIBRARY_PATH=/home/ubuntu/nested-vm-test/lib:\$LD_LIBRARY_PATH ./run-nested-test.sh $nat1 $nat2 $relay"
    vm_ssh "$cmd"
    return $?
}

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
        echo -e "${GREEN}Outer VM is ready. Connecting to shell...${NC}"
        echo "Run nested tests with: sudo ./nested-vm-test/run-nested-test.sh <nat1> <nat2> [relay]"
        echo "Exit shell to stop VM."
        echo ""
        vm_ssh
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
        run_nested_test "$1" "$2" "${3:-}"
        ;;
esac
