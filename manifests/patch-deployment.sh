#!/bin/bash
# Workaround: VpcEgressGateway controller doesn't attach the internal subnet
# as a Multus NAD in non-primary-cni-mode (Kube-OVN as secondary CNI).
#
# The controller sets ovn.kubernetes.io/logical_switch but that annotation is
# ignored when Kube-OVN is not the primary CNI. We need the internal subnet
# attached via k8s.v1.cni.cncf.io/networks instead.
#
# We also set v1.multus-cni.io/default-network to the internal NAD so eth0
# becomes the OVN overlay interface (matching stock VpcEgressGateway behavior).
#
# See bug-report-vpcegressgateway.md for full details and source code analysis.
#
# Usage: ./patch-deployment.sh <namespace> <veg-name>

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> <veg-name>}"
VEG_NAME="${2:?Usage: $0 <namespace> <veg-name>}"

echo "Waiting for Deployment ${NAMESPACE}/${VEG_NAME} to exist..."
until kubectl get deployment -n "$NAMESPACE" "$VEG_NAME" &>/dev/null; do
  sleep 2
done

echo "Patching Deployment to set internal OVN NAD as default-network..."
kubectl patch deployment -n "$NAMESPACE" "$VEG_NAME" --type=json -p "[
  {
    \"op\": \"add\",
    \"path\": \"/spec/template/metadata/annotations/v1.multus-cni.io~1default-network\",
    \"value\": \"${NAMESPACE}/ovn-internal\"
  }
]"

echo "Patch applied. Waiting for rollout..."
kubectl rollout status deployment -n "$NAMESPACE" "$VEG_NAME" --timeout=300s

echo ""
echo "Pod status:"
kubectl get pods -n "$NAMESPACE" -l "ovn.kubernetes.io/vpc-egress-gateway=${VEG_NAME}" -o wide
