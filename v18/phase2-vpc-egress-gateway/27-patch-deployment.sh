#!/bin/bash
# Workaround: VpcEgressGateway controller doesn't attach the internal subnet
# as a Multus NAD in non-primary-cni-mode. This patch adds it.
#
# The controller sets ovn.kubernetes.io/logical_switch but that annotation is
# ignored when Kube-OVN is the secondary CNI. We need the internal subnet
# attached via k8s.v1.cni.cncf.io/networks instead.
#
# We also set v1.multus-cni.io/default-network to the internal NAD so eth0
# becomes the OVN overlay interface (matching stock VpcEgressGateway behavior).

set -euo pipefail

NAMESPACE="${1:-default}"
VEG_NAME="${2:-egress-default}"

echo "Waiting for Deployment ${VEG_NAME} to exist..."
until kubectl get deployment -n "$NAMESPACE" "$VEG_NAME" &>/dev/null; do
  sleep 2
done

echo "Patching Deployment ${VEG_NAME} to add internal OVN NAD..."
kubectl patch deployment -n "$NAMESPACE" "$VEG_NAME" --type=json -p '[
  {
    "op": "add",
    "path": "/spec/template/metadata/annotations/v1.multus-cni.io~1default-network",
    "value": "default/ovn-internal"
  },
  {
    "op": "replace",
    "path": "/spec/template/metadata/annotations/k8s.v1.cni.cncf.io~1networks",
    "value": "default/ovn-internal, default/egress-ext"
  }
]'

echo "Patch applied. Waiting for rollout..."
kubectl rollout status deployment -n "$NAMESPACE" "$VEG_NAME" --timeout=300s

echo "Checking pod status..."
kubectl get pods -n "$NAMESPACE" -l "ovn.kubernetes.io/vpc-egress-gateway=${VEG_NAME}" -o wide
