# Egress IP PoC - Harvester v1.8.0-rc2

**Date:** 2026-03-24
**Status:** Testing
**Tracks:** [harvester#9455](https://github.com/harvester/harvester/issues/9455)

## Background

On Harvester v1.7.1, all Kube-OVN egress IP approaches were blocked because
Kube-OVN v1.14.10 lacked `--non-primary-cni-mode` (see `../VpcEgressGateway-Analysis.md`).

Harvester v1.8.0-rc2 ships Kube-OVN v1.15.0+ with this fix.

## Phase 0: Post-Upgrade Validation

Run these checks before applying any manifests.

### 1. Verify Kube-OVN version

```bash
kubectl get deploy -n kube-system kube-ovn-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expect: v1.15.0 or later
```

### 2. Verify --non-primary-cni-mode=true

```bash
kubectl get deploy -n kube-system kube-ovn-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep non-primary
# Expect: --non-primary-cni-mode=true
```

If missing, check the kubeovn-operator addon Helm values and re-enable the addon.

### 3. Check required CRDs

```bash
kubectl get crd | grep -E 'vpcnatgateways|iptableseips|iptablessnatrules|vpcegressgateways'
# Expect all four present
```

**DECISION GATE:** If `--non-primary-cni-mode` is NOT present, stop here - everything is blocked.

---

## Phase 1: VpcNatGateway

**Goal:** Egress SNAT via VpcNatGateway so VMs on 172.20.10.0/24 exit as 192.168.31.200.

### Apply order

```bash
cd phase1-vpc-nat-gateway/

kubectl apply -f 00-vpc.yaml
kubectl apply -f 01-nad-internal.yaml
kubectl apply -f 02-nad-external.yaml
kubectl apply -f 03-subnet-internal.yaml
kubectl apply -f 04-provider-network.yaml
kubectl apply -f 05-vlan.yaml
kubectl apply -f 06-subnet-external.yaml
```

Before applying the gateway config, verify the image tag matches your cluster:

```bash
KUBEOVN_TAG=$(kubectl get deploy -n kube-system kube-ovn-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -oP 'v[\d.]+')
echo "Kube-OVN version: $KUBEOVN_TAG"
# Update 07-ovn-vpc-nat-config.yaml if tag differs from v1.15.0
```

```bash
kubectl apply -f 07-ovn-vpc-nat-config.yaml
kubectl apply -f 08-ovn-vpc-nat-gw-config.yaml
kubectl apply -f 09-vpc-nat-gateway.yaml
```

### Checkpoint: Gateway pod

```bash
# Pod running?
kubectl get pods -n kube-system -l app=vpc-nat-gw-gw1

# 3 interfaces? (eth0=Canal, net1=overlay, net2=external)
kubectl exec -n kube-system vpc-nat-gw-gw1-0 -- ip addr show

# External connectivity from gateway?
kubectl exec -n kube-system vpc-nat-gw-gw1-0 -- ping -c 3 192.168.31.1
kubectl exec -n kube-system vpc-nat-gw-gw1-0 -- ping -c 3 8.8.8.8
```

If the gateway pod is not running, check events:
```bash
kubectl describe pod -n kube-system vpc-nat-gw-gw1-0
kubectl logs -n kube-system vpc-nat-gw-gw1-0 --all-containers
```

### Apply EIP and SNAT

```bash
kubectl apply -f 10-eip.yaml
kubectl apply -f 11-snat.yaml
```

### Checkpoint: SNAT rule

```bash
kubectl get iptableseip eip-egress1
kubectl get iptablessnatrule snat-default

# Verify iptables inside the gateway:
kubectl exec -n kube-system vpc-nat-gw-gw1-0 -- iptables-legacy-save -t nat | grep SNAT
# Expect: -A SHARED_SNAT -s 172.20.10.0/24 -o net2 -j SNAT --to-source 192.168.31.200
```

### Create test VM

```bash
kubectl apply -f 12-vm-test.yaml

# Wait for VM to start
kubectl get vm test-egress -w

# Get VMI IP
kubectl get vmi test-egress -o jsonpath='{.status.interfaces[0].ipAddress}'
```

### Final verification

SSH into the VM (via console or virtctl) and run:

```bash
# Check default route points to NAT gateway
ip route
# Expect: default via 172.20.10.254

# Verify traffic reaches the internet through the gateway
traceroute -n 8.8.8.8
# First hop should be 172.20.10.254 (the NAT gateway), NOT a node IP
```

Since 192.168.31.200 is a private IP, `curl ifconfig.me` will return the router's
WAN IP — it does NOT prove which source IP was used on the LAN side. Instead, verify
the SNAT is applied by checking from the gateway pod and Wireshark on the Hyper-V vSwitch:

```bash
# 1. Confirm iptables SNAT rule in the gateway pod
kubectl exec -n kube-system vpc-nat-gw-gw1-0 -- iptables-legacy-save -t nat | grep SNAT
# Expect: -A SHARED_SNAT -s 172.20.10.0/24 -o net2 -j SNAT --to-source 192.168.31.200
```

**2. Wireshark on the Hyper-V host** — capture on the vSwitch / external NIC while
the VM generates traffic (e.g. `curl -s http://example.com` from the test-egress VM):

```
SNAT working (traffic from VM exits as 192.168.31.200):
  host 192.168.31.200 and src host 192.168.31.200

SNAT NOT working (traffic leaks with overlay IP):
  host 192.168.31.200 or net 172.20.10.0/24

Full picture — gateway + VM + router:
  host 192.168.31.200 or net 172.20.10.0/24

Response traffic back to gateway:
  dst host 192.168.31.200
```

If SNAT is working correctly, you should see **only 192.168.31.200** as source on the
wire — no 172.20.10.x addresses should appear on the physical segment.

### Risk: ProviderNetwork on mgmt-br

Using `mgmt-br` as the ProviderNetwork interface **could disrupt management connectivity**.
Have IPMI/console access ready before applying `04-provider-network.yaml`.

If management connectivity drops after applying, consider using a VLAN sub-interface instead,
or remove the ProviderNetwork and use the existing external subnet from the v1.7 PoC.

---

## Phase 2: VpcEgressGateway

**Goal:** Prove VpcEgressGateway works now that `--non-primary-cni-mode=true` is available.

This was blocked on v1.7.1 with "Nexthop has invalid gateway" init crash.

### Apply

The Harvester webhook blocks macvlan NADs. Temporarily disable it:

```bash
kubectl -n cattle-system scale deploy harvester-webhook --replicas=0
```

```bash
cd phase2-vpc-egress-gateway/

kubectl apply -f 20-nad-macvlan-external.yaml
kubectl apply -f 21-subnet-macvlan.yaml
kubectl apply -f 22-vpc-egress-gateway.yaml
```

Re-enable webhook:

```bash
kubectl -n cattle-system scale deploy harvester-webhook --replicas=3
```

### Verification

```bash
# Gateway pod should start without init crash
kubectl get pods -l ovn.kubernetes.io/vpc-egress-gateway=egress-default

# Check logs for "Nexthop has invalid gateway" (should NOT appear)
kubectl logs -l ovn.kubernetes.io/vpc-egress-gateway=egress-default --all-containers
```

---

## Cleanup

Remove in reverse order:

```bash
# Phase 2
kubectl delete -f phase2-vpc-egress-gateway/ --ignore-not-found

# Phase 1 - VM first
kubectl delete -f phase1-vpc-nat-gateway/12-vm-test.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/11-snat.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/10-eip.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/09-vpc-nat-gateway.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/08-ovn-vpc-nat-gw-config.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/07-ovn-vpc-nat-config.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/06-subnet-external.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/05-vlan.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/04-provider-network.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/03-subnet-internal.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/02-nad-external.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/01-nad-internal.yaml --ignore-not-found
kubectl delete -f phase1-vpc-nat-gateway/00-vpc.yaml --ignore-not-found
```

## Network Topology

### Phase 1: VpcNatGateway

Gateway pod with 3 NICs (eth0=Canal, net1=overlay, net2=external) bridges
a custom VPC overlay to the physical network via ProviderNetwork + Vlan + underlay Subnet.
SNAT is performed by iptables inside the gateway pod.

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
                       │  Physical: mgmt-br (untagged)         │
                       │  subnetexternal: 192.168.31.0/24      │
                       │  ProviderNetwork pn-mgmt + vlan0-mgmt │
                       └───────────────────┬───────────────────┘
                                           │
                  ┌────────────────────────┴──────────────────────┐
                  │                                                │
       ┌──────────┴───────────┐                      ┌─────────────┴────────────┐
       │  Harvester Node(s)   │                      │  vpc-nat-gw-gw1-0 pod   │
       │  192.168.31.x        │                      │  net2: 192.168.31.200    │
       └──────────────────────┘                      │  net1: 172.20.10.254    │
                                                     │  iptables SNAT          │
                                                     └─────────────┬───────────┘
                                                                   │
                                                     ┌─────────────┴───────────┐
                                                     │  Overlay (Kube-OVN)     │
                                                     │  subnetinternal         │
                                                     │  172.20.10.0/24         │
                                                     │  VPC: commonvpc         │
                                                     └─────────────┬───────────┘
                                                                   │
                                                     ┌─────────────┴───────────┐
                                                     │  VM: test-egress        │
                                                     │  172.20.10.x            │
                                                     │  default gw: .254       │
                                                     │  curl ifconfig.me       │
                                                     │   → 192.168.31.200      │
                                                     └─────────────────────────┘
```

### Phase 2: VpcEgressGateway

Gateway pod with 2 NICs (eth0=Canal + Kube-OVN secondary, net1=macvlan).
No ProviderNetwork/Vlan needed — macvlan attaches directly to mgmt-br.
SNAT is performed by the gateway pod's init script (OVN-managed).

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
                       │  Physical: mgmt-br (untagged)         │
                       │  192.168.31.0/24                      │
                       └───────────────────┬───────────────────┘
                                           │
                  ┌────────────────────────┴──────────────────────┐
                  │                                                │
       ┌──────────┴───────────┐                      ┌─────────────┴────────────┐
       │  Harvester Node(s)   │                      │  egress-default pod      │
       │  192.168.31.x        │                      │  net1: macvlan on mgmt-br│
       └──────────────────────┘                      │   192.168.31.201 (auto)  │
                                                     │  eth0: Canal + OVN       │
                                                     │   secondary (overlay)    │
                                                     └─────────────┬───────────┘
                                                                   │
                                                     ┌─────────────┴───────────┐
                                                     │  Overlay (Kube-OVN)     │
                                                     │  subnetinternal         │
                                                     │  172.20.10.0/24         │
                                                     │  VPC: ovn-cluster       │
                                                     └─────────────┬───────────┘
                                                                   │
                                                     ┌─────────────┴───────────┐
                                                     │  VM on overlay          │
                                                     │  172.20.10.x            │
                                                     └─────────────────────────┘
```

Key differences:
- **Phase 1** uses a custom VPC (`commonvpc`) + ProviderNetwork + Vlan + underlay Subnet + iptables EIP/SNAT
- **Phase 2** uses the default VPC (`ovn-cluster`) + macvlan NAD directly on mgmt-br — no ProviderNetwork stack needed
