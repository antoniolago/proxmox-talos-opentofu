variable "proxmox_api_url" {
  type = string
}

variable "proxmox_api_token_id" {
  type      = string
  sensitive = true
}

variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}

variable "proxmox_target_node" {
  type = string
}

variable "proxmox_storage_device" {
  type = string
}

variable "talos_version" {
  type    = string
  default = "1.12.1"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35.0"
}

variable "talos_linux_iso_image_url" {
  description = "URL of the Talos ISO image for initially booting the VM"
  type        = string
  default     = "https://factory.talos.dev/image/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515/v1.12.1/nocloud-amd64.iso"
}

variable "talos_linux_iso_image_filename" {
  description = "Filename of the Talos ISO image for initially booting the VM"
  type        = string
  default     = "nocloud-amd64.iso"
}

variable "cluster_name" {
  description = "A name to provide for the Talos cluster"
  type        = string
  default     = "talos"
}

variable "cluster_vip_shared_ip" {
  description = "Shared virtual IP address for control plane nodes"
  type        = string
  default     = "192.168.2.200"
}

variable "node_data" {
  description = "A map of node data"
  type = object({
    controlplanes = map(object({
      install_disk  = string
      install_image = string
      hostname      = optional(string)
      memory        = optional(number, 8192)
      cpu_cores     = optional(number, 2)
      disk_size     = optional(string, "50G")
      target_node   = optional(string)
    }))
    workers = map(object({
      install_disk  = string
      install_image = string
      hostname      = optional(string)
      memory        = optional(number, 16384)
      cpu_cores     = optional(number, 2)
      disk_size     = optional(string, "50G")
      target_node   = optional(string)
    }))
  })
  default = {
    controlplanes = {
      "192.168.1.101" = {
        install_disk  = "/dev/vda"
        install_image = "factory.talos.dev/nocloud-installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.12.1"
      },
    }
    workers = {
      "192.168.1.102" = {
        install_disk  = "/dev/vda"
        install_image = "factory.talos.dev/nocloud-installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.12.1"
      },
    }
  }
}

variable "network" {
  description = "Network for all nodes"
  type        = string
  default     = "192.168.88.0/24"
}

variable "network_gateway" {
  description = "Network gateway for all nodes"
  type        = string
  default     = "192.168.88.1"
}

variable "domain_name_server" {
  description = "DNS for all nodes"
  type        = string
  default     = "192.168.88.1"
}

variable "vlan_tag" {
  description = "Vlan tag for all nodes, default does not configure a Vlan"
  type        = number
  default     = 0
}

variable "merge_kubeconfig" {
  description = "If true, merges the generated kubeconfig into $HOME/.kube/config on the machine running OpenTofu"
  type        = bool
  default     = false
}

variable "merge_kubeconfig_path" {
  description = "Target kubeconfig path for merge when merge_kubeconfig is enabled"
  type        = string
  default     = "~/.kube/config"
}

variable "install_cilium" {
  description = "If true, installs Cilium CNI into the bootstrapped cluster (requires helm CLI on the machine running OpenTofu)"
  type        = bool
  default     = false
}

variable "cilium_version" {
  description = "Cilium Helm chart version to install"
  type        = string
  default     = "1.18.5"
}

