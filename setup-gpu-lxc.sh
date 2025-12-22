#!/bin/bash
# Proxmox NVIDIA GPU LXC Passthrough Script
# Streamlined version of https://digitalspaceport.com/proxmox-lxc-docker-gpu-passthrough-setup-guide/

set -euo pipefail

echo "=== Proxmox NVIDIA GPU LXC Passthrough Setup ==="
echo "This script automates GPU passthrough to LXC containers for Docker/NVIDIA Container Toolkit"

# Check if running as root on Proxmox
if [[ $EUID -ne 0 ]]; then
   echo "Must run as root"
   exit 1
fi

if ! command -v pveversion &> /dev/null; then
    echo "This script must run on Proxmox host"
    exit 1
fi

# Get NVIDIA device info
if ! command -v nvidia-smi &> /dev/null; then
    echo "ERROR: NVIDIA drivers not detected. Install first with: apt install nvidia-driver"
    exit 1
fi

echo "NVIDIA GPU detected:"
nvidia-smi --query-gpu=name --format=csv,noheader

# Prompt for NVIDIA .run installer URL
read -p "Enter NVIDIA .run installer URL (default: 580.119.02): " NVIDIA_URL
NVIDIA_URL=${NVIDIA_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/580.119.02/NVIDIA-Linux-x86_64-580.119.02.run}
RUNFILE="NVIDIA-Linux-x86_64-580.119.02.run"

# List containers
echo -e "\nAvailable LXC containers:"
pct list | awk 'NR>1 {print $1" "$2}' | while read ID NAME; do
    if [[ $ID != "VMID" ]]; then
        echo "  $ID: $NAME"
    fi
done

read -p "Enter LXC container ID to configure: " CTID

if ! pct status $CTID &> /dev/null; then
    echo "ERROR: Container $CTID not found"
    exit 1
fi

CTNAME=$(pct list | awk -v id=$CTID '$1==id {print $2}')
echo "Configuring container: $CTID ($CTNAME)"

# Download NVIDIA driver to container
echo -e "\n=== Downloading NVIDIA driver to container ==="
pct push $CTID $NVIDIA_URL $RUNFILE -y
pct exec $CTID -- bash -c "chmod +x $RUNFILE"

# Get NVIDIA device nodes from host
echo "=== Detecting NVIDIA device nodes ==="
NVIDIA_DEVS=$(ls -la /dev/nvidia* /dev/nvidia-caps/* 2>/dev/null | grep -E 'nvidia[0-9]+|nvidiactl|nvidia-uvm|nvidia-uvm-tools|nvidia-cap[0-9]+' | awk '{print $9","$4","$5}' | sort -u)

if [[ -z "$NVIDIA_DEVS" ]]; then
    echo "ERROR: No NVIDIA devices found"
    exit 1
fi

echo "Found NVIDIA devices:"
echo "$NVIDIA_DEVS"

# Extract major numbers for cgroups
MAJORS=$(echo "$NVIDIA_DEVS" | cut -d, -f3 | cut -d: -f1 | sort -u | tr '\n' ' ')
echo "Major device numbers: $MAJORS"

# Stop container for config changes
echo -e "\n=== Stopping container for configuration ==="
pct stop $CTID

# Backup and modify LXC config
CONFIG="/etc/pve/lxc/$CTID.conf"
cp "$CONFIG" "${CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"

cat >> "$CONFIG" << EOF

# NVIDIA GPU Passthrough
lxc.cgroup2.devices.allow: ${MAJORS// / } rwm
EOF

# Add device mounts
while IFS=',' read -r DEV PERMS MAJOR_MINOR; do
    if [[ -n "$DEV" ]]; then
        MAJOR=$(echo "$MAJOR_MINOR" | cut -d: -f1)
        NAME=$(basename "$DEV")
        echo "lxc.mount.entry: /dev/$NAME dev/$NAME none bind,optional,create=file" >> "$CONFIG"
    fi
done <<< "$NVIDIA_DEVS"

echo "LXC config updated: $CONFIG"

# Install NVIDIA Container Toolkit inside container
echo -e "\n=== Installing NVIDIA Container Toolkit in container ==="
pct start $CTID
pct exec $CTID -- bash -c "
apt update && apt install -y gpg curl

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \\
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt update
apt install -y nvidia-container-toolkit

# Install NVIDIA driver WITHOUT kernel modules (host has them)
cd /root && ./$RUNFILE --no-kernel-modules --no-drm -a -s || true

# Configure nvidia-container-runtime
sed -i 's/no-cgroups = false/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml
systemctl restart docker || true
"

echo -e "\n=== GPU Passthrough Setup Complete! ==="
echo ""
echo "Container $CTID ($CTNAME) now has NVIDIA GPU access"
echo ""
echo "Test inside container:"
echo "  pct enter $CTID"
echo "  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi"
echo ""
echo "Config backup: ${CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
echo "Done!"
