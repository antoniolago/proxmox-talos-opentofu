output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "schematic_id" {
  value       = talos_image_factory_schematic.this.id
  description = "The schematic ID for the generated Talos image with extensions"
}
