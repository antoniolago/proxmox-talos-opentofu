#!/bin/bash
set -e
set -x

# Use the correct kubeconfig
export KUBECONFIG="/home/tonio/.kube/config"

echo "Applying FluxInstance..."

# Apply the FluxInstance manifest
kubectl apply -f - <<EOF
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
  annotations:
    fluxcd.controlplane.io/reconcile: "enabled"
    fluxcd.controlplane.io/reconcileEvery: "1h"
    fluxcd.controlplane.io/reconcileTimeout: "3m"
spec:
  sync:
    kind: GitRepository
    url: https://github.com/antoniolago/lag0-fleet-infra-ton
    ref: refs/heads/main
    path: cluster
    pullSecret: github-credentials
  distribution:
    version: 2.x
    registry: ghcr.io/fluxcd
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
    - image-reflector-controller
    - image-automation-controller
  cluster:
    type: kubernetes
EOF

echo "Checking FluxInstance status..."
kubectl get fluxinstance flux -n flux-system

echo "Waiting for FluxInstance to be ready..."
kubectl wait --for=condition=ready --timeout=600s fluxinstance/flux -n flux-system

echo "Checking Flux components..."
kubectl get pods -n flux-system

echo "FluxInstance applied successfully!"
