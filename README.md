# Egress IP PoC - Kube-OVN on Harvester v1.7

**Date:** 2026-03-18
**Status:** ALL APPROACHES **BLOCKED** - architectural incompatibility

## Files

| File | Description |
|------|-------------|
| `VpcEgressGateway-Analysis.md` | Full technical analysis |
| `vpc-ovn-cluster.yaml` | Default Kube-OVN VPC |
| `subnet-vm-subnet.yaml` | VM subnet (10.55.0.0/24) with natOutgoing + DHCP |
| `nad-ovn-net.yaml` | NetworkAttachmentDefinition for VM attachment |
| `vm-leap-15-6.yaml` | Test VM definition |
| `cloud-init-default.yaml` | Reusable cloud-init template |
| `provider-network-external.yaml` | ProviderNetwork for OVN EIP/SNAT |
| `vlan-external.yaml` | Vlan for external network |
| `subnet-external.yaml` | External underlay subnet |
| `ovn-eip-ns-foo.yaml` | OvnEip allocation |
| `ovn-snat-rule-ns-foo.yaml` | OvnSnatRule for vm-subnet |
| `ovn-external-gw-config.yaml` | External gateway ConfigMap |

## Results Summary

### Option A: Kube-OVN Overlay + natOutgoing ✅

- VM attached to Kube-OVN overlay: **working**
- natOutgoing egress to internet: **working**
- Egress IP: node IP (192.168.31.68) - **NOT configurable**

### Option B: VpcEgressGateway ❌

- VpcEgressGateway CRD exists: **yes**
- Gateway pod starts: **no - init crash**
- Root cause: Pod eth0 = Canal, not Kube-OVN

### Option C: OVN Native EIP/SNAT ❌

- ProviderNetwork + Vlan + Subnet: **created** (webhook bypass required)
- OvnEip + OvnSnatRule: **created, READY=true**
- VPC extraExternalSubnets lrp: **NOT auto-created**
- Manual OVN lrp creation: **breaks routing, VM loses connectivity**
- Root cause: Routing path conflict with natOutgoing

## Key Finding

```
Harvester's Kube-OVN integration is VM-only via Multus.
All Kube-OVN egress IP features assume full CNI control.

┌─────────────────────────────────────────────────────┐
│              What Works                             │
├─────────────────────────────────────────────────────┤
│  VM → Kube-OVN overlay → natOutgoing → node IP     │
│                                                     │
│  Egress IP = 192.168.31.68 (node)                  │
│  NOT configurable per-namespace                     │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│              What's Blocked                         │
├─────────────────────────────────────────────────────┤
│  VpcEgressGateway: pod eth0 ≠ Kube-OVN             │
│  OVN EIP/SNAT: lrp not created, routing conflict   │
│  VpcNatGateway: same dual-CNI issue                │
└─────────────────────────────────────────────────────┘
```

## Remaining Options

1. **Node iptables SNAT** - Manual rules on Harvester nodes
2. **External SNAT** - Upstream firewall/load balancer
3. **Cilium CNI** - Wait for [harvester#7197](https://github.com/harvester/harvester/issues/7197)

See `VpcEgressGateway-Analysis.md` for full details.
