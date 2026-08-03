variable "proxmox_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID"
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "proxmox_target_node" {
  description = "Proxmox node to deploy the VM on"
  type        = string
}

variable "proxmox_storage_device" {
  description = "Storage device for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "vm_name" {
  description = "Name of the workstation VM"
  type        = string
  default     = "ubuntu-workstation"
}

variable "vm_description" {
  description = "Description of the workstation VM"
  type        = string
  default     = "Ubuntu Server + i3wm Development Workstation"
}

variable "vm_memory" {
  description = "Memory in MB for the VM"
  type        = number
  default     = 8192
}

variable "vm_cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 4
}

variable "vm_disk_size" {
  description = "Disk size for the VM"
  type        = string
  default     = "40G"
}

variable "vm_ip_address" {
  description = "Static IP address for the VM (e.g., 192.168.88.50)"
  type        = string
}

variable "network_gateway" {
  description = "Network gateway"
  type        = string
  default     = "192.168.88.1"
}

variable "network_cidr" {
  description = "Network CIDR suffix (e.g., 24 for /24)"
  type        = number
  default     = 24
}

variable "domain_name_server" {
  description = "DNS server"
  type        = string
  default     = "192.168.88.1"
}

variable "vlan_tag" {
  description = "VLAN tag (0 = no VLAN)"
  type        = number
  default     = 0
}

variable "ubuntu_cloud_image_url" {
  description = "URL of the Ubuntu cloud image"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ubuntu_cloud_image_filename" {
  description = "Filename for the Ubuntu cloud image"
  type        = string
  default     = "ubuntu-24.04-cloudimg-amd64.img"
}

variable "vm_username" {
  description = "Username for the VM"
  type        = string
  default     = "dev"
}

variable "vm_password" {
  description = "Password for the VM user (will be hashed)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key file"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Path to your SSH private key file (for SSH config)"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "configure_ssh_config" {
  description = "If true, adds an entry to ~/.ssh/config for easy SSH access"
  type        = bool
  default     = true
}

variable "ssh_config_path" {
  description = "Path to SSH config file"
  type        = string
  default     = "~/.ssh/config"
}

variable "install_docker" {
  description = "Install Docker on the workstation"
  type        = bool
  default     = true
}

variable "install_vscode" {
  description = "Install VS Code on the workstation"
  type        = bool
  default     = true
}

variable "additional_packages" {
  description = "Additional apt packages to install"
  type        = list(string)
  default     = []
}

variable "timezone" {
  description = "Timezone for the VM"
  type        = string
  default     = "America/Sao_Paulo"
}

variable "locale" {
  description = "Locale for the VM"
  type        = string
  default     = "en_US.UTF-8"
}

variable "proxmox_template_name" {
  description = "Name of the Proxmox template to clone"
  type        = string
  default     = "ws-template"
}

variable "template_vmid" {
  description = "VM ID for the Ubuntu cloud template"
  type        = number
  default     = 9000
}

variable "auto_create_template" {
  description = "Automatically create the Ubuntu cloud template if it doesn't exist"
  type        = bool
  default     = true
}
