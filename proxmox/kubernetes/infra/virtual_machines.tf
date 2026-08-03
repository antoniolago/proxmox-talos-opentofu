resource "proxmox_vm_qemu" "kubernetes_control_plane" {
  depends_on  = [null_resource.talos_linux_iso_image]
  for_each    = var.node_data.controlplanes
  name        = format("%s-k8s-control-plane-%s", replace(var.cluster_name, " ", "-"), index(keys(var.node_data.controlplanes), each.key))
  description = "Kubernetes Control Plane"
  target_node = each.value.target_node != null ? each.value.target_node : var.proxmox_target_node
  agent       = 1
  vm_state    = "running"
  start_at_node_boot      = true
  memory      = each.value.memory
  boot        = "order=virtio0;ide2"
  nameserver  = var.domain_name_server

  cpu {
    cores = each.value.cpu_cores
  }

  vga {
    type = "std"
  }

  disk {
    slot    = "ide0"
    type    = "cloudinit"
    storage = var.proxmox_storage_device
  }

  disk {
    slot = "ide2"
    type = "cdrom"
    iso  = "local:iso/${local.talos_linux_iso_image_filename_dynamic}"
  }

  disk {
    slot    = "virtio0"
    type    = "disk"
    storage = var.proxmox_storage_device
    size    = each.value.disk_size
    discard = true
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
    tag    = var.vlan_tag
  }

  # Cloud init setup
  os_type   = "cloud-init"
  ipconfig0 = "ip=${each.key}/24,gw=${var.network_gateway}"

  lifecycle {
    ignore_changes = [
      disk[0].format,
      disk[1].format,
      disk[2].format,
    ]
    # Control planes: Manual replacement recommended to preserve etcd quorum
    # Replace one at a time using: tofu taint 'proxmox_vm_qemu.kubernetes_control_plane["<ip>"]'
  }
  startup_shutdown {
    order            = -1
    shutdown_timeout = -1
    startup_delay    = -1
  }
}


resource "proxmox_vm_qemu" "kubernetes_worker" {
  depends_on  = [null_resource.talos_linux_iso_image]
  for_each    = var.node_data.workers
  name        = format("%s-k8s-worker-%s", replace(var.cluster_name, " ", "-"), index(keys(var.node_data.workers), each.key))
  description = "Kubernetes Worker Node"
  target_node = each.value.target_node != null ? each.value.target_node : var.proxmox_target_node
  agent       = 1
  vm_state    = "running"
  start_at_node_boot = true
  machine     = length(each.value.pci_devices) > 0 ? "q35" : "pc"
  bios        = length(each.value.pci_devices) > 0 ? "ovmf" : "seabios"
  memory      = each.value.memory
  boot        = "order=virtio0;ide2"
  nameserver  = var.domain_name_server

  cpu {
    cores = each.value.cpu_cores
  }

  vga {
    type = "std"
  }

  disk {
    slot    = "ide0"
    type    = "cloudinit"
    storage = var.proxmox_storage_device
  }
  startup_shutdown {
    order            = -1
    shutdown_timeout = -1
    startup_delay    = -1
  }
  disk {
    slot = "ide2"
    type = "cdrom"
    iso  = "local:iso/${local.talos_linux_iso_image_filename_dynamic}"
  }

  disk {
    slot    = "virtio0"
    type    = "disk"
    storage = var.proxmox_storage_device
    size    = each.value.disk_size
    discard = true
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
    tag    = var.vlan_tag
  }

  # EFI disk required for OVMF BIOS (GPU passthrough VMs)
  dynamic "efidisk" {
    for_each = length(each.value.pci_devices) > 0 ? [1] : []
    content {
      efitype = "4m"
      storage = var.proxmox_storage_device
    }
  }

  # GPU / PCI passthrough (optional per-worker)
  dynamic "pci" {
    for_each = each.value.pci_devices
    content {
      id         = pci.value.id
      mapping_id = pci.value.mapping_id
      pcie       = pci.value.pcie
      rombar     = pci.value.rombar
    }
  }

  # Cloud init setup
  os_type   = "cloud-init"
  ipconfig0 = "ip=${each.key}/24,gw=${var.network_gateway}"

  lifecycle {
    ignore_changes = [
      disk[0].format,
      disk[1].format,
      disk[2].format,
    ]
    # Workers: Auto-replace when schematic changes (safe - workloads will reschedule)
    replace_triggered_by = [talos_image_factory_schematic.this]
  }
}

# ─── Hook script: auto-restart VMs on unexpected stop ─────────────────────
# Deployed to each Proxmox node so the VM hookscript reference works.
locals {
  proxmox_nodes = distinct(concat(
    [for k, v in var.node_data.controlplanes : v.target_node != null ? v.target_node : var.proxmox_target_node],
    [for k, v in var.node_data.workers : v.target_node != null ? v.target_node : var.proxmox_target_node],
  ))
  proxmox_node_ips = {
    ton01 = "192.168.88.240"
    ton02 = "192.168.88.241"
    ton03 = "192.168.88.242"
  }
}

resource "null_resource" "deploy_hook_script" {
  for_each = toset(local.proxmox_nodes)
  triggers = {
    script_hash = filesha256("${path.module}/templates/vm-auto-restart-hook.sh")
    node        = each.key
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      NODE_IP="${lookup(local.proxmox_node_ips, each.key, "unknown")}"
      echo "=== Deploying hook script to $NODE_IP ($each.key) ==="
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$NODE_IP \
        "mkdir -p /var/lib/vz/snippets"
      scp -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "${path.module}/templates/vm-auto-restart-hook.sh" \
        root@$NODE_IP:/var/lib/vz/snippets/vm-auto-restart-hook.sh
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$NODE_IP \
        "chmod +x /var/lib/vz/snippets/vm-auto-restart-hook.sh && \
         echo 'HOOK_DEPLOYED on $each.key'"
    SCRIPT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-SCRIPT
      case "${each.key}" in
        ton01) NODE_IP="192.168.88.240" ;;
        ton02) NODE_IP="192.168.88.241" ;;
        ton03) NODE_IP="192.168.88.242" ;;
        *)     NODE_IP="" ;;
      esac
      [ -n "$NODE_IP" ] && \
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$NODE_IP \
          "rm -f /var/lib/vz/snippets/vm-auto-restart-hook.sh" 2>/dev/null || true
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# ─── Configure hookscript on all control-plane VMs via Proxmox API ────
# Telmate provider lacks hookscript support, so we use the REST API.
resource "null_resource" "set_cp_hookscript" {
  depends_on = [
    null_resource.deploy_hook_script,
    proxmox_vm_qemu.kubernetes_control_plane,
  ]
  for_each = var.node_data.controlplanes

  triggers = {
    vm_id      = proxmox_vm_qemu.kubernetes_control_plane[each.key].id
    node       = each.value.target_node != null ? each.value.target_node : var.proxmox_target_node
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      API="${var.proxmox_api_url}"
      NODE="${each.value.target_node != null ? each.value.target_node : var.proxmox_target_node}"
      # Map node to IP for SSH
      case "$NODE" in
        ton01) NODE_IP="192.168.88.240" ;;
        ton02) NODE_IP="192.168.88.241" ;;
        ton03) NODE_IP="192.168.88.242" ;;
        *)     echo "Unknown node $NODE"; exit 1 ;;
      esac
      VMID=$(echo "${proxmox_vm_qemu.kubernetes_control_plane[each.key].id}" | cut -d/ -f3)
      echo "=== Hookscript: $NODE VM $VMID ==="
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$NODE_IP \
        "qm set $VMID --hookscript local:snippets/vm-auto-restart-hook.sh"
      echo "HOOK_OK $NODE/$VMID"
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# ─── Configure hookscript on all worker VMs via Proxmox API ───────────
resource "null_resource" "set_worker_hookscript" {
  depends_on = [
    null_resource.deploy_hook_script,
    proxmox_vm_qemu.kubernetes_worker,
  ]
  for_each = var.node_data.workers

  triggers = {
    vm_id      = proxmox_vm_qemu.kubernetes_worker[each.key].id
    node       = each.value.target_node != null ? each.value.target_node : var.proxmox_target_node
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      API="${var.proxmox_api_url}"
      NODE="${each.value.target_node != null ? each.value.target_node : var.proxmox_target_node}"
      case "$NODE" in
        ton01) NODE_IP="192.168.88.240" ;;
        ton02) NODE_IP="192.168.88.241" ;;
        ton03) NODE_IP="192.168.88.242" ;;
        *)     echo "Unknown node $NODE"; exit 1 ;;
      esac
      VMID=$(echo "${proxmox_vm_qemu.kubernetes_worker[each.key].id}" | cut -d/ -f3)
      echo "=== Hookscript: $NODE VM $VMID ==="
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$NODE_IP \
        "qm set $VMID --hookscript local:snippets/vm-auto-restart-hook.sh"
      echo "HOOK_OK $NODE/$VMID"
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# ─── Label worker nodes with node-role.kubernetes.io/worker ─────────────
# Talos nodeLabels only apply at node registration; existing nodes need
# explicit labeling. This runs when the worker list or cluster name changes.
resource "null_resource" "label_worker_nodes" {
  depends_on = [talos_machine_configuration_apply.worker]
  for_each   = var.node_data.workers

  triggers = {
    node_name   = format("%s-k8s-worker-%s", replace(var.cluster_name, " ", "-"), index(keys(var.node_data.workers), each.key))
    node_ip     = each.key
    cluster     = var.cluster_name
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      NAME="${format("%s-k8s-worker-%s", replace(var.cluster_name, " ", "-"), index(keys(var.node_data.workers), each.key))}"
      echo "=== Labeling worker $NAME ==="
      kubectl --server=https://192.168.88.203:6443 --insecure-skip-tls-verify=true \
        label node "$NAME" \
        node-role.kubernetes.io/worker="" \
        --overwrite 2>/dev/null || true
      echo "LABEL_DONE"
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# ─── Immich DB restore after cluster rebuild ─────────────────────────────
# When the cluster is destroyed and recreated, the CNPG database is fresh.
# This Job restores the latest S3 backup into the new immich database.
# The Job itself handles waiting for the immich CNPG cluster to be ready.
resource "null_resource" "immich_db_restore" {
  depends_on = [
    talos_machine_bootstrap.this,
    talos_cluster_kubeconfig.this,
  ]
  triggers = {
    cluster_name = var.cluster_name
    always_run   = timestamp()
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      KCFG="${abspath(path.module)}/.generated-kubeconfig"
      JOB="${abspath(path.module)}/templates/immich-db-restore-job.yaml"

      echo "=== Waiting for cluster readiness ==="
      for i in $(seq 1 60); do
        if KCFG="$(echo "${abspath(path.module)}/.generated-kubeconfig")" && kubectl --kubeconfig="$(echo "${abspath(path.module)}/.generated-kubeconfig")" get nodes 2>/dev/null | grep -q Ready; then
          echo "Cluster ready after $(( i * 10 ))s"
          break
        fi
        sleep 10
      done

      echo "=== Waiting for immich namespace ==="
      for i in $(seq 1 60); do
        if kubectl --kubeconfig="$(echo "${abspath(path.module)}/.generated-kubeconfig")" get ns immich 2>/dev/null >/dev/null; then
          echo "Immich namespace ready"
          break
        fi
        sleep 10
      done

      echo "=== Applying immich DB restore Job ==="
      kubectl --kubeconfig="$(echo "${abspath(path.module)}/.generated-kubeconfig")" apply -f "$(echo "${abspath(path.module)}/templates/immich-db-restore-job.yaml")" 2>/dev/null || true
      echo "IMMICH_RESTORE_JOB_APPLIED"
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}
