locals {
  cloud_init_user_data = templatefile("${path.module}/templates/cloud_init_user_data.tftpl", {
    hostname            = var.vm_name
    username            = var.vm_username
    ssh_public_key      = local.ssh_public_key
    timezone            = var.timezone
    locale              = var.locale
    install_docker      = var.install_docker
    install_vscode      = var.install_vscode
    additional_packages = var.additional_packages
  })
}

resource "local_file" "cloud_init_user_data" {
  content  = local.cloud_init_user_data
  filename = "${path.module}/.generated-cloud-init.yaml"
}
