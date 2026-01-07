# proxmox-talos-opentofu
A turnkey Kubernetes cluster built with [Talos Linux](https://www.talos.dev/) running on a
[Proxmox VE hypervisor](https://www.proxmox.com/en/products/proxmox-virtual-environment/overview).
Provisioning is done with [OpenTofu](https://opentofu.org/).

Kubernetes cluster features:
* Kubernetes v1.35.0
* [Flux Operator](https://fluxcd.io/flux/components/operator/) for GitOps
* [FluxInstance](https://fluxcd.io/flux/components/operator/) with full GitOps stack
* Network management handled by Flux (Istio will be reconciled via GitOps) 

This Kubernetes cluster is meant to be used in a test or home lab environment.

## Multi-Node Configuration with Granular Resource Allocation

This repository supports multi-node Kubernetes clusters with granular resource allocation. You can configure:

- **Control Plane nodes**: Specify memory, CPU cores, disk size, and target Proxmox node per node
- **Worker nodes**: Configure different resource profiles for heterogeneous workloads
- **Flexible scaling**: Add or remove nodes by modifying the `node_data` configuration
- **Multi-host deployment**: Distribute VMs across multiple Proxmox nodes for high availability

### Example Resource Profiles

The configuration example includes different worker node profiles:
- **Small workers**: 8GB RAM, 2 CPU cores, 50GB disk
- **Medium workers**: 16GB RAM, 4 CPU cores, 100GB disk  
- **Large workers**: 32GB RAM, 8 CPU cores, 200GB disk

### Per-Node Target Assignment

You can specify which Proxmox host each VM should be deployed to:
```hcl
"192.168.88.101" = {
  install_disk  = "/dev/vda"
  install_image = "factory.talos.dev/nocloud-installer/..."
  memory        = 8192
  cpu_cores     = 2
  disk_size     = "50G"
  target_node   = "proxmox-node-1"  # Deploy to specific Proxmox node
}
```

If `target_node` is not specified for a node, it will use the global `proxmox_target_node` setting. This allows you to:
- Distribute control plane nodes across multiple Proxmox hosts for HA
- Balance worker nodes based on hardware capabilities
- Optimize resource utilization across your Proxmox cluster

This allows you to allocate resources based on workload requirements - use larger nodes for database or heavy computation workloads, and smaller nodes for lightweight services.

## Requirements
You need to have installed on your local machine:
* [OpenTofu](https://opentofu.org/)
* [kubectl](https://kubernetes.io/docs/reference/kubectl/) (for testing and cluster interaction)

## Provisioning
The project is grouped in two sections:
* proxmox: provisioning of virtual machines, operating systems and Kubernetes cluster
* kubernetes: provisioning of Kubernetes cluster resources

This way you can choose to only provision the cluster itself or/and provision Kubernetes resources and bootstrap
also [Flux Operator](https://fluxcd.io/flux/components/operator/).

You will have a [Flux Operator](https://fluxcd.io/flux/components/operator/) instance running in the cluster eventually. You can then
install your applications using the GitOps approach. 

### Proxmox VE
So you want first to provision the Proxmox part: create a `configuration.auto.tfvars` file based on the example and
edit it so it suits your needs:
```shell
cd proxmox
cope configuration.auto.tfvars.example configuration.auto.tfvars
vim configuration.auto.tfvars
```
Then apply the configuration using OpenTofu:
```shell
tofu init
tofu plan
tofu apply
```
You can then grab and move the kube config file for Kubernetes provisioning like so:
```shell
tofu output kubeconfig -raw > ~/.kube/config
chmod 600 ~/.kube/config
```
Test if your cluster access works by listing the nodes:
```shell
kubectl get nodes
```
You might need to wait a bit until the cluster comes up. Proceed with the next step when all nodes are in the `ready`
state.

### Kubernetes
Secondly, you can provision the Resources inside the Kubernetes cluster. This project installs:
- Flux Operator in the `flux-system` namespace
- GitHub credentials secret for GitRepository authentication
- FluxInstance manifest that configures your GitOps repository
- Vaultwarden Kubernetes Secrets sync service in the `vaultwarden-system` namespace

The FluxInstance will reconcile your Git repository and install Istio and other components via GitOps. The Vaultwarden Kubernetes Secrets service will sync secrets from your Vaultwarden instance to Kubernetes secrets. You need to create a `configuration.auto.tfvars` file as well first:
```shell
cd kubernetes
cp configuration.auto.tfvars.example configuration.auto.tfvars
vim configuration.auto.tfvars
```
Make sure to set:
- Your GitHub username and personal access token
- Your Vaultwarden server URL, client ID, client secret, and master password

Then do the provisioning with OpenTofu:
```shell
tofu init
tofu plan
tofu apply
```

The [Flux Operator](https://fluxcd.io/flux/components/operator/) instance will be installed in the `flux-system` namespace and will start reconciling your GitOps repository to install Istio and other components. The [Vaultwarden Kubernetes Secrets](https://github.com/antoniolago/vaultwarden-kubernetes-secrets) service will sync secrets from your Vaultwarden vault to Kubernetes.


## Information Sources
* [Talos Linux documentation](https://www.talos.dev/v1.8/)
* [Talos Linux Image Factory](https://factory.talos.dev/)
* [Flux CD documentation](https://fluxcd.io/flux/)
* Terraform providers:
  * [terraform-provider-proxmox](https://github.com/Telmate/terraform-provider-proxmox)
  * [terraform-provider-talos](https://github.com/siderolabs/terraform-provider-talos)
  * [terraform-provider-helm](https://github.com/hashicorp/terraform-provider-helm)
* Helm charts:
  * [Flux Operator](https://github.com/controlplaneio-fluxcd/charts)