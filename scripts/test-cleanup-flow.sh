#!/bin/bash
# Test the full cleanup flow
set -e

cd ~/omerta

CLI=".build/debug/omerta"

echo "=== Omerta Cleanup Flow Test ==="
echo ""

# Step 1: Clean up any existing state
echo "Step 1: Cleaning up existing state..."
sudo $CLI vm cleanup --all --force 2>&1 || true
echo ""

# Step 2: Make sure omertad is running
echo "Step 2: Checking omertad..."
if ! pgrep -f omertad > /dev/null; then
    echo "Starting omertad..."
    nohup .build/debug/omertad start --port 51820 \
        --network-key 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
        > /tmp/omertad.log 2>&1 &
    sleep 2
fi
echo "omertad is running"
echo ""

# Step 3: Request a VM
echo "Step 3: Requesting VM..."
sudo $CLI vm request \
    --provider 127.0.0.1:51820 \
    --network-key 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    --cpu 2 --memory 2048
echo ""

# Step 4: Check cleanup status (dry-run)
echo "Step 4: Checking cleanup status..."
sudo $CLI vm cleanup --dry-run
echo ""

# Step 5: List VMs
echo "Step 5: Listing VMs..."
$CLI vm list
echo ""

# Step 6: Clean up
echo "Step 6: Cleaning up..."
sudo $CLI vm cleanup --all --force
echo ""

# Step 7: Verify clean state
echo "Step 7: Verifying clean state..."
sudo $CLI vm cleanup --dry-run
echo ""

echo "=== Test Complete ==="
