# VpcEgressGateway — Per-Namespace Egress IPs on Harvester v1.8.0-rc2

## Overview

This setup proves configurable egress IPs per namespace using Kube-OVN's
VpcEgressGateway CRD on Harvester v1.8.0-rc2.

Each namespace gets its own VpcEgressGateway with a dedicated egress IP.
Traffic from pods in that namespace exits to the physical network via SNAT
through the gateway pod.

| Namespace | Egress IP | Internal Subnet |
|-----------|-----------|-----------------|
| default | 192.168.31.102 | 172.20.10.0/24 |
| tenant-b | 192.168.31.150 | 172.20.20.0/24 |

## Prerequisites

- Harvester v1.8.0-rc2 with kubeovn-operator addon enabled
- `--non-primary-cni-mode=true` (set by default)
- Dedicated NIC (`eth1`) on the same L2 network as management
- **Hyper-V MAC address spoofing enabled** on eth1 NIC
  (VM Settings → Network Adapter → Advanced Features → Enable MAC address spoofing)

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
               │ mgmt-bo bond    │             │ ProviderNetwork │
               │ mgmt-br bridge  │             │ pn-external     │
               │ 192.168.31.68   │             │ OVS br-pn-ext   │
               └─────────────────┘             └────────┬────────┘
                                                        │
                                          ┌─────────────┴─────────────┐
                                          │                           │
                                ┌─────────┴──────────┐   ┌───────────┴────────┐
                                │ egress-default pod  │   │ egress-tenant-b pod│
                                │ ns: default         │   │ ns: tenant-b       │
                                │                     │   │                    │
                                │ eth0: 172.20.10.2   │   │ eth0: 172.20.20.5  │
                                │  (OVN overlay)      │   │  (OVN overlay)     │
                                │ net2: 192.168.31.102│   │ net2: 192.168.31.150│
                                │  (external, SNAT)   │   │  (external, SNAT)  │
                                └─────────┬──────────┘   └───────────┬────────┘
                                          │                           │
                             ┌────────────┴───────────────────────────┴──────┐
                             │          OVN Logical Router (ovn-cluster)     │
                             │  Policy routes redirect traffic to gateways  │
                             └────────────┬───────────────────────────┬─────┘
                                          │                           │
                             ┌────────────┴──────────┐   ┌───────────┴────────┐
                             │  ovn-default subnet   │   │  ovn-default subnet│
                             │  Pods in default ns   │   │  Pods in tenant-b  │
                             │  → egress 31.102      │   │  → egress 31.150   │
                             └───────────────────────┘   └────────────────────┘
```

## How It Works

1. **ProviderNetwork** (`pn-external`) takes over `eth1` and creates an OVS bridge
2. Each namespace gets:
   - A **kube-ovn overlay NAD** (`ovn-internal`) for VPC internal traffic
   - A **kube-ovn underlay NAD** (`egress-ext`) for external traffic via eth1
   - Matching **Subnets** for IP allocation
   - A **VpcEgressGateway** CRD that creates a gateway Deployment
3. The gateway pod gets 3 interfaces:
   - `eth0`: OVN overlay (internal VPC subnet)
   - `net1`: OVN overlay duplicate (from Multus)
   - `net2`: OVN underlay on eth1 (external, egress IP)
4. The init container configures **iptables MASQUERADE** rules
5. OVN creates **policy routes** on the logical router to redirect traffic through the gateways

## Workaround: Deployment Patch

The VpcEgressGateway controller has a bug in `--non-primary-cni-mode`:
it doesn't attach the internal subnet as a Multus NAD. The pod gets no
OVN overlay interface and crashes.

**Fix:** After the CRD creates the Deployment, patch it to add the internal NAD:

```bash
bash 27-patch-deployment.sh [namespace] [gateway-name]
```

This adds `v1.multus-cni.io/default-network` and the internal NAD to
`k8s.v1.cni.cncf.io/networks`.

## Apply Order — Default Namespace

```bash
# Infrastructure (once)
kubectl apply -f 20-provider-network.yaml     # wait for READY
kubectl apply -f 21-vlan.yaml

# Default namespace gateway
kubectl apply -f 22-nad-external.yaml
kubectl apply -f 23-subnet-external.yaml
kubectl apply -f 24-nad-internal.yaml
kubectl apply -f 25-subnet-internal.yaml
kubectl apply -f 26-vpc-egress-gateway.yaml
bash 27-patch-deployment.sh default egress-default
```

## Apply Order — Tenant-B Namespace

```bash
kubectl apply -f 30-tenant-b-namespace.yaml

# NOTE: Harvester webhook blocks some of these.
# Temporarily remove webhook configs:
#   kubectl delete validatingwebhookconfiguration harvester-network-webhook
#   kubectl delete mutatingwebhookconfiguration harvester-network-webhook
# Re-enable after:
#   kubectl rollout restart deploy -n harvester-system harvester-network-webhook

kubectl apply -f 31-tenant-b-nad-internal.yaml
kubectl apply -f 32-tenant-b-subnet-internal.yaml
kubectl apply -f 33-tenant-b-nad-external.yaml
kubectl apply -f 34-tenant-b-subnet-external.yaml
kubectl apply -f 35-tenant-b-vpc-egress-gateway.yaml
bash 27-patch-deployment.sh tenant-b egress-tenant-b
```

## Verification

```bash
# Both gateways ready
kubectl get vpc-egress-gateways.kubeovn.io -A -o wide

# External connectivity from each gateway
kubectl exec -n default deploy/egress-default -c gateway -- ping -c 2 8.8.8.8
kubectl exec -n tenant-b deploy/egress-tenant-b -c gateway -- ping -c 2 8.8.8.8

# SNAT rules
kubectl exec -n default deploy/egress-default -c gateway -- iptables-save -t nat
kubectl exec -n tenant-b deploy/egress-tenant-b -c gateway -- iptables-save -t nat

# Wireshark capture filters on Hyper-V (eth1 NIC):
#   host 192.168.31.102    (default namespace traffic)
#   host 192.168.31.150    (tenant-b traffic)
```

## Known Issues

1. **VpcEgressGateway controller bug**: doesn't attach internal subnet as Multus NAD
   in non-primary-cni-mode. Requires `27-patch-deployment.sh` workaround.

2. **Harvester webhook restrictions**:
   - NAD types: only `bridge` and `kube-ovn` (macvlan rejected)
   - Subnet providers: must be 3-part `name.namespace.ovn`
   - NAD provider must match its namespace
   - Workaround: temporarily delete webhook configs for cross-namespace or non-standard resources

3. **Hyper-V MAC spoofing**: must be enabled on the dedicated NIC or ARP fails silently
