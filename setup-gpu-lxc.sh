#!/bin/bash
# Proxmox NVIDIA GPU LXC Passthrough Script
# Streamlined version of https://digitalspaceport.com/proxmox-lxc-docker-gpu-passthrough-setup-guide/

set -euo pipefail

# Ensure robust PATH for cron/@reboot
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Wait for PVE tools to become available (boot safety)
PVE_WAIT_TIMEOUT=300
PVE_WAIT_ELAPSED=0
while ! command -v pveversion &> /dev/null && [ $PVE_WAIT_ELAPSED -lt $PVE_WAIT_TIMEOUT ]; do
    echo "Waiting for Proxmox management tools... ($PVE_WAIT_ELAPSED/${PVE_WAIT_TIMEOUT}s)"
    sleep 5
    PVE_WAIT_ELAPSED=$((PVE_WAIT_ELAPSED + 5))
done

echo "=== Proxmox NVIDIA GPU LXC Passthrough Setup ==="
echo "This script automates GPU passthrough to LXC containers for Docker/NVIDIA Container Toolkit"

# Check if running as root on Proxmox
if [[ $EUID -ne 0 ]]; then
   echo "Must run as root"
   exit 1
fi

VERSION="1.2.0"
GITHUB_RAW_URL="https://raw.githubusercontent.com/scottchristian/proxmox-nvidia-gpu-lxc-setup/refs/heads/main/setup-gpu-lxc.sh"

# --- Script Update Check ---
# Non-blocking check for a newer version on GitHub
(
    REMOTE_VERSION=$(curl -s --connect-timeout 2 "$GITHUB_RAW_URL" | grep -oE 'VERSION="[0-9.]+"' | cut -d'"' -f2 | head -n 1)
    if [[ -n "$REMOTE_VERSION" && "$REMOTE_VERSION" != "$VERSION" ]]; then
        echo -e "\n\033[1;33m[*] A new version of this script is available: $REMOTE_VERSION (Current: $VERSION)\033[0m"
        echo "Update with: wget -O $0 $GITHUB_RAW_URL"
    fi
) &

# --- Argument Parsing ---
CTID=""
HOST_METHOD=""
DRIVER_URL=""
LOG_DIR=""
NO_REBOOT=false
NO_VERIFY=false

show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -c, --container-id ID      LXC Container ID to configure"
    echo "  -m, --install-method TYPE  Host driver install method: 'repo', 'run', or 'skip'"
    echo "  -u, --driver-url URL       Specific NVIDIA .run installer URL"
    echo "  -l, --log-dir DIR          Directory to save execution logs"
    echo "  --no-reboot                Disable automatic container reboots"
    echo "  --no-verify                Skip final nvidia-smi verification"
    echo "  -h, --help                 Show this help message"
    exit 0
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -c|--container-id) CTID="$2"; shift ;;
        -m|--install-method) HOST_METHOD="$2"; shift ;;
        -u|--driver-url) DRIVER_URL="$2"; shift ;;
        -l|--log-dir) LOG_DIR="$2"; shift ;;
        --no-reboot) NO_REBOOT=true ;;
        --no-verify) NO_VERIFY=true ;;
        -h|--help) show_help ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# --- Logging Setup ---
SCRIPT_DIR=$(dirname "$(realpath "$0")")
if [[ -z "$LOG_DIR" ]]; then
    LOG_DIR="$SCRIPT_DIR/setup-gpu-lxc-logs"
fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/nvidia-lxc-setup-$(date +%Y%m%d_%H%M%S).log"
echo "Logging to $LOG_FILE"

# Start redirection
exec > >(tee -a "$LOG_FILE") 2>&1

echo "--- Setup started: $(date) ---"

# Trap to print the stop timestamp on exit
trap 'echo -e "\n--- Setup finished: $(date) ---"' EXIT

# Track choices for cron suggestion
CRON_ARGS=""
[[ -n "$LOG_DIR" ]] && CRON_ARGS+=" --log-dir $LOG_DIR"
[[ "$NO_REBOOT" == true ]] && CRON_ARGS+=" --no-reboot"
[[ "$NO_VERIFY" == true ]] && CRON_ARGS+=" --no-verify"

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

# Check for NVIDIA drivers on host
if ! command -v nvidia-smi &> /dev/null || ! [ -f /proc/driver/nvidia/version ]; then
    echo "✗ NVIDIA drivers not found or not working on host."
    
    if [[ -z "$HOST_METHOD" ]]; then
        echo "Choose installation method:"
        echo "1) Add repository and install (Recommended for Proxmox/Debian)"
        echo "2) Download and install latest .run file (if you run into issues with Option 1)"
        echo "3) Skip host driver installation"
        read -p "Selection [1-3]: " INSTALL_CHOICE
        case $INSTALL_CHOICE in
            1) HOST_METHOD="repo" ;;
            2) HOST_METHOD="run" ;;
            3) HOST_METHOD="skip" ;;
            *) echo "Invalid selection. Exiting."; exit 1 ;;
        esac
    fi
    
    CRON_ARGS+=" --install-method $HOST_METHOD"
    
    case "$HOST_METHOD" in
        "repo")
                echo "Ensuring contrib, non-free, and non-free-firmware repositories are enabled..."
                # More robust way: clean existing components and re-add them after 'main'
                for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
                    if [ -f "$file" ]; then
                        # Clean existing instances to avoid duplicates
                        sed -i '/^deb/ s/[[:space:]]\+\(contrib\|non-free\|non-free-firmware\)//g' "$file"
                        # Add them after 'main'
                        sed -i '/^deb/ s/main/main contrib non-free non-free-firmware/g' "$file"
                    fi
                done
                # Handle DEB822 format (.sources)
                if ls /etc/apt/sources.list.d/*.sources &> /dev/null; then
                    for file in /etc/apt/sources.list.d/*.sources; do
                        # Clean existing
                        sed -i '/^Components:/ s/[[:space:]]\+\(contrib\|non-free\|non-free-firmware\)//g' "$file"
                        # Add them
                        sed -i '/^Components:/ s/main/main contrib non-free non-free-firmware/g' "$file"
                    done
                fi
                apt update
                echo "Installing NVIDIA driver and headers..."
                apt install -y pve-headers nvidia-driver || apt install -y linux-headers-amd64 nvidia-driver || apt install -y nvidia-kernel-dkms nvidia-driver
                echo "✓ Drivers installed via repository. A reboot is highly recommended."
                ;;
            "run")
                echo -e "\nFetching available NVIDIA driver branches..."
                # Extract all version numbers from the directory listing
                RAW_VERSIONS=$(curl -s https://download.nvidia.com/XFree86/Linux-x86_64/ | grep -oE '[0-9]{3,}\.[0-9]+(\.[0-9]+)?/' | sed 's/\///' | sort -Vr | uniq)
                # Extract unique major branches (e.g., 595, 580, 550, 470)
                BRANCHES=$(echo "$RAW_VERSIONS" | cut -d. -f1 | uniq | head -n 8)
                NVIDIA_URL=""
                if [[ -n "$DRIVER_URL" ]]; then
                    NVIDIA_URL="$DRIVER_URL"
                    echo "Using provided NVIDIA driver URL: $NVIDIA_URL"
                elif [[ -n "$BRANCHES" ]]; then
                    GPU_INFO=$(lspci | grep -i nvidia | head -n 1)
                    echo -e "\nDetected GPU: $(echo "$GPU_INFO" | cut -d: -f3- | xargs)"
                    
                    # Architecture detection and recommendation for 2026
                    RECOMMENDED=""
                    ARCH_NAME=""
                    if echo "$GPU_INFO" | grep -qi "GK"; then RECOMMENDED="470"; ARCH_NAME="Kepler (Legacy)"
                    elif echo "$GPU_INFO" | grep -qi "GM"; then RECOMMENDED="580"; ARCH_NAME="Maxwell (Legacy Security)"
                    elif echo "$GPU_INFO" | grep -qi "GP"; then RECOMMENDED="580"; ARCH_NAME="Pascal (Legacy Security)"
                    elif echo "$GPU_INFO" | grep -qi "GV"; then RECOMMENDED="580"; ARCH_NAME="Volta (Legacy Security)"
                    else RECOMMENDED=$(echo "$BRANCHES" | head -n 1); ARCH_NAME="Modern (Turing+)"
                    fi
                    
                    select BRANCH in $BRANCHES "Manual URL Entry"; do
                        if [[ "$BRANCH" == "Manual URL Entry" ]]; then
                            echo -e "\nTo find a URL manually:"
                            echo "1. Go to: https://www.nvidia.com/en-us/drivers/unix/linux-amd64-display-archive/"
                            echo "2. Right-click the 'Download' link for your desired version and 'Copy Link Address'"
                            echo "Example URL: https://us.download.nvidia.com/XFree86/Linux-x86_64/550.163.01/NVIDIA-Linux-x86_64-550.163.01.run"
                            read -p "Enter NVIDIA .run installer URL: " NVIDIA_URL
                            break
                        elif [[ -n "$BRANCH" ]]; then
                            # Get the latest version within the selected branch
                            VERSION=$(echo "$RAW_VERSIONS" | grep "^$BRANCH\." | head -n 1)
                            NVIDIA_URL="https://download.nvidia.com/XFree86/Linux-x86_64/$VERSION/NVIDIA-Linux-x86_64-$VERSION.run"
                            echo "Selected latest version $VERSION from branch $BRANCH."
                            break
                        fi
                    done
                else
                    echo "Could not fetch branches automatically."
                    read -p "Enter NVIDIA .run installer URL: " NVIDIA_URL
                fi

                if [[ -z "$NVIDIA_URL" ]]; then
                    echo "No URL selected. Exiting."
                    exit 1
                fi

                RUNFILE=$(basename "$NVIDIA_URL")
                echo "Downloading NVIDIA driver ($RUNFILE)..."
                curl -L "$NVIDIA_URL" -o "/tmp/$RUNFILE"
                chmod +x "/tmp/$RUNFILE"
                echo "Installing NVIDIA driver..."
                /tmp/$RUNFILE -a -s
                echo "✓ Drivers installed via .run file. A reboot is highly recommended."
                ;;
            "skip")
                echo "Skipping host driver installation."
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
fi

echo "NVIDIA GPU detected on host:"
nvidia-smi --query-gpu=name --format=csv,noheader

# Container selection
if [[ -z "$CTID" ]]; then
    echo -e "\nAvailable LXC containers:"
    pct list | awk 'NR>1 {printf "  %-8s %s\n", $1, $NF}'
    read -p "Enter LXC container ID to configure: " CTID
else
    echo "Using provided Container ID: $CTID"
fi

CRON_ARGS+=" --container-id $CTID"

# --- Container Wait Loop (Boot Safety) ---
MAX_WAIT=600
ELAPSED=0
CHECK_INTERVAL=15

if [[ ! -f "/etc/pve/lxc/${CTID}.conf" ]]; then
    echo "Waiting for container $CTID configuration to appear in /etc/pve/lxc/..."
    while [[ $ELAPSED -lt $MAX_WAIT ]]; do
        if [[ -f "/etc/pve/lxc/${CTID}.conf" ]]; then
            echo "✓ Container $CTID configuration found."
            break
        fi
        sleep $CHECK_INTERVAL
        ELAPSED=$((ELAPSED + CHECK_INTERVAL))
        echo "  Still waiting for config file /etc/pve/lxc/${CTID}.conf... ($ELAPSED/${MAX_WAIT}s)"
    done
fi

if [[ ! -f "/etc/pve/lxc/${CTID}.conf" ]]; then
    echo "ERROR: Container $CTID configuration not found after ${MAX_WAIT}s. Exiting."
    exit 1
fi

CTNAME=$(pct list | awk -v id=$CTID '$1==id {print $NF}')
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
if grep -q "# --- NVIDIA GPU Passthrough START ---" "$CONFIG" 2>/dev/null; then
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
    echo -e "\n=== Updating LXC configuration with Rollback Safety ==="
    
    # Store original state
    WAS_RUNNING=$CONTAINER_RUNNING
    
    # Stop container if running
    if $CONTAINER_RUNNING; then
        echo "Stopping container for configuration changes..."
        pct stop $CTID
        CONTAINER_RUNNING=false
    fi
    
    # Backup config to temporary location
    TEMP_BACKUP="/tmp/lxc_${CTID}_$(date +%Y%m%d_%H%M%S).conf"
    cp "$CONFIG" "$TEMP_BACKUP"
    # Also keep a backup in the PVE directory for user reference
    cp "$CONFIG" "${CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "Created config backup at $TEMP_BACKUP"
    
    # Ensure the config file ends with a newline before we append
    [[ -n $(tail -c1 "$CONFIG") ]] && echo "" >> "$CONFIG"
    
    # Remove old GPU config if exists (use more specific markers for safety)
    sed -i '/# --- NVIDIA GPU Passthrough START ---/,/# --- NVIDIA GPU Passthrough END ---/d' "$CONFIG"
    
    # Add new GPU config with clear markers
    cat >> "$CONFIG" << EOF

# --- NVIDIA GPU Passthrough START ---
lxc.cgroup2.devices.allow: ${MAJORS// / } rwm
EOF

    # Add device mounts
    while IFS=',' read -r DEV PERMS MAJOR_MINOR; do
        if [[ -n "$DEV" ]]; then
            NAME=$(basename "$DEV")
            echo "lxc.mount.entry: /dev/$NAME dev/$NAME none bind,optional,create=file" >> "$CONFIG"
        fi
    done <<< "$NVIDIA_DEVS"
    
    echo "# --- NVIDIA GPU Passthrough END ---" >> "$CONFIG"
    
    echo "LXC config applied. Verifying container start..."
    
    # Attempt to start the container to verify the config
    if ! pct start $CTID &> /tmp/lxc_start_error.log; then
        echo -e "\n\033[1;31mERROR: Container failed to start with the new configuration!\033[0m"
        echo "Error message: $(cat /tmp/lxc_start_error.log)"
        echo "Triggering automatic rollback..."
        cp "$TEMP_BACKUP" "$CONFIG"
        echo "✓ Configuration rolled back to previous working state."
        exit 1
    else
        echo "✓ Container started successfully. Configuration verified."
        CONTAINER_RUNNING=true
        # We'll leave it running for software checks in the next step
    fi
else
    echo -e "\n✓ LXC configuration is already correct - no changes needed"
fi

# Detect host driver version for parity check
# Supports both 2-part (580.142) and 3-part (535.154.05) versions
HOST_NVIDIA_VER=$(grep "Kernel Module" /proc/driver/nvidia/version 2>/dev/null | grep -oE '[0-9]{3,}\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)

# Check if NVIDIA drivers/toolkit need installation in container
NEEDS_DRIVER_INSTALL=false
NEEDS_TOOLKIT_INSTALL=false

# Container is already running if config was updated, otherwise start it
if ! $CONTAINER_RUNNING; then
    echo -e "\n=== Starting container to check software installation ==="
    pct start $CTID
    sleep 3
    CONTAINER_RUNNING=true
fi

echo -e "\n=== Checking NVIDIA software in container ==="
echo "Detected Host Driver: ${HOST_NVIDIA_VER:-Unknown}"

# Check for nvidia-smi and version parity
if pct exec $CTID -- which nvidia-smi &> /dev/null; then
    # Capture both stdout and stderr since NVML errors often go to stdout in this context
    CONT_OUTPUT=$(pct exec $CTID -- nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>&1 | head -n 1 || true)
    
    if [[ "$CONT_OUTPUT" == *"Failed to initialize NVML"* ]]; then
        echo -e "\033[1;33m✗ Driver mismatch detected (NVML Initialization Failed)!\033[0m"
        NEEDS_DRIVER_INSTALL=true
    elif [[ -n "$HOST_NVIDIA_VER" && "$CONT_OUTPUT" != "$HOST_NVIDIA_VER" ]]; then
        echo -e "\033[1;33m✗ Driver version mismatch detected!\033[0m"
        echo "Host: $HOST_NVIDIA_VER | Container: $CONT_OUTPUT"
        NEEDS_DRIVER_INSTALL=true
    else
        echo "✓ NVIDIA drivers already installed in container ($CONT_OUTPUT)"
    fi
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
        # Use the same driver version as the host for consistency
        if [[ -n "$HOST_NVIDIA_VER" ]]; then
            echo "Host driver version $HOST_NVIDIA_VER detected. Using for container parity."
            PRIMARY_URL="https://download.nvidia.com/XFree86/Linux-x86_64/$HOST_NVIDIA_VER/NVIDIA-Linux-x86_64-$HOST_NVIDIA_VER.run"
            FALLBACK_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/$HOST_NVIDIA_VER/NVIDIA-Linux-x86_64-$HOST_NVIDIA_VER.run"
            RUN_FILE_BASE="NVIDIA-Linux-x86_64-$HOST_NVIDIA_VER.run"
            
            echo "Downloading driver version $HOST_NVIDIA_VER to host /tmp..."
            if ! wget -q --show-progress -O "/tmp/$RUN_FILE_BASE" "$PRIMARY_URL"; then
                echo "Primary download failed, trying fallback URL..."
                if ! wget -q --show-progress -O "/tmp/$RUN_FILE_BASE" "$FALLBACK_URL"; then
                    echo -e "\033[1;31mERROR: Failed to download NVIDIA driver version $HOST_NVIDIA_VER from any known location.\033[0m"
                    echo "Please find the .run installer URL manually at: https://www.nvidia.com/en-us/drivers/unix/linux-amd64-display-archive/"
                    read -p "Enter manual .run installer URL: " MANUAL_URL
                    if ! wget -q --show-progress -O "/tmp/$RUN_FILE_BASE" "$MANUAL_URL"; then
                        echo "Manual download also failed. Exiting."
                        exit 1
                    fi
                fi
            fi
        else
            # Fallback to manual prompt if host detection failed
            CONTAINER_DRIVER_URL=${NVIDIA_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/580.119.02/NVIDIA-Linux-x86_64-580.119.02.run}
            read -p "Enter NVIDIA .run installer URL for container (default: $CONTAINER_DRIVER_URL): " DRIVER_URL
            DRIVER_URL=${DRIVER_URL:-$CONTAINER_DRIVER_URL}
            RUN_FILE_BASE=$(basename "$DRIVER_URL")
            wget -q --show-progress -O "/tmp/$RUN_FILE_BASE" "$DRIVER_URL"
        fi
        
        echo "Pushing driver installer to container..."
        pct push $CTID "/tmp/$RUN_FILE_BASE" "/root/$RUN_FILE_BASE"
        rm -f "/tmp/$RUN_FILE_BASE"  # Cleanup host
        
        pct exec $CTID -- bash -c "chmod +x /root/$RUN_FILE_BASE"
        
        echo "Installing NVIDIA driver in container (without kernel modules)..."
        pct exec $CTID -- bash -c "cd /root && ./$RUN_FILE_BASE --no-kernel-modules --no-drm -a -s || true"
        echo "✓ NVIDIA driver installed in container"
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

# No restart prompt needed as we already verified start above

# Verify GPU access
if [[ "$NO_VERIFY" != true ]]; then
    echo -e "\n=== Verifying GPU Access ==="
    while true; do
        echo -e "--- Running nvidia-smi in container $CTID ---"
        if pct exec $CTID -- nvidia-smi; then
            echo -e "\n\033[1;32m✓ GPU verification successful!\033[0m"
            break
        else
            echo -e "\n\033[1;33m✗ GPU verification failed.\033[0m"
            echo "Note: 'Driver/library version mismatch' usually requires a full container reboot."
            
            if [[ "$NO_REBOOT" == true ]]; then
                echo "Automatic reboot disabled. Skipping."
                break
            fi

            read -p "Would you like to reboot the container and try again? (y/n): " REBOOT_CHOICE
            if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
                echo "Rebooting container $CTID..."
                pct stop $CTID
                sleep 2
                pct start $CTID
                sleep 3
                # Loop continues to verify again
            else
                break
            fi
        fi
    done
fi

# Final summary
FINAL_STATUS=$(pct status $CTID | cut -d: -f2 | xargs)
echo -e "\n=== Setup Complete! ==="
echo ""
if [[ "$GPU_ALREADY_WORKING" == true ]] && [[ "$CONFIG_NEEDS_UPDATE" == false ]]; then
    echo "✓ GPU was already working - no changes were needed"
else
    echo "✓ Container $CTID ($CTNAME) is now configured for NVIDIA GPU access"
    echo "  Status: $FINAL_STATUS"
fi

# Construct cron command
# Use absolute path for the script
SCRIPT_PATH=$(realpath "$0")
CRON_CMD="$SCRIPT_PATH $CRON_ARGS"

echo -e "\n\033[1;36m=== Automation & Cron Support ===\033[0m"
echo "To automate this setup (e.g., after kernel updates):"
echo "1. Run: crontab -e"
echo "2. Add this line to the bottom of the file:"
echo -e "\n  \033[1;33m@reboot $CRON_CMD\033[0m"
echo -e "\nAlternatively, run this manually for the same configuration:"
echo -e "  \033[1;33m$CRON_CMD\033[0m"
echo ""
echo "Test commands:"
echo "  pct enter $CTID"
echo "  nvidia-smi"
echo "  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi"
echo ""
echo "Done!"
