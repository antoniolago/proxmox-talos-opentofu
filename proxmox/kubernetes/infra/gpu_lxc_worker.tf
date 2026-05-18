# GPU worker LXC — joins the Talos cluster via kubeadm
# FULLY AUTOMATED: tofu create -> LXC created, configured, joined cluster
# tofu destroy -> LXC destroyed, node removed from cluster
#
# Architecture:
#   Proxmox host (amdgpu /dev/dri)
#     └─ LXC privilegiado (kubeadm join → Talos cluster)
#          ├─ /dev/dri montado do host → pods acessam GPU
#          ├─ /dev/fuse montado → fuse-overlayfs disponível
#          ├─ AppArmor unconfined → runc pode montar proc/overlay
#          ├─ systemd-networkd override → sandboxing LXC compatível
#          ├─ containerd com disable_apparmor → pods não falham loading profile
#          └─ bridge CNI → pod networking sem depender de flannel

locals {
  lxc_gpu_enabled   = true
  lxc_gpu_vmid      = 130
  lxc_gpu_name      = "ton-cluster-k8s-worker-2"
  lxc_gpu_ip        = "192.168.88.221"
  lxc_gpu_memory    = 8192
  lxc_gpu_cores     = 4
  lxc_gpu_disk      = "40G"
  lxc_gpu_template  = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

# Step 0: Create LXC on Proxmox host (API token lacks root@pam for privileged LXC)
resource "null_resource" "create_lxc_gpu" {
  count = local.lxc_gpu_enabled ? 1 : 0
  triggers = {
    vmid    = local.lxc_gpu_vmid
    name    = local.lxc_gpu_name
    host    = "192.168.88.242"
    always  = timestamp()
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      HOST="192.168.88.242"
      VMID=${local.lxc_gpu_vmid}
      TEMPLATE="${local.lxc_gpu_template}"

      echo "=== Creating LXC $VMID on $HOST ==="

      # Check if LXC already exists
      if ssh root@$HOST "pct list 2>/dev/null | grep -qw $VMID"; then
        echo "LXC $VMID already exists, skipping creation"
        exit 0
      fi

      ssh root@$HOST "pct create $VMID $TEMPLATE \
        --hostname ${local.lxc_gpu_name} \
        --storage local-lvm \
        --rootfs local-lvm:${local.lxc_gpu_disk} \
        --memory ${local.lxc_gpu_memory} \
        --cores ${local.lxc_gpu_cores} \
        --swap 2048 \
        --net0 name=eth0,bridge=vmbr0,ip=${local.lxc_gpu_ip}/24,gw=192.168.88.1 \
        --unprivileged 0 \
        --password ubuntu \
        --onboot 1 \
        --startup order=3 \
        --tags gpu,kubeadm,worker \
        2>&1"

      echo "LXC $VMID created successfully"
    SCRIPT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-SCRIPT
      set -e
      HOST="192.168.88.242"
      VMID=${self.triggers.vmid}
      NAME="${self.triggers.name}"

      echo "=== Destroying LXC $VMID ==="

      # Remove from Kubernetes first
      kubectl delete node $NAME --ignore-not-found 2>/dev/null || true

      # Destroy LXC
      ssh root@$HOST "pct stop $VMID --skiplock 2>/dev/null; pct destroy $VMID --purge 2>&1" || true

      echo "LXC $VMID destroyed"
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# Step 1: Configure LXC on the Proxmox host (apparmor, devices, mounts)
resource "null_resource" "configure_lxc_gpu_config" {
  count = local.lxc_gpu_enabled ? 1 : 0
  depends_on = [null_resource.create_lxc_gpu]
  triggers = {
    vmid    = local.lxc_gpu_vmid
    host    = local.proxmox_host
    always  = timestamp()
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      HOST="192.168.88.242"
      VMID=${local.lxc_gpu_vmid}

      echo "=== Configuring LXC $VMID on $HOST ==="

      ssh root@$HOST "cat > /etc/pve/lxc/$VMID.conf << 'CONF'
# GPU worker LXC - managed by tofu
arch: amd64
cmode: tty
console: 1
cores: ${local.lxc_gpu_cores}
cpulimit: 0
cpuunits: 1024
hostname: ${local.lxc_gpu_name}
memory: ${local.lxc_gpu_memory}
net0: name=eth0,bridge=vmbr0,gw=192.168.88.1,hwaddr=BC:24:11:38:A3:ED,ip=${local.lxc_gpu_ip}/24,ip6=auto,type=veth
onboot: 1
ostype: ubuntu
protection: 0
rootfs: local-lvm:vm-${local.lxc_gpu_vmid}-disk-0,size=${local.lxc_gpu_disk}
startup: order=3
swap: 2048
tags: gpu;kubeadm;worker
tty: 2
# LXC critical fixes for kubelet:
lxc.mount.auto: cgroup:rw sys:rw
lxc.autodev: 1
lxc.apparmor.profile: unconfined
# GPU passthrough
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
# KVM for nested virtualization
lxc.cgroup2.devices.allow: c 10:232 rwm
lxc.mount.entry: /dev/kvm dev/kvm none bind,optional,create=file
# Required for kubelet
lxc.cgroup2.devices.allow: c 1:11 rwm
lxc.cgroup2.devices.allow: c 10:229 rwm
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/kmsg dev/kmsg none bind,optional,create=file
lxc.mount.entry: /dev/fuse dev/fuse none bind,optional,create=file
CONF"
      echo "LXC config written. Rebooting..."
      ssh root@$HOST "pct reboot $VMID" 2>/dev/null || true
      sleep 5
      echo "CONFIGURE_DONE"
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# Step 2: Install k8s packages + configure everything + join cluster
resource "null_resource" "setup_lxc_gpu" {
  count = local.lxc_gpu_enabled ? 1 : 0
  depends_on = [null_resource.configure_lxc_gpu_config]
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
      HOST="192.168.88.242"
      KCFG="${abspath(path.module)}/.csr-kubeconfig"

      # Wait for LXC SSH (reboot may take time)
      echo "=== Waiting for LXC SSH ==="
      for i in $(seq 1 60); do
        if sshpass -p ubuntu ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$NODE "echo ready" 2>/dev/null; then
          echo "SSH ready after $(( i * 10 ))s"
          break
        fi
        sleep 10
      done

      echo "=== Installing k8s packages + fixing LXC limitations ==="
      sshpass -p ubuntu ssh ubuntu@$NODE sudo bash -c '
        set -e

        apt-get update -qq
        apt-get install -y -qq curl wget gnupg ca-certificates apt-transport-https jq containerd

        # Kubernetes apt repo
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo \"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /\" > /etc/apt/sources.list.d/kubernetes.list
        apt-get update -qq
        apt-get install -y -qq kubelet kubeadm kubectl
        apt-mark hold kubelet kubeadm kubectl

        # === FIX 1: containerd - disable apparmor ===
        mkdir -p /etc/containerd/conf.d
        cat > /etc/containerd/conf.d/disable-apparmor.toml << \"C1\"
version = 3
[plugins.\"io.containerd.cri.v1.runtime\"]
  disable_apparmor = true
C1

        containerd config default > /etc/containerd/config.toml 2>/dev/null || true
        sed -i \"s/SystemdCgroup = false/SystemdCgroup = true/\" /etc/containerd/config.toml
        systemctl enable containerd
        systemctl restart containerd

        # === FIX 2: systemd-networkd override (LXC compat) ===
        mkdir -p /etc/systemd/system/systemd-networkd.service.d/
        cat > /etc/systemd/system/systemd-networkd.service.d/lxc-override.conf << \"C2\"
[Service]
ProtectSystem=no
ProtectHome=no
ProtectControlGroups=no
ProtectKernelModules=no
ProtectKernelLogs=no
ProtectClock=no
ProtectProc=default
RestrictNamespaces=no
LockPersonality=no
MemoryDenyWriteExecute=no
RestrictRealtime=no
RestrictSUIDSGID=no
SystemCallFilter=
SystemCallErrorNumber=
C2
        systemctl daemon-reload
        systemctl restart systemd-networkd

        # === FIX 3: kubelet swap + config ===
        echo \"KUBELET_EXTRA_ARGS=--fail-swap-on=false\" > /etc/default/kubelet
        swapoff -a
        sed -i \"/swap/d\" /etc/fstab || true

        mkdir -p /var/lib/kubelet
        cat > /var/lib/kubelet/config.yaml << \"C3\"
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
clusterDNS:
  - 10.253.0.10
clusterDomain: cluster.local
serverTLSBootstrap: true
rotateCertificates: true
C3

        # DNS fix: create kubeadm-flags.env so --cluster-dns is on CLI too
        cat > /var/lib/kubelet/kubeadm-flags.env << \"C3dns\"
KUBELET_KUBEADM_ARGS=--cluster-dns=10.253.0.10
C3dns

        # CA cert and auth config for kubectl logs/exec
        KCFG="/etc/kubernetes/kubelet.conf"
        export KUBECONFIG="$KCFG"
        mkdir -p /etc/kubernetes/pki
        # Extract CA cert from the kubeconfig (it has certificate-authority-data from bootstrap)
        python3 -c "
import yaml, base64
with open('$KCFG') as f:
    cfg = yaml.safe_load(f)
ca = cfg.get('clusters',[{}])[0].get('cluster',{}).get('certificate-authority-data','')
if ca:
    cert = base64.b64decode(ca).decode()
    with open('/etc/kubernetes/pki/ca.crt','w') as f:
        f.write(cert)
    import os; os.chmod('/etc/kubernetes/pki/ca.crt', 0o644)
    print('CA cert extracted to /etc/kubernetes/pki/ca.crt')
else:
    print('WARNING: no certificate-authority-data in kubeconfig')
" 2>/dev/null || true

        # Add authentication config to kubelet
        python3 -c "
import yaml
with open('/var/lib/kubelet/config.yaml') as f:
    cfg = yaml.safe_load(f)
if 'authentication' not in cfg:
    cfg['authentication'] = {'x509': {'clientCAFile': '/etc/kubernetes/pki/ca.crt'}}
    with open('/var/lib/kubelet/config.yaml','w') as f:
        yaml.dump(cfg, f)
    print('Added authentication to kubelet config')
else:
    print('Authentication already configured')
" 2>/dev/null || true

        # === FIX 4: sysctl ===
        cat > /etc/sysctl.d/k8s.conf << \"C4\"
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
C4
        sysctl --system

        # === FIX 5: /dev/kmsg ===
        mknod /dev/kmsg c 1 11 2>/dev/null || true
        chmod 666 /dev/kmsg 2>/dev/null || true

        # === FIX 6: CNI plugins + bridge config ===
        if [ ! -f /opt/cni/bin/bridge ]; then
          mkdir -p /opt/cni/bin
          curl -sL \"https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz\" -o /tmp/cni-plugins.tgz
          tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin/
          rm -f /tmp/cni-plugins.tgz
          ln -sf /opt/cni/bin/flanneld /opt/cni/bin/flannel 2>/dev/null || true
        fi

        mkdir -p /etc/cni/net.d

        # Install jq
        apt-get install -y -qq jq 2>/dev/null || true

        echo \"INSTALL_DONE\"
      '\" 2>&1

      # Verify GPU
      echo \"=== Checking GPU access ===\"
      sshpass -p ubuntu ssh ubuntu@$NODE \"ls -la /dev/dri/ 2>/dev/null || echo 'WARNING: no /dev/dri'\"

      # Join cluster
      echo \"=== Joining Talos cluster ===\"
      kubectl --kubeconfig=\"$KCFG\" delete node $NAME --ignore-not-found 2>/dev/null || true

      TOKEN=$(openssl rand -hex 3).$(openssl rand -hex 8)
      kubectl --kubeconfig=\"$KCFG\" create secret generic \"bootstrap-token-$${TOKEN%.*}\" -n kube-system \
        --type=\"bootstrap.kubernetes.io/token\" \
        --from-literal=\"token-id=$${TOKEN%.*}\" \
        --from-literal=\"token-secret=$${TOKEN#*.}\" \
        --from-literal=\"usage-bootstrap-authentication=true\" \
        --from-literal=\"usage-bootstrap-signing=true\" 2>/dev/null || true

      sshpass -p ubuntu ssh ubuntu@$NODE \"sudo kubeadm join $VIP:6443 \
        --token $TOKEN \
        --discovery-token-unsafe-skip-ca-verification \
        --node-name=$NAME \
        --ignore-preflight-errors=All,SystemVerification\" 2>&1

      # Label node (retry until successful)
      echo "=== Labeling node ==="
      for retry in $(seq 1 10); do
        if kubectl --kubeconfig="$KCFG" label node $NAME \
          node-role.kubernetes.io/worker="" \
          gpu.amd.com/node=lxc-gpu \
          --overwrite 2>/dev/null; then
          echo "Node labeled successfully"
          break
        fi
        echo "Waiting for node to be ready... (attempt $retry)"
        sleep 10
      done

      # Restart kubelet
      sshpass -p ubuntu ssh ubuntu@$NODE \"sudo systemctl restart kubelet\" 2>/dev/null || true

      # Pre-pull images
      echo \"=== Pre-pulling images ===\"
      sshpass -p ubuntu ssh ubuntu@$NODE \"sudo ctr image pull registry.k8s.io/pause:3.10.1 2>&1 | tail -1\" || true
      sshpass -p ubuntu ssh ubuntu@$NODE \"sudo ctr image pull registry.k8s.io/kube-proxy:v1.36.0 2>&1 | tail -1\" || true
      sshpass -p ubuntu ssh ubuntu@$NODE \"sudo ctr image pull ghcr.io/siderolabs/flannel:v0.28.4 2>&1 | tail -1\" || true
      sshpass -p ubuntu ssh ubuntu@$NODE \"sudo ctr image pull quay.io/kubevirt/virt-handler:v1.8.2 2>&1 | tail -1\" || true
      sshpass -p ubuntu ssh ubuntu@$NODE \"sudo ctr image pull quay.io/kubevirt/virt-launcher:v1.8.2 2>&1 | tail -1\" || true

      echo \"=====================================================\"
      echo \"  DONE: LXC GPU worker ready!\"
      echo \"  Node: $NAME ($NODE)\"
      echo \"=====================================================\"
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}

# Step 3: Approve CSRs
resource "null_resource" "approve_lxc_csr" {
  count = local.lxc_gpu_enabled ? 1 : 0
  depends_on = [null_resource.setup_lxc_gpu]
  triggers = {
    name   = local.lxc_gpu_name
    always = timestamp()
  }

  provisioner "local-exec" {
    command = <<-SCRIPT
      set -e
      NAME="${local.lxc_gpu_name}"
      KCFG="${abspath(path.module)}/.csr-kubeconfig"

      echo "=== Approving CSRs for $NAME ==="
      sleep 30
      kubectl --kubeconfig="$KCFG" get csr -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.conditions == null) | .metadata.name' | \
        xargs -I {} kubectl --kubeconfig="$KCFG" certificate approve {} 2>/dev/null || true

      echo "CSR_APPROVE_DONE"
    SCRIPT
    interpreter = ["bash", "-c"]
  }
}
