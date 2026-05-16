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
  default = "1.13.0"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36.0"
}

data "talos_image_factory_extensions_versions" "this" {
  talos_version = var.talos_version
  filters = {
    names = [
      "binfmt-misc",
      "qemu-guest-agent",
    ]
  }
}

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode(
    {
      customization = {
        systemExtensions = {
          officialExtensions = data.talos_image_factory_extensions_versions.this.extensions_info.*.name
        }
      }
    }
  )
}

variable "talos_linux_iso_image_url" {
  description = "URL of the Talos ISO image for initially booting the VM"
  type        = string
  default     = ""
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
      install_image = optional(string)
      hostname      = optional(string)
      memory        = optional(number, 8192)
      cpu_cores     = optional(number, 2)
      disk_size     = optional(string, "50G")
      target_node   = optional(string)
    }))
    workers = map(object({
      install_disk  = string
      install_image = optional(string)
      hostname      = optional(string)
      memory        = optional(number, 16384)
      cpu_cores     = optional(number, 2)
      disk_size     = optional(string, "50G")
      target_node   = optional(string)
      pci_devices = optional(list(object({
        id         = string
        mapping_id = string
        pcie       = optional(bool, false)
        rombar     = optional(bool, true)
      })), [])
      machine_config_extra = optional(string, "")
    }))
  })
  default = {
    controlplanes = {
      "192.168.1.101" = {
        install_disk  = "/dev/vda"
      },
    }
    workers = {
      "192.168.1.102" = {
        install_disk  = "/dev/vda"
      },
    }
  }
}

variable "windows_vm" {
  description = "Configuration for a standalone Windows VM with GPU passthrough"
  type = object({
    enabled      = optional(bool, false)
    target_node  = optional(string, "ton03")
    vmid         = optional(number, 110)
    name         = optional(string, "windows-gpu")
    memory       = optional(number, 16384)
    cpu_cores    = optional(number, 4)
    disk_size    = optional(string, "100G")
    ip_address   = optional(string, "")
    pci_devices  = optional(list(object({
      id         = string
      mapping_id = string
      pcie       = optional(bool, false)
      rombar     = optional(bool, true)
    })), [])
    iso_storage     = optional(string, "local")
    windows_iso     = optional(string, "")
    virtio_iso      = optional(string, "")
    auto_iso        = optional(string, "")
  })
  default = {
    enabled = false
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

variable "auto_replace_vms_on_schematic_change" {
  description = "If true, automatically replace VMs when the Talos schematic changes. Set to false to manually control when nodes are replaced."
  type        = bool
  default     = true
}
