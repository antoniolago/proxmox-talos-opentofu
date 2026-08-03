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

variable "vaultwarden_client_id" {
  type      = string
  sensitive = true
  description = ""
}

variable "vaultwarden_client_secret" {
  type      = string
  sensitive = true
  description = ""
}

variable "vaultwarden_master_password" {
  type      = string
  sensitive = true
  description = ""
}

variable "cloudflare_token" {
  type      = string
  sensitive = true
  description = "Cloudflare API token for cert-manager DNS-01 challenge"
}

variable "vaultwarden_namespace" {
  type      = string
  default   = "vaultwarden"
  description = "Namespace for vaultwarden deployment"
}

variable "vaultwarden_admin_token" {
  type      = string
  sensitive = true
  description = "Vaultwarden admin token for the admin panel"
}

variable "vaultwarden_chart_version" {
  type      = string
  default   = "1.35.2"
  description = "Vaultwarden server image tag"
}

variable "vaultwarden_server_url" {
  type      = string
  default   = "https://vw.lag0.com.br"
  description = "External URL where vaultwarden is accessible"
}

variable "vaultwarden_postgres_password" {
  type      = string
  sensitive = true
  description = "PostgreSQL password for vaultwarden database"
}
