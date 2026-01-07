variable "kubernetes_config_path" {
  type      = string
  sensitive = true
}

variable "Kubernetes_config_context" {
  type      = string
  sensitive = true
}

variable "github_username" {
  type      = string
  sensitive = true
  description = "GitHub username for Flux GitRepository authentication"
}

variable "github_password" {
  type      = string
  sensitive = true
  description = "GitHub password or personal access token for Flux GitRepository authentication"
}

variable "vaultwarden_server_url" {
  type        = string
  description = "Vaultwarden server URL"
}

variable "vaultwarden_client_id" {
  type      = string
  sensitive = true
  description = "Vaultwarden client ID"
}

variable "vaultwarden_client_secret" {
  type      = string
  sensitive = true
  description = "Vaultwarden client secret"
}

variable "vaultwarden_master_password" {
  type      = string
  sensitive = true
  description = "Vaultwarden master password"
}

variable "vaultwarden_chart_version" {
  type        = string
  default     = "latest"
  description = "Vaultwarden Kubernetes Secrets chart version"
}

variable "vaultwarden_namespace" {
  type        = string
  default     = "vaultwarden-system"
  description = "Namespace for vaultwarden-kubernetes-secrets"
}

