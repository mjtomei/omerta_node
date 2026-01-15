#!/bin/bash
# Interactive serial console helper
#
# Usage:
#   ./serial-console.sh <vm-name>       # Connect to VM serial console
#   ./serial-console.sh list            # List available serial sockets
#   ./serial-console.sh exec <vm> <cmd> # Execute command on VM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/vm-utils.sh"

usage() {
    echo "Serial Console Helper"
    echo ""
    echo "Usage:"
    echo "  $0 <vm-name>              Connect to VM serial console"
    echo "  $0 list                   List available VMs with serial sockets"
    echo "  $0 exec <vm-name> <cmd>   Execute command on VM"
    echo "  $0 log <vm-name>          Show VM console log"
    echo ""
    echo "Examples:"
    echo "  $0 peer1                  # Interactive console to peer1"
    echo "  $0 list                   # Show all running VMs"
    echo "  $0 exec peer1 'ip addr'   # Run 'ip addr' on peer1"
    echo "  $0 log nat-gw1            # Show nat-gw1 boot/console log"
    echo ""
    echo "To exit interactive console: Press Ctrl+C"
    exit 1
}

list_vms() {
    echo "Available VMs with serial sockets:"
    echo ""
    if [[ -d "$RUN_DIR" ]]; then
        for vm_dir in "$RUN_DIR"/*/; do
            if [[ -d "$vm_dir" ]]; then
                local vm_name=$(basename "$vm_dir")
                local socket="$vm_dir/serial.sock"
                local pid_file="$vm_dir/qemu.pid"
                local status="stopped"

                if [[ -f "$pid_file" ]]; then
                    local pid=$(cat "$pid_file")
                    if kill -0 "$pid" 2>/dev/null; then
                        status="running (PID $pid)"
                    fi
                fi

                if [[ -S "$socket" ]]; then
                    echo "  $vm_name: $socket [$status]"
                else
                    echo "  $vm_name: (no socket) [$status]"
                fi
            fi
        done
    else
        echo "  (no VMs running)"
    fi
}

show_log() {
    local vm_name="$1"
    local logfile="$RUN_DIR/$vm_name/console.log"

    if [[ -f "$logfile" ]]; then
        echo "=== Console log for $vm_name ==="
        cat "$logfile"
    else
        echo "No console log found for $vm_name"
        exit 1
    fi
}

case "${1:-}" in
    list)
        list_vms
        ;;
    exec)
        [[ -z "${2:-}" || -z "${3:-}" ]] && usage
        serial_exec "$2" "$3" 10
        ;;
    log)
        [[ -z "${2:-}" ]] && usage
        show_log "$2"
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        serial_console "$1"
        ;;
esac
