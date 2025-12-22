# Proxmox NVIDIA GPU LXC Passthrough Setup

[![GitHub stars](https://img.shields.io/github/stars/scottchristian/proxmox-gpu-lxc-setup)](https://github.com/scottchristian/proxmox-gpu-lxc-setup/stars)
[![GitHub issues](https://img.shields.io/github/issues/scottchristian/proxmox-gpu-lxc-setup)](https://github.com/scottchristian/proxmox-gpu-lxc-setup/issues)

**One-command NVIDIA GPU passthrough for Proxmox LXC containers!**

## Features
- ✅ Auto-detects NVIDIA devices & cgroups
- ✅ Interactive container selection
- ✅ Downloads & installs NVIDIA drivers
- ✅ Configures LXC cgroup2 + mounts
- ✅ NVIDIA Container Toolkit setup
- ✅ Config backups with timestamps

## Usage
```
chmod +x setup-gpu-lxc.sh
./setup-gpu-lxc.sh
```

## Test
```
pct enter <CTID>
nvidia-smi
```

## License
MIT
