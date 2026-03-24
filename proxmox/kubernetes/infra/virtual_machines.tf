resource "proxmox_vm_qemu" "kubernetes_control_plane" {
  for_each    = var.node_data.controlplanes
  name        = format("%s-k8s-control-plane-%s", replace(var.cluster_name, " ", "-"), index(keys(var.node_data.controlplanes), each.key))
  description = "Kubernetes Control Plane"
  target_node = each.value.target_node != null ? each.value.target_node : var.proxmox_target_node
  agent       = 1
  vm_state    = "running"
  start_at_node_boot      = true
  memory      = each.value.memory
  boot        = "order=virtio0;ide2"
  nameserver  = var.domain_name_server

  cpu {
    cores = each.value.cpu_cores
  }

  vga {
    type = "std"
  }

  disk {
    slot    = "ide0"
    type    = "cloudinit"
    storage = var.proxmox_storage_device
  }

  disk {
    slot = "ide2"
    type = "cdrom"
    iso  = "local:iso/${var.talos_linux_iso_image_filename}"
  }

  disk {
    slot    = "virtio0"
    type    = "disk"
    storage = var.proxmox_storage_device
    size    = each.value.disk_size
    discard = true
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
    tag    = var.vlan_tag
  }

  # Cloud init setup
  os_type   = "cloud-init"
  ipconfig0 = "ip=${each.key}/24,gw=${var.network_gateway}"

  lifecycle {
    ignore_changes = [
      disk[0].format,
      disk[1].format,
      disk[2].format,
    ]
  }
  startup_shutdown {
    order            = -1
    shutdown_timeout = -1
    startup_delay    = -1
  }
}


resource "proxmox_vm_qemu" "kubernetes_worker" {
  for_each    = var.node_data.workers
  name        = format("%s-k8s-worker-%s", replace(var.cluster_name, " ", "-"), index(keys(var.node_data.workers), each.key))
  description = "Kubernetes Worker Node"
  target_node = each.value.target_node != null ? each.value.target_node : var.proxmox_target_node
  agent       = 1
  vm_state    = "running"
  start_at_node_boot = true
  machine     = length(each.value.pci_devices) > 0 ? "q35" : "pc"
  bios        = length(each.value.pci_devices) > 0 ? "ovmf" : "seabios"
  memory      = each.value.memory
  boot        = "order=virtio0;ide2"
  nameserver  = var.domain_name_server

  cpu {
    cores = each.value.cpu_cores
  }

  vga {
    type = "std"
  }

  disk {
    slot    = "ide0"
    type    = "cloudinit"
    storage = var.proxmox_storage_device
  }
  startup_shutdown {
    order            = -1
    shutdown_timeout = -1
    startup_delay    = -1
  }
  disk {
    slot = "ide2"
    type = "cdrom"
    iso  = "local:iso/${var.talos_linux_iso_image_filename}"
  }

  disk {
    slot    = "virtio0"
    type    = "disk"
    storage = var.proxmox_storage_device
    size    = each.value.disk_size
    discard = true
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
    tag    = var.vlan_tag
  }

  # EFI disk required for OVMF BIOS (GPU passthrough VMs)
  dynamic "efidisk" {
    for_each = length(each.value.pci_devices) > 0 ? [1] : []
    content {
      efitype = "4m"
      storage = var.proxmox_storage_device
    }
  }

  # GPU / PCI passthrough (optional per-worker)
  dynamic "pci" {
    for_each = each.value.pci_devices
    content {
      id         = pci.value.id
      mapping_id = pci.value.mapping_id
      pcie       = pci.value.pcie
      rombar     = pci.value.rombar
    }
  }

  # Cloud init setup
  os_type   = "cloud-init"
  ipconfig0 = "ip=${each.key}/24,gw=${var.network_gateway}"

  lifecycle {
    ignore_changes = [
      disk[0].format,
      disk[1].format,
      disk[2].format,
    ]
  }
}
