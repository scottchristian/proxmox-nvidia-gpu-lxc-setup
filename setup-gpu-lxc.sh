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

# Check for NVIDIA GPU hardware
echo "Checking for NVIDIA GPU hardware..."
if ! lspci -n | grep -q "10de:"; then
    echo "ERROR: No NVIDIA GPU hardware detected on this machine."
    exit 1
fi
echo "✓ NVIDIA GPU hardware detected."

# Get NVIDIA device info
if ! command -v nvidia-smi &> /dev/null || ! [ -f /proc/driver/nvidia/version ]; then
    echo "NVIDIA drivers not detected or not functioning on Proxmox host."
    read -p "Would you like to install them now? (y/n): " INSTALL_HOST_DRIVERS
    if [[ "$INSTALL_HOST_DRIVERS" =~ ^[Yy]$ ]]; then
        echo "Choose installation method:"
        echo "1) Add repository and install (Recommended for Proxmox/Debian)"
        echo "2) Download and install latest .run file"
        read -p "Selection [1-2]: " INSTALL_METHOD
        
        case $INSTALL_METHOD in
            1)
                echo "Adding non-free repositories and installing nvidia-driver..."
                # Add contrib and non-free for Debian (Proxmox is based on Debian)
                apt update && apt install -y software-properties-common
                add-apt-repository -y contrib non-free-firmware || true
                # Fallback for older Debian/Proxmox versions if add-apt-repository fails
                if ! grep -q "non-free-firmware" /etc/apt/sources.list; then
                    sed -i 's/main/main contrib non-free non-free-firmware/g' /etc/apt/sources.list
                fi
                apt update
                apt install -y pve-headers nvidia-driver
                echo "✓ Drivers installed via repository. A reboot is highly recommended."
                ;;
            2)
                read -p "Enter NVIDIA .run installer URL (default: 580.119.02): " NVIDIA_URL
                NVIDIA_URL=${NVIDIA_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/580.119.02/NVIDIA-Linux-x86_64-580.119.02.run}
                RUNFILE="NVIDIA-Linux-host-x86_64.run"
                echo "Downloading NVIDIA driver..."
                curl -L "$NVIDIA_URL" -o "/tmp/$RUNFILE"
                chmod +x "/tmp/$RUNFILE"
                echo "Installing NVIDIA driver..."
                /tmp/$RUNFILE -a -s
                echo "✓ Drivers installed via .run file. A reboot is highly recommended."
                ;;
            *)
                echo "Invalid selection. Exiting."
                exit 1
                ;;
        esac
        # Re-check for nvidia-smi and driver
        if ! command -v nvidia-smi &> /dev/null || ! [ -f /proc/driver/nvidia/version ]; then
            echo "ERROR: NVIDIA drivers installation failed or requires a reboot."
            exit 1
        fi
    else
        echo "Drivers must be installed on the host first. Exiting."
        exit 1
    fi
fi

echo "NVIDIA GPU detected on host:"
nvidia-smi --query-gpu=name --format=csv,noheader

# List containers
echo -e "\nAvailable LXC containers:"
pct list | awk 'NR>1 {printf "  %-8s %s\n", $1, $3}'

read -p "Enter LXC container ID to configure: " CTID

if ! pct status $CTID &> /dev/null; then
    echo "ERROR: Container $CTID not found"
    exit 1
fi

CTNAME=$(pct list | awk -v id=$CTID '$1==id {print $2}')
echo "Configuring container: $CTID ($CTNAME)"

# Check if container is running
CONTAINER_RUNNING=false
if pct status $CTID | grep -q "running"; then
    CONTAINER_RUNNING=true
    echo "Container is currently running"
else
    echo "Container is stopped"
fi

# Check if GPU is already working in container
echo -e "\n=== Checking current GPU status in container ==="
GPU_ALREADY_WORKING=false

if $CONTAINER_RUNNING; then
    if pct exec $CTID -- nvidia-smi &> /dev/null; then
        echo "✓ GPU is already accessible and working in container!"
        GPU_ALREADY_WORKING=true
    else
        echo "✗ GPU not currently accessible in container"
    fi
else
    echo "Container stopped - will check configuration"
fi

# Get NVIDIA device nodes from host
echo -e "\n=== Detecting NVIDIA device nodes on host ==="
NVIDIA_DEVS=$(ls -la /dev/nvidia* /dev/nvidia-caps/* 2>/dev/null | grep -E 'nvidia[0-9]+|nvidiactl|nvidia-uvm|nvidia-uvm-tools|nvidia-cap[0-9]+' | awk '{print $9","$4","$5}' | sort -u)

if [[ -z "$NVIDIA_DEVS" ]]; then
    echo "ERROR: No NVIDIA devices found on host"
    exit 1
fi

echo "Found NVIDIA devices:"
echo "$NVIDIA_DEVS"

# Extract major numbers for cgroups
MAJORS=$(echo "$NVIDIA_DEVS" | cut -d, -f3 | cut -d: -f1 | sort -u | tr '\n' ' ')
echo "Major device numbers: $MAJORS"

# Check existing LXC config
CONFIG="/etc/pve/lxc/$CTID.conf"
CONFIG_NEEDS_UPDATE=false

echo -e "\n=== Checking existing LXC configuration ==="
if grep -q "NVIDIA GPU Passthrough" "$CONFIG" 2>/dev/null; then
    echo "✓ GPU passthrough configuration already exists in LXC config"
    
    # Check if all required devices are present
    MISSING_DEVICES=false
    while IFS=',' read -r DEV PERMS MAJOR_MINOR; do
        if [[ -n "$DEV" ]]; then
            NAME=$(basename "$DEV")
            if ! grep -q "lxc.mount.entry.*$NAME" "$CONFIG"; then
                echo "✗ Missing device mount: $NAME"
                MISSING_DEVICES=true
            fi
        fi
    done <<< "$NVIDIA_DEVS"
    
    if $MISSING_DEVICES; then
        echo "Some devices are missing from config - will update"
        CONFIG_NEEDS_UPDATE=true
    else
        echo "✓ All GPU devices are configured"
    fi
else
    echo "✗ No GPU passthrough configuration found"
    CONFIG_NEEDS_UPDATE=true
fi

# Update config if needed
if $CONFIG_NEEDS_UPDATE; then
    echo -e "\n=== Updating LXC configuration ==="
    
    # Stop container if running
    if $CONTAINER_RUNNING; then
        echo "Stopping container for configuration changes..."
        pct stop $CTID
        CONTAINER_RUNNING=false
    fi
    
    # Backup config
    cp "$CONFIG" "${CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "Created config backup"
    
    # Remove old GPU config if exists
    sed -i '/# NVIDIA GPU Passthrough/,/^$/d' "$CONFIG"
    
    # Add new GPU config
    cat >> "$CONFIG" << EOF

# NVIDIA GPU Passthrough
lxc.cgroup2.devices.allow: ${MAJORS// / } rwm
EOF

    # Add device mounts
    while IFS=',' read -r DEV PERMS MAJOR_MINOR; do
        if [[ -n "$DEV" ]]; then
            NAME=$(basename "$DEV")
            echo "lxc.mount.entry: /dev/$NAME dev/$NAME none bind,optional,create=file" >> "$CONFIG"
        fi
    done <<< "$NVIDIA_DEVS"
    
    echo "✓ LXC config updated: $CONFIG"
else
    echo -e "\n✓ LXC configuration is already correct - no changes needed"
fi

# Check if NVIDIA drivers/toolkit need installation in container
NEEDS_DRIVER_INSTALL=false
NEEDS_TOOLKIT_INSTALL=false

if ! $CONTAINER_RUNNING; then
    echo -e "\n=== Starting container to check software installation ==="
    pct start $CTID
    sleep 3
    CONTAINER_RUNNING=true
fi

echo -e "\n=== Checking NVIDIA software in container ==="

# Check for nvidia-smi
if pct exec $CTID -- which nvidia-smi &> /dev/null; then
    echo "✓ NVIDIA drivers already installed in container"
else
    echo "✗ NVIDIA drivers not found in container"
    NEEDS_DRIVER_INSTALL=true
fi

# Check for nvidia-container-toolkit
if pct exec $CTID -- which nvidia-container-runtime &> /dev/null; then
    echo "✓ NVIDIA Container Toolkit already installed"
else
    echo "✗ NVIDIA Container Toolkit not found"
    NEEDS_TOOLKIT_INSTALL=true
fi

# Install missing components
if $NEEDS_DRIVER_INSTALL || $NEEDS_TOOLKIT_INSTALL; then
    echo -e "\n=== Installing missing NVIDIA components ==="
    
    if $NEEDS_DRIVER_INSTALL; then
        # Prompt for NVIDIA .run installer URL
        read -p "Enter NVIDIA .run installer URL (default: 580.119.02): " NVIDIA_URL
        NVIDIA_URL=${NVIDIA_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/580.119.02/NVIDIA-Linux-x86_64-580.119.02.run}
        RUNFILE="NVIDIA-Linux-x86_64-580.119.02.run"
        
        echo "Downloading NVIDIA driver to container..."
        pct push $CTID $NVIDIA_URL $RUNFILE -y
        pct exec $CTID -- bash -c "chmod +x $RUNFILE"
        
        echo "Installing NVIDIA driver (without kernel modules)..."
        pct exec $CTID -- bash -c "cd /root && ./$RUNFILE --no-kernel-modules --no-drm -a -s || true"
        echo "✓ NVIDIA driver installed"
    fi
    
    if $NEEDS_TOOLKIT_INSTALL; then
        echo "Installing NVIDIA Container Toolkit..."
        pct exec $CTID -- bash -c "
apt update && apt install -y gpg curl

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \\
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt update
apt install -y nvidia-container-toolkit

# Configure nvidia-container-runtime
sed -i 's/no-cgroups = false/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml
systemctl restart docker || true
"
        echo "✓ NVIDIA Container Toolkit installed"
    fi
else
    echo -e "\n✓ All required software is already installed"
fi

# Prompt for restart if config changed
if $CONFIG_NEEDS_UPDATE; then
    echo -e "\n=== Configuration changes were made ==="
    read -p "Container restart required for changes to take effect. Restart now? (y/n): " RESTART_CHOICE
    
    if [[ "$RESTART_CHOICE" =~ ^[Yy]$ ]]; then
        echo "Restarting container..."
        pct stop $CTID
        sleep 2
        pct start $CTID
        sleep 3
        echo "✓ Container restarted"
    else
        echo "Skipping restart. You'll need to restart manually for changes to take effect."
    fi
fi

# Verify GPU access
echo -e "\n=== Verifying GPU Access ==="
read -p "Run nvidia-smi in container to verify GPU access? (y/n): " VERIFY_CHOICE

if [[ "$VERIFY_CHOICE" =~ ^[Yy]$ ]]; then
    echo -e "\n--- Running nvidia-smi in container ---"
    if pct exec $CTID -- nvidia-smi; then
        echo -e "\n✓ GPU verification successful!"
    else
        echo -e "\n✗ GPU verification failed. You may need to restart the container."
    fi
fi

echo -e "\n=== Setup Complete! ==="
echo ""
if $GPU_ALREADY_WORKING && ! $CONFIG_NEEDS_UPDATE; then
    echo "✓ GPU was already working - no changes were needed"
else
    echo "✓ Container $CTID ($CTNAME) is configured for NVIDIA GPU access"
fi
echo ""
echo "Test commands:"
echo "  pct enter $CTID"
echo "  nvidia-smi"
echo "  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi"
echo ""
echo "Done!"
