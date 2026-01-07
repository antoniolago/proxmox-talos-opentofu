resource "helm_release" "flux_operator" {
  name             = "flux-operator"
  namespace        = "flux-system"
  create_namespace = true
  chart            = "flux-operator"
  repository       = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  timeout          = 120
}

resource "kubernetes_secret" "github_credentials" {
  depends_on = [helm_release.flux_operator]
  metadata {
    name      = "github-credentials"
    namespace = "flux-system"
  }

  data = {
    username = var.github_username
    password = var.github_password
  }

  type = "Opaque"
}

resource "kubernetes_manifest" "fluxinstance" {
  depends_on = [kubernetes_secret.github_credentials]
  manifest = {
    apiVersion = "fluxcd.controlplane.io/v1"
    kind       = "FluxInstance"
    metadata = {
      name      = "flux"
      namespace = "flux-system"
      annotations = {
        "fluxcd.controlplane.io/reconcile"       = "enabled"
        "fluxcd.controlplane.io/reconcileEvery"  = "1h"
        "fluxcd.controlplane.io/reconcileTimeout" = "3m"
      }
    }
    spec = {
      sync = {
        kind       = "GitRepository"
        url        = "https://github.com/antoniolago/lag0-fleet-infra-ton"
        ref        = "refs/heads/main"
        path       = "cluster"
        pullSecret = "github-credentials"
      }
      distribution = {
        version  = "2.x"
        registry = "ghcr.io/fluxcd"
      }
      components = [
        "source-controller",
        "kustomize-controller",
        "helm-controller",
        "notification-controller",
        "image-reflector-controller",
        "image-automation-controller"
      ]
      cluster = {
        type = "kubernetes"
      }
    }
  }
}

resource "kubernetes_namespace" "vaultwarden" {
  metadata {
    name = var.vaultwarden_namespace
  }
}

resource "kubernetes_secret" "vaultwarden_credentials" {
  depends_on = [kubernetes_namespace.vaultwarden]
  metadata {
    name      = "vaultwarden-kubernetes-secrets"
    namespace = var.vaultwarden_namespace
  }

  data = {
    BW_CLIENTID                  = var.vaultwarden_client_id
    BW_CLIENTSECRET              = var.vaultwarden_client_secret
    VAULTWARDEN__MASTERPASSWORD  = var.vaultwarden_master_password
  }

  type = "Opaque"
}

resource "helm_release" "vaultwarden_kubernetes_secrets" {
  depends_on       = [kubernetes_secret.vaultwarden_credentials]
  name             = "vaultwarden-kubernetes-secrets"
  namespace        = var.vaultwarden_namespace
  create_namespace = false
  chart            = "vaultwarden-kubernetes-secrets"
  repository       = "oci://ghcr.io/antoniolago/charts"
  version          = var.vaultwarden_chart_version
  timeout          = 120

  set {
    name  = "env.config.VAULTWARDEN__SERVERURL"
    value = var.vaultwarden_server_url
  }

  set {
    name  = "image.tag"
    value = var.vaultwarden_chart_version
  }
}

