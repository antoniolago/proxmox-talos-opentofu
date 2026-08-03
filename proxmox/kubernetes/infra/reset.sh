# Step 1: Replace worker nodes (runs automatically on next apply)
tofu apply

# Step 2: Wait for workers to stabilize
kubectl get nodes -w

# Step 3: Replace control planes ONE AT A TIME
# For each control plane:
# tofu taint 'proxmox_vm_qemu.kubernetes_control_plane["192.168.1.101"]'
# tofu apply

# Step 4: Verify node rejoined cluster and etcd synced before replacing next
# talosctl -n 192.168.1.101 health
# kubectl get nodes
# Check etcd health
# talosctl -n 192.168.1.101 etcd status
