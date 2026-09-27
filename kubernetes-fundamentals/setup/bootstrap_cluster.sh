#!/bin/bash

# ==========================================
# Kubeadm Cluster Bootstrap (Single Node) — IDEMPOTENT
# Kubernetes v1.35
# CNI: Calico v3.31.x
#
# Safe to run any number of times:
#   - Skips kubeadm init if a healthy cluster already exists
#   - Uses `kubectl apply` (not `create`) for Calico manifests
#   - Auto-detects and self-heals the known CNI startup race
#     (pods that landed on a stale/competing CNI network before
#     Calico's own config was in place)
#   - Auto-detects and self-heals a stale calico-node CNI token
#     (causes stuck ContainerCreating on create AND stuck Terminating
#     on delete after the node has been running a long time — see
#     Lab 4 in kubernetes-fundamentals for the full incident writeup)
# ==========================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

K8S_VERSION="v1.35.0"
CALICO_VERSION="v3.31.0"
POD_CIDR="192.168.0.0/16"
POD_CIDR_PREFIX="192.168."   # used to detect pods that landed on the WRONG network

STEP=0
TOTAL_STEPS=8

step() { STEP=$((STEP+1)); echo -e "\n${BLUE}[STEP ${STEP}/${TOTAL_STEPS}] $1${NC}"; }
ok()   { echo -e "  ${GREEN}[OK]${NC}   $1"; }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1 (already satisfied)"; }
doing(){ echo -e "  ${BLUE}[DOING]${NC} $1"; }
fixed(){ echo -e "  ${GREEN}[FIXED]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
  echo -e "${BLUE}Please run as root (use sudo)${NC}"
  exit 1
fi

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE} Kubeadm Cluster Bootstrap (idempotent)${NC}"
echo -e "${BLUE}==========================================${NC}"

REAL_USER=${SUDO_USER:-$(whoami)}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG=/etc/kubernetes/admin.conf

# ------------------------------------------------------------------
step "Detect advertise IP and current cluster state"
# ------------------------------------------------------------------
ADVERTISE_IP=$(hostname -I | tr ' ' '\n' | grep -v '^172\.\(1[7-9]\|2[0-9]\|3[01]\)\.' | head -n1)
if [ -z "$ADVERTISE_IP" ]; then
  fail "could not auto-detect a non-docker interface IP. Run 'hostname -I' and hardcode ADVERTISE_IP."
  exit 1
fi
ok "advertise address: ${ADVERTISE_IP}"

CLUSTER_ALREADY_UP=false
if [ -f /etc/kubernetes/admin.conf ]; then
  # swap can silently come back on WSL2 and crash kubelet — fix pre-emptively before checking
  if [ -n "$(swapon --show)" ]; then
    doing "swap is on; disabling before checking cluster health"
    swapoff -a
    systemctl restart kubelet
    sleep 5
    fixed "swap disabled, kubelet restarted"
  fi
  if kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes >/dev/null 2>&1; then
    ok "existing healthy cluster detected — will skip kubeadm init"
    CLUSTER_ALREADY_UP=true
  else
    warn "admin.conf exists but cluster is not responding yet — will retry kubelet, then decide"
    systemctl restart kubelet
    sleep 10
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes >/dev/null 2>&1; then
      ok "cluster came up after kubelet restart — will skip kubeadm init"
      CLUSTER_ALREADY_UP=true
    else
      warn "cluster still unresponsive. If kubeadm init below fails with 'already exists' errors,"
      warn "run 'sudo kubeadm reset -f' first, then re-run this script."
    fi
  fi
else
  ok "no existing cluster found — will run kubeadm init"
fi

# ------------------------------------------------------------------
step "Initialize control plane"
# ------------------------------------------------------------------
if [ "$CLUSTER_ALREADY_UP" = true ]; then
  skip "kubeadm init"
else
  doing "pulling control plane images"
  kubeadm config images pull --kubernetes-version "${K8S_VERSION#v}"

  doing "running kubeadm init"
  kubeadm init \
    --kubernetes-version "${K8S_VERSION#v}" \
    --pod-network-cidr="${POD_CIDR}" \
    --apiserver-advertise-address="${ADVERTISE_IP}" \
    --cri-socket unix:///var/run/containerd/containerd.sock
  fixed "control plane initialized"
fi

# ------------------------------------------------------------------
step "Configure kubeconfig for regular user"
# ------------------------------------------------------------------
mkdir -p "$USER_HOME/.kube"
if [ -f "$USER_HOME/.kube/config" ] && cmp -s /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"; then
  skip "$USER_HOME/.kube/config already up to date"
else
  doing "copying admin.conf to $USER_HOME/.kube/config"
  cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
  chown "$REAL_USER:$REAL_USER" "$USER_HOME/.kube/config"
  fixed "$USER_HOME/.kube/config updated"
fi

# ------------------------------------------------------------------
step "Install/verify Calico CNI"
# ------------------------------------------------------------------
if kubectl get namespace tigera-operator >/dev/null 2>&1; then
  skip "tigera-operator namespace already exists"
else
  doing "applying tigera-operator.yaml (${CALICO_VERSION})"
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
  fixed "tigera-operator applied"
fi

doing "waiting for Tigera operator CRDs to register"
kubectl wait --for=condition=Established --timeout=90s \
  crd/installations.operator.tigera.io \
  crd/apiservers.operator.tigera.io >/dev/null 2>&1 || warn "CRDs not established within timeout — will still try applying custom-resources.yaml"

if kubectl get installation.operator.tigera.io default >/dev/null 2>&1; then
  skip "Calico Installation custom resource already exists"
else
  doing "applying custom-resources.yaml (${CALICO_VERSION})"
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"
  fixed "Calico custom resources applied"
fi

doing "waiting up to 90s for calico-system pods to be ready"
for i in $(seq 1 18); do
  TOTAL=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | wc -l)
  READY=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1]==a[2]) c++} END{print c+0}')
  if [ "$TOTAL" -gt 0 ] && [ "$READY" -eq "$TOTAL" ]; then
    ok "all $TOTAL calico-system pods ready"
    break
  fi
  sleep 5
done

# ------------------------------------------------------------------
step "Self-heal: detect and fix pods stuck on the wrong CNI network"
# ------------------------------------------------------------------
# Known WSL2 race: a pod scheduled before Calico's own CNI conflist was
# written can fall through to a stale/competing CNI config (e.g. a leftover
# Podman bridge) and get an IP outside the real pod-network CIDR. Such pods
# never become Ready. Detect and delete them so they reschedule correctly.
doing "scanning calico-system and kube-system for pods with mis-assigned IPs"

BAD_PODS=""
for ns in calico-system kube-system; do
  while read -r name ip hostnet; do
    [ -z "$name" ] && continue
    [ "$hostnet" = "true" ] && continue          # hostNetwork pods are expected to have the node IP
    [ -z "$ip" ] || [ "$ip" = "<none>" ] && continue
    case "$ip" in
      ${POD_CIDR_PREFIX}*) ;;                     # correct network, fine
      "$ADVERTISE_IP") ;;                         # node's own IP (e.g. calico-node, typha), fine
      *) BAD_PODS="${BAD_PODS} ${ns}/${name}" ;;
    esac
  done < <(kubectl get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP} {.spec.hostNetwork}{"\n"}{end}' 2>/dev/null)
done

if [ -z "$BAD_PODS" ]; then
  ok "no mis-networked pods found"
else
  warn "found pods on the wrong network:${BAD_PODS}"
  for entry in $BAD_PODS; do
    ns="${entry%%/*}"
    name="${entry#*/}"
    doing "deleting ${ns}/${name} to force reschedule onto the correct CNI network"
    kubectl delete pod -n "$ns" "$name" --ignore-not-found >/dev/null
  done
  doing "waiting 30s for rescheduled pods to come up"
  sleep 30
  fixed "rescheduled mis-networked pods (re-run this script if any are still not Ready)"
fi

# ------------------------------------------------------------------
step "Self-heal: detect and fix a stale Calico CNI token (Unauthorized errors)"
# ------------------------------------------------------------------
# Known recurring issue on long-lived nodes: calico-node's "install-cni" init
# container writes a ONE-TIME snapshot of a service account token to
# /etc/cni/net.d/calico-kubeconfig when the pod starts. Unlike a token
# mounted into a running pod (which kubelet auto-rotates roughly hourly),
# this on-disk snapshot is never refreshed for the lifetime of the
# calico-node pod. After enough elapsed time, the standalone `calico` CNI
# binary — invoked directly by containerd for every pod ADD (create) and
# DEL (delete) — starts failing with "connection is unauthorized:
# Unauthorized", which blocks BOTH new pod creation (stuck
# ContainerCreating) AND pod deletion (stuck Terminating). Fix: cycle
# calico-node so its init container re-runs and writes a fresh token.
if kubectl get pods -n calico-system -l k8s-app=calico-node >/dev/null 2>&1; then
  doing "scanning recent events for CNI 'Unauthorized' authentication failures"

  STALE_TOKEN_EVENTS=$(kubectl get events -A --field-selector reason=FailedCreatePodSandBox -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -c "Unauthorized" || true)
  STALE_TOKEN_EVENTS_DEL=$(kubectl get events -A --field-selector reason=FailedKillPod -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -c "Unauthorized" || true)

  if [ "${STALE_TOKEN_EVENTS:-0}" -gt 0 ] || [ "${STALE_TOKEN_EVENTS_DEL:-0}" -gt 0 ]; then
    warn "found CNI 'Unauthorized' errors (create: ${STALE_TOKEN_EVENTS:-0}, delete: ${STALE_TOKEN_EVENTS_DEL:-0}) — calico-node's CNI token has likely gone stale"
    doing "cycling calico-node to force a fresh token snapshot"
    kubectl delete pod -n calico-system -l k8s-app=calico-node --ignore-not-found >/dev/null

    doing "waiting up to 90s for calico-node to become ready again"
    for i in $(seq 1 18); do
      if kubectl get pods -n calico-system -l k8s-app=calico-node --no-headers 2>/dev/null | awk '{split($2,a,"/"); exit !(a[1]==a[2])}'; then
        fixed "calico-node is ready with a fresh CNI token"
        break
      fi
      sleep 5
    done

    doing "waiting 20s for any pods stuck on the stale token to retry and recover"
    sleep 20
  else
    ok "no stale CNI token symptoms found"
  fi
else
  skip "calico-node not present yet (fresh install) — nothing to check"
fi

# ------------------------------------------------------------------
step "Remove control-plane taint (single-node scheduling)"
# ------------------------------------------------------------------
if kubectl get nodes -o jsonpath='{.items[*].spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")].key}' 2>/dev/null | grep -q control-plane; then
  doing "removing control-plane taint"
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null
  fixed "control-plane taint removed"
else
  skip "control-plane taint already absent"
fi

# ------------------------------------------------------------------
step "Final status"
# ------------------------------------------------------------------
echo "------------------------------------------------"
kubectl get nodes -o wide
echo "------------------------------------------------"
kubectl get pods -A
echo "------------------------------------------------"

echo -e "\n${GREEN}Bootstrap check complete. Safe to re-run this script any time.${NC}"
echo -e "${BLUE}Verify with:${NC} export KUBECONFIG=${USER_HOME}/.kube/config && kubectl get nodes"
