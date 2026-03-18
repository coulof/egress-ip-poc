# Egress IP on Harvester v1.7 — Analysis Report

**Date:** 2026-03-18
**Harvester version:** v1.7.1
**Kube-OVN version:** v1.14.10
**Cluster:** Single-node (hv-01)

---

## Executive Summary

**No Kube-OVN egress IP solution works on Harvester v1.7** due to architectural incompatibilities between Harvester's dual-CNI model and Kube-OVN's assumptions.

| Approach | Status | Blocker |
|----------|--------|---------|
| VpcEgressGateway | ❌ BLOCKED | Gateway pod eth0 = Canal, not Kube-OVN |
| OVN Native EIP/SNAT | ❌ BLOCKED | Routing path conflict with natOutgoing |
| VpcNatGateway | ❌ BLOCKED | Same dual-CNI issue as VpcEgressGateway |

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

### Option C: OVN Native EIP/SNAT ❌ FAILS

| Step | Status | Notes |
|------|--------|-------|
| Create ProviderNetwork | ✅ | `external` using mgmt-br |
| Create Vlan | ✅ | `vlan0` (untagged) |
| Create external Subnet | ⚠️ | Required webhook bypass; auto-assigned to ovn-cluster VPC |
| Create OvnEip | ✅ | 192.168.31.200 allocated, READY=true |
| Create OvnSnatRule | ✅ | SNAT 10.55.0.0/24 → 192.168.31.200, READY=true |
| VPC extraExternalSubnets | ⚠️ | Configured but lrp NOT auto-created |
| Manual OVN lrp creation | ❌ | Breaks existing routing, VM loses connectivity |

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

## Option C: OVN Native EIP/SNAT — Deep Dive

### What OVN EIP/SNAT Expects

OVN native EIP/SNAT uses OVN's built-in NAT capabilities without a gateway pod:

```
┌─────────────────────────────────────────────────────────────────┐
│                     OVN Logical Router                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ lrp-internal │  │ lrp-join     │  │ lrp-external         │  │
│  │ 10.55.0.1    │  │ 100.64.0.1   │  │ 192.168.31.101       │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│         │                │                      │               │
│         │                │              SNAT: 10.55.0.0/24      │
│         │                │                  → 192.168.31.200    │
└─────────┼────────────────┼──────────────────────┼───────────────┘
          │                │                      │
          ▼                ▼                      ▼
    vm-subnet          join network         external subnet
    (overlay)          (to node)            (underlay/localnet)
```

Traffic flow: VM → lrp-internal → SNAT → lrp-external → physical network

### What Harvester Provides

```
┌─────────────────────────────────────────────────────────────────┐
│                     OVN Logical Router (ovn-cluster)            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ lrp-internal │  │ lrp-join     │  │ lrp-external         │  │
│  │ 10.55.0.1    │  │ 100.64.0.1   │  │ MISSING!             │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│         │                │                                      │
│         │                ▼                                      │
│         │         natOutgoing path                              │
│         │         (node IP SNAT)                                │
└─────────┼────────────────┼──────────────────────────────────────┘
          │                │
          ▼                ▼
    vm-subnet          join network → node → physical network
    (overlay)              ↓
                    SNAT to 192.168.31.68 (node IP)
```

### The Routing Path Conflict

**natOutgoing flow (working):**
```
VM (10.55.0.5) → vm-subnet → ovn-cluster router
  → policy route (priority 29000): reroute to 100.64.0.2
  → join network → node's network stack
  → iptables MASQUERADE → physical network
  → egress IP = node IP (192.168.31.68)
```

**OVN SNAT flow (required but blocked):**
```
VM (10.55.0.5) → vm-subnet → ovn-cluster router
  → lrp-external (192.168.31.101)  ← MISSING!
  → OVN SNAT rule applies
  → external subnet (localnet)
  → egress IP = 192.168.31.200
```

### Why extraExternalSubnets Doesn't Create lrp

The VPC `extraExternalSubnets: [external]` configuration should auto-create the router port, but fails because:

1. **Subnet VPC assignment:** External subnet auto-assigned to `ovn-cluster` VPC with `provider: ovn`, treating it as overlay instead of underlay

2. **Missing startup parameters:** OVN EIP/SNAT requires kube-ovn-controller args:
   ```
   --external-gateway-vlanid=0
   --external-gateway-switch=external
   ```
   These are not configurable via kubeovn-operator on Harvester.

3. **Default VPC special handling:** Controller logs show:
   ```
   default vpc only use extra external subnets: [external]
   ```
   But no lrp creation follows — the feature expects full Kube-OVN deployment, not Multus-only.

### Evidence: Manual lrp Creation Breaks Routing

**Commands executed:**
```bash
# Create router port
ovn-nbctl lrp-add ovn-cluster ovn-cluster-external 02:ac:10:ff:01:01 192.168.31.101/24

# Create switch port and link
ovn-nbctl lsp-add external external-ovn-cluster-external
ovn-nbctl lsp-set-type external-ovn-cluster-external router
ovn-nbctl lsp-set-options external-ovn-cluster-external router-port=ovn-cluster-external

# Set gateway chassis
ovn-nbctl lrp-set-gateway-chassis ovn-cluster-external 92c5e833-3e30-48c2-a4b0-ee355c4c5517 20

# Add SNAT rule
ovn-nbctl lr-nat-add ovn-cluster snat 192.168.31.200 10.55.0.0/24

# Add policy route for external traffic
ovn-nbctl lr-policy-add ovn-cluster 30000 \
  "ip4.src == 10.55.0.0/24 && ip4.dst != 10.55.0.0/24 && ip4.dst != 10.54.0.0/16 && ip4.dst != 100.64.0.0/16" \
  reroute 192.168.31.1
```

**Result:** VM loses all network connectivity. The policy route conflicts with existing natOutgoing routing through join network.

**Root cause:** The lrp-external → localnet path requires proper OVS bridge integration that Harvester's Kube-OVN deployment doesn't configure.

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
| OVN EIP/SNAT CRDs | ✅ Exist | OvnEip, OvnSnatRule present |
| ProviderNetwork + Vlan | ✅ Created | Webhook bypass required |
| extraExternalSubnets lrp | ❌ Not created | Missing controller integration |
| Manual OVN lrp | ❌ Breaks routing | Conflicts with natOutgoing path |
| OVN EIP/SNAT overall | ❌ Incompatible | Routing path conflict |

---

## Recommendations

### Blocked Approaches (Do Not Pursue)

1. **VpcEgressGateway** — Requires pod eth0 = Kube-OVN, Harvester uses Canal
2. **OVN Native EIP/SNAT** — Routing conflicts with natOutgoing path
3. **VpcNatGateway** — Same dual-CNI issue as VpcEgressGateway

### Remaining Options (Untested)

1. **Node-level iptables SNAT**
   Configure iptables rules directly on Harvester nodes to SNAT specific source CIDRs to dedicated IPs. Bypasses Kube-OVN entirely.
   ```bash
   iptables -t nat -A POSTROUTING -s 10.55.0.0/24 -o mgmt-br -j SNAT --to-source 192.168.31.200
   ```
   **Pros:** Simple, works with existing routing
   **Cons:** Not Kubernetes-native, requires node access, no HA

2. **External SNAT (firewall/load balancer)**
   Perform SNAT at the upstream firewall or a dedicated SNAT appliance outside Harvester.
   **Pros:** Decoupled from Harvester, enterprise-grade
   **Cons:** Requires network infrastructure changes

3. **Wait for Cilium CNI support**
   Track [harvester/harvester#7197](https://github.com/harvester/harvester/issues/7197) — custom CNI at install time would enable `CiliumEgressGatewayPolicy`.
   **Pros:** Fully supported solution
   **Cons:** Unknown timeline, requires cluster rebuild

### Feature Requests

1. **Harvester:** Support Kube-OVN as primary pod CNI (not just for VMs via Multus)
2. **Harvester:** Document OVN EIP/SNAT limitations in kubeovn-operator add-on docs
3. **Kube-OVN:** VpcEgressGateway should support Multus-attached internal subnets
4. **Kube-OVN:** extraExternalSubnets should work without startup parameter changes

---

## Files in This PoC

| File | Description |
|------|-------------|
| `vpc-ovn-cluster.yaml` | Default VPC |
| `subnet-vm-subnet.yaml` | VM overlay subnet (working) |
| `nad-ovn-net.yaml` | NAD for VM attachment (working) |
| `vm-leap-15-6.yaml` | Test VM (working) |
| `cloud-init-default.yaml` | Cloud-init template |
| `provider-network-external.yaml` | ProviderNetwork for OVN EIP/SNAT |
| `vlan-external.yaml` | Vlan for external network |
| `subnet-external.yaml` | External underlay subnet |
| `ovn-eip-ns-foo.yaml` | OvnEip allocation (192.168.31.200) |
| `ovn-snat-rule-ns-foo.yaml` | OvnSnatRule for vm-subnet |
| `ovn-eip-lrp.yaml` | lrp-type OvnEip (attempted) |
| `ovn-external-gw-config.yaml` | External gateway ConfigMap |
| `VpcEgressGateway-Analysis.md` | This document |
