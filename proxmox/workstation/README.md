# Ubuntu Workstation VM with i3wm

This OpenTofu configuration creates a lightweight Ubuntu Server VM with i3wm window manager, optimized for development work on Proxmox.

## Features

- **Ubuntu 24.04 LTS (Noble Numbat)** - Latest LTS release
- **i3wm** - Tiling window manager (keyboard-focused, minimal resource usage)
- **~200MB idle RAM** - Extremely lightweight
- **Full development environment** - Pre-configured with essential tools
- **Automatic SSH configuration** - Adds entry to `~/.ssh/config` for easy access
- **VirtIO optimizations** - Best performance on Proxmox

## Pre-installed Software

### Window Manager & Desktop
- i3wm, i3status, i3lock
- LightDM display manager
- Rofi (application launcher)
- Picom (compositor)
- Dunst (notifications)
- Kitty (terminal)

### Development Tools
- Neovim, VS Code (optional)
- Git, build-essential
- Python 3, Node.js, Go, Rust
- Docker & Docker Compose (optional)

### Utilities
- Firefox browser
- Thunar file manager
- htop, tmux, ranger
- Screenshot tools (maim)

## Prerequisites

1. **Proxmox VE** with API access configured
2. **Ubuntu cloud template** created on Proxmox (see below)
3. **SSH key pair** on your local machine

## Setup Instructions

### Step 1: Create Ubuntu Cloud Template on Proxmox

SSH into your Proxmox host and run:

```bash
# Download and run the template creation script
curl -sSL https://raw.githubusercontent.com/.../create-ubuntu-template.sh | bash

# Or copy the script manually and run:
chmod +x scripts/create-ubuntu-template.sh
scp scripts/create-ubuntu-template.sh root@proxmox-host:/tmp/
ssh root@proxmox-host "bash /tmp/create-ubuntu-template.sh"
```

Or manually:

```bash
# On Proxmox host
TEMPLATE_ID=9000
STORAGE=local-lvm

# Download Ubuntu cloud image
wget -O /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Install libguestfs-tools
apt-get update && apt-get install -y libguestfs-tools

# Customize image (install qemu-guest-agent)
virt-customize -a /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img \
  --install qemu-guest-agent

# Create VM
qm create $TEMPLATE_ID --name "ws-template" --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 --ostype l26 --agent enabled=1 \
  --bios ovmf --machine q35 --cpu host

# Add EFI disk
qm set $TEMPLATE_ID --efidisk0 ${STORAGE}:1,efitype=4m

# Import disk
qm importdisk $TEMPLATE_ID /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img $STORAGE
qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-1

# Add cloud-init drive
qm set $TEMPLATE_ID --ide2 ${STORAGE}:cloudinit
qm set $TEMPLATE_ID --boot c --bootdisk scsi0
qm set $TEMPLATE_ID --serial0 socket --vga serial0

# Convert to template
qm template $TEMPLATE_ID
```

### Step 2: Configure OpenTofu

```bash
cd proxmox/workstation

# Copy example configuration
cp configuration.auto.tfvars.example configuration.auto.tfvars

# Edit with your settings
vim configuration.auto.tfvars
```

Key settings to configure:
- `proxmox_api_url` - Your Proxmox API URL
- `proxmox_api_token_id` / `proxmox_api_token_secret` - API credentials
- `proxmox_target_node` - Proxmox node name
- `vm_ip_address` - Static IP for the VM
- `ssh_public_key_path` / `ssh_private_key_path` - Your SSH key paths

### Step 3: Deploy

```bash
# Initialize OpenTofu
tofu init

# Preview changes
tofu plan

# Deploy
tofu apply
```

### Step 4: Connect

After deployment, you can connect via:

```bash
# Using the auto-configured SSH alias
ssh dev-workstation

# Or directly
ssh dev@192.168.88.50
```

## i3wm Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Super+Return` | Open terminal (Kitty) |
| `Super+d` | Application launcher (Rofi) |
| `Super+Shift+q` | Close window |
| `Super+h/j/k/l` | Move focus (vim-style) |
| `Super+Shift+h/j/k/l` | Move window |
| `Super+1-9` | Switch workspace |
| `Super+Shift+1-9` | Move window to workspace |
| `Super+f` | Toggle fullscreen |
| `Super+v` | Split vertical |
| `Super+b` | Split horizontal |
| `Super+Shift+x` | Lock screen |
| `Super+Shift+r` | Restart i3 |
| `Print` | Screenshot |

## Remote Access Options

### SSH (Recommended)
Already configured automatically. Use VS Code Remote-SSH for a full IDE experience.

### VNC/SPICE
Access the console directly through Proxmox web UI.

### X11 Forwarding
```bash
ssh -X dev-workstation firefox
```

## Resource Tuning

Edit `configuration.auto.tfvars` to adjust:

```hcl
vm_memory    = 8192   # RAM in MB (4096-16384 recommended)
vm_cpu_cores = 4      # CPU cores (2-8 recommended)
vm_disk_size = "40G"  # Disk size (20G-100G)
```

## Troubleshooting

### VM won't boot
- Ensure the Ubuntu cloud template exists and is named `ws-template`
- Check Proxmox console for boot errors

### SSH connection refused
- Wait 2-3 minutes for cloud-init to complete
- Check VM IP address in Proxmox console
- Verify network connectivity

### i3 not starting
- SSH in and check: `systemctl status lightdm`
- Start manually: `sudo systemctl start lightdm`

## Cleanup

```bash
# Destroy the workstation VM
tofu destroy
```

This will also remove the SSH config entry automatically.
