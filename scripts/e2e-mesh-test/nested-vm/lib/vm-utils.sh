#!/bin/bash
# VM Lifecycle Utilities
#
# Helper functions for managing QEMU VMs in the nested test environment.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="$SCRIPT_DIR/images"
CLOUD_INIT_DIR="$SCRIPT_DIR/cloud-init"
RUN_DIR="$SCRIPT_DIR/.run"

# Detect architecture
HOST_ARCH=$(uname -m)
if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
    QEMU_CMD="qemu-system-aarch64"
    MACHINE_OPTS="-machine virt"
    if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]]; then
        ACCEL_OPTS="-accel kvm -cpu host"
    else
        ACCEL_OPTS="-accel tcg -cpu cortex-a72"
    fi
    EFI_CODE="/usr/share/AAVMF/AAVMF_CODE.fd"
else
    QEMU_CMD="qemu-system-x86_64"
    MACHINE_OPTS="-machine q35"
    if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]]; then
        ACCEL_OPTS="-accel kvm -cpu host"
    else
        ACCEL_OPTS="-accel tcg -cpu qemu64"
    fi
    EFI_CODE=""
fi

# Get SSH public key (generate if needed)
get_ssh_key() {
    local key_file
    for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
        if [[ -f "$key_file" ]]; then
            cat "$key_file"
            return 0
        fi
    done
    # Generate a new key pair if none exists
    echo "Generating new SSH key..." >&2
    mkdir -p ~/.ssh
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" >&2
    cat ~/.ssh/id_ed25519.pub
    return 0
}

# Create cloud-init ISO for a VM
# Usage: create_cloud_init_iso <vm-name> <template> [extra-vars...]
create_cloud_init_iso() {
    local vm_name="$1"
    local template="$2"
    shift 2

    local iso_dir="$RUN_DIR/$vm_name/cloud-init"
    mkdir -p "$iso_dir"

    # Get SSH key
    local ssh_key
    ssh_key=$(get_ssh_key)

    # Process template with variable substitution
    local user_data="$iso_dir/user-data"
    local meta_data="$iso_dir/meta-data"

    # Create user-data from template
    export SSH_PUBLIC_KEY="$ssh_key"
    export PEER_NAME="$vm_name"
    # Export any extra vars passed as key=value
    for var in "$@"; do
        export "${var}"
    done

    # Only substitute specific template variables, not shell variables in scripts
    # This prevents $NAT_TYPE etc in embedded scripts from being replaced
    envsubst '${SSH_PUBLIC_KEY} ${PEER_NAME} ${INET_IP} ${LAN_IP} ${NAT_TYPE} ${PEER_IP} ${GATEWAY_IP}' < "$CLOUD_INIT_DIR/$template" > "$user_data"

    # Create meta-data
    cat > "$meta_data" <<EOF
instance-id: $vm_name
local-hostname: $vm_name
EOF

    # Extract network config from user-data and create separate network-config file
    # NoCloud datasource requires network config in a separate file
    local network_config="$iso_dir/network-config"
    if grep -q "^network:" "$user_data"; then
        # Extract the network section (from 'network:' to next top-level key or EOF)
        awk '/^network:/{p=1} p{print} /^[a-z]/ && !/^network:/ && p{p=0}' "$user_data" > "$network_config"
        # Remove the network section from user-data
        sed -i '/^network:/,/^[a-z]/{ /^network:/d; /^  /d; }' "$user_data"
        # Clean up any leftover empty lines at the network section
        sed -i '/^# Network configuration/,/^$/d' "$user_data"
    fi

    # Create ISO
    local iso_file="$RUN_DIR/$vm_name/cloud-init.iso"
    if command -v genisoimage &>/dev/null; then
        genisoimage -output "$iso_file" -volid cidata -joliet -rock "$iso_dir" 2>/dev/null
    elif command -v mkisofs &>/dev/null; then
        mkisofs -output "$iso_file" -volid cidata -joliet -rock "$iso_dir" 2>/dev/null
    else
        echo "ERROR: No ISO creation tool found (need genisoimage or mkisofs)" >&2
        return 1
    fi

    echo "$iso_file"
}

# Create VM disk image (copy-on-write)
# Usage: create_vm_disk <vm-name> <base-image> [size]
create_vm_disk() {
    local vm_name="$1"
    local base_image="$2"
    local size="${3:-10G}"

    local disk_file="$RUN_DIR/$vm_name/disk.qcow2"
    mkdir -p "$(dirname "$disk_file")"

    # Use absolute path for backing file to avoid path resolution issues
    local abs_base_image
    abs_base_image=$(realpath "$base_image")

    qemu-img create -f qcow2 -F qcow2 -b "$abs_base_image" "$disk_file" "$size" >&2
    echo "$disk_file"
}

# Start a VM
# Usage: start_vm <vm-name> <ram-mb> <cpus> <disk> <cloud-init-iso> <network-opts...>
start_vm() {
    local vm_name="$1"
    local ram="$2"
    local cpus="$3"
    local disk="$4"
    local cloud_init="$5"
    shift 5
    local network_opts=("$@")

    local pidfile="$RUN_DIR/$vm_name/qemu.pid"
    local logfile="$RUN_DIR/$vm_name/console.log"

    mkdir -p "$(dirname "$pidfile")"

    # Build network arguments with unique MAC addresses
    local net_args=""
    local netdev_id=0
    # Generate a unique base from VM name (hash to 2 bytes)
    local vm_hash=$(echo -n "$vm_name" | md5sum | cut -c1-4)
    local vm_byte1=$((16#${vm_hash:0:2}))
    local vm_byte2=$((16#${vm_hash:2:2}))

    for net_opt in "${network_opts[@]}"; do
        # Generate unique MAC: 52:54:00:XX:YY:ZZ where XX:YY from vm_name hash, ZZ from interface id
        local mac=$(printf "52:54:00:%02x:%02x:%02x" $vm_byte1 $vm_byte2 $netdev_id)
        net_args+=" -netdev $net_opt,id=net${netdev_id}"
        net_args+=" -device virtio-net-pci,netdev=net${netdev_id},mac=$mac"
        ((netdev_id++))
    done

    # EFI options for ARM64
    local efi_args=""
    if [[ -n "$EFI_CODE" ]] && [[ -f "$EFI_CODE" ]]; then
        local efi_vars="$RUN_DIR/$vm_name/efi-vars.fd"
        cp /usr/share/AAVMF/AAVMF_VARS.fd "$efi_vars" 2>/dev/null || true
        efi_args="-drive if=pflash,format=raw,readonly=on,file=$EFI_CODE"
        if [[ -f "$efi_vars" ]]; then
            efi_args+=" -drive if=pflash,format=raw,file=$efi_vars"
        fi
    fi

    # Start QEMU
    $QEMU_CMD \
        -name "$vm_name" \
        $MACHINE_OPTS \
        $ACCEL_OPTS \
        -m "$ram" \
        -smp "$cpus" \
        $efi_args \
        -drive file="$disk",format=qcow2,if=virtio \
        -drive file="$cloud_init",format=raw,if=virtio \
        $net_args \
        -display none \
        -serial file:"$logfile" \
        -pidfile "$pidfile" \
        -daemonize

    # Wait for PID file
    local wait_count=0
    while [[ ! -f "$pidfile" ]] && [[ $wait_count -lt 10 ]]; do
        sleep 0.5
        ((wait_count++))
    done

    if [[ -f "$pidfile" ]]; then
        local pid=$(cat "$pidfile")
        echo "$pid"
    else
        echo "ERROR: Failed to start VM $vm_name" >&2
        return 1
    fi
}

# Stop a VM
# Usage: stop_vm <vm-name>
stop_vm() {
    local vm_name="$1"
    local pidfile="$RUN_DIR/$vm_name/qemu.pid"

    if [[ -f "$pidfile" ]]; then
        local pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$pidfile"
            echo "Stopped VM $vm_name (PID $pid)"
        fi
    fi
}

# Wait for VM to be ready (SSH accessible)
# Usage: wait_for_vm <ip-address> <port> [timeout-seconds]
wait_for_vm() {
    local ip="$1"
    local port="${2:-22}"
    local timeout="${3:-120}"

    local start_time=$(date +%s)
    while true; do
        if ssh -q -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -p "$port" ubuntu@"$ip" "echo ready" 2>/dev/null; then
            return 0
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            echo "ERROR: Timeout waiting for VM at $ip:$port" >&2
            return 1
        fi

        sleep 2
    done
}

# Run command on VM via SSH
# Usage: vm_ssh <ip> <port> <command>
vm_ssh() {
    local ip="$1"
    local port="$2"
    shift 2

    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p "$port" ubuntu@"$ip" "$@"
}

# Copy file to VM
# Usage: vm_scp <local-file> <ip> <port> <remote-path>
vm_scp() {
    local local_file="$1"
    local ip="$2"
    local port="$3"
    local remote_path="$4"

    scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -P "$port" "$local_file" ubuntu@"$ip":"$remote_path"
}

# Cleanup VM run directory
# Usage: cleanup_vm <vm-name>
cleanup_vm() {
    local vm_name="$1"
    stop_vm "$vm_name"
    rm -rf "$RUN_DIR/$vm_name"
}

# Cleanup all VMs
cleanup_all_vms() {
    if [[ -d "$RUN_DIR" ]]; then
        for vm_dir in "$RUN_DIR"/*/; do
            if [[ -d "$vm_dir" ]]; then
                local vm_name=$(basename "$vm_dir")
                cleanup_vm "$vm_name"
            fi
        done
    fi
}
