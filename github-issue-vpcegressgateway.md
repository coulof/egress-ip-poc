<!-- GitHub issue draft for kubeovn/kube-ovn -->
<!-- Submit with: gh issue create -R kubeovn/kube-ovn --title "[BUG] ..." --body-file github-issue-vpcegressgateway.md -->

## Environment

- **Kube-OVN:** v1.15.4, v1.15.7, v1.16.0 (tested all three, same result)
- **Kubernetes:** v1.35.2+rke2r1
- **Primary CNI:** Canal (Calico + Flannel)
- **Kube-OVN mode:** `--non-primary-cni-mode=true`, `--enable-eip-snat=true`
- **Platform:** Harvester v1.8.0-rc2 (single node)

## Description

VpcEgressGateway does not work when Kube-OVN is configured as a secondary CNI (`--non-primary-cni-mode=true`). The gateway pod's init container crashes with `Error: Nexthop has invalid gateway` because the internal VPC subnet is not attached as a network interface.

The controller sets `ovn.kubernetes.io/logical_switch` for the internal subnet, but this annotation is **ignored** in non-primary-cni-mode — only networks listed in `k8s.v1.cni.cncf.io/networks` (Multus) result in actual interfaces.

This is the same class of bug that was fixed for **VpcNatGateway** in PR #6212, but VpcEgressGateway was not updated.

## Steps to Reproduce

1. Deploy Kube-OVN with `--non-primary-cni-mode=true` (another CNI is primary)
2. Create a NetworkAttachmentDefinition + Subnet for the external network
3. Create a VpcEgressGateway:

```yaml
apiVersion: kubeovn.io/v1
kind: VpcEgressGateway
metadata:
  name: egress-default
  namespace: default
spec:
  vpc: ovn-cluster
  replicas: 1
  externalSubnet: egress-external
  policies:
    - snat: true
      subnets:
        - ovn-default
```

4. The gateway pod crashes in init.

## Expected Behavior

The gateway pod should get:
- **eth0:** Kube-OVN overlay (internal VPC subnet)
- **net1:** External network (via Multus NAD)

And the init script should successfully configure routes and iptables SNAT.

## Actual Behavior

The gateway pod gets:
- **eth0:** Primary CNI (Canal) — `10.52.0.80/32`
- **net1:** External network — `192.168.31.101/24`
- **Missing:** No Kube-OVN overlay interface

Init container crash:
```
+ INTERNAL_GATEWAY_IPV4=10.54.0.1
+ internal_ipv4=10.52.0.80        # Canal IP, not OVN
+ internal_iface=eth0              # Canal, not OVN overlay
+ ip -4 route replace default via 10.54.0.1 table 1000
Error: Nexthop has invalid gateway.
```

Pod annotations set by controller:
```
k8s.v1.cni.cncf.io/networks: default/egress-external    # external ONLY
ovn.kubernetes.io/logical_switch: ovn-default        # ignored in non-primary mode
```

## Root Cause

In `pkg/controller/vpc_egress_gateway.go`:

**Line ~396** — only the external NAD is added to Multus annotations:
```go
annotations[nadv1.NetworkAttachmentAnnot] = attachmentNetworkName  // external only
```

**Line ~397** — internal subnet uses hardcoded bare `ovn.kubernetes.io/` prefix:
```go
annotations[util.LogicalSwitchAnnotation] = intSubnet.Name
```

In non-primary-cni-mode, `getPodKubeovnNets()` in `pod.go` skips the bare `ovn.kubernetes.io/logical_switch` annotation:
```go
if c.config.EnableNonPrimaryCNI {
    return podNets, nil  // only returns Multus NAD networks
}
```

There are **zero references** to `EnableNonPrimaryCNI` in `vpc_egress_gateway.go`.

## Comparison with VpcNatGateway (PR #6212)

PR #6212 fixed the equivalent issue for VpcNatGateway by:
1. Setting `v1.multus-cni.io/default-network` to the internal NAD when using a custom provider
2. Adding the internal NAD to `k8s.v1.cni.cncf.io/networks`
3. Using provider-templated annotation keys

The same pattern should be applied to VpcEgressGateway.

## Workaround

After the CRD creates the Deployment, patch it to add the internal NAD:

```bash
kubectl patch deployment -n default egress-default --type=json -p '[
  {"op":"add",
   "path":"/spec/template/metadata/annotations/v1.multus-cni.io~1default-network",
   "value":"default/egress-internal"},
  {"op":"replace",
   "path":"/spec/template/metadata/annotations/k8s.v1.cni.cncf.io~1networks",
   "value":"default/egress-internal, default/egress-external"}
]'
```

This requires a pre-existing kube-ovn NAD (`egress-internal`) for the internal subnet.

After patch, the gateway pod works correctly:
```
NAME             PHASE       READY   INTERNAL IPS      EXTERNAL IPS
egress-default   Completed   true    ["172.20.10.2"]   ["192.168.31.102"]
```

## Related

- #5885 — Same class of bug for VpcNatGateway
- #6212 — Fix for VpcNatGateway (equivalent fix needed)
- #5360 — Non-primary CNI plugin feature request
