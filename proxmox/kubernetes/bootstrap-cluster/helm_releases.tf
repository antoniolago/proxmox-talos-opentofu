resource "null_resource" "local_path_provisioner" {
  triggers = {
    version = "v0.0.34"
  }

  provisioner "local-exec" {
    command = <<-EOT
      KUBECONFIG_PATH="${var.kubernetes_config_path}"
      KUBECONFIG_PATH="$${KUBECONFIG_PATH/#\~/$HOME}"
      kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.34/deploy/local-path-storage.yaml
      kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" label namespace local-path-storage pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite
      kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    EOT
    interpreter = ["bash", "-c"]
  }
}

resource "null_resource" "flux_operator_install" {
  depends_on = [null_resource.local_path_provisioner]
  
  triggers = {
    version = "0.38.1"
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      set -x
      
      KUBECONFIG_PATH="${var.kubernetes_config_path}"
      KUBECONFIG_PATH="$${KUBECONFIG_PATH/#\~/$HOME}"
      
      echo "Using kubeconfig: $KUBECONFIG_PATH"
      echo "Using context: ${var.Kubernetes_config_context}"
      
      # Check if we can connect to the cluster
      kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" cluster-info
      
      # Create flux-system namespace first
      echo "Creating flux-system namespace..."
      kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" create namespace flux-system --dry-run=client -o yaml | kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" apply -f -
      
      # Install Flux Operator (includes CRDs and operator deployment)
      echo "Installing Flux Operator..."
      kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" apply --server-side -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v0.38.1/install.yaml
      
      # Wait for CRDs to be established
      echo "Waiting for CRDs..."
      kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" wait --for condition=established --timeout=300s crd/fluxinstances.fluxcd.controlplane.io
      
      # Wait for operator deployment to be ready
      echo "Waiting for operator deployment..."
      kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" wait --for=condition=available --timeout=600s deployment/flux-operator -n flux-system
      
      echo "Flux operator installation complete!"
    EOT
    interpreter = ["bash", "-c"]
  }
}


resource "kubernetes_secret" "github_credentials" {
  depends_on = [null_resource.flux_operator_install]
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

resource "null_resource" "fluxinstance" {
  depends_on = [
    null_resource.flux_operator_install,
    kubernetes_secret.github_credentials
  ]
  
  triggers = {
    flux_operator_version = "0.38.1"
    manifest_sha          = sha256(jsonencode({
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
    }))
  }
  
  provisioner "local-exec" {
    command = <<-EOT
      KUBECONFIG_PATH="${var.kubernetes_config_path}"
      KUBECONFIG_PATH="$${KUBECONFIG_PATH/#\~/$HOME}"
      
      # Wait for CRDs to be ready
      echo "Waiting for FluxInstance CRD to be established..."
      kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" wait --for condition=established --timeout=300s crd/fluxinstances.fluxcd.controlplane.io || {
        echo "CRD not ready, checking if it exists..."
        kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" get crd fluxinstances.fluxcd.controlplane.io
        exit 1
      }
      
      kubectl --kubeconfig="$KUBECONFIG_PATH" --context="${var.Kubernetes_config_context}" apply -f - <<EOF
      apiVersion: fluxcd.controlplane.io/v1
      kind: FluxInstance
      metadata:
        name: flux
        namespace: flux-system
        annotations:
          fluxcd.controlplane.io/reconcile: "enabled"
          fluxcd.controlplane.io/reconcileEvery: "1h"
          fluxcd.controlplane.io/reconcileTimeout: "3m"
      spec:
        sync:
          kind: GitRepository
          url: https://github.com/antoniolago/lag0-fleet-infra-ton
          ref: refs/heads/main
          path: cluster
          pullSecret: github-credentials
        distribution:
          version: 2.x
          registry: ghcr.io/fluxcd
        components:
          - source-controller
          - kustomize-controller
          - helm-controller
          - notification-controller
          - image-reflector-controller
          - image-automation-controller
        cluster:
          type: kubernetes
      EOF
    EOT
    interpreter = ["bash", "-c"]
  }
}

resource "kubernetes_namespace" "vaultwarden_secrets" {
  depends_on = [null_resource.local_path_provisioner]
  metadata {
    name = var.vaultwarden_namespace
  }
}

resource "kubernetes_secret" "vaultwarden_credentials" {
  depends_on = [kubernetes_namespace.vaultwarden_secrets]
  metadata {
    name      = "vaultwarden-kubernetes-secrets"
    namespace = var.vaultwarden_namespace
  }

  data = {
    BW_CLIENTID                  = var.vaultwarden_client_id
    BW_CLIENTSECRET              = var.vaultwarden_client_secret
    VAULTWARDEN__MASTERPASSWORD  = var.vaultwarden_master_password
  }
}

resource "kubernetes_namespace" "vaultwarden_server" {
  depends_on = [null_resource.local_path_provisioner]
  metadata {
    name = "vaultwarden"
  }
}

resource "kubernetes_secret" "vaultwarden_server_credentials" {
  depends_on = [kubernetes_namespace.vaultwarden_server]
  metadata {
    name      = "vaultwarden-secrets"
    namespace = "vaultwarden"
  }

  data = {
    POSTGRES_PASSWORD                  = var.vaultwarden_postgres_password
    ADMIN_TOKEN              = var.vaultwarden_admin_token
  }

  type = "Opaque"
}

resource "kubernetes_namespace" "domain_vars" {
  metadata {
    name = "domain-vars"
  }
}

resource "kubernetes_secret" "cloudflare_secrets" {
  depends_on = [kubernetes_namespace.domain_vars]
  metadata {
    name      = "cloudflare-secrets"
    namespace = kubernetes_namespace.domain_vars.metadata[0].name
  }

  data = {
    cloudflare-token = var.cloudflare_token
  }

  type = "Opaque"
}

resource "kubernetes_secret" "cloudflare_secrets_cert_manager" {
  depends_on = [kubernetes_secret.cloudflare_secrets, kubernetes_namespace.cert_manager]
  metadata {
    name      = "cloudflare-secrets"
    namespace = "cert-manager"
  }

  data = {
    cloudflare-token = var.cloudflare_token
  }

  type = "Opaque"
}

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

