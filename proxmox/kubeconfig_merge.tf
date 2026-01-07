resource "local_sensitive_file" "generated_kubeconfig" {
  count    = var.merge_kubeconfig ? 1 : 0
  filename = "${path.module}/.generated-kubeconfig"
  content  = talos_cluster_kubeconfig.this.kubeconfig_raw
}

resource "null_resource" "merge_kubeconfig" {
  count = var.merge_kubeconfig ? 1 : 0

  triggers = {
    kubeconfig_sha256 = sha256(talos_cluster_kubeconfig.this.kubeconfig_raw)
    target_path       = var.merge_kubeconfig_path
  }

  depends_on = [local_sensitive_file.generated_kubeconfig]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      TARGET="${var.merge_kubeconfig_path}"
      TARGET="$${TARGET/#\~/$HOME}"
      mkdir -p "$(dirname "$TARGET")"

      TMPFILE="${path.module}/.generated-kubeconfig"
      if [ -f "$TARGET" ]; then
        KUBECONFIG="$TMPFILE:$TARGET" kubectl config view --flatten > "$TARGET.tmp"
      else
        KUBECONFIG="$TMPFILE" kubectl config view --flatten > "$TARGET.tmp"
      fi
      mv "$TARGET.tmp" "$TARGET"
    EOT
    interpreter = ["bash", "-c"]
  }
}
