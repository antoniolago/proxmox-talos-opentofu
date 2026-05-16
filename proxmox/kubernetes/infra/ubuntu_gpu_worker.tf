# Ubuntu GPU Worker — joins the Talos cluster automatically
# Receives the AMD GPU via PCI passthrough for KubeVirt nested VFIO
# Architecture:
#   1. Creates Proxmox template from Ubuntu cloud image (one-time)
#   2. Clones VM from template with GPU passthrough + cloud-init
#   3. Configures vIOMMU and joins cluster via kubeadm

locals {
  ubuntu_gpu_enabled        = var.ubuntu_gpu_worker.enabled
  ubuntu_template_name      = "ubuntu-2410-cloudimg"
  ubuntu_template_vmid      = 9001
  ubuntu_cloud_image_url    = "https://cloud-images.ubuntu.com/releases/24.10/release/ubuntu-24.10-server-cloudimg-amd64.img"
  ubuntu_cloud_image_file   = "/var/lib/vz/template/iso/ubuntu-24.10-server-cloudimg-amd64.img"
  ubuntu_cloudinit_snippet  = "local:snippets/cloud-init-ubuntu-gpu.yaml"
}

# Step 1: Download Ubuntu cloud image (idempotent)
resource "null_resource" "ubuntu_cloud_image" {
  count = local.ubuntu_gpu_enabled ? 1 : 0
  triggers = {
    url       = local.ubuntu_cloud_image_url
    target    = local.ubuntu_cloud_image_file
    node_ip   = "192.168.88.242"
  }
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      NODE="192.168.88.242"
      IMG="${local.ubuntu_cloud_image_file}"
      if ! ssh root@$$NODE "[ -f $$IMG ]" 2>/dev/null; then
        echo "=== Downloading Ubuntu cloud image on ton03 ==="
        ssh root@$$NODE "wget -q --show-progress -O $$IMG '${local.ubuntu_cloud_image_url}'"
      fi
      echo "Image: $$(ssh root@$$NODE "ls -lh $$IMG | awk '{print \$$5}'")"
    EOT
    interpreter = ["bash", "-c"]
  }
}

# Step 2: Create Proxmox template from cloud image (idempotent)
resource "null_resource" "create_ubuntu_template" {
  count = local.ubuntu_gpu_enabled ? 1 : 0
  depends_on = [null_resource.ubuntu_cloud_image]
  triggers = {
    template_vmid = local.ubuntu_template_vmid
    image_file    = local.ubuntu_cloud_image_file
  }
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      NODE="192.168.88.242"
      VMID=${local.ubuntu_template_vmid}
      NAME="${local.ubuntu_template_name}"
      IMG="${local.ubuntu_cloud_image_file}"
      STORAGE="${var.proxmox_storage_device}"

      # Check if template already exists
      if ssh root@$$NODE "qm list 2>/dev/null | grep -qw $${VMID}"; then
        echo "=== Template '$$NAME' already exists (VMID $${VMID}) ==="
        exit 0
      fi

      echo "=== Copying cloud-init snippet to Proxmox ==="
      ssh root@$$NODE "mkdir -p /var/lib/vz/snippets"
      scp "${path.module}/templates/cloud-init-ubuntu-gpu.yaml" root@$$NODE:/var/lib/vz/snippets/

      echo "=== Creating Proxmox template '$$NAME' ==="
      ssh root@$$NODE "
        qm create $${VMID} --memory 2048 --net0 virtio,bridge=vmbr0 --name $${NAME}
        qm importdisk $${VMID} $${IMG} $${STORAGE}
        qm set $${VMID} --scsihw virtio-scsi-pci --virtio0 $${STORAGE}:vm-$${VMID}-disk-0
        qm set $${VMID} --ide2 $${STORAGE}:cloudinit
        qm set $${VMID} --boot order=virtio0
        qm set $${VMID} --serial0 socket --vga serial0
        qm template $${VMID}
      "
      echo "=== Template created! ==="
    EOT
    interpreter = ["bash", "-c"]
  }
}

# Step 3: Clone VM from template with GPU passthrough + cloud-init
resource "proxmox_vm_qemu" "ubuntu_gpu_worker" {
  count       = local.ubuntu_gpu_enabled ? 1 : 0
  depends_on  = [null_resource.create_ubuntu_template]
  target_node = var.ubuntu_gpu_worker.target_node
  vmid        = var.ubuntu_gpu_worker.vmid
  name        = var.ubuntu_gpu_worker.name
  description = "Ubuntu worker with AMD GPU passthrough for KubeVirt"

  clone      = local.ubuntu_template_name
  full_clone = true

  agent    = 1
  vm_state = "running"
  start_at_node_boot = true
  memory   = var.ubuntu_gpu_worker.memory
  machine  = "q35"
  bios     = "ovmf"
  boot     = "order=virtio0;ide2"

  cpu {
    cores = var.ubuntu_gpu_worker.cpu_cores
    type  = "host"
  }

  vga { type = "std" }

  # Cloud-init via cicustom + provider fields
  os_type    = "cloud-init"
  ciuser     = "ubuntu"
  cipassword = "ubuntu"
  cicustom   = "user=${local.ubuntu_cloudinit_snippet}"
  searchdomain = "local"
  nameserver   = var.ubuntu_gpu_worker.dns
  sshkeys  = join("\n", var.ubuntu_gpu_worker.ssh_keys)
  ipconfig0 = "ip=${var.ubuntu_gpu_worker.ip_address}/24,gw=${var.ubuntu_gpu_worker.gateway}"

  network {
    id     = 0
    model  = "virtio"
    bridge = var.ubuntu_gpu_worker.bridge
  }

  # Cloud-init ISO
  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.proxmox_storage_device
  }

  # GPU passthrough
  dynamic "pci" {
    for_each = var.ubuntu_gpu_worker.pci_devices
    content {
      id         = pci.value.id
      mapping_id = pci.value.mapping_id
      pcie       = pci.value.pcie
      rombar     = pci.value.rombar
    }
  }

  # EFI disk for OVMF boot
  efidisk {
    efitype = "4m"
    storage = var.proxmox_storage_device
  }

  lifecycle {
    ignore_changes = [
      cicustom, ciuser, cipassword, sshkeys,
    ]
  }
}

# Step 4: Configure vIOMMU + join cluster via kubeadm
resource "null_resource" "setup_ubuntu_gpu" {
  count = local.ubuntu_gpu_enabled ? 1 : 0
  depends_on = [proxmox_vm_qemu.ubuntu_gpu_worker]
  triggers = {
    vm_id   = var.ubuntu_gpu_worker.vmid
    ip      = var.ubuntu_gpu_worker.ip_address
    name    = var.ubuntu_gpu_worker.name
    always  = timestamp()
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      VMID="${var.ubuntu_gpu_worker.vmid}"
      NODE="${var.ubuntu_gpu_worker.ip_address}"
      NAME="${var.ubuntu_gpu_worker.name}"
      VIP="${var.cluster_vip_shared_ip}"
      KCFG="${abspath(path.module)}/.csr-kubeconfig"
      PVE_HOST="192.168.88.242"

      # Step 1: Stop VM, set viommu=intel, resize disk, start
      echo "=== Configuring vIOMMU + resizing disk on ton03 ==="
      ssh root@$$PVE_HOST "qm stop $${VMID} --skiplock 2>/dev/null; sleep 2; qm set $${VMID} -machine 'q35,viommu=intel'; qm resize $${VMID} virtio0 ${var.ubuntu_gpu_worker.disk_size}; qm start $${VMID}" || true

      # Step 2: Wait for SSH (cloud-init first boot — installing packages)
      echo "=== Waiting for SSH (phase 1 — cloud-init) ==="
      for i in $$(seq 1 60); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$$NODE "echo ready" 2>/dev/null; then
          echo "SSH ready after $${i} x 10s"
          break
        fi
        sleep 10
      done

      # Step 3: Wait for cloud-init to finish + reboot
      echo "=== Waiting for cloud-init to complete + VM reboot ==="
      sleep 90
      echo "=== Waiting for SSH (phase 2 — after reboot) ==="
      for i in $$(seq 1 60); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$$NODE "echo ready" 2>/dev/null; then
          echo "SSH ready after $${i} x 10s"
          break
        fi
        sleep 10
      done

      # Step 4: Verify VFIO modules are loaded
      echo "=== Verifying VFIO modules ==="
      ssh ubuntu@$$NODE "sudo lsmod | grep vfio || echo 'WARNING: VFIO modules not loaded!'"

      # Step 5: Check GPU is visible
      echo "=== Checking GPU visibility ==="
      ssh ubuntu@$$NODE "sudo lspci -nn | grep -i amd || echo 'No AMD GPU found via lspci'"

      # Step 6: Join cluster via kubeadm
      echo "=== Joining Talos cluster ==="
      TOKEN=$(openssl rand -hex 3).$(openssl rand -hex 8)
      kubectl --kubeconfig="$$KCFG" create secret generic "bootstrap-token-$${TOKEN%.*}" -n kube-system \
        --type="bootstrap.kubernetes.io/token" \
        --from-literal="token-id=$${TOKEN%.*}" \
        --from-literal="token-secret=$${TOKEN#*.}" \
        --from-literal="usage-bootstrap-authentication=true" \
        --from-literal="usage-bootstrap-signing=true" 2>/dev/null || true

      ssh ubuntu@$$NODE "sudo kubeadm join $${VIP}:6443 \
        --token $${TOKEN} \
        --discovery-token-unsafe-skip-ca-verification \
        --node-name=$${NAME} \
        --ignore-preflight-errors=All" 2>&1

      # Step 7: Label the node
      echo "=== Labeling node ==="
      kubectl --kubeconfig="$$KCFG" label node $${NAME} node-role.kubernetes.io/worker="" --overwrite 2>/dev/null || true

      echo "====================================================="
      echo "  DONE: Ubuntu GPU worker joined the cluster!"
      echo "  Node: $${NAME}"
      echo "  GPU:  AMD Radeon (1002:1636) via PCI passthrough"
      echo "====================================================="
      echo ""
      echo "Next steps:"
      echo "  1. kubectl get nodes"
      echo "  2. Configure KubeVirt to expose GPU as permittedHostDevices"
      echo "  3. Deploy Windows VM via KubeVirt with GPU"
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}
