# GPU Worker LXC — joins the Talos cluster via kubeadm
# Architecture:
#   Proxmox host (amdgpu /dev/dri)
#     └─ LXC privilegiado (kubeadm join → Talos cluster)
#          ├─ /dev/dri montado do host → pods acessam GPU
#          └─ kubelet + containerd para workloads GPU
locals {
  lxc_gpu_enabled = true
  lxc_gpu_vmid    = 130
  lxc_gpu_name    = "ton-cluster-k8s-worker-2"
  lxc_gpu_ip      = "192.168.88.221"
  lxc_gpu_memory  = 8192
  lxc_gpu_cores   = 4
  lxc_gpu_disk    = "40G"
}

# Download Ubuntu LXC template (idempotent)
resource "null_resource" "lxc_ubuntu_template" {
  count = local.lxc_gpu_enabled ? 1 : 0
  triggers = {
    template = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  }
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      NODE="192.168.88.242"
      TEMPLATE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
      if ! ssh root@$NODE "pveam list local 2>/dev/null | grep -q $TEMPLATE"; then
        echo "=== Downloading LXC template ==="
        ssh root@$NODE "pveam download local $TEMPLATE"
      fi
      echo "Template ready"
    EOT
    interpreter = ["bash", "-c"]
  }
}

# Create GPU worker LXC
resource "proxmox_lxc" "gpu_worker" {
  count       = local.lxc_gpu_enabled ? 1 : 0
  depends_on  = [null_resource.lxc_ubuntu_template]
  target_node = "ton03"
  vmid        = local.lxc_gpu_vmid
  hostname    = local.lxc_gpu_name
  ostemplate  = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  password    = "ubuntu"
  unprivileged = false
  memory      = local.lxc_gpu_memory
  cores       = local.lxc_gpu_cores
  swap        = 2048
  description = "GPU worker with amdgpu via /dev/dri, joins Talos cluster"
  tags        = "gpu,worker,kubeadm"

  # Networking
  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = "${local.lxc_gpu_ip}/24"
    gw     = "192.168.88.1"
    ip6    = "auto"
  }

  # Root filesystem
  rootfs {
    storage = var.proxmox_storage_device
    size    = local.lxc_gpu_disk
  }

  # Features
  features {
    nesting = true
    fuse    = true
    keyctl  = true
  }

  # SSH key for management
  ssh_public_keys = join("\n", var.ubuntu_gpu_worker.ssh_keys)

  # Run on Proxmox host boot
  onboot = true

  startup = "order=3"
}

# Setup: install kubelet + kubeadm + containerd + join cluster
resource "null_resource" "setup_lxc_gpu" {
  count = local.lxc_gpu_enabled ? 1 : 0
  depends_on = [proxmox_lxc.gpu_worker]
  triggers = {
    ip      = local.lxc_gpu_ip
    name    = local.lxc_gpu_name
    always  = timestamp()
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      NODE="${local.lxc_gpu_ip}"
      NAME="${local.lxc_gpu_name}"
      VIP="${var.cluster_vip_shared_ip}"
      KCFG="${abspath(path.module)}/.csr-kubeconfig"

      # Step 1: Wait for container SSH
      echo "=== Waiting for LXC SSH ==="
      for i in $(seq 1 30); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$NODE "echo ready" 2>/dev/null; then
          echo "SSH ready after $(( i * 10 ))s"
          break
        fi
        sleep 10
      done

      # Step 2: Configure bind mounts for GPU (/dev/dri + /dev/kvm)
      echo "=== Configuring bind mounts on LXC ==="
      ssh root@192.168.88.242 "pct set ${local.lxc_gpu_vmid} -mp0 /dev/dri,mp=/dev/dri 2>/dev/null; pct set ${local.lxc_gpu_vmid} -mp1 /dev/kvm,mp=/dev/kvm 2>/dev/null; pct reboot ${local.lxc_gpu_vmid} 2>/dev/null; sleep 10" || true

      # Step 3: Install kubelet, kubeadm, containerd
      echo "=== Installing k8s packages ==="
      ssh ubuntu@$NODE "sudo bash -c '
        set -e
        apt-get update -qq
        apt-get install -y -qq curl wget gnupg ca-certificates apt-transport-https jq containerd

        # Kubernetes apt repo
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo \"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /\" > /etc/apt/sources.list.d/kubernetes.list
        apt-get update -qq
        apt-get install -y -qq kubelet kubeadm kubectl
        apt-mark hold kubelet kubeadm kubectl

        # Configure containerd
        mkdir -p /etc/containerd
        containerd config default > /etc/containerd/config.toml
        sed -i \"s/SystemdCgroup = false/SystemdCgroup = true/\" /etc/containerd/config.toml
        systemctl enable containerd
        systemctl start containerd

        # Disable swap (requirement for kubelet)
        swapoff -a
        sed -i \"/ swap /d\" /etc/fstab || true

        # Enable modules
        modprobe overlay
        modprobe br_netfilter
        echo \"overlay\" >> /etc/modules-load.d/k8s.conf
        echo \"br_netfilter\" >> /etc/modules-load.d/k8s.conf

        # sysctl
        cat > /etc/sysctl.d/k8s.conf << \"SYSCTL\"
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL
        sysctl --system

        # Wait for containerd to be ready
        sleep 5
        ctr version >/dev/null 2>&1 || echo \"Warning: containerd not ready\"

        echo \"INSTALL_DONE\"
      '" 2>&1

      # Step 3: Verify GPU is visible (amdgpu)
      echo "=== Checking GPU access ==="
      ssh ubuntu@$NODE "ls -la /dev/dri/ 2>/dev/null || echo 'WARNING: no /dev/dri'"

      # Step 4: Delete old Talos worker-2 node if it still exists
      echo "=== Cleaning up old Talos node ==="
      kubectl --kubeconfig="$KCFG" delete node ton-cluster-k8s-worker-2 --ignore-not-found 2>/dev/null || true
      kubectl --kubeconfig="$KCFG" delete node worker-2 --ignore-not-found 2>/dev/null || true

      # Step 5: Join cluster
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
        --ignore-preflight-errors=All,SystemVerification,FileContent--proc-sys-net-bridge-bridge-nf-call-iptables,FileContent--proc-sys-net-ipv4-ip_forward" 2>&1

      # Step 6: Label the node
      echo "=== Labeling node ==="
      kubectl --kubeconfig="$KCFG" label node $NAME node-role.kubernetes.io/worker="" --overwrite 2>/dev/null || true
      kubectl --kubeconfig="$KCFG" label node $NAME gpu.amd.com/node=lxc-gpu --overwrite 2>/dev/null || true

      echo "====================================================="
      echo "  DONE: LXC GPU worker joined the cluster!"
      echo "  Node: $NAME"
      echo "  GPU:  AMD Renoir via /dev/dri (amdgpu)"
      echo "  Label: gpu.amd.com/node=lxc-gpu"
      echo "====================================================="
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}
