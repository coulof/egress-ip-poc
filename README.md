# Egress IP PoC - Kube-OVN on Harvester v1.7

**Date:** 2026-03-18
**Status:** VpcEgressGateway **BLOCKED** - architectural incompatibility

## Files

| File | Description |
|------|-------------|
| `VpcEgressGateway-Analysis.md` | Full technical analysis of failure |
| `vpc-ovn-cluster.yaml` | Default Kube-OVN VPC |
| `subnet-vm-subnet.yaml` | VM subnet (10.55.0.0/24) with natOutgoing + DHCP |
| `nad-ovn-net.yaml` | NetworkAttachmentDefinition for VM attachment |
| `vm-leap-15-6.yaml` | Test VM definition |
| `secret-cloud-init.yaml` | Cloud-init secret |
| `cloud-init-default.yaml` | Reusable cloud-init template |

## Results Summary

### Option A: Kube-OVN Overlay + natOutgoing ✅

- VM attached to Kube-OVN overlay: **working**
- natOutgoing egress to internet: **working**
- Egress IP: node IP (192.168.31.68) - **NOT configurable**

### Option B: VpcEgressGateway ❌

- VpcEgressGateway CRD exists: **yes**
- Gateway pod starts: **no - init crash**
- Root cause: Harvester uses Canal for pods, Kube-OVN only for VMs

## Key Finding

```
Harvester CNI model:
  Pod eth0 = Canal (Flannel)
  VM attachment = Kube-OVN via Multus

VpcEgressGateway assumption:
  Pod eth0 = Kube-OVN overlay (provider: ovn)

Result: Gateway pod has no interface on internal overlay network
```

See `VpcEgressGateway-Analysis.md` for full details.
