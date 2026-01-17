#!/bin/bash
# Migrate Omerta storage from old locations to ~/.omerta/
# Run this once on each machine after updating to the new code

set -e

OMERTA_DIR="$HOME/.omerta"
MESH_DIR="$OMERTA_DIR/mesh"
LOGS_DIR="$OMERTA_DIR/logs"

echo "Migrating Omerta storage to $OMERTA_DIR"
echo ""

# Create directories
mkdir -p "$MESH_DIR"
mkdir -p "$LOGS_DIR/daemon"
mkdir -p "$LOGS_DIR/provider"
mkdir -p "$LOGS_DIR/consumer"
mkdir -p "$LOGS_DIR/mesh"

# Function to migrate a file
migrate_file() {
    local src="$1"
    local dst="$2"
    if [[ -f "$src" ]] && [[ ! -f "$dst" ]]; then
        echo "  Moving $src -> $dst"
        mv "$src" "$dst"
    elif [[ -f "$src" ]] && [[ -f "$dst" ]]; then
        echo "  Skipping $src (destination exists)"
    fi
}

# Function to migrate a directory's contents
migrate_dir() {
    local src="$1"
    local dst="$2"
    if [[ -d "$src" ]]; then
        echo "  Moving contents of $src -> $dst"
        mkdir -p "$dst"
        # Move files, skip if destination exists
        for f in "$src"/*; do
            [[ -e "$f" ]] || continue
            local fname=$(basename "$f")
            if [[ ! -e "$dst/$fname" ]]; then
                mv "$f" "$dst/"
            else
                echo "    Skipping $fname (already exists)"
            fi
        done
    fi
}

echo "1. Migrating mesh data..."

# Linux: ~/.local/share/OmertaMesh/
if [[ -d "$HOME/.local/share/OmertaMesh" ]]; then
    migrate_file "$HOME/.local/share/OmertaMesh/networks.json" "$MESH_DIR/networks.json"
    migrate_file "$HOME/.local/share/OmertaMesh/identities.json" "$MESH_DIR/identities.json"
    migrate_file "$HOME/.local/share/OmertaMesh/peers.json" "$MESH_DIR/peers.json"
    rmdir "$HOME/.local/share/OmertaMesh" 2>/dev/null || true
fi

# macOS: ~/Library/Application Support/OmertaMesh/
if [[ -d "$HOME/Library/Application Support/OmertaMesh" ]]; then
    migrate_file "$HOME/Library/Application Support/OmertaMesh/networks.json" "$MESH_DIR/networks.json"
    migrate_file "$HOME/Library/Application Support/OmertaMesh/identities.json" "$MESH_DIR/identities.json"
    migrate_file "$HOME/Library/Application Support/OmertaMesh/peers.json" "$MESH_DIR/peers.json"
    rmdir "$HOME/Library/Application Support/OmertaMesh" 2>/dev/null || true
fi

# ~/.config/OmertaMesh/
if [[ -d "$HOME/.config/OmertaMesh" ]]; then
    migrate_file "$HOME/.config/OmertaMesh/peer_endpoints.json" "$MESH_DIR/peer_endpoints.json"
    migrate_file "$HOME/.config/OmertaMesh/machine_id" "$MESH_DIR/machine_id"
    migrate_dir "$HOME/.config/OmertaMesh/logs" "$LOGS_DIR/mesh"
    rmdir "$HOME/.config/OmertaMesh" 2>/dev/null || true
fi

echo ""
echo "2. Migrating logs..."

# ~/.config/OmertaDaemon/logs/
migrate_dir "$HOME/.config/OmertaDaemon/logs" "$LOGS_DIR/daemon"
rmdir "$HOME/.config/OmertaDaemon" 2>/dev/null || true

# ~/.config/OmertaProvider/logs/
migrate_dir "$HOME/.config/OmertaProvider/logs" "$LOGS_DIR/provider"
rmdir "$HOME/.config/OmertaProvider" 2>/dev/null || true

# ~/.config/OmertaConsumer/logs/
migrate_dir "$HOME/.config/OmertaConsumer/logs" "$LOGS_DIR/consumer"
rmdir "$HOME/.config/OmertaConsumer" 2>/dev/null || true

echo ""
echo "3. Final structure:"
if command -v tree &>/dev/null; then
    tree -L 2 "$OMERTA_DIR" 2>/dev/null || ls -la "$OMERTA_DIR"
else
    ls -la "$OMERTA_DIR"
    echo ""
    ls -la "$MESH_DIR" 2>/dev/null || true
    echo ""
    ls -la "$LOGS_DIR" 2>/dev/null || true
fi

echo ""
echo "Migration complete!"
