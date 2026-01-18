#!/bin/bash
# Clean up old Omerta storage directories from root's home
# Run with: sudo ./cleanup-root-storage.sh

set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

ROOT_HOME="/root"
if [[ "$(uname)" == "Darwin" ]]; then
    ROOT_HOME="/var/root"
fi

echo "Cleaning up old Omerta directories from $ROOT_HOME"
echo ""

# Function to remove directory if it exists
remove_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        echo "  Removing: $dir"
        rm -rf "$dir"
    fi
}

# Function to remove file if it exists
remove_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        echo "  Removing: $file"
        rm -f "$file"
    fi
}

echo "1. Removing mesh data directories..."
remove_dir "$ROOT_HOME/.local/share/OmertaMesh"
remove_dir "$ROOT_HOME/Library/Application Support/OmertaMesh"
remove_dir "$ROOT_HOME/.config/OmertaMesh"

echo ""
echo "2. Removing log directories..."
remove_dir "$ROOT_HOME/.config/OmertaDaemon"
remove_dir "$ROOT_HOME/.config/OmertaProvider"
remove_dir "$ROOT_HOME/.config/OmertaConsumer"

echo ""
echo "3. Removing .omerta directory..."
remove_dir "$ROOT_HOME/.omerta"

echo ""
echo "Cleanup complete!"
