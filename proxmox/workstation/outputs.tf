output "vm_ip_address" {
  description = "IP address of the workstation VM"
  value       = var.vm_ip_address
}

output "vm_name" {
  description = "Name of the workstation VM"
  value       = proxmox_vm_qemu.workstation.name
}

output "ssh_command" {
  description = "SSH command to connect to the workstation"
  value       = "ssh ${var.vm_username}@${var.vm_ip_address}"
}

output "ssh_config_entry" {
  description = "SSH config entry for the workstation"
  value       = <<-EOT
    Host ${var.vm_name}
        HostName ${var.vm_ip_address}
        User ${var.vm_username}
        IdentityFile ${var.ssh_private_key_path}
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
  EOT
}
