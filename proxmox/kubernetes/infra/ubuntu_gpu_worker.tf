# Ubuntu GPU Worker — joins the Talos cluster automatically
# Receives the AMD GPU via PCI passthrough for KubeVirt nested VFIO
resource "null_resource" "ubuntu_cloud_image" {
  count = var.ubuntu_gpu_worker.enabled ? 1 : 0
  triggers = {
    url = "https://cloud-images.ubuntu.com/releases/24.10/release/ubuntu-24.10-server-cloudimg-amd64.img"
  }
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      IMG="/var/lib/vz/template/iso/ubuntu-24.10-server-cloudimg-amd64.img"
      if [ ! -f "$IMG" ]; then
        wget -q --show-progress -O "$IMG" \
          "https://cloud-images.ubuntu.com/releases/24.10/release/ubuntu-24.10-server-cloudimg-amd64.img"
      fi
      echo "Image ready: $(ls -lh $IMG | awk '{print $5}')"
    EOT
    interpreter = ["bash", "-c"]
  }
}

# Ubuntu GPU Worker
resource "proxmox_vm_qemu" "ubuntu_gpu_worker" {
  count       = var.ubuntu_gpu_worker.enabled ? 1 : 0
  name        = var.ubuntu_gpu_worker.name
  description = "Ubuntu worker with AMD GPU passthrough for KubeVirt"
  target_node = var.ubuntu_gpu_worker.target_node
  vmid        = var.ubuntu_gpu_worker.vmid

  agent    = 1
  vm_state = "running"
  start_at_node_boot = true
  memory   = var.ubuntu_gpu_worker.memory
  machine  = "q35"
  bios     = "ovmf"
  boot     = "order=virtio0;ide0"

  cpu {
    cores = var.ubuntu_gpu_worker.cpu_cores
    type  = "host"
  }

  vga { type = "std" }

  os_type    = "cloud-init"
  ciuser     = "ubuntu"
  cipassword = "ubuntu"
  searchdomain = "local"
  nameserver   = var.ubuntu_gpu_worker.dns
  sshkeys  = join("\n", var.ubuntu_gpu_worker.ssh_keys)
  ipconfig0 = "ip=${var.ubuntu_gpu_worker.ip_address}/24,gw=${var.ubuntu_gpu_worker.gateway}"

  network {
    id     = 0
    model  = "virtio"
    bridge = var.ubuntu_gpu_worker.bridge
  }

  disk {
    slot    = "virtio0"
    type    = "disk"
    storage = var.proxmox_storage_device
    size    = var.ubuntu_gpu_worker.disk_size
    discard = true
  }

  disk {
    slot    = "ide0"
    type    = "cloudinit"
    storage = var.proxmox_storage_device
  }

  dynamic "pci" {
    for_each = var.ubuntu_gpu_worker.pci_devices
    content {
      id         = pci.value.id
      mapping_id = pci.value.mapping_id
      pcie       = pci.value.pcie
      rombar     = pci.value.rombar
    }
  }

  efidisk {
    efitype = "4m"
    storage = var.proxmox_storage_device
  }

  lifecycle {
    ignore_changes = [ disk[0].format, disk[1].format, cicustom, ciuser, cipassword, sshkeys ]
  }
}

# Sets vIOMMU and joins node to cluster after boot
resource "null_resource" "setup_ubuntu_gpu" {
  count = var.ubuntu_gpu_worker.enabled ? 1 : 0
  depends_on = [proxmox_vm_qemu.ubuntu_gpu_worker]
  triggers = { vm_id = var.ubuntu_gpu_worker.vmid, ip = var.ubuntu_gpu_worker.ip_address, always = timestamp() }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      VMID="${var.ubuntu_gpu_worker.vmid}"
      NODE="${var.ubuntu_gpu_worker.ip_address}"
      NAME="${var.ubuntu_gpu_worker.name}"
      VIP="${var.cluster_vip_shared_ip}"
      KCFG="${abspath(path.module)}/.csr-kubeconfig"

      # Step 1: Stop VM, set viommu=intel, start
      echo "=== Configuring vIOMMU ==="
      ssh root@192.168.88.242 "qm stop $${VMID} --skiplock 2>/dev/null; sleep 2; qm set $${VMID} -machine 'q35,viommu=intel'; qm start $${VMID}" || true

      # Step 2: Wait for SSH
      echo "=== Waiting for SSH ==="
      for i in $$(seq 1 60); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$$NODE "echo ready" 2>/dev/null; then
          echo "SSH ready after $${i}s"
          break
        fi
        sleep 10
      done

      # Step 3: Join cluster
      echo "=== Joining cluster ==="
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

      echo "=== DONE: Ubuntu GPU worker joined the cluster! ==="
      echo "Next: kubectl label node $${NAME} node-role.kubernetes.io/worker=""
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}
