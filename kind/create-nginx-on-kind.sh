#!/bin/bash

# ==========================================
# Create nginx test pods on the btlabs-k8s Kind cluster
#
# What:  Switches kubectl to the Kind cluster, confirms nodes are ready,
#        creates two nginx pods, and shows which node each landed on.
# Why:   kubectl acts on whatever context is currently active — running
#        this without switching context first is the #1 way pods end up
#        on the wrong cluster (as happened earlier in this session, when
#        nginx-01/nginx-02 landed on the kubeadm cluster's node "b"
#        instead of btlabs-k8s).
# ==========================================

set -e

CLUSTER_CONTEXT="kind-btlabs-k8s"
NAMESPACE="default"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()    { echo -e "  ${GREEN}[OK]${NC}   $1"; }
doing() { echo -e "  ${BLUE}[DOING]${NC} $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "  ${RED}[FAIL]${NC} $1"; }

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE} Create nginx test pods on ${CLUSTER_CONTEXT}${NC}"
echo -e "${BLUE}==========================================${NC}"

# ------------------------------------------------------------------
echo -e "\n${BLUE}[STEP 1/5] Switch to the Kind cluster context${NC}"
# ------------------------------------------------------------------
if ! kubectl config get-contexts -o name | grep -qx "$CLUSTER_CONTEXT"; then
  fail "context '$CLUSTER_CONTEXT' not found. Run: kind get clusters"
  kubectl config get-contexts -o name
  exit 1
fi

CURRENT=$(kubectl config current-context)
if [ "$CURRENT" = "$CLUSTER_CONTEXT" ]; then
  ok "already on $CLUSTER_CONTEXT"
else
  doing "switching from '$CURRENT' to '$CLUSTER_CONTEXT'"
  kubectl config use-context "$CLUSTER_CONTEXT" >/dev/null
  ok "switched to $CLUSTER_CONTEXT"
fi

# ------------------------------------------------------------------
echo -e "\n${BLUE}[STEP 2/5] Confirm the namespace in use${NC}"
# ------------------------------------------------------------------
NS_IN_USE=$(kubectl config view --minify -o jsonpath='{..namespace}')
NS_IN_USE=${NS_IN_USE:-default}
if [ "$NS_IN_USE" != "$NAMESPACE" ]; then
  warn "this context's saved namespace is '$NS_IN_USE', not '$NAMESPACE'"
  warn "pods will be created in '$NS_IN_USE' unless you pass -n $NAMESPACE explicitly"
else
  ok "namespace '$NAMESPACE' confirmed"
fi

# ------------------------------------------------------------------
echo -e "\n${BLUE}[STEP 3/5] Confirm cluster nodes are Ready${NC}"
# ------------------------------------------------------------------
doing "checking node status"
kubectl get nodes
NOT_READY=$(kubectl get nodes --no-headers | grep -vc " Ready " || true)
if [ "${NOT_READY:-0}" -gt 0 ]; then
  fail "one or more nodes are not Ready — fix this before continuing"
  exit 1
fi
ok "all nodes Ready"

# ------------------------------------------------------------------
echo -e "\n${BLUE}[STEP 4/5] Create the pods (idempotent: skips if already present)${NC}"
# ------------------------------------------------------------------
for pod in nginx-01 nginx-02; do
  if kubectl get pod "$pod" -n "$NAMESPACE" >/dev/null 2>&1; then
    ok "$pod already exists, skipping"
  else
    doing "creating $pod"
    kubectl run "$pod" --image=nginx -n "$NAMESPACE" >/dev/null
    ok "$pod created"
  fi
done

doing "waiting up to 60s for both pods to be Ready"
kubectl wait --for=condition=Ready pod/nginx-01 pod/nginx-02 -n "$NAMESPACE" --timeout=60s >/dev/null
ok "both pods Ready"

# ------------------------------------------------------------------
echo -e "\n${BLUE}[STEP 5/5] Show where each pod landed${NC}"
# ------------------------------------------------------------------
kubectl get pods -n "$NAMESPACE" -o wide
echo ""
CP_NAME=$(kubectl get nodes -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/control-plane=="")].metadata.name}')
for pod in nginx-01 nginx-02; do
  NODE=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
  if [ "$NODE" = "$CP_NAME" ]; then
    warn "$pod landed on the CONTROL PLANE ($NODE) — unexpected, check for a removed taint"
  else
    ok "$pod landed on worker node: $NODE"
  fi
done

echo -e "\n${GREEN}Done. Clean up with:${NC} kubectl delete pod nginx-01 nginx-02 -n $NAMESPACE"
