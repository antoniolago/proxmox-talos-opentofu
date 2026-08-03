locals {
  # Dynamically construct the ISO image URL using the generated schematic ID
  talos_linux_iso_image_url = var.talos_linux_iso_image_url != "" ? var.talos_linux_iso_image_url : "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/${var.talos_version}/nocloud-amd64.iso"

  # Install image URL for Talos to pull during installation (includes extensions from schematic)
  talos_linux_install_image_url = "factory.talos.dev/nocloud-installer/${talos_image_factory_schematic.this.id}:v${var.talos_version}"

  # Trigger value that changes whenever extensions or talos version changes
  vm_restart_trigger = "${talos_image_factory_schematic.this.id}${var.talos_version}"

  # Dynamic filename based on schematic ID to force re-download of new ISO
  talos_linux_iso_image_filename_dynamic = "${replace(talos_image_factory_schematic.this.id, "/", "-")}-nocloud-amd64.iso"

  # Extract Proxmox host IP from the API URL for SSH-based ISO download
  proxmox_host = split(":", split("://", var.proxmox_api_url)[1])[0]
  proxmox_iso_storage_path = "/var/lib/vz/template/iso"
}
