#!/bin/bash
set -e
set -x

# Source the variables from the terraform tfvars file
echo "Debugging Flux installation..."

# Try to find the kubeconfig
for path in "$HOME/.bootstrap-kubeconfig" "../proxmox/.bootstrap-kubeconfig" "$HOME/.kube/config" ".kubeconfig"; do
  if [ -f "$path" ]; then
    echo "Found kubeconfig at: $path"
    export KUBECONFIG="$path"
    break
  fi
done

if [ -z "$KUBECONFIG" ]; then
  echo "ERROR: Could not find kubeconfig file"
  exit 1
fi

echo "Using KUBECONFIG: $KUBECONFIG"

# Check contexts
kubectl config get-contexts

# Try to connect
echo "Testing cluster connection..."
kubectl cluster-info --context talos-default || kubectl cluster-info

# Check current namespaces
echo "Current namespaces:"
kubectl get namespace | grep flux || echo "No flux namespace found"

# Try to install flux
echo "Installing Flux operator..."
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

echo "Applying Flux operator manifest..."
kubectl apply --server-side -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/v0.38.1/install.yaml

echo "Checking CRDs..."
kubectl get crd | grep fluxcd || echo "No flux CRDs found"

echo "Waiting for CRDs..."
kubectl wait --for condition=established --timeout=300s crd/fluxinstances.fluxcd.controlplane.io

echo "Checking flux-system namespace..."
kubectl get namespace flux-system

echo "Checking flux-operator deployment..."
kubectl get deployment -n flux-system

echo "Waiting for flux-operator..."
kubectl wait --for=condition=available --timeout=600s deployment/flux-operator -n flux-system

echo "Flux installation complete!"
