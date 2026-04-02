# Proxmox NVIDIA GPU LXC Passthrough Setup

[![GitHub stars](https://img.shields.io/github/stars/scottchristian/proxmox-nvidia-gpu-lxc-setup)](https://github.com/scottchristian/proxmox-nvidia-gpu-lxc-setup/stars)
[![GitHub issues](https://img.shields.io/github/issues/scottchristian/proxmox-nvidia-gpu-lxc-setup)](https://github.com/scottchristian/proxmox-nvidia-gpu-lxc-setup/issues)

**One-command NVIDIA GPU passthrough for Proxmox LXC containers!**

## Features
- ✅ **Update Detection**: Built-in VERSION tracking; checks GitHub for newer versions on startup
- ✅ **Hardware Detection**: Auto-detects NVIDIA devices & cgroups on host
- ✅ **Smart Driver Selection**: Branch-based .run selection with Architecture recommendation (Pascal, Maxwell, etc.)
- ✅ **Interactive container selection**: Easily pick from a list of containers (with name support)
- ✅ **Safe Config Update**: Surgical LXC configuration with markers and **Automatic Rollback** on failure
- ✅ **Version Parity**: Enforces matching driver versions between host/container (Host-to-Container transfer)
- ✅ **NVIDIA Container Toolkit setup**: Automated installation and cgroup-friendly configuration
- ✅ **Automated Verification**: Automatic `nvidia-smi` run with reboot recovery option
- ✅ **Automation & Cron**: Full command-line argument support for non-interactive `@reboot` execution

## Usage
On the Proxmox host, download and run the script:
```bash
wget https://raw.githubusercontent.com/scottchristian/proxmox-nvidia-gpu-lxc-setup/refs/heads/main/setup-gpu-lxc.sh -O ~/setup-gpu-lxc.sh
chmod +x ~/setup-gpu-lxc.sh
~/setup-gpu-lxc.sh
```

### Automation & Cron
The script supports arguments for non-interactive use. To handle kernel updates automatically, run `crontab -e` and add:
```bash
@reboot /root/setup-gpu-lxc.sh --container-id 103 --install-method repo
```
The script includes built-in **Boot-Safety** logic: it will wait for up to 10 minutes for the Proxmox tools (`pct`) and your container configuration to be ready after a host reboot.

### Logging
The script automatically logs its execution to a `setup-gpu-lxc-logs/` directory next to the script. Logs include start/stop timestamps and full execution details.

## How it Works
The script follows a systematic approach:
1.  **Validation**: Ensures it is on Proxmox, as root, and checks for NVIDIA hardware.
2.  **Update Check**: Non-blocking check for a newer version on GitHub.
3.  **Host Driver Check**: Installs drivers (Repo or .run) if functional ones are missing.
4.  **LXC Selection**: Prompts for ID and identifies the container name.
5.  **Config & Safety**: Surgically adds GPU rules; **Rollback** occurs if the container fails to start.
6.  **Version Sync**: Detects host version and pushes matching drivers to the container if needed.
7.  **Verification**: Runs `nvidia-smi` and loops with reboot-on-fail to clear version mismatches.

## Test
1. Enter into the LXC container: `pct enter <CTID>`
2. Run `nvidia-smi` to verify GPU stats.
3. (Optional) Docker test: `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi`

## License
MIT
