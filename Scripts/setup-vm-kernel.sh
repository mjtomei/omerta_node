#!/bin/bash
set -e

OMERTA_DIR="$HOME/.omerta"
KERNEL_DIR="$OMERTA_DIR/kernel"

echo "Setting up Linux kernel for Omerta VMs..."

# Create directories
mkdir -p "$KERNEL_DIR"
cd "$KERNEL_DIR"

# Check if kernel already exists
if [ -f "vmlinuz" ]; then
    echo "✓ Kernel already exists at $KERNEL_DIR/vmlinuz"
    exit 0
fi

echo "Downloading minimal Linux kernel..."

# For MVP, we'll use a pre-built kernel from Ubuntu
# This is a minimal 5.x kernel suitable for virtualization
KERNEL_URL="https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-arm64-vmlinuz-generic"

if command -v curl &> /dev/null; then
    curl -L -o vmlinuz "$KERNEL_URL"
elif command -v wget &> /dev/null; then
    wget -O vmlinuz "$KERNEL_URL"
else
    echo "Error: Neither curl nor wget found. Please install one."
    exit 1
fi

echo "✓ Kernel downloaded to $KERNEL_DIR/vmlinuz"

# Create a minimal initramfs with busybox
echo "Creating minimal initramfs..."

INITRAMFS_DIR="$(mktemp -d)"
cd "$INITRAMFS_DIR"

# Create directory structure
mkdir -p bin sbin etc proc sys dev tmp

# Create init script that will execute our workload
cat > init << 'INIT_EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# Check if we have a script to execute
if [ -f /workload.sh ]; then
    echo "Executing workload..."
    sh /workload.sh
    EXIT_CODE=$?
    echo "EXIT_CODE:$EXIT_CODE"
else
    echo "No workload found, dropping to shell"
    /bin/sh
fi

# Shutdown
poweroff -f
INIT_EOF

chmod +x init

# For MVP, we'll use a statically compiled busybox
# In production, we'd build this ourselves or include it in the repo
echo "Note: For full functionality, busybox binary is needed."
echo "For now, using basic init script only."

# Create the initramfs
find . | cpio -o -H newc | gzip > "$KERNEL_DIR/initramfs.gz"

cd "$KERNEL_DIR"
rm -rf "$INITRAMFS_DIR"

echo "✓ Initramfs created at $KERNEL_DIR/initramfs.gz"
echo ""
echo "Setup complete! VM kernel ready at:"
echo "  Kernel: $KERNEL_DIR/vmlinuz"
echo "  Initramfs: $KERNEL_DIR/initramfs.gz"
