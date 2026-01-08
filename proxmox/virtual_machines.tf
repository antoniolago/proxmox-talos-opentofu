resource "proxmox_vm_qemu" "kubernetes_control_plane" {
  for_each    = var.node_data.controlplanes
  name        = format("%s-k8s-control-plane-%s", replace(var.cluster_name, " ", "-"), index(keys(var.node_data.controlplanes), each.key))
  description = "Kubernetes Control Plane"
  target_node = each.value.target_node != null ? each.value.target_node : var.proxmox_target_node
  agent       = 1
  vm_state    = "running"
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
      startup_shutdown,
    ]
  }
}


resource "proxmox_vm_qemu" "kubernetes_worker" {
  for_each    = var.node_data.workers
  name        = format("%s-k8s-worker-%s", replace(var.cluster_name, " ", "-"), index(keys(var.node_data.workers), each.key))
  description = "Kubernetes Worker Node"
  target_node = each.value.target_node != null ? each.value.target_node : var.proxmox_target_node
  agent       = 1
  vm_state    = "running"
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
      startup_shutdown,
    ]
  }
}
