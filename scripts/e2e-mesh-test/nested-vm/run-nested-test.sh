#!/bin/bash
# Nested VM NAT Test Runner
#
# Runs realistic NAT traversal tests using nested VMs with proper network isolation.
# Automatically creates an outer VM to run the tests in, avoiding the need for
# root/sudo on the host machine.
#
# Usage:
#   ./run-nested-test.sh <nat-type-1> <nat-type-2> [relay] [--serial]
#   ./run-nested-test.sh --shell        # Get interactive shell in test VM
#   ./run-nested-test.sh --cleanup      # Remove VM images
#
# NAT Types:
#   public        No NAT (direct public IP)
#   full-cone     Full Cone NAT (easiest traversal)
#   addr-restrict Address-Restricted Cone NAT
#   port-restrict Port-Restricted Cone NAT
#   symmetric     Symmetric NAT (hardest, usually needs relay)
#
# Examples:
#   ./run-nested-test.sh full-cone full-cone
#   ./run-nested-test.sh symmetric symmetric relay
#   ./run-nested-test.sh port-restrict symmetric --serial

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMERTA_DIR="${OMERTA_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# Check if we're being run inside the outer VM (internal use)
if [[ "${__NESTED_VM_INNER:-}" == "1" ]]; then
    # We're inside the outer VM - run the actual test
    exec "$SCRIPT_DIR/lib/run-test-inner.sh" "$@"
fi

# Fail if running as root - we want to use the outer VM for isolation
if [[ $EUID -eq 0 ]]; then
    echo "Error: Do not run this script as root/sudo."
    echo ""
    echo "This script automatically creates an isolated VM for testing."
    echo "Run it as a normal user:"
    echo ""
    echo "  ./run-nested-test.sh full-cone full-cone"
    echo ""
    exit 1
fi

# Outer VM configuration
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

# Outer VM resources
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
    echo "Nested VM NAT Test Runner"
    echo ""
    echo "Usage:"
    echo "  $0 <nat-type-1> <nat-type-2> [relay] [--serial]"
    echo "  $0 --shell                    Get interactive shell in test VM"
    echo "  $0 --cleanup                  Remove all VM images"
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
    echo "  --serial      Use serial console instead of SSH for peer VMs"
    echo ""
    echo "Examples:"
    echo "  $0 full-cone full-cone           # Direct connection test"
    echo "  $0 symmetric symmetric relay     # Must use relay"
    echo "  $0 port-restrict symmetric       # Hole punching test"
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

    if [[ -z "$ssh_key" ]]; then
        echo -e "${YELLOW}No SSH key found. Generating one...${NC}"
        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
        ssh_key=$(cat ~/.ssh/id_ed25519.pub)
    fi

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
  - iproute2
  - bridge-utils
  - nftables
  - curl
  - wget
  - genisoimage
  - socat

runcmd:
  - sysctl -p /etc/sysctl.d/99-nested-vm.conf 2>/dev/null || true
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
    echo -e "${CYAN}Starting test VM...${NC}"

    local accel_opts=""
    local cpu_opts=""
    local efi_opts=""

    if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
        if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
            accel_opts="-accel kvm"
            cpu_opts="-cpu host"
        else
            echo -e "${YELLOW}Warning: KVM not available, tests will be slow${NC}"
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
            accel_opts="-accel kvm"
            cpu_opts="-cpu host,+vmx"
        else
            echo -e "${YELLOW}Warning: KVM not available, tests will be slow${NC}"
            accel_opts="-accel tcg"
            cpu_opts="-cpu qemu64"
        fi
    fi

    # Log console to file to avoid mixing with test output
    local console_log="$VM_DIR/console.log"

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
        -serial file:"$console_log" &

    VM_PID=$!
    echo $VM_PID > "$VM_DIR/vm.pid"
    echo "Console log: $console_log"

    echo -n "Waiting for VM to boot"
    for i in {1..90}; do
        if ssh -q -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -p $SSH_PORT $VM_USER@localhost echo "ready" 2>/dev/null; then
            echo -e "\n${GREEN}VM ready${NC}"
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
    echo -e "${CYAN}Building and copying test files...${NC}"

    # Build on host first
    if ! command -v swift &> /dev/null; then
        echo -e "${RED}Error: Swift not installed. Install Swift first.${NC}"
        exit 1
    fi

    echo "Building omerta CLI and daemon..."
    (cd "$OMERTA_DIR" && swift build --product omerta --product omertad 2>&1 | tail -5)

    if [[ ! -f "$OMERTA_DIR/.build/debug/omerta" ]]; then
        echo -e "${RED}Error: omerta build failed${NC}"
        exit 1
    fi
    if [[ ! -f "$OMERTA_DIR/.build/debug/omertad" ]]; then
        echo -e "${RED}Error: omertad build failed${NC}"
        exit 1
    fi

    # Wait for cloud-init
    echo "Waiting for VM setup to complete..."
    vm_ssh "cloud-init status --wait" 2>/dev/null || true

    # Create directory structure
    vm_ssh "mkdir -p /home/ubuntu/nested-vm-test/{lib,images,cloud-init,.run}"

    # Copy binaries
    echo "Copying omerta and omertad binaries..."
    vm_scp "$OMERTA_DIR/.build/debug/omerta" $VM_USER@localhost:/home/ubuntu/nested-vm-test/
    vm_scp "$OMERTA_DIR/.build/debug/omertad" $VM_USER@localhost:/home/ubuntu/nested-vm-test/

    # Copy Swift runtime libraries
    echo "Copying Swift runtime libraries..."
    local swift_lib_dir=""

    # Find Swift library directory
    if [[ -d "$HOME/.local/share/swiftly/toolchains" ]]; then
        for toolchain in "$HOME/.local/share/swiftly/toolchains"/*/usr/lib/swift/linux; do
            if [[ -d "$toolchain" ]]; then
                swift_lib_dir="$toolchain"
                break
            fi
        done
    fi

    if [[ -z "$swift_lib_dir" ]] || [[ ! -d "$swift_lib_dir" ]]; then
        local swift_bin=$(which swift 2>/dev/null)
        if [[ -n "$swift_bin" ]]; then
            local swift_root=$(dirname $(dirname $(readlink -f "$swift_bin")))
            if [[ -d "$swift_root/lib/swift/linux" ]]; then
                swift_lib_dir="$swift_root/lib/swift/linux"
            fi
        fi
    fi

    if [[ -n "$swift_lib_dir" ]] && [[ -d "$swift_lib_dir" ]]; then
        vm_scp "$swift_lib_dir"/*.so* $VM_USER@localhost:/home/ubuntu/nested-vm-test/lib/ 2>/dev/null || true
    else
        echo -e "${YELLOW}Warning: Could not find Swift runtime libraries${NC}"
    fi

    # Copy test scripts
    echo "Copying test scripts..."
    vm_scp "$SCRIPT_DIR/lib/run-test-inner.sh" $VM_USER@localhost:/home/ubuntu/nested-vm-test/
    vm_scp "$SCRIPT_DIR/lib/vm-utils.sh" $VM_USER@localhost:/home/ubuntu/nested-vm-test/
    vm_scp "$SCRIPT_DIR/setup-infra.sh" $VM_USER@localhost:/home/ubuntu/nested-vm-test/
    vm_scp -r "$SCRIPT_DIR/cloud-init" $VM_USER@localhost:/home/ubuntu/nested-vm-test/

    # Make scripts executable and set up infrastructure
    echo "Setting up test infrastructure in VM..."
    vm_ssh << 'REMOTE_SCRIPT'
set -e
cd /home/ubuntu/nested-vm-test
chmod +x *.sh
echo 'export LD_LIBRARY_PATH=/home/ubuntu/nested-vm-test/lib:$LD_LIBRARY_PATH' >> ~/.bashrc
sudo ./setup-infra.sh 2>&1 | tail -5
echo "Infrastructure ready"
REMOTE_SCRIPT
}

run_test_in_vm() {
    local args="$*"

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}Running NAT Test${NC}"
    echo -e "${CYAN}============================================================${NC}"

    vm_ssh "cd /home/ubuntu/nested-vm-test && sudo LD_LIBRARY_PATH=/home/ubuntu/nested-vm-test/lib:\$LD_LIBRARY_PATH ./run-test-inner.sh $args"
}

do_cleanup() {
    stop_vm
    echo "Removing VM files..."
    rm -rf "$VM_DIR"
    echo -e "${GREEN}Cleanup complete${NC}"
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
        echo -e "${GREEN}Test VM is ready. Connecting to shell...${NC}"
        echo ""
        echo "Inside the VM, run tests with:"
        echo "  cd /home/ubuntu/nested-vm-test"
        echo "  sudo LD_LIBRARY_PATH=./lib ./run-test-inner.sh full-cone full-cone"
        echo ""
        echo "Exit shell to stop VM."
        echo ""
        vm_ssh
        ;;
    --cleanup)
        do_cleanup
        exit 0
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        # Validate NAT types
        NAT1="${1:-}"
        NAT2="${2:-}"

        [[ -z "$NAT1" || -z "$NAT2" ]] && usage

        valid_nats="public full-cone addr-restrict port-restrict symmetric"
        if ! echo "$valid_nats" | grep -qw "$NAT1"; then
            echo -e "${RED}Invalid NAT type: $NAT1${NC}"
            usage
        fi
        if ! echo "$valid_nats" | grep -qw "$NAT2"; then
            echo -e "${RED}Invalid NAT type: $NAT2${NC}"
            usage
        fi

        download_image
        create_cloud_init
        create_vm_disk
        start_vm
        copy_test_files

        # Pass all arguments to the inner test
        run_test_in_vm "$@"
        ;;
esac
