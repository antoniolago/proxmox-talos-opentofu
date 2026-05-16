# ISO is downloaded locally then SCP'd to Proxmox (bypasses API upload issues)
resource "null_resource" "talos_linux_iso_image" {
  triggers = {
    schematic_id   = talos_image_factory_schematic.this.id
    talos_version  = var.talos_version
    iso_url        = local.talos_linux_iso_image_url
    iso_filename   = local.talos_linux_iso_image_filename_dynamic
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      HOST="${local.proxmox_host}"
      STORAGE_PATH="${local.proxmox_iso_storage_path}"
      ISO_URL="${local.talos_linux_iso_image_url}"
      ISO_FILENAME="${local.talos_linux_iso_image_filename_dynamic}"
      LOCAL_TMP="/tmp/$ISO_FILENAME"

      # Check if ISO already exists on Proxmox
      if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$HOST" \
        "[ -f '$STORAGE_PATH/$ISO_FILENAME' ]" 2>/dev/null; then
        echo "ISO already exists on Proxmox, skipping."
        exit 0
      fi

      # Download locally
      echo "Downloading $ISO_FILENAME from Talos Factory..."
      curl -fsSL --retry 3 --retry-delay 5 -o "$LOCAL_TMP" "$ISO_URL"
      echo "Download complete (size: $(stat -c%s '$LOCAL_TMP') bytes)."

      # SCP to Proxmox
      echo "Uploading to Proxmox host $HOST..."
      scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$LOCAL_TMP" "root@$HOST:$STORAGE_PATH/$ISO_FILENAME"

      # Trigger Proxmox storage rescan to recognize the new ISO
      echo "Triggering storage rescan..."
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$HOST" \
        "pvesm rescan local 2>/dev/null || true"

      # Clean up
      rm -f "$LOCAL_TMP"
      echo "ISO upload complete."
    EOT
    interpreter = ["bash", "-c"]
  }
}
