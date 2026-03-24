#!/bin/bash
# Script to create Ubuntu cloud-init template on Proxmox
# Run this script on your Proxmox host before running OpenTofu

set -e

# Configuration - adjust these values
TEMPLATE_ID="${TEMPLATE_ID:-9000}"
TEMPLATE_NAME="${TEMPLATE_NAME:-ws-template}"
STORAGE="${STORAGE:-local-lvm}"
UBUNTU_VERSION="${UBUNTU_VERSION:-noble}"  # noble = 24.04 LTS
BRIDGE="${BRIDGE:-vmbr0}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Ubuntu Cloud Template Creator ===${NC}"
echo "Template ID: $TEMPLATE_ID"
echo "Template Name: $TEMPLATE_NAME"
echo "Storage: $STORAGE"
echo "Ubuntu Version: $UBUNTU_VERSION"
echo ""

# Check if running on Proxmox
if ! command -v qm &> /dev/null; then
    echo -e "${RED}Error: This script must be run on a Proxmox host${NC}"
    exit 1
fi

# Check if template already exists
if qm status $TEMPLATE_ID &> /dev/null; then
    echo -e "${YELLOW}Warning: VM $TEMPLATE_ID already exists${NC}"
    read -p "Do you want to destroy it and recreate? (y/N): " confirm
    if [[ $confirm == [yY] ]]; then
        echo "Destroying existing VM..."
        qm destroy $TEMPLATE_ID --purge
    else
        echo "Aborting."
        exit 0
    fi
fi

# Download Ubuntu cloud image
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/${UBUNTU_VERSION}/current/${UBUNTU_VERSION}-server-cloudimg-amd64.img"
CLOUD_IMAGE_FILE="/var/lib/vz/template/iso/${UBUNTU_VERSION}-server-cloudimg-amd64.img"

echo -e "${GREEN}Downloading Ubuntu cloud image...${NC}"
if [ ! -f "$CLOUD_IMAGE_FILE" ]; then
    wget -O "$CLOUD_IMAGE_FILE" "$CLOUD_IMAGE_URL"
else
    echo "Image already exists, skipping download"
fi

# Install libguestfs-tools if not present (for virt-customize)
if ! command -v virt-customize &> /dev/null; then
    echo -e "${YELLOW}Installing libguestfs-tools...${NC}"
    apt-get update && apt-get install -y libguestfs-tools
fi

# Customize the image to install qemu-guest-agent
echo -e "${GREEN}Customizing image (installing qemu-guest-agent)...${NC}"
CUSTOM_IMAGE="/tmp/${UBUNTU_VERSION}-server-cloudimg-custom.img"
cp "$CLOUD_IMAGE_FILE" "$CUSTOM_IMAGE"
virt-customize -a "$CUSTOM_IMAGE" --install qemu-guest-agent

# Create the VM (template uses minimal resources - actual VM specs controlled by OpenTofu)
echo -e "${GREEN}Creating VM template...${NC}"
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

# Import the disk
echo -e "${GREEN}Importing disk...${NC}"
qm importdisk $TEMPLATE_ID "$CUSTOM_IMAGE" $STORAGE

# Attach the disk
qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-1

# Add cloud-init drive
qm set $TEMPLATE_ID --ide2 ${STORAGE}:cloudinit

# Set boot order
qm set $TEMPLATE_ID --boot c --bootdisk scsi0

# Add serial console for cloud-init
qm set $TEMPLATE_ID --serial0 socket --vga serial0

# Enable QEMU guest agent
qm set $TEMPLATE_ID --agent 1

# Convert to template
echo -e "${GREEN}Converting to template...${NC}"
qm template $TEMPLATE_ID

# Cleanup
rm -f "$CUSTOM_IMAGE"

echo ""
echo -e "${GREEN}=== Template created successfully! ===${NC}"
echo ""
echo "Template ID: $TEMPLATE_ID"
echo "Template Name: $TEMPLATE_NAME"
echo ""
echo "You can now use this template with OpenTofu by setting:"
echo "  clone = \"$TEMPLATE_NAME\""
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Copy configuration.auto.tfvars.example to configuration.auto.tfvars"
echo "2. Edit configuration.auto.tfvars with your settings"
echo "3. Run: tofu init && tofu apply"
