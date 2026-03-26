# VpcEgressGateway init crash in non-primary-cni-mode

## Environment

- **Harvester:** v1.8.0-rc2
- **Kube-OVN:** tested on v1.15.4, v1.15.7, and v1.16.0 — same failure on all three
- **Kubernetes:** v1.35.2+rke2r1
- **Node:** single node (`hv-01`, `192.168.31.68`)
- **Primary CNI:** Canal (`10.52.0.0/x`)
- **Controller flags:** `--non-primary-cni-mode=true`, `--enable-eip-snat=true`

### Confirmed --non-primary-cni-mode=true is active

```
$ kubectl get deploy -n kube-system kube-ovn-controller \
    -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -E "non-primary|enable-eip"
"--non-primary-cni-mode=true"
"--enable-eip-snat=true"
```

This flag is set by default via the kubeovn-operator addon (`nonPrimaryCNI: true` in the Configuration CR).

---

## Problem

VpcEgressGateway init container crashes with `Error: Nexthop has invalid gateway.`

The pod gets only 2 interfaces instead of 3:
- **eth0:** Canal IP (`10.52.0.80`) — primary CNI
- **net1:** External network (e.g. macvlan or bridge on eth1)
- **Missing:** No Kube-OVN overlay interface for the internal VPC subnet

The controller sets `ovn.kubernetes.io/logical_switch: ovn-default` but in
`--non-primary-cni-mode`, this annotation is **ignored** — Kube-OVN only creates
interfaces for networks listed in `k8s.v1.cni.cncf.io/networks` (Multus annotations).

---

## Root cause — source code analysis

File: [`pkg/controller/vpc_egress_gateway.go`](https://github.com/kubeovn/kube-ovn/blob/v1.15.4/pkg/controller/vpc_egress_gateway.go) (v1.15.4, identical through master)

### 1. Only the external NAD is added to Multus annotations

```go
// Line ~396: only the external subnet's NAD is added
annotations[nadv1.NetworkAttachmentAnnot] = attachmentNetworkName  // e.g. "default/egress-external"
```

The `attachmentNetworkName` is derived solely from the **external** subnet's provider (lines 298-309).
The internal subnet is never added to `k8s.v1.cni.cncf.io/networks`.

### 2. Internal subnet uses hardcoded bare annotation

```go
// Line ~397: always uses bare ovn.kubernetes.io/ prefix
annotations[util.LogicalSwitchAnnotation] = intSubnet.Name  // "ovn.kubernetes.io/logical_switch"
```

In `--non-primary-cni-mode`, the pod controller's `getPodKubeovnNets()` function skips
the bare `ovn.kubernetes.io/` annotation entirely:

```go
// pkg/controller/pod.go
if c.config.EnableNonPrimaryCNI {
    return podNets, nil  // ONLY returns networks from Multus NAD annotations
}
```

### 3. Routes also hardcoded to bare `ovn` provider

```go
// Lines ~377-385: always uses "ovn", never a custom provider
routes.Add(util.OvnProvider, bfdIPv4, intGatewayIPv4)
```

### 4. Zero awareness of non-primary-cni-mode

There is **no reference** to `EnableNonPrimaryCNI`, `non-primary-cni-mode`, or `non_primary`
anywhere in `vpc_egress_gateway.go`.

### Compare with VpcNatGateway (fixed in PR #6212)

`GenNatGwPodAnnotations()` in [`pkg/util/vpc_nat_gateway.go`](https://github.com/kubeovn/kube-ovn/blob/v1.15.4/pkg/util/vpc_nat_gateway.go)
**does** handle non-default providers:

```go
if p != OvnProvider {
    providerSplit := strings.Split(provider, ".")
    name, namespace := providerSplit[0], providerSplit[1]
    result[DefaultNetworkAnnotation] = fmt.Sprintf("%s/%s", namespace, name)
}
```

An equivalent fix is needed in `vpc_egress_gateway.go`.

---

## Before patch — init crash

### Init container log

```
+ INTERNAL_GATEWAY_IPV4=10.54.0.1
+ EXTERNAL_GATEWAY_IPV4=192.168.31.1
...
+ internal_ipv4=10.52.0.80        ← Canal IP, NOT OVN
+ external_ipv4=10.52.0.80        ← Canal IP, NOT external
+ internal_iface=eth0              ← Canal, NOT OVN overlay
+ external_iface=eth0              ← Canal, NOT external bridge
+ ip -4 route replace default via 10.54.0.1 table 1000
Error: Nexthop has invalid gateway.
```

The init script does `ip route get 10.54.0.1` (OVN gateway). Since there is no OVN
interface on the pod, the route resolves via Canal's eth0. Then `ip route replace`
fails because 10.54.0.1 is not a valid next-hop on the Canal interface.

### Pod annotations (set by controller)

```yaml
k8s.v1.cni.cncf.io/networks: default/egress-external          # external ONLY
ovn.kubernetes.io/logical_switch: ovn-default              # ignored in non-primary mode
```

### Pod network-status (2 interfaces, missing OVN)

```json
[
  {"name": "k8s-pod-network", "interface": "eth0", "ips": ["10.52.0.80"]},
  {"name": "default/egress-external", "interface": "net1", "ips": ["192.168.31.101"]}
]
```

### VpcEgressGateway status

```
Phase: Processing    Ready: false
```

---

## After patch — working

### Workaround

The Deployment created by the CRD is patched to add the internal OVN NAD:

```bash
kubectl patch deployment -n default egress-default --type=json -p '[
  {"op":"add","path":"/spec/template/metadata/annotations/v1.multus-cni.io~1default-network",
   "value":"default/egress-internal"},
  {"op":"replace","path":"/spec/template/metadata/annotations/k8s.v1.cni.cncf.io~1networks",
   "value":"default/egress-internal, default/egress-external"}
]'
```

This does two things:
1. Sets `v1.multus-cni.io/default-network` to the internal OVN NAD — making eth0 the OVN overlay
2. Adds the internal NAD to `k8s.v1.cni.cncf.io/networks` — alongside the external NAD

This is equivalent to what PR [#6212](https://github.com/kubeovn/kube-ovn/pull/6212)
does for VpcNatGateway at the controller level.

### Pod annotations (after patch)

```yaml
v1.multus-cni.io/default-network: default/egress-internal    # ADDED by patch
k8s.v1.cni.cncf.io/networks: default/egress-internal, default/egress-external  # PATCHED
ovn.kubernetes.io/logical_switch: egress-internal          # still set by controller
```

### Pod interfaces (3 interfaces, all present)

```
87: eth0@if88:  172.20.10.2/24   ← OVN internal (default-network override)
89: net1@if90:  172.20.10.2/24   ← OVN internal (Multus secondary, duplicate)
91: net2@if92:  192.168.31.102/24 ← External on eth1 via ProviderNetwork
```

### Pod routes

```
default via 192.168.31.1 dev net2
172.20.10.0/24 dev eth0 proto kernel scope link src 172.20.10.2
192.168.31.0/24 dev net2 proto kernel scope link src 192.168.31.102
```

### iptables (set by init script, working)

```
-A PREROUTING -i eth0 -j MARK --set-xmark 0x4000/0x4000
-A POSTROUTING -j VEG-MASQUERADE
-A VEG-MASQUERADE -j MARK --set-xmark 0x0/0xffffffff
-A VEG-MASQUERADE -j MASQUERADE --random-fully
```

### VpcEgressGateway status

```
NAME             VPC           REPLICAS   PHASE       READY   INTERNAL IPS      EXTERNAL IPS
egress-default   ovn-cluster   1          Completed   true    ["172.20.10.2"]   ["192.168.31.102"]
```

### Verified: per-namespace egress IPs

Two namespaces with different egress IPs, both working simultaneously:

| Namespace | Gateway | Internal IP | Egress IP |
|-----------|---------|-------------|-----------|
| default | egress-default | 172.20.10.2 | 192.168.31.102 |
| tenant-b | egress-tenant-b | 172.20.20.5 | 192.168.31.150 |

---

## Versions tested

| Kube-OVN | Result |
|----------|--------|
| v1.15.4 (Harvester default) | Init crash: "Nexthop has invalid gateway" |
| v1.15.7 | Same crash — PR #6212 only fixed VpcNatGateway |
| v1.16.0 | Same crash — VpcEgressGateway still unfixed |
| v1.15.4 + deployment patch | **Working** — per-namespace egress IPs proven |

---

## GitHub issue survey

| Repo | Issue/PR | Title | Covers VpcEgressGateway in non-primary? |
|------|----------|-------|-----------------------------------------|
| [kubeovn#5360](https://github.com/kubeovn/kube-ovn/issues/5360) | Feature | Non-primary CNI plugin support | No — VpcNatGateway only |
| [kubeovn#5885](https://github.com/kubeovn/kube-ovn/issues/5885) | Bug | Tenant network not attached to VPC NAT gateway | No — VpcNatGateway only |
| [kubeovn#6212](https://github.com/kubeovn/kube-ovn/pull/6212) | PR | Fix VpcNatGateway default network | No — equivalent fix needed for VpcEgressGateway |
| [kubeovn#5598](https://github.com/kubeovn/kube-ovn/issues/5598) | Bug | VPC Egress Gateway cannot work in custom VPC | No — general bug, not non-primary-cni |
| [kubeovn#5665](https://github.com/kubeovn/kube-ovn/issues/5665) | Bug | VPC Egress Gateway init crash | No — general bug, not non-primary-cni |
| [kubeovn#6100](https://github.com/kubeovn/kube-ovn/issues/6100) | Bug | Subnet doesn't create VEG lr-policy | No — general bug, not non-primary-cni |
| [harvester#9455](https://github.com/harvester/harvester/issues/9455) | Feature | External connectivity for VMs on custom VPCs | No — broad scope |
| [harvester#10153](https://github.com/harvester/harvester/issues/10153) | Feature | Terraform provider for VPC Egress Gateway | No — no mention of non-primary-cni |
| harvester/kubeovn-operator | — | No egress-related issues | — |

**No existing issue covers VpcEgressGateway in non-primary-cni-mode. A new issue should be filed.**

---

## Suggested fix

Apply the same pattern as PR [#6212](https://github.com/kubeovn/kube-ovn/pull/6212)
to `pkg/controller/vpc_egress_gateway.go`:

1. When `EnableNonPrimaryCNI` is true and the internal subnet has a custom provider,
   add the internal NAD to `k8s.v1.cni.cncf.io/networks`
2. Set `v1.multus-cni.io/default-network` to the internal NAD so eth0 becomes the
   OVN overlay interface
3. Use provider-templated annotation keys instead of bare `ovn.kubernetes.io/`

---

## Related issues

- [kubeovn#5360](https://github.com/kubeovn/kube-ovn/issues/5360) — Feature: Kube-OVN as non-primary CNI plugin
- [kubeovn#5885](https://github.com/kubeovn/kube-ovn/issues/5885) — Bug: VpcNatGateway tenant network not attached (same class of bug)
- [kubeovn#6212](https://github.com/kubeovn/kube-ovn/pull/6212) — PR: fix VpcNatGateway default network (equivalent fix needed)
- [kubeovn#5618](https://github.com/kubeovn/kube-ovn/pull/5618) — PR: Non-primary CNI mode support
- [harvester#9455](https://github.com/harvester/harvester/issues/9455) — Support external connectivity for VMs on custom VPCs
