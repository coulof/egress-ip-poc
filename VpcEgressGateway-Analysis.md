# VpcEgressGateway on Harvester v1.7 — Analysis Report

**Date:** 2026-03-18
**Harvester version:** v1.7.1
**Kube-OVN version:** v1.14.10
**Cluster:** Single-node (hv-01)

---

## Executive Summary

**VpcEgressGateway does NOT work on Harvester v1.7** due to architectural incompatibilities between Harvester's dual-CNI model and VpcEgressGateway's assumptions about pod networking.

---

## What Was Tested

### Option A: Basic Kube-OVN Connectivity ✅ WORKS

| Step | Status | Notes |
|------|--------|-------|
| Enable kubeovn-operator | ✅ | Add-on enabled via Harvester UI |
| Default VPC `ovn-cluster` | ✅ | Auto-created |
| Create NAD `ovn-net` | ✅ | Provider: `ovn-net.default.ovn` |
| Create Subnet `vm-subnet` | ✅ | 10.55.0.0/24, natOutgoing=true, enableDHCP=true |
| Create VM on Kube-OVN | ✅ | VM gets IP 10.55.0.5, can reach internet |
| Egress to internet | ✅ | Traffic NATs via node IP (192.168.31.68) |

**Limitation:** With `natOutgoing: true`, egress IP = node IP (not configurable per-namespace).

### Option B: VpcEgressGateway ❌ FAILS

| Step | Status | Notes |
|------|--------|-------|
| Create macvlan NAD | ⚠️ | Required disabling Harvester webhook |
| Create macvlan-subnet | ⚠️ | Required disabling Harvester webhook |
| Create VpcEgressGateway | ✅ | CRD created successfully |
| Gateway pod starts | ❌ | Init container crashes |

---

## Architecture Comparison

### What VpcEgressGateway Expects

```
┌─────────────────────────────────────────────────────────────┐
│                    Gateway Pod                              │
│  ┌─────────────────────┐    ┌─────────────────────────┐    │
│  │ eth0 (internal)     │    │ net1 (external)         │    │
│  │ Kube-OVN overlay    │    │ macvlan                 │    │
│  │ provider: ovn       │    │ physical NIC            │    │
│  │ IP: 10.x.x.x        │    │ IP: 192.168.31.200      │    │
│  └─────────────────────┘    └─────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
   OVN Overlay Network           Physical Network
   (default pod network)         (egress to firewall)
```

### What Harvester Provides

```
┌─────────────────────────────────────────────────────────────┐
│                    Gateway Pod                              │
│  ┌─────────────────────┐    ┌─────────────────────────┐    │
│  │ eth0 (primary)      │    │ net1 (secondary)        │    │
│  │ Canal/Flannel       │    │ macvlan                 │    │
│  │ k8s-pod-network     │    │ IP: 192.168.31.200      │    │
│  │ IP: 10.52.x.x       │    │                         │    │
│  └─────────────────────┘    └─────────────────────────┘    │
│           ▲                                                 │
│           │                                                 │
│    NOT Kube-OVN!              Missing: Kube-OVN overlay     │
└─────────────────────────────────────────────────────────────┘
```

---

## The Incompatibility

### Harvester CNI Model

| Network | CNI Plugin | Usage |
|---------|------------|-------|
| Pod primary (eth0) | Canal (Calico + Flannel) | All pods |
| VM overlay | Kube-OVN via Multus | VMs only |
| VM underlay | Bridge/VLAN via Multus | VMs only |

### VpcEgressGateway Assumptions

| Assumption | Harvester Reality | Impact |
|------------|-------------------|--------|
| Pod eth0 = Kube-OVN overlay | Pod eth0 = Canal | ❌ No OVN interface |
| `internalSubnet` creates interface | Only allocates IP | ❌ No route to gateway |
| `provider: ovn` for internal | Harvester uses `provider: <nad>.namespace.ovn` | ❌ Mismatch |

---

## Evidence: Pod Network Interfaces

**Expected (3 interfaces):**
```
eth0 → Kube-OVN internal (10.55.0.x)
net1 → macvlan external (192.168.31.200)
```

**Actual (from `k8s.v1.cni.cncf.io/network-status`):**
```
k8s-pod-network: eth0 → ['10.52.0.136']     # Canal, NOT Kube-OVN!
default/macvlan-external: net1 → ['192.168.31.200']
```

**OVN allocation (unused):**
```yaml
ovn.kubernetes.io/ip_address: 10.55.0.10   # Allocated but NO interface
ovn.kubernetes.io/logical_switch: vm-subnet
ovn.kubernetes.io/gateway: 10.55.0.1
```

---

## Evidence: Init Container Failure

**Log output:**
```bash
+ internal_iface=eth0
+ external_iface=net1
+ '[' -n 10.55.0.1 ']'
++ ip -o route get 10.55.0.1
++ grep -o 'src [^ ]*'
++ awk '{print $2}'
+ internal_ipv4=192.168.31.200      # WRONG! Should be 10.55.0.x
++ ip -o route get 192.168.31.1
++ grep -o 'dev [^ ]*'
++ awk '{print $2}'
+ internal_iface=net1               # WRONG! Should be eth0
+ ip -4 route replace default via 10.55.0.1 table 1000
Error: Nexthop has invalid gateway.   # FAILS - 10.55.0.1 unreachable
```

**Root cause:** Script does `ip route get 10.55.0.1` but pod has no interface on that subnet. Traffic routes via macvlan default gateway (192.168.31.1), so source IP = 192.168.31.200.

---

## Attempted Workaround: Add ovn-net as Secondary Network

**Patch applied:**
```bash
kubectl patch deploy egress-foo --type=merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{
    "k8s.v1.cni.cncf.io/networks":"default/ovn-net,default/macvlan-external"
  }}}}}'
```

**Result:**
```
k8s-pod-network: eth0 → ['10.52.0.136']
default/ovn-net: net1 → ['10.55.0.10']        # Added!
default/macvlan-external: net2 → ['192.168.31.200']
```

**But:** VpcEgressGateway controller **overrides** the deployment annotation on each reconcile:
```yaml
# Controller resets to:
k8s.v1.cni.cncf.io/networks: default/macvlan-external
```

---

## Harvester Webhook Restrictions

Creating macvlan NAD requires **temporarily disabling Harvester webhooks**:

```bash
kubectl delete mutatingwebhookconfiguration harvester-network-webhook
kubectl delete validatingwebhookconfiguration harvester-network-webhook
# ... create resources ...
kubectl apply -f /tmp/harvester-network-webhook.yaml
kubectl apply -f /tmp/harvester-network-webhook-validating.yaml
```

**Webhook errors encountered:**

| Error | Cause |
|-------|-------|
| `invalid provider length 2 for provider X.Y` | Harvester requires 3-part provider |
| `can't create nad because the length of bridge name is less than 3` | macvlan type not recognized |
| `cannot determine the network type from netconf type macvlan` | macvlan not supported by webhook |
| `labels are empty for nad default/X` | Missing Harvester labels |

---

## Hard-coded Values / Assumptions

### In VpcEgressGateway Controller

| Behavior | Location | Impact |
|----------|----------|--------|
| Only attaches `externalSubnet` NAD | Deployment template generation | No internal overlay interface |
| Assumes pod primary = OVN | Init script routing logic | Route lookups fail |
| Overrides deployment annotations | Reconcile loop | Workarounds reverted |

### In Harvester Network Webhook

| Restriction | Impact |
|-------------|--------|
| NAD must be bridge or kube-ovn type | macvlan NADs blocked |
| Provider must be 3-part format | Standard Kube-OVN patterns rejected |
| All NADs validated, no bypass | Requires disabling webhook |

---

## Summary Table

| Component | Status | Blocker |
|-----------|--------|---------|
| Kube-OVN overlay for VMs | ✅ Works | — |
| natOutgoing (shared egress IP) | ✅ Works | IP = node IP, not configurable |
| VpcEgressGateway CRD | ✅ Exists | v1.14.10 has the CRD |
| macvlan NAD creation | ⚠️ Requires webhook disable | Harvester blocks macvlan |
| Gateway pod internal interface | ❌ Fails | Pod eth0 = Canal, not OVN |
| Gateway pod initialization | ❌ Fails | Route to internal gateway unreachable |
| VpcEgressGateway overall | ❌ Incompatible | Architectural mismatch |

---

## Recommendations

1. **Document as Known Limitation**
   VpcEgressGateway is not compatible with Harvester v1.7's dual-CNI architecture.

2. **Alternative: iptables-snat-rules CRD**
   May work differently (uses node's network stack). Untested.

3. **Alternative: Custom SNAT Rules**
   Manual OVN/iptables rules on gateway node. Requires operational overhead.

4. **Feature Request: Harvester**
   Support Kube-OVN as primary pod CNI (not just for VMs via Multus).

5. **Feature Request: Kube-OVN**
   VpcEgressGateway should support Multus-attached internal subnets.

---

## Files in This PoC

| File | Description |
|------|-------------|
| `vpc-ovn-cluster.yaml` | Default VPC |
| `subnet-vm-subnet.yaml` | VM overlay subnet (working) |
| `nad-ovn-net.yaml` | NAD for VM attachment (working) |
| `vm-leap-15-6.yaml` | Test VM (working) |
| `cloud-init-default.yaml` | Cloud-init template |
| `VpcEgressGateway-Analysis.md` | This document |
