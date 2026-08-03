#!/bin/bash
# Quick script to create Ubuntu cloud template on Proxmox
# Run this on your Proxmox host

set -e

TEMPLATE_ID=9000
TEMPLATE_NAME="ws-template"
STORAGE="local-lvm"
BRIDGE="vmbr0"

echo "=== Creating Ubuntu Cloud Template ==="
echo "Template ID: $TEMPLATE_ID"
echo "Template Name: $TEMPLATE_NAME"
echo "Storage: $STORAGE"
echo ""

# Check if running on Proxmox
if ! command -v qm &> /dev/null; then
    echo "Error: This script must be run on a Proxmox host"
    exit 1
fi

# Destroy existing template if it exists
if qm status $TEMPLATE_ID &> /dev/null; then
    echo "Destroying existing template..."
    qm destroy $TEMPLATE_ID --purge
fi

# Download Ubuntu 24.04 cloud image
echo "Downloading Ubuntu 24.04 cloud image..."
wget -O /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img \
    https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Install libguestfs-tools if needed
if ! command -v virt-customize &> /dev/null; then
    echo "Installing libguestfs-tools..."
    apt-get update && apt-get install -y libguestfs-tools
fi

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
qm set $TEMPLATE_ID --efidisk0 ${STORAGE}:1,efitype=4m

# Import disk
echo "Importing disk..."
qm importdisk $TEMPLATE_ID /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img $STORAGE
qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-1

# Add cloud-init drive
qm set $TEMPLATE_ID --ide2 ${STORAGE}:cloudinit
qm set $TEMPLATE_ID --boot c --bootdisk scsi0
qm set $TEMPLATE_ID --serial0 socket --vga serial0

# Convert to template
echo "Converting to template..."
qm template $TEMPLATE_ID

echo ""
echo "=== Template created successfully! ==="
echo ""
echo "Template ID: $TEMPLATE_ID"
echo "Template Name: $TEMPLATE_NAME"
echo ""
echo "You can now deploy the workstation with: tofu apply"
