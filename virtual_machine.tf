resource "proxmox_vm_qemu" "workstation" {
  name        = var.vm_name
  target_node = var.proxmox_target_node
  memory      = var.vm_memory
  
  cpu {
    cores = var.vm_cpu_cores
  }
  
  disk {
    slot    = "scsi0"
    type    = "disk"
    storage = var.proxmox_storage_device
    size    = var.vm_disk_size
  }
  
  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }
}
