# Create Ubuntu cloud template automatically if needed
resource "null_resource" "create_ubuntu_template" {
  # Only create if auto_create_template is enabled
  count = var.auto_create_template ? 1 : 0

  # This will run before the VM is created
  triggers = {
    template_name = var.proxmox_template_name
    template_vmid = var.template_vmid
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Extract Proxmox host from API URL
      PROXMOX_HOST=$(echo "${var.proxmox_api_url}" | sed 's|https://||' | sed 's|:8006/api2/json||')
      
      echo "=== Creating Ubuntu Cloud Template on $PROXMOX_HOST ==="
      
      # Create the template creation script
      cat > /tmp/create_template_${self.triggers.template_vmid}.sh << 'SCRIPT'
      #!/bin/bash
      set -e
      
      TEMPLATE_ID="${self.triggers.template_vmid}"
      TEMPLATE_NAME="${self.triggers.template_name}"
      STORAGE="${var.proxmox_storage_device}"
      BRIDGE="vmbr0"
      
      echo "Creating Ubuntu cloud template: $TEMPLATE_NAME (ID: $TEMPLATE_ID)"
      
      # Check if template already exists
      if qm status $TEMPLATE_ID &> /dev/null; then
        echo "Template $TEMPLATE_ID already exists. Skipping creation."
        exit 0
      fi
      
      # Install required packages
      if ! command -v virt-customize &> /dev/null; then
        echo "Installing libguestfs-tools..."
        apt-get update && apt-get install -y libguestfs-tools
      fi
      
      # Download Ubuntu 24.04 cloud image
      echo "Downloading Ubuntu 24.04 cloud image..."
      wget -q -O /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img \
        https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
      
      # Customize image to install qemu-guest-agent
      echo "Customizing image..."
      virt-customize -a /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img \
        --install qemu-guest-agent
      
      # Create VM
      echo "Creating VM..."
      qm create $TEMPLATE_ID \
        --name "$TEMPLATE_NAME" \
        --memory 1024 \
        --cores 1 \
        --net0 virtio,bridge=$BRIDGE \
        --ostype l26 \
        --agent enabled=1 \
        --bios ovmf \
        --machine q35 \
        --cpu host
      
      # Add EFI disk
      qm set $TEMPLATE_ID --efidisk0 $STORAGE:1,efitype=4m
      
      # Import disk
      echo "Importing disk..."
      qm importdisk $TEMPLATE_ID /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img $STORAGE
      qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$TEMPLATE_ID-disk-1
      
      # Add cloud-init drive
      qm set $TEMPLATE_ID --ide2 $STORAGE:cloudinit
      qm set $TEMPLATE_ID --boot c --bootdisk scsi0
      qm set $TEMPLATE_ID --serial0 socket --vga serial0
      
      # Convert to template
      echo "Converting to template..."
      qm template $TEMPLATE_ID
      
      echo "Template created successfully!"
      SCRIPT
      
      # Copy script to Proxmox host and execute
      echo "Copying template creation script to $PROXMOX_HOST..."
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PasswordAuthentication=no \
        /tmp/create_template_${self.triggers.template_vmid}.sh \
        root@$PROXMOX_HOST:/tmp/ || {
        echo "SSH key authentication failed. Please set up SSH key access to your Proxmox host:"
        echo "  ssh-copy-id root@$PROXMOX_HOST"
        echo "Or run the template creation script manually on the Proxmox host."
        exit 1
      }
      
      echo "Executing template creation script on $PROXMOX_HOST..."
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PasswordAuthentication=no \
        root@$PROXMOX_HOST \
        "bash /tmp/create_template_${self.triggers.template_vmid}.sh"
      
      # Cleanup
      rm -f /tmp/create_template_${self.triggers.template_vmid}.sh
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        root@$PROXMOX_HOST \
        "rm -f /tmp/create_template_${self.triggers.template_vmid}.sh"
      
      echo "=== Template creation completed ==="
    EOT
  }
}
