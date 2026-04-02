# Proxmox NVIDIA GPU LXC Passthrough Setup

[![GitHub stars](https://img.shields.io/github/stars/scottchristian/proxmox-nvidia-gpu-lxc-setup)](https://github.com/scottchristian/proxmox-nvidia-gpu-lxc-setup/stars)
[![GitHub issues](https://img.shields.io/github/issues/scottchristian/proxmox-nvidia-gpu-lxc-setup)](https://github.com/scottchristian/proxmox-nvidia-gpu-lxc-setup/issues)

**One-command NVIDIA GPU passthrough for Proxmox LXC containers!**

## Features
- ✅ Auto-detects NVIDIA devices & cgroups
- ✅ Interactive container selection
- ✅ Downloads & installs NVIDIA drivers
- ✅ Configures LXC cgroup2 + mounts
- ✅ NVIDIA Container Toolkit setup
- ✅ Config backups with timestamps

## Usage
On the proxmox host, download and run the script:
```bash
wget https://raw.githubusercontent.com/scottchristian/proxmox-nvidia-gpu-lxc-setup/refs/heads/main/setup-gpu-lxc.sh
chmod +x setup-gpu-lxc.sh
./setup-gpu-lxc.sh
```
It should prompt you for a link to a NVIDIA driver to use and an LXC container to share the GPU with. Once complete, you can then move on to testing it

## Test
```
# Enter into the LXC container (you can also just go to the console of it in the Proxmox interface
pct enter <CTID>
# Then run the following inside the container, which should present you with the GPU stats, and if so, then you have successfully shared the GPU resource
nvidia-smi
```

## License
MIT
