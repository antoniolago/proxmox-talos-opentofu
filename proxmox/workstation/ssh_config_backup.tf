locals {
  ssh_config_entry = <<-EOT
  
  # Workstation VM - Added by OpenTofu
  Host ${var.vm_name}
      HostName ${var.vm_ip_address}
      User ${var.vm_username}
      IdentityFile ${var.ssh_private_key_path}
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR
  EOT

  ssh_config_path = pathexpand(var.ssh_config_path)
}

resource "null_resource" "ssh_config" {
  count = var.configure_ssh_config ? 1 : 0

  triggers = {
    vm_name    = var.vm_name
    ip_address = var.vm_ip_address
    username   = var.vm_username
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Create .ssh directory if it doesn't exist
      mkdir -p ~/.ssh
      chmod 700 ~/.ssh
      
      # Create config file if it doesn't exist
      touch ${local.ssh_config_path}
      chmod 600 ${local.ssh_config_path}
      
      # Remove existing entry for this host if present
      if grep -q "^Host ${var.vm_name}$" ${local.ssh_config_path} 2>/dev/null; then
        # Use sed to remove the existing block
        sed -i '/^# Workstation VM.*${var.vm_name}/,/^$/d' ${local.ssh_config_path} 2>/dev/null || true
        sed -i '/^Host ${var.vm_name}$/,/^$/d' ${local.ssh_config_path} 2>/dev/null || true
      fi
      
      # Append the new entry
      cat >> ${local.ssh_config_path} << 'SSHEOF'
${local.ssh_config_entry}
SSHEOF
      
      echo "SSH config updated. You can now connect with: ssh ${var.vm_name}"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      # Remove SSH config entry on destroy
      if [ -f ~/.ssh/config ]; then
        sed -i '/^# Workstation VM.*${self.triggers.vm_name}/,/^$/d' ~/.ssh/config 2>/dev/null || true
        sed -i '/^Host ${self.triggers.vm_name}$/,/^$/d' ~/.ssh/config 2>/dev/null || true
      fi
    EOT
  }

  depends_on = [proxmox_vm_qemu.workstation]
}

resource "null_resource" "wait_for_ssh" {
  triggers = {
    vm_id = proxmox_vm_qemu.workstation.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for SSH to become available..."
      for i in $(seq 1 60); do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -i ${pathexpand(var.ssh_private_key_path)} \
           ${var.vm_username}@${var.vm_ip_address} "echo 'SSH is ready'" 2>/dev/null; then
          echo "SSH connection successful!"
          exit 0
        fi
        echo "Attempt $i/60 - SSH not ready yet, waiting..."
        sleep 10
      done
      echo "Warning: SSH did not become available within timeout period"
      exit 0
    EOT
  }

  depends_on = [proxmox_vm_qemu.workstation]
}
