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
        --rootfs local-lvm:${replace(local.lxc_gpu_disk, "G", "")} \\
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
# Kubelet requires write access to sysctls
lxc.cgroup2.devices.allow: c 1:9 rwm
lxc.mount.entry: /proc/sys/vm/overcommit_memory proc/sys/vm/overcommit_memory none bind,optional,create=file
lxc.mount.entry: /proc/sys/kernel/panic proc/sys/kernel/panic none bind,optional,create=file
lxc.mount.entry: /proc/sys/kernel/panic_on_oops proc/sys/kernel/panic_on_oops none bind,optional,create=file
CONF"
      echo "LXC config written. Rebooting..."
      # Ensure host sysctls are set for kubelet in LXC
      ssh root@$HOST "echo 'vm.overcommit_memory=1' > /etc/sysctl.d/99-kubelet-lxc.conf && echo 'kernel.panic=10' >> /etc/sysctl.d/99-kubelet-lxc.conf && echo 'kernel.panic_on_oops=0' >> /etc/sysctl.d/99-kubelet-lxc.conf && sysctl -p /etc/sysctl.d/99-kubelet-lxc.conf" 2>/dev/null || true
      ssh root@$HOST "pct reboot $VMID" 2>/dev/null || true
      sleep 5
      # Ensure LXC is running after reboot
      ssh root@$HOST "pct start $VMID" 2>/dev/null || true
      sleep 3
      # Create ubuntu user (lost on LXC recreation)
      ssh root@$HOST "pct exec $VMID -- useradd -m -s /bin/bash -G sudo ubuntu 2>/dev/null; echo 'ubuntu:ubuntu' | pct exec $VMID -- chpasswd; bash -c 'echo \"ubuntu ALL=(ALL) NOPASSWD:ALL\" | pct exec $VMID -- tee /etc/sudoers.d/ubuntu > /dev/null && pct exec $VMID -- chmod 440 /etc/sudoers.d/ubuntu'" 2>/dev/null || true
      # Install KubePrism proxy (required by Talos flannel daemonset before kubelet starts)
      ssh root@$HOST "pct exec $VMID -- apt-get install -y -qq socat 2>/dev/null" || true
      ssh root@$HOST "pct exec $VMID -- bash -c 'cat > /etc/systemd/system/kubeprism-proxy.service << KPP
[Unit]
Description=KubePrism proxy for Talos (127.0.0.1:7445 -> API server)
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:7445,fork,reuseaddr TCP:192.168.88.200:6443
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
KPP
systemctl daemon-reload
systemctl enable kubeprism-proxy
systemctl restart kubeprism-proxy'" 2>/dev/null || true
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
      KCFG="${abspath(path.module)}/.csr-kubeconfig"

      # Wait for LXC SSH
      echo "=== Waiting for LXC SSH ==="
      for i in $(seq 1 60); do
        if sshpass -p ubuntu ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$NODE "echo ready" 2>/dev/null; then
          echo "SSH ready after $(( i * 10 ))s"
          break
        fi
        sleep 10
      done

      # Write setup script locally, SCP it, execute
      echo "=== Generating setup script ==="
      cat > /tmp/lxc-setup.sh << 'SCRIPT_B64'
#!/bin/bash
set -e
apt-get update -qq
apt-get install -y -qq curl wget gnupg ca-certificates apt-transport-https jq containerd
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
mkdir -p /etc/containerd/conf.d
cat > /etc/containerd/conf.d/disable-apparmor.toml << 'C1'
version = 3
[plugins."io.containerd.cri.v1.runtime"]
  disable_apparmor = true
C1
containerd config default > /etc/containerd/config.toml 2>/dev/null || true
sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml
systemctl enable containerd; systemctl restart containerd
echo 'KUBELET_EXTRA_ARGS=--fail-swap-on=false' > /etc/default/kubelet
swapoff -a 2>/dev/null || true
mkdir -p /var/lib/kubelet
cat > /var/lib/kubelet/config.yaml << 'C3'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
clusterDNS:
  - 10.253.0.10
clusterDomain: cluster.local
serverTLSBootstrap: true
rotateCertificates: true
C3
echo 'KUBELET_KUBEADM_ARGS=--cluster-dns=10.253.0.10' > /var/lib/kubelet/kubeadm-flags.env
printf "net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n" > /etc/sysctl.d/k8s.conf
sysctl --system >/dev/null 2>&1
mknod /dev/kmsg c 1 11 2>/dev/null || true; chmod 666 /dev/kmsg 2>/dev/null || true
if [ ! -f /opt/cni/bin/bridge ]; then
  mkdir -p /opt/cni/bin
  curl -sL "https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz" -o /tmp/cni-plugins.tgz
  tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin/
  rm -f /tmp/cni-plugins.tgz
fi
apt-get install -y -qq jq 2>/dev/null || true
# Install flannel CNI binary
if [ ! -f /opt/cni/bin/flannel ]; then
  curl -sL "https://github.com/flannel-io/cni-plugin/releases/download/v1.9.1-flannel1/flannel-amd64" -o /tmp/flannel
  chmod +x /tmp/flannel
  mv /tmp/flannel /opt/cni/bin/flannel
fi
echo "INSTALL_DONE"
SCRIPT_B64

      echo "=== Copying + executing setup on LXC ==="
      sshpass -p ubuntu scp -o StrictHostKeyChecking=no /tmp/lxc-setup.sh ubuntu@$NODE:/tmp/lxc-setup.sh
      sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@$NODE "sudo bash /tmp/lxc-setup.sh" 2>&1

      # Verify GPU and join cluster
      echo "=== Checking GPU access ==="
      sshpass -p ubuntu ssh ubuntu@$NODE "ls -la /dev/dri/ 2>/dev/null || echo 'WARNING: no /dev/dri'"

      echo "=== Joining Talos cluster ==="
      kubectl --kubeconfig="$KCFG" delete node $NAME --ignore-not-found 2>/dev/null || true
      TOKEN=$(openssl rand -hex 3).$(openssl rand -hex 8)
      kubectl --kubeconfig="$KCFG" create secret generic "bootstrap-token-$${TOKEN%.*}" -n kube-system \
        --type="bootstrap.kubernetes.io/token" \
        --from-literal="token-id=$${TOKEN%.*}" \
        --from-literal="token-secret=$${TOKEN#*.}" \
        --from-literal="usage-bootstrap-authentication=true" \
        --from-literal="usage-bootstrap-signing=true" \
        --from-literal="extra-groups=system:bootstrappers:nodes" 2>/dev/null || true
      cat <<RBAC | kubectl --kubeconfig="$KCFG" apply -f - 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lxc-bootstrap-$${TOKEN%.*}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-bootstrapper
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: system:bootstrap:$${TOKEN%.*}
RBAC
      cat > /tmp/lxc-bootstrap.conf << BOOTCFG
apiVersion: v1
clusters:
- cluster:
    server: https://$VIP:6443
    insecure-skip-tls-verify: true
  name: default-cluster
contexts:
- context:
    cluster: default-cluster
    namespace: default
    user: tls-bootstrap-token-user
  name: tls-bootstrap-token-user@default-cluster
current-context: tls-bootstrap-token-user@default-cluster
kind: Config
users:
- name: tls-bootstrap-token-user
  user:
    token: $TOKEN
BOOTCFG
      sshpass -p ubuntu scp -o StrictHostKeyChecking=no /tmp/lxc-bootstrap.conf ubuntu@$NODE:/tmp/bootstrap.conf
      sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@$NODE "sudo mkdir -p /etc/kubernetes && sudo cp /tmp/bootstrap.conf /etc/kubernetes/bootstrap-kubelet.conf && sudo chmod 600 /etc/kubernetes/bootstrap-kubelet.conf && sudo systemctl start kubelet"

      # Approve CSRs and label
      echo "=== Approving CSRs + labeling ==="
      for i in $(seq 1 15); do
        kubectl --kubeconfig="$KCFG" get csr -o json 2>/dev/null | \
          jq -r '.items[] | select(.status.conditions == null) | .metadata.name' 2>/dev/null | \
          xargs -I{} kubectl --kubeconfig="$KCFG" certificate approve {} 2>/dev/null || true
        if kubectl --kubeconfig="$KCFG" get node $NAME 2>/dev/null >/dev/null; then
          echo "Node $NAME registered!"
          kubectl --kubeconfig="$KCFG" label node $NAME \
            node-role.kubernetes.io/worker="" gpu.amd.com/node=lxc-gpu --overwrite 2>/dev/null || true
          break
        fi
        sleep 4
      done

      echo "====================================================="
      echo "  DONE: LXC GPU worker ready!"
      echo "  Node: $NAME ($NODE)"
      echo "====================================================="
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
