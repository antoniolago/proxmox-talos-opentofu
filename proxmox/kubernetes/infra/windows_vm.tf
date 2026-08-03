# Windows VM with GPU passthrough (standalone, runs directly on Proxmox)
# This VM gets the AMD GPU via PCI mapping for GPU-accelerated workloads
resource "proxmox_vm_qemu" "windows" {
  count       = var.windows_vm.enabled ? 1 : 0
  name        = var.windows_vm.name
  description = "Windows GPU VM with AMD Radeon passthrough"
  target_node = var.windows_vm.target_node
  vmid        = var.windows_vm.vmid

  agent    = 1
  vm_state = "running"
  start_at_node_boot = true
  memory   = var.windows_vm.memory
  machine  = length(var.windows_vm.pci_devices) > 0 ? "q35" : "pc"
  bios     = length(var.windows_vm.pci_devices) > 0 ? "ovmf" : "seabios"
  boot     = "order=virtio0;ide2;ide0"

  cpu {
    cores = var.windows_vm.cpu_cores
    type  = "host"
  }

  vga {
    type = "qxl"
  }

  # Cloud-init for network config (optional)
  os_type   = "other"
  ipconfig0 = var.windows_vm.ip_address != "" ? "ip=${var.windows_vm.ip_address}/24,gw=192.168.88.1" : "ip=dhcp"

  # Network
  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Main disk for Windows
  disk {
    slot    = "virtio0"
    type    = "disk"
    storage = var.proxmox_storage_device
    size    = var.windows_vm.disk_size
    discard = true
  }

  # Windows installation ISO (ide0)
  dynamic "disk" {
    for_each = var.windows_vm.windows_iso != "" ? [1] : []
    content {
      slot = "ide0"
      type = "cdrom"
      iso  = "${var.windows_vm.iso_storage}:iso/${var.windows_vm.windows_iso}"
    }
  }

  # VirtIO drivers ISO (ide2)
  dynamic "disk" {
    for_each = var.windows_vm.virtio_iso != "" ? [1] : []
    content {
      slot = "ide2"
      type = "cdrom"
      iso  = "${var.windows_vm.iso_storage}:iso/${var.windows_vm.virtio_iso}"
    }
  }

  # Auto-unattended answer ISO (ide1) — autounattend.xml + setup.ps1
  dynamic "disk" {
    for_each = var.windows_vm.auto_iso != "" ? [1] : []
    content {
      slot = "ide1"
      type = "cdrom"
      iso  = "${var.windows_vm.iso_storage}:iso/${var.windows_vm.auto_iso}"
    }
  }

  # Cloud-init (ide3)
  disk {
    slot    = "ide3"
    type    = "cloudinit"
    storage = var.proxmox_storage_device
  }

  # GPU / PCI passthrough
  dynamic "pci" {
    for_each = var.windows_vm.pci_devices
    content {
      id         = pci.value.id
      mapping_id = pci.value.mapping_id
      pcie       = pci.value.pcie
      rombar     = pci.value.rombar
    }
  }

  # EFI disk for OVMF (required for GPU passthrough)
  dynamic "efidisk" {
    for_each = length(var.windows_vm.pci_devices) > 0 ? [1] : []
    content {
      efitype = "4m"
      storage = var.proxmox_storage_device
    }
  }

  lifecycle {
    ignore_changes = [
      disk[0].format,
      disk[1].format,
      disk[2].format,
      disk[3].format,
      disk[4].format,
    ]
  }
}
