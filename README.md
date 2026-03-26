# Per-Namespace Egress IPs on Harvester using Kube-OVN VpcEgressGateway

Configurable egress IP per namespace on Harvester v1.8.0-rc2 using
Kube-OVN's [VpcEgressGateway](https://kube-ovn.readthedocs.io/zh-cn/latest/en/vpc/vpc-egress-gateway/) CRD.

Each tenant namespace gets its own egress gateway with a dedicated external IP.
All pods in that namespace exit to the physical network via SNAT through the gateway.

| Tenant | Egress IP | Internal Subnet |
|--------|-----------|-----------------|
| tenant-a | 192.168.31.101 | 172.20.10.0/24 |
| tenant-b | 192.168.31.150 | 172.20.20.0/24 |

## Prerequisites

- **Harvester v1.8.0-rc2** with kubeovn-operator addon enabled
- `--non-primary-cni-mode=true` (set by default by the addon)
- **Dedicated NIC** (`eth1`) on the same L2 network as management
- **Hyper-V MAC address spoofing enabled** on the dedicated NIC
  (VM Settings > Network Adapter > Advanced Features > Enable MAC address spoofing)

## Network Topology

```
                             ┌──────────────────────┐
                             │      Internet        │
                             └──────────┬───────────┘
                                        │
                             ┌──────────┴───────────┐
                             │  Router 192.168.31.1 │
                             └──────────┬───────────┘
                                        │
                    ┌───────────────────┴───────────────────┐
                    │   Physical Network 192.168.31.0/24    │
                    └───┬───────────────────────────────┬───┘
                        │                               │
               ┌────────┴────────┐             ┌────────┴────────┐
               │ eth0 (mgmt)     │             │ eth1 (external) │
               │ 192.168.31.68   │             │ ProviderNetwork │
               └─────────────────┘             └────────┬────────┘
                                                        │
                                          ┌─────────────┴─────────────┐
                                          │                           │
                                ┌─────────┴──────────┐   ┌───────────┴────────┐
                                │ egress-tenant-a     │   │ egress-tenant-b    │
                                │ eth0: 172.20.10.x   │   │ eth0: 172.20.20.x  │
                                │ net2: 192.168.31.101│   │ net2: 192.168.31.150│
                                └─────────┬──────────┘   └───────────┬────────┘
                                          │                           │
                             ┌────────────┴───────────────────────────┴──────┐
                             │          OVN Logical Router (ovn-cluster)     │
                             └────────────┬───────────────────────────┬─────┘
                                          │                           │
                                ┌─────────┴──────┐          ┌────────┴───────┐
                                │  Tenant-A VMs  │          │  Tenant-B VMs  │
                                │  → 31.101      │          │  → 31.150      │
                                └────────────────┘          └────────────────┘
```

## Quick Start

### 1. Infrastructure (once)

```bash
kubectl apply -f manifests/infra/
# Wait for ProviderNetwork to be READY
kubectl get provider-networks.kubeovn.io pn-external
```

### 2. Tenant-A

```bash
kubectl apply -f manifests/tenant-a/00-namespace.yaml
kubectl apply -f manifests/tenant-a/01-nad-internal.yaml
kubectl apply -f manifests/tenant-a/02-subnet-internal.yaml

# External NAD/Subnet may require temporarily disabling Harvester webhook
# See "Known Issues" below
kubectl apply -f manifests/tenant-a/03-nad-external.yaml
kubectl apply -f manifests/tenant-a/04-subnet-external.yaml

kubectl apply -f manifests/tenant-a/05-vpc-egress-gateway.yaml

# Apply workaround for controller bug
./manifests/patch-deployment.sh tenant-a egress-tenant-a

# Deploy test VMs
kubectl apply -f manifests/tenant-a/06-vm-test-1.yaml
kubectl apply -f manifests/tenant-a/07-vm-test-2.yaml
```

### 3. Tenant-B

```bash
kubectl apply -f manifests/tenant-b/00-namespace.yaml
kubectl apply -f manifests/tenant-b/01-nad-internal.yaml
kubectl apply -f manifests/tenant-b/02-subnet-internal.yaml

# External NAD/Subnet may require temporarily disabling Harvester webhook
kubectl apply -f manifests/tenant-b/03-nad-external.yaml
kubectl apply -f manifests/tenant-b/04-subnet-external.yaml

kubectl apply -f manifests/tenant-b/05-vpc-egress-gateway.yaml

# Apply workaround for controller bug
./manifests/patch-deployment.sh tenant-b egress-tenant-b

# Deploy test VM
kubectl apply -f manifests/tenant-b/06-vm-test-1.yaml
```

## Verification

### Overview of all resources

```bash
# Egress gateways
kubectl get vpc-egress-gateways.kubeovn.io -A -o wide

# Gateway pods
kubectl get pods -A -l app=vpc-egress-gateway -o wide

# Virtual machines
kubectl get vmi -A -o wide

# Subnets
kubectl get subnets.kubeovn.io

# Network attachments
kubectl get net-attach-def -A

# ProviderNetwork
kubectl get provider-networks.kubeovn.io
```

### Connectivity tests

```bash
# Gateway can reach internet
kubectl exec -n tenant-a deploy/egress-tenant-a -c gateway -- ping -c 2 8.8.8.8

# From VM console: ping should work via egress gateway
ping 8.8.8.8

# Wireshark on Hyper-V (eth1 NIC) to verify SNAT:
#   Capture filter: host 192.168.31.101
#   Traffic from tenant-a VMs should appear with src 192.168.31.101
```

> **Note:** Since 192.168.31.x is a private IP behind a NAT router, `curl ifconfig.me`
> returns the router's WAN IP. Use Wireshark to verify the egress IP on the LAN side.

## Known Issues

### 1. VpcEgressGateway controller bug (requires workaround)

The controller doesn't attach the internal OVN subnet as a Multus NAD in
`--non-primary-cni-mode`. The `patch-deployment.sh` script fixes this by adding
the internal NAD to the pod's Multus annotations.

See [bug-report-vpcegressgateway.md](bug-report-vpcegressgateway.md) for full details.

### 2. Harvester webhook restrictions

- **NAD types:** only `bridge` and `kube-ovn` (macvlan rejected)
- **Subnet providers:** must be 3-part `name.namespace.ovn`
- **Workaround:** temporarily delete `harvester-network-webhook` validating/mutating configs

### 3. Hyper-V MAC spoofing

Must be enabled on the dedicated NIC. Without it, OVS sends packets with
pod MACs that Hyper-V silently drops.

## Directory Structure

```
manifests/                              # Production manifests (the working setup)
  infra/                                # Shared ProviderNetwork + VLAN
  tenant-a/                             # NADs, subnets, gateway, 2 VMs
  tenant-b/                             # NADs, subnets, gateway, 1 VM
  patch-deployment.sh                   # Workaround for controller bug
  cloud-init.yaml                       # Shared cloud-init template
bug-report-vpcegressgateway.md          # Detailed bug report with source analysis
github-issue-vpcegressgateway.md        # Draft for upstream issue on kubeovn/kube-ovn
v17/                                    # Harvester v1.7 analysis (all blocked)
v18/                                    # v1.8 testing journey (historical archive)
```

## Related Issues

| Issue | Description | Status |
|-------|-------------|--------|
| [harvester#9455](https://github.com/harvester/harvester/issues/9455) | External connectivity for VMs on custom VPCs | v1.8.0 milestone |
| [kubeovn#5360](https://github.com/kubeovn/kube-ovn/issues/5360) | Kube-OVN as non-primary CNI plugin | Closed (v1.15.0) |
| [kubeovn#6212](https://github.com/kubeovn/kube-ovn/pull/6212) | Fix VpcNatGateway default network | Merged (v1.15.5) |
| [kubeovn#5885](https://github.com/kubeovn/kube-ovn/issues/5885) | VpcNatGateway tenant network not attached | Closed |
| VpcEgressGateway in non-primary-cni | **Not yet filed** — see [bug report](bug-report-vpcegressgateway.md) / [issue draft](github-issue-vpcegressgateway.md) | Pending |
