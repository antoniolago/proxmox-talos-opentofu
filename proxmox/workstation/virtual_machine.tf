locals {
  ssh_public_key = try(file(pathexpand(var.ssh_public_key_path)), "")
}

resource "proxmox_vm_qemu" "workstation" {
  depends_on = [
    null_resource.create_ubuntu_template
  ]
  name               = var.vm_name
  description        = var.vm_description
  target_node        = var.proxmox_target_node
  agent              = 1
  vm_state           = "running"
  memory             = var.vm_memory
  boot               = "order=scsi0"
  nameserver         = var.domain_name_server
  start_at_node_boot = true
  bios               = "ovmf"
  machine            = "q35"

  cpu {
    cores = var.vm_cpu_cores
    type  = "host"
  }

  vga {
    type   = "virtio"
    memory = 32
  }

  disk {
    slot    = "scsi0"
    type    = "disk"
    storage = var.proxmox_storage_device
    size    = var.vm_disk_size
    discard = true
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
    tag    = var.vlan_tag
  }

  # Cloud-init configuration
  os_type    = "cloud-init"
  ipconfig0  = "ip=${var.vm_ip_address}/${var.network_cidr},gw=${var.network_gateway}"
  ciuser     = var.vm_username
  cipassword = var.vm_password != "" ? var.vm_password : null
  sshkeys    = local.ssh_public_key != "" ? local.ssh_public_key : null

  # EFI disk for UEFI boot
  efidisk {
    storage = var.proxmox_storage_device
    efitype = "4m"
  }

  lifecycle {
    ignore_changes = [
      disk[0].format,
    ]
  }

  startup_shutdown {
    order            = 1
    shutdown_timeout = 120
    startup_delay    = 0
  }

  # Clone from cloud-init template
  clone = "ws-template"
}
