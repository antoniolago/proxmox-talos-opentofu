resource "local_sensitive_file" "csr_kubeconfig" {
  filename = "${path.module}/.csr-kubeconfig"
  content  = talos_cluster_kubeconfig.this.kubeconfig_raw
}

resource "null_resource" "approve_csr" {
  depends_on = [
    talos_machine_configuration_apply.worker,
    talos_machine_configuration_apply.controlplane,
    local_sensitive_file.csr_kubeconfig,
  ]

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      KUBECONFIG_PATH="${path.module}/.csr-kubeconfig"

      # Approve all pending kubelet serving certificate CSRs
      echo "Checking for pending CSRs..."
      kubectl --kubeconfig="$KUBECONFIG_PATH" get csr -o json | \
        jq -r '.items[] | select(.status.conditions == null) | .metadata.name' | \
        xargs -I {} kubectl --kubeconfig="$KUBECONFIG_PATH" certificate approve {} || true

      echo "CSR approval complete"
    EOT
    interpreter = ["bash", "-c"]
  }
}
