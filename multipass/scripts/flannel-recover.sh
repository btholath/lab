#!/usr/bin/env bash
# flannel-recover.sh
#
# Checks the pod network after the nodes' addresses changed, repairs stale flannel
# records, and verifies the cluster end to end.
#
# Run it on the MASTER (it needs kubectl and the `bridge` command):
#   bash flannel-recover.sh            check, repair what is stale, verify
#   bash flannel-recover.sh --check    check only, change nothing
#
# From PowerShell, without opening a shell:
#   multipass transfer flannel-recover.sh master:/home/ubuntu/
#   multipass exec master -- bash /home/ubuntu/flannel-recover.sh
#
# What it does:
#   1. lists the nodes and flags any that are not Ready
#   2. compares the address flannel recorded for each node with the node's own address,
#      and (unless --check) restarts the flannel pod of every node that is stale
#   3. verifies the pod network: master -> each worker, worker <-> worker, worker -> master
#   4. verifies DNS from a test pod on each worker
#   5. verifies the metrics API and `kubectl top nodes`
#
# It creates two small test pods (probe-w1, probe-w2) in the namespace "dns".
# Remove them afterwards with:  kubectl delete namespace dns
#
# Exit status: 0 = every check passed, 1 = at least one failed, 2 = kubectl cannot
# reach the API server (you are probably not on the master).
set -u

MASTER=${MASTER:-master}
W1=${W1:-worker1}
W2=${W2:-worker2}
FIX=1
[ "${1:-}" = "--check" ] && FIX=0

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
say() { printf '\n== %s\n' "$*"; }

node_ip()    { kubectl get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
flannel_ip() { kubectl get node "$1" -o custom-columns=F:.metadata.annotations.flannel\\.alpha\\.coreos\\.com/public-ip --no-headers 2>/dev/null; }
pod_net()    { local c; c=$(kubectl get node "$1" -o jsonpath='{.spec.podCIDR}'); printf '%s' "${c%/*}"; }
all_nodes()  { kubectl get nodes -o jsonpath='{.items[*].metadata.name}'; }

stale_nodes() {
  local n out=""
  for n in $(all_nodes); do
    [ "$(node_ip "$n")" = "$(flannel_ip "$n")" ] || out="$out $n"
  done
  printf '%s' "$out"
}

kubectl get nodes >/dev/null 2>&1 || {
  echo "kubectl cannot reach the API server. Run this script on the master." >&2
  exit 2
}
API_HOST=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#^https?://([^:/]+).*#\1#')

# ---------------------------------------------------------------- 1. nodes
say "1. Nodes"
kubectl get nodes -o wide
NOTREADY=$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}' | tr '\n' ' ')
if [ -z "$NOTREADY" ]; then
  ok "all nodes are Ready"
else
  bad "not Ready: $NOTREADY"
  echo "        On each of them, run:  sudo ip route add ${API_HOST}/32 dev eth0"
fi

# ---------------------------------------------------------------- 2. flannel records
say "2. Flannel's recorded address against each node's address"
for n in $(all_nodes); do
  printf '  %-9s node address %-16s flannel record %s\n' "$n" "$(node_ip "$n")" "$(flannel_ip "$n")"
done

STALE=$(stale_nodes)
if [ -n "$STALE" ] && [ "$FIX" = 1 ]; then
  echo "  Stale on:$STALE  -> restarting flannel on those nodes"
  for n in $STALE; do
    p=$(kubectl -n kube-flannel get pods -o jsonpath="{range .items[?(@.spec.nodeName==\"$n\")]}{.metadata.name}{end}")
    if [ -n "$p" ]; then
      kubectl -n kube-flannel delete pod "$p" --wait=false
    else
      echo "  no flannel pod found on $n"
    fi
  done
  echo "  waiting for the new records (up to 2 minutes)..."
  for i in $(seq 1 24); do
    STALE=$(stale_nodes)
    [ -z "$STALE" ] && break
    sleep 5
  done
  sleep 10   # give flannel a moment to program its routes
fi

for n in $(all_nodes); do
  if [ "$(node_ip "$n")" = "$(flannel_ip "$n")" ]; then
    ok "$n: flannel records $(flannel_ip "$n"), which is the node's address"
  else
    bad "$n: flannel records $(flannel_ip "$n"), but the node's address is $(node_ip "$n")"
  fi
done
echo "  Tunnel table on this node (bridge fdb show dev flannel.1):"
bridge fdb show dev flannel.1 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------- 3. pod network
say "3. Pod network"
kubectl get namespace dns >/dev/null 2>&1 || kubectl create namespace dns >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: probe-w1
  namespace: dns
spec:
  nodeName: $W1
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: probe-w2
  namespace: dns
spec:
  nodeName: $W2
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
EOF
kubectl -n dns wait --for=condition=Ready pod/probe-w1 pod/probe-w2 --timeout=90s >/dev/null 2>&1 \
  || bad "the test pods in namespace dns did not become Ready"

M0=$(pod_net "$MASTER")
P1=$(pod_net "$W1")
P2=$(pod_net "$W2")

for pair in "$W1:$P1" "$W2:$P2"; do
  n=${pair%%:*}
  t=${pair#*:}
  if ping -c2 -W2 "$t" >/dev/null 2>&1; then ok "master -> $n ($t)"; else bad "master -> $n ($t)"; fi
done

podping() { timeout 25 kubectl -n dns exec "$1" -- ping -c2 -W2 "$2" >/dev/null 2>&1; }
podping probe-w1 "$P2" && ok "pod on $W1 -> $W2 ($P2)"     || bad "pod on $W1 -> $W2 ($P2)"
podping probe-w2 "$P1" && ok "pod on $W2 -> $W1 ($P1)"     || bad "pod on $W2 -> $W1 ($P1)"
podping probe-w1 "$M0" && ok "pod on $W1 -> master ($M0)"  || bad "pod on $W1 -> master ($M0)"
podping probe-w2 "$M0" && ok "pod on $W2 -> master ($M0)"  || bad "pod on $W2 -> master ($M0)"

# ---------------------------------------------------------------- 4. DNS
say "4. DNS from a pod on each worker"
for p in probe-w1 probe-w2; do
  s=$(date +%s)
  out=$(timeout 40 kubectl -n dns exec "$p" -- ping -c1 -W1 kubernetes.default 2>&1 | head -1)
  took=$(( $(date +%s) - s ))
  case "$out" in
    PING*) ok "$p resolved kubernetes.default in ${took}s: $out" ;;
    *)     bad "$p could not resolve kubernetes.default (${took}s): ${out:-no answer within 40s}" ;;
  esac
done

# ---------------------------------------------------------------- 5. metrics
say "5. Metrics API"
st=""
for i in $(seq 1 12); do
  st=$(kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
  [ "$st" = "True" ] && break
  sleep 5
done
if [ "$st" = "True" ]; then ok "the metrics APIService is Available"; else bad "the metrics APIService is not Available (status: ${st:-unknown})"; fi
rows=$(kubectl top nodes --no-headers 2>/dev/null | wc -l)
if [ "$rows" -ge 3 ]; then ok "kubectl top nodes shows $rows nodes"; else bad "kubectl top nodes shows $rows nodes"; fi

# ---------------------------------------------------------------- result
say "Result"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  The cluster network is healthy."
  exit 0
fi
echo "  Something is still wrong. Run the script again, and keep its full output."
exit 1
