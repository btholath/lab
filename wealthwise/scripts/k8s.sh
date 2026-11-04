#!/usr/bin/env bash
# Local Kubernetes workflow on kind.   Usage: scripts/k8s.sh up|deploy|status|logs [app]|smoke|down
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=wealthwise
NS=wealthwise
NODE="${CLUSTER}-control-plane"
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml"
URL="http://localhost:8080"
TIMEOUT=900s   # image pulls can be slow on some networks
THIRD_PARTY_IMAGES="kong:3.8 postgres:16-alpine softwaremill/elasticmq-native:1.6.11"

need() { command -v "$1" >/dev/null || { echo "missing '$1' - run: make k8s-setup"; exit 1; }; }
need docker; need kubectl; need kind

cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    echo "==> cluster '$CLUSTER' already exists"
  else
    echo "==> creating kind cluster (host :8080 -> ingress)"
    kind create cluster --config k8s/kind-config.yaml
  fi
  kubectl config use-context "kind-$CLUSTER" >/dev/null
}

ingress() {
  if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
    echo "==> installing ingress-nginx"
    kubectl apply -f "$INGRESS_MANIFEST"
  fi
  kubectl -n ingress-nginx wait --for=condition=available deployment/ingress-nginx-controller --timeout=$TIMEOUT
  # The Deployment reports "available" before its pod exists (maxUnavailable is 1), so wait for the pod to appear first.
  for _ in $(seq 1 90); do
    kubectl -n ingress-nginx get pod -l app.kubernetes.io/component=controller -o name 2>/dev/null | grep -q . && break
    sleep 2
  done
  kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=$TIMEOUT
  # Local dev only: the admission webhook is flaky on kind/WSL2 ("connection refused") and not needed here.
  kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found
}

images() {
  local arch; case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  echo "==> building images"
  docker build --provenance=false --sbom=false -t wealthwise-api:local -f api/Dockerfile .
  docker build --provenance=false --sbom=false -t wealthwise-web:local -f web/Dockerfile .

  echo "==> loading images into the cluster"
  for img in $THIRD_PARTY_IMAGES; do
    docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img"
  done
  # Docker 28+/29 uses the containerd image store, where `kind load` can fail on multi-platform images
  # ("ctr images import --all-platforms" errors). Export one platform and import it without strict flags.
  local tar; tar="$(mktemp --suffix=.tar)"
  # shellcheck disable=SC2086
  docker save --platform "linux/$arch" -o "$tar" wealthwise-api:local wealthwise-web:local $THIRD_PARTY_IMAGES 2>/dev/null \
    || docker save -o "$tar" wealthwise-api:local wealthwise-web:local $THIRD_PARTY_IMAGES   # older Docker: no --platform
  docker exec --privileged -i "$NODE" ctr --namespace=k8s.io images import - < "$tar"
  rm -f "$tar"
}

apply() {
  echo "==> applying manifests"
  for attempt in 1 2 3 4 5; do
    if kubectl kustomize --load-restrictor LoadRestrictionsNone k8s | kubectl apply -f -; then break; fi
    echo "apply failed (attempt $attempt); retrying in 5s"; sleep 5
    [ "$attempt" = 5 ] && exit 1
  done
}

wait_ready() {
  echo "==> waiting for workloads"
  kubectl -n $NS rollout status statefulset/postgres --timeout=$TIMEOUT
  for d in elasticmq api kong web; do kubectl -n $NS rollout status deployment/$d --timeout=$TIMEOUT; done
  for i in $(seq 1 30); do
    curl -fs "$URL/api/health" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "app not answering on $URL yet; check: make k8s-status"; return 1
}

case "${1:-help}" in
  up)     cluster; ingress; images; apply; wait_ready; echo; echo "Ready: $URL" ;;
  deploy) # rebuild + roll out after code changes
          kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || { echo "cluster '$CLUSTER' not found - run: make k8s-up"; exit 1; }
          images; apply
          kubectl -n $NS rollout restart deployment/api deployment/web
          wait_ready; echo "Redeployed: $URL" ;;
  status) kubectl -n $NS get pods,svc,ingress -o wide ;;
  logs)   kubectl -n $NS logs -l "app=${2:-api}" --tail=100 -f --prefix --max-log-requests=10 ;;
  smoke)  # Kong is not exposed outside the cluster, so tunnel to it for the end-to-end script.
          # Default 8801 so it never collides with the Docker Compose gateway on 8800.
          PORT="${KONG_PORT:-8801}"
          if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
            echo "local port $PORT is already in use; free it or set KONG_PORT=<other port>"; exit 1
          fi
          kubectl -n $NS port-forward svc/kong "$PORT:8000" >/dev/null 2>&1 &
          PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT; sleep 3
          kill -0 $PF 2>/dev/null || { echo "port-forward to Kong failed"; exit 1; }
          GW="http://localhost:$PORT" bash scripts/smoke.sh ;;
  down)   kind delete cluster --name "$CLUSTER" ;;
  *)      echo "usage: $0 up|deploy|status|logs [app]|smoke|down"; exit 1 ;;
esac
