# Commented out due to API timeout issues - upload ISO manually to Proxmox:
# SSH to Proxmox and run:
# cd /var/lib/vz/template/iso
# wget https://factory.talos.dev/image/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515/v1.12.1/nocloud-amd64.iso -O talos-linux-v1.12.1-qemu-guest-agent-amd64.iso

# resource "proxmox_storage_iso" "talos_linux_iso_image" {
#   url      = var.talos_linux_iso_image_url
#   filename = var.talos_linux_iso_image_filename
#   storage  = "local"
#   pve_node = var.proxmox_target_node
# }

