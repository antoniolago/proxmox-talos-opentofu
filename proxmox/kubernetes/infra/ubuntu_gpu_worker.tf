# Ubuntu GPU Worker — joins the Talos cluster automatically
# Receives the AMD GPU via PCI passthrough for KubeVirt nested VFIO
#
# Bash variable escaping in heredocs (OpenTofu):
#   $VAR       → literal, bash expands   ✓ (when followed by space, end, or :)
#   $$VAR      → PID + "VAR" IN BASH     ✗
#   $${VAR}    → HCL escapes to ${VAR}   ✓ (use when adjacent to alphanum chars)
#   ${VAR}     → HCL tries to resolve    ✗

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
      if ! ssh root@$NODE "[ -f $IMG ]" 2>/dev/null; then
        echo "=== Downloading Ubuntu cloud image on ton03 ==="
        ssh root@$NODE "wget -q --show-progress -O $IMG '${local.ubuntu_cloud_image_url}'"
      fi
      echo "Image: $(ssh root@$NODE "ls -lh $IMG | awk '{print \$5}'")"
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
      if ssh root@$NODE "qm list 2>/dev/null | grep -qw $VMID"; then
        echo "=== Template '$NAME' already exists (VMID $VMID) ==="
        exit 0
      fi

      echo "=== Copying cloud-init snippet to Proxmox ==="
      ssh root@$NODE "mkdir -p /var/lib/vz/snippets"
      scp "${path.module}/templates/cloud-init-ubuntu-gpu.yaml" root@$NODE:/var/lib/vz/snippets/

      echo "=== Creating Proxmox template '$NAME' ==="
      ssh root@$NODE "
        qm create $VMID --memory 2048 --net0 virtio,bridge=vmbr0 --name $NAME
        qm importdisk $VMID $IMG $STORAGE
        qm set $VMID --scsihw virtio-scsi-pci --virtio0 $STORAGE:vm-$VMID-disk-0
        qm set $VMID --boot order=virtio0
        qm set $VMID --serial0 socket --vga serial0
        qm template $VMID
      "
      echo "=== Template created! ==="
    EOT
    interpreter = ["bash", "-c"]
  }
}

# Step 3: Clone VM from template (stopped — null_resource configures GPU+boot)
resource "proxmox_vm_qemu" "ubuntu_gpu_worker" {
  count       = local.ubuntu_gpu_enabled ? 1 : 0
  depends_on  = [null_resource.create_ubuntu_template]
  target_node = var.ubuntu_gpu_worker.target_node
  vmid        = var.ubuntu_gpu_worker.vmid
  name        = var.ubuntu_gpu_worker.name
  description = "Ubuntu worker with AMD GPU passthrough for KubeVirt"

  clone        = local.ubuntu_template_name
  full_clone   = true
  force_create = true

  agent    = 1
  vm_state = "stopped"  # null_resource.setup_ubuntu_gpu starts it after GPU config
  start_at_node_boot = true
  memory   = var.ubuntu_gpu_worker.memory
  machine  = "q35"
  bios     = "ovmf"

  cpu {
    cores = var.ubuntu_gpu_worker.cpu_cores
    type  = "host"
  }

  vga { type = "std" }

  # Preserve template's root disk (virtio0) — resized by null_resource
  disk {
    slot    = "virtio0"
    type    = "disk"
    storage = var.proxmox_storage_device
    size    = var.ubuntu_gpu_worker.disk_size
    discard = true
  }

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

  # EFI disk for OVMF boot
  efidisk {
    efitype = "4m"
    storage = var.proxmox_storage_device
  }

  lifecycle {
    ignore_changes = [
      cicustom, ciuser, cipassword, sshkeys, disk[0].format,
      # GPU config is managed by setup_ubuntu_gpu (raw PCI + x-vga=on)
      # viommu is managed by setup_ubuntu_gpu
      # vm_state is managed by setup_ubuntu_gpu
    ]
  }
}

# Step 4: Configure GPU (x-vga=on), viommu, start, join cluster
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
      DISK_SIZE="${var.ubuntu_gpu_worker.disk_size}"

      # Step 1: Configure GPU with x-vga=on + viommu + disk resize
      # GPU must use raw PCI with x-vga=on — AMD Renoir/Vega crashes without it
      echo "=== Configuring GPU (raw PCI + x-vga=on) + vIOMMU ==="
      ssh root@$PVE_HOST "
        qm stop $VMID --skiplock 2>/dev/null || true
        sleep 2
        # Replace mapping with raw PCI + x-vga=on
        qm set $VMID --delete hostpci0 2>/dev/null || true
        qm set $VMID -hostpci0 '0000:09:00.0,pcie=1,x-vga=on'
        qm set $VMID -hostpci1 '0000:09:00.1,pcie=1'
        qm set $VMID -machine 'q35,viommu=intel'
        qm resize $VMID virtio0 $DISK_SIZE
        qm start $VMID
      " || true

      # Step 2: Wait for SSH (cloud-init first boot — installing packages)
      echo "=== Waiting for SSH (phase 1 — cloud-init) ==="
      for i in $(seq 1 60); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$NODE "echo ready" 2>/dev/null; then
          echo "SSH ready after $(( i * 10 ))s"
          break
        fi
        sleep 10
      done

      # Step 3: Wait for cloud-init to finish + reboot
      echo "=== Waiting for cloud-init to complete + VM reboot ==="
      sleep 90
      echo "=== Waiting for SSH (phase 2 — after reboot) ==="
      for i in $(seq 1 60); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$NODE "echo ready" 2>/dev/null; then
          echo "SSH ready after $(( i * 10 ))s"
          break
        fi
        sleep 10
      done

      # Step 4: Verify VFIO modules are loaded
      echo "=== Verifying VFIO modules ==="
      ssh ubuntu@$NODE "sudo lsmod | grep vfio || echo 'WARNING: VFIO modules not loaded!'"

      # Step 5: Check GPU is visible
      echo "=== Checking GPU visibility ==="
      ssh ubuntu@$NODE "sudo lspci -nn | grep -i amd || echo 'No AMD GPU found via lspci'"

      # Step 6: Delete old Talos worker-2 node if it exists
      echo "=== Cleaning up old Talos worker-2 (if exists) ==="
      kubectl --kubeconfig="$KCFG" delete node ton-cluster-k8s-worker-2 --ignore-not-found 2>/dev/null || true

      # Step 7: Join cluster via kubeadm
      echo "=== Joining Talos cluster ==="
      TOKEN=$(openssl rand -hex 3).$(openssl rand -hex 8)
      kubectl --kubeconfig="$KCFG" create secret generic "bootstrap-token-$${TOKEN%.*}" -n kube-system \
        --type="bootstrap.kubernetes.io/token" \
        --from-literal="token-id=$${TOKEN%.*}" \
        --from-literal="token-secret=$${TOKEN#*.}" \
        --from-literal="usage-bootstrap-authentication=true" \
        --from-literal="usage-bootstrap-signing=true" 2>/dev/null || true

      ssh ubuntu@$NODE "sudo kubeadm join $VIP:6443 \
        --token $TOKEN \
        --discovery-token-unsafe-skip-ca-verification \
        --node-name=$NAME \
        --ignore-preflight-errors=All" 2>&1

      # Step 7: Fix LXC — make /proc/sys writable for kubelet
      # LXC containers mount /proc/sys read-only by default. kubelet needs to
      # write to vm.overcommit_memory, kernel.panic, kernel.panic_on_oops.
      echo "=== Fixing LXC /proc/sys writable ==="
      ssh root@$PVE_HOST "grep -q 'proc/sys' /etc/pve/lxc/$VMID.conf || echo 'lxc.mount.entry: /proc/sys proc/sys none rw,bind 0 0' >> /etc/pve/lxc/$VMID.conf" 2>/dev/null || true
      ssh root@$PVE_HOST "sysctl -w vm.overcommit_memory=1 kernel.panic=10 kernel.panic_on_oops=1" 2>/dev/null || true

      # Step 8: Install flannel CNI wrapper (bypasses broken flanneld which tries to contact etcd)
      # The original flannel CNI plugin (flanneld) when invoked with CNI_COMMAND=ADD
      # tries to connect to etcd at 127.0.0.1:4001/2379 (kubeSubnetMgr=false) and hangs.
      # This wrapper reads /run/flannel/subnet.env and delegates directly to bridge.
      echo "=== Installing flannel CNI wrapper ==="
      ssh ubuntu@$NODE "sudo tee /opt/cni/bin/flannel > /dev/null" << 'FLWRAPPER'
#!/bin/bash
set -euo pipefail
if [ -f /run/flannel/subnet.env ]; then
  source /run/flannel/subnet.env
fi
FLANNEL_SUBNET="$${FLANNEL_SUBNET:-10.252.6.0/24}"
FLANNEL_MTU="$${FLANNEL_MTU:-1450}"
FLANNEL_IPMASQ="$${FLANNEL_IPMASQ:-true}"
IP="$${FLANNEL_SUBNET%%/*}"
PREFIX="$${FLANNEL_SUBNET#*/}"
NETWORK="$${IP%.*}.0/$PREFIX"
exec /opt/cni/bin/bridge <<INNER
{
  "cniVersion": "1.0.0",
  "name": "cbr0",
  "type": "bridge",
  "bridge": "cbr0",
  "mtu": $FLANNEL_MTU,
  "isDefaultGateway": true,
  "ipMasq": $FLANNEL_IPMASQ,
  "ipam": {
    "type": "host-local",
    "subnet": "$NETWORK",
    "gateway": "$IP",
    "dataDir": "/var/lib/cni/networks"
  }
}
INNER
FLWRAPPER
      ssh ubuntu@$NODE "sudo chmod +x /opt/cni/bin/flannel" 2>/dev/null || true

      # Step 9: Label the node
      echo "=== Labeling node ==="
      kubectl --kubeconfig="$KCFG" label node $NAME node-role.kubernetes.io/worker="" --overwrite 2>/dev/null || true

      # Step 10: Fix Flannel CNI — create host directories needed for hostPath volumes
      # containerd v2.2.1 (Ubuntu 24.04) behaves differently from v2.2.3 (Talos):
      # hostPath volumes under /run/ with type="" get mounted as private tmpfs
      # instead of bind mounts. Pre-creating dirs + DirectoryOrCreate fixes this.
      echo "=== Fixing Flannel CNI host directories ==="
      ssh ubuntu@$NODE "sudo mkdir -p /etc/cni/net.d /run/flannel"

      # Step 11: Patch Flannel daemonset to use DirectoryOrCreate (idempotent)
      echo "=== Patching Flannel daemonset hostPath types ==="
      kubectl --kubeconfig="$KCFG" patch ds -n kube-system kube-flannel --type strategic --patch '
spec:
  template:
    spec:
      volumes:
        - name: run
          hostPath:
            path: /run/flannel
            type: DirectoryOrCreate
        - name: cni
          hostPath:
            path: /etc/cni/net.d
            type: DirectoryOrCreate
' 2>/dev/null || true

      # Step 12: Restart Flannel pod on this node to pick up new volume types
      echo "=== Restarting Flannel pod on $NAME ==="
      kubectl --kubeconfig="$KCFG" delete pod -n kube-system -l k8s-app=flannel \
        --field-selector spec.nodeName=$NAME --ignore-not-found 2>/dev/null || true
      sleep 5

      # Step 13: Restart kubelet to ensure clean CNI state
      echo "=== Restarting kubelet ==="
      ssh ubuntu@$NODE "sudo systemctl restart kubelet" 2>/dev/null || true
      sleep 10

      echo "====================================================="
      echo "  DONE: Ubuntu GPU worker joined the cluster!"
      echo "  Node: $NAME"
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
