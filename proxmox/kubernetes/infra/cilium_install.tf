resource "local_sensitive_file" "bootstrap_kubeconfig" {
  count    = var.install_cilium ? 1 : 0
  filename = "${path.module}/.bootstrap-kubeconfig"
  content  = talos_cluster_kubeconfig.this.kubeconfig_raw
}

resource "null_resource" "install_cilium" {
  count = var.install_cilium ? 1 : 0

  triggers = {
    kubeconfig_sha256    = sha256(talos_cluster_kubeconfig.this.kubeconfig_raw)
    cilium_version       = var.cilium_version
    cluster_endpoint     = var.cluster_vip_shared_ip
    cilium_values_sha256 = filesha256("${path.module}/cilium-values.yaml")
  }

  depends_on = [local_sensitive_file.bootstrap_kubeconfig]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      KUBECONFIG_FILE="${path.module}/.bootstrap-kubeconfig"

      for i in $(seq 1 60); do
        if KUBECONFIG="$KUBECONFIG_FILE" kubectl version --request-timeout=5s >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done

      KUBECONFIG="$KUBECONFIG_FILE" kubectl version --request-timeout=5s >/dev/null

      helm repo add cilium https://helm.cilium.io --force-update >/dev/null
      helm repo update >/dev/null

      KUBECONFIG="$KUBECONFIG_FILE" helm upgrade --install cilium cilium/cilium \
        --namespace kube-system \
        --version "${var.cilium_version}" \
        --values "${path.module}/cilium-values.yaml" \
        --set kubeProxyReplacement=true \
        --set k8sServiceHost="${var.cluster_vip_shared_ip}" \
        --set k8sServicePort=6443 \
        --set ipam.mode=kubernetes \
        --set operator.replicas=1 \
        --set-string extraConfig.clean-cilium-state=false \
        --set-string extraConfig.clean-cilium-bpf-state=false
    EOT
    interpreter = ["bash", "-c"]
  }
}
