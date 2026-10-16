#!/usr/bin/env bash
# ingress-lab.sh
#
# Sets up, checks and removes the Ingress lab: Traefik as the Ingress controller, two small
# test apps, and an Ingress that routes by host name. Safe to run again and again: a second
# run changes nothing that is already right.
#
# Run it on the MASTER (it needs kubectl and curl):
#   bash ingress-lab.sh              set everything up (same as: up), then check it
#   bash ingress-lab.sh status       check only, change nothing
#   bash ingress-lab.sh down         remove everything the lab created (and the temporary
#                                    traefik-nodes-reader role, if it was made by hand)
#   bash ingress-lab.sh reset        down, then up: a clean start from nothing
#   bash ingress-lab.sh render       print both manifests    (render traefik | render apps)
#
# From PowerShell, without opening a shell:
#   multipass transfer ingress-lab.sh master:/home/ubuntu/
#   multipass exec master -- bash /home/ubuntu/ingress-lab.sh
#
# Settings (environment variables, all optional):
#   TRAEFIK_VERSION   image tag of Traefik            default v3.7.12
#   WHOAMI_VERSION    image tag of the test apps      default v1.11
#   NODEPORT          the port opened on every node   default 30080
#   LAB_IP            address used for the requests   default: the control-plane node's address
#   ROLLOUT_TIMEOUT   seconds to wait for each Deployment (image pulls can be slow)  default 600
#   ROUTE_TIMEOUT     seconds to wait for Traefik to learn the Ingress               default 90
#   DELETE_TIMEOUT    seconds to wait for the namespaces to finish deleting          default 120
#
# What 'up' does, in order:
#   1. looks at the nodes
#   2. asks Docker Hub whether both image tags exist       (stops here if one does not)
#   3. checks that the NodePort is free, or already ours   (stops here if another Service has it)
#   4. applies Traefik: namespace, ServiceAccount, ClusterRole, ClusterRoleBinding,
#      IngressClass, Deployment, Service; waits for the Pod; checks that Traefik's ServiceAccount
#      can read everything it needs and that its log has no permission errors; checks that
#      the door answers
#   5. applies the test apps and the Ingress; waits for the Pods
#   6. checks the routing: both host names, load sharing, 404 for unknown hosts
#
# Steps 1 to 3 change nothing, so a failure there leaves the cluster as it was.
#
# Exit status: 0 = every check passed, 1 = at least one failed, 2 = kubectl cannot reach the API.
set -u

TRAEFIK_VERSION=${TRAEFIK_VERSION:-v3.7.12}
WHOAMI_VERSION=${WHOAMI_VERSION:-v1.11}
NODEPORT=${NODEPORT:-30080}
LAB_IP=${LAB_IP:-}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-600}
ROUTE_TIMEOUT=${ROUTE_TIMEOUT:-90}
DELETE_TIMEOUT=${DELETE_TIMEOUT:-120}
LAB_OBJECTS="ns/ingress-lab ns/traefik ingressclass/traefik clusterrole/traefik-ingress-controller clusterrolebinding/traefik-ingress-controller"
STRAY_OBJECTS="clusterrole/traefik-nodes-reader clusterrolebinding/traefik-nodes-reader"
TRAEFIK_IMAGE="traefik:${TRAEFIK_VERSION}"
WHOAMI_IMAGE="traefik/whoami:${WHOAMI_VERSION}"
SA="system:serviceaccount:traefik:traefik-ingress-controller"
URL=""

PASS=0; FAIL=0; WARN=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  WARN  %s\n' "$*"; WARN=$((WARN + 1)); }
info() { printf '  info  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
indent() { sed 's/^/        /'; }

# ---------------------------------------------------------------- the manifests
render_traefik() {
cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-ingress-controller
  namespace: traefik
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: traefik-ingress-controller
rules:
- apiGroups:
  - ""
  resources:
  - services
  - secrets
  - nodes
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - extensions
  - networking.k8s.io
  resources:
  - ingresses
  - ingressclasses
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - extensions
  - networking.k8s.io
  resources:
  - ingresses/status
  verbs:
  - update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: traefik-ingress-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik-ingress-controller
subjects:
- kind: ServiceAccount
  name: traefik-ingress-controller
  namespace: traefik
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: traefik
spec:
  controller: traefik.io/ingress-controller
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: traefik
  labels:
    app: traefik
spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik-ingress-controller
      containers:
      - name: traefik
        image: ${TRAEFIK_IMAGE}
        args:
        - --providers.kubernetesingress
        - --entryPoints.web.address=:8000
        - --entryPoints.traefik.address=:8080
        - --ping=true
        - --accesslog=true
        - --log.level=INFO
        ports:
        - name: web
          containerPort: 8000
        - name: traefik
          containerPort: 8080
        readinessProbe:
          httpGet:
            path: /ping
            port: traefik
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /ping
            port: traefik
          periodSeconds: 10
          failureThreshold: 3
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: traefik
spec:
  type: NodePort
  selector:
    app: traefik
  ports:
  - name: web
    port: 80
    targetPort: web
    nodePort: ${NODEPORT}
EOF
}

render_apps() {
cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ingress-lab
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: ingress-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
      - name: whoami
        image: ${WHOAMI_IMAGE}
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /health
            port: 80
          periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: ingress-lab
spec:
  selector:
    app: whoami
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web2
  namespace: ingress-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web2
  template:
    metadata:
      labels:
        app: web2
    spec:
      containers:
      - name: whoami
        image: ${WHOAMI_IMAGE}
        args:
        - --name=app-two
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /health
            port: 80
          periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: web2
  namespace: ingress-lab
spec:
  selector:
    app: web2
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: host-routing
  namespace: ingress-lab
spec:
  ingressClassName: traefik
  rules:
  - host: whoami.lab
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: whoami
            port:
              number: 80
  - host: web2.lab
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web2
            port:
              number: 80
EOF
}

# ---------------------------------------------------------------- helpers
preflight() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found. Run this script on the master." >&2; exit 2; }
  kubectl get nodes >/dev/null 2>&1 || {
    echo "kubectl cannot reach the API server. Run this script on the master." >&2; exit 2; }
  if [ -z "$LAB_IP" ]; then
    LAB_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    [ -n "$LAB_IP" ] || LAB_IP=$(kubectl get nodes \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  fi
  URL="http://${LAB_IP}:${NODEPORT}"
}

check_nodes() {
  local total notready
  total=$(kubectl get nodes --no-headers | wc -l)
  notready=$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}' | tr '\n' ' ')
  if [ -z "$notready" ]; then
    ok "all $total nodes are Ready"
  else
    warn "not Ready: $notready (the pod network may be broken: try flannel-recover.sh --check)"
  fi
  info "requests will go to $URL"
}

# Asks Docker Hub, without downloading anything, whether a tag exists. Prints 200, 404, or another word.
registry_has() {
  local repo=$1 tag=$2 token
  token=$(curl -s -m 10 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  if [ -z "$token" ]; then echo "no-token"; return; fi
  curl -s -m 10 -o /dev/null -I -w '%{http_code}' -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://registry-1.docker.io/v2/${repo}/manifests/${tag}"
}

check_tag() {   # repo tag variable-name
  local r
  r=$(registry_has "$1" "$2")
  case "$r" in
    200) ok "$1:$2 exists on Docker Hub" ;;
    404) bad "$1:$2 does not exist on Docker Hub. Choose a tag that does, with  $3=<tag>" ;;
    *)   warn "could not check $1:$2 on Docker Hub (answer: $r). The cluster will try to pull it anyway" ;;
  esac
}

check_nodeport() {
  local users
  users=$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .spec.ports[*]}{.nodePort}{" "}{end}{"\n"}{end}' \
    | awk -v p="$NODEPORT" '{for (i = 2; i <= NF; i++) if ($i == p) print $1}' \
    | grep -v '^traefik/traefik$' | tr '\n' ' ')
  users=${users% }
  if [ -n "$users" ]; then
    bad "NodePort $NODEPORT is already used by: $users. Choose another with  NODEPORT=<port>"
  else
    ok "NodePort $NODEPORT is free, or already used by this lab"
  fi
}

apply_manifest() {   # name render-function
  local out rc
  out=$("$2" | kubectl apply -f - 2>&1); rc=$?
  printf '%s\n' "$out" | indent
  if [ $rc -eq 0 ]; then ok "$1 applied"; else bad "kubectl apply failed for $1"; fi
  return $rc
}

diagnose() {   # namespace app-label
  echo "        --- pods:"
  kubectl -n "$1" get pods -l app="$2" -o wide 2>&1 | indent
  echo "        --- recent events:"
  kubectl -n "$1" get events --sort-by=.lastTimestamp 2>&1 | tail -6 | cut -c1-170 | indent
  echo "        --- log tail:"
  kubectl -n "$1" logs -l app="$2" --tail=8 2>&1 | cut -c1-170 | indent
}

# Waits for a Deployment, printing what its Pods are doing (so a slow image pull is visible),
# and gives up early if an event says an image cannot be found.
wait_rollout() {   # namespace deployment
  local ns=$1 dep=$2 start now state evs last=-100
  start=$(date +%s)
  while :; do
    if kubectl -n "$ns" rollout status "deploy/$dep" --timeout=2s >/dev/null 2>&1; then
      ok "$ns/$dep is rolled out"; return 0
    fi
    now=$(( $(date +%s) - start ))
    if [ $((now - last)) -ge 10 ]; then
      state=$(kubectl -n "$ns" get pods -l app="$dep" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"/"}{.status.containerStatuses[0].state.waiting.reason}{"  "}{end}' 2>/dev/null)
      info "waiting for $ns/$dep (${now}s): ${state:-no Pods yet}"
      last=$now
    fi
    if [ "$now" -ge "${FAILFAST_AFTER:-20}" ]; then
      evs=$(kubectl -n "$ns" get events --field-selector type=Warning \
        -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null \
        | grep -Ei 'manifest unknown|pull access denied|failed to resolve reference|no such image|not found' | tail -1)
      if [ -n "$evs" ]; then
        bad "$ns/$dep cannot start: $(printf '%s' "$evs" | cut -c1-150)"; diagnose "$ns" "$dep"; return 1
      fi
    fi
    if [ "$now" -ge "$ROLLOUT_TIMEOUT" ]; then
      bad "$ns/$dep was not ready after ${ROLLOUT_TIMEOUT}s"; diagnose "$ns" "$dep"; return 1
    fi
    sleep 3
  done
}

# Polls the NodePort until it answers with the wanted HTTP status. Prints the last status seen.
wait_code() {   # wanted-code host-header-or-empty seconds
  local want=$1 host=$2 limit=$3 start code
  start=$(date +%s)
  while :; do
    if [ -n "$host" ]; then
      code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Host: $host" "$URL/")
    else
      code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$URL/")
    fi
    if [ "$code" = "$want" ]; then echo "$code"; return 0; fi
    if [ $(( $(date +%s) - start )) -ge "$limit" ]; then echo "$code"; return 1; fi
    sleep 3
  done
}

# Polls until the answer for a host contains a pattern. Prints the last answer seen.
wait_body() {   # host grep-pattern seconds
  local host=$1 pat=$2 limit=$3 start body
  start=$(date +%s)
  while :; do
    body=$(curl -s -m 5 -H "Host: $host" "$URL/")
    if printf '%s' "$body" | grep -q "$pat"; then printf '%s' "$body"; return 0; fi
    if [ $(( $(date +%s) - start )) -ge "$limit" ]; then printf '%s' "$body"; return 1; fi
    sleep 3
  done
}

distinct_pods() {   # 10 requests; how many different whoami Pods answered
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -m 5 -H 'Host: whoami.lab' "$URL/" | sed -n 's/^Hostname: //p' | head -1
  done | sort -u | wc -l
}

# ---------------------------------------------------------------- checks
check_rbac() {
  local missing="" spec
  for spec in services secrets nodes endpointslices.discovery.k8s.io ingresses.networking.k8s.io ingressclasses.networking.k8s.io; do
    [ "$(kubectl auth can-i list "$spec" -A --as="$SA" 2>/dev/null)" = "yes" ] || missing="$missing $spec"
  done
  if [ -z "$missing" ]; then
    ok "Traefik's ServiceAccount can list what it watches (services, secrets, nodes, endpointslices, ingresses, ingressclasses)"
  else
    bad "Traefik's ServiceAccount cannot list:${missing}. Its ClusterRole is missing a rule, and Traefik will not load any route"
  fi
}

diagnose_routing() {
  echo "        --- the Ingress as the cluster sees it:"
  kubectl -n ingress-lab describe ingress host-routing 2>&1 | head -22 | cut -c1-150 | indent
  echo "        --- the last lines of the Traefik log:"
  kubectl -n traefik logs deploy/traefik --tail=8 2>&1 | cut -c1-200 | indent
}

# Run AFTER the routing checks. Old permission errors stay in the log for a while after a fix,
# so they only count as a failure when the routes do not work.
check_log() {
  local errs forb
  errs=$(kubectl -n traefik logs deploy/traefik --tail=100 2>/dev/null | grep -cE '(^| )ERR( |$)|^E[0-9]{4} ')
  forb=$(kubectl -n traefik logs deploy/traefik --tail=100 2>/dev/null | grep -c 'forbidden')
  if [ "${forb:-0}" -gt 0 ]; then
    if [ "${ROUTE_OK:-0}" = 1 ]; then
      warn "the Traefik log still holds $forb permission errors, but the routes work: they are probably from before the permission was fixed"
    else
      bad "the Traefik log reports $forb permission errors: kubectl -n traefik logs deploy/traefik | grep forbidden"
    fi
  elif [ "${errs:-0}" -gt 0 ]; then
    warn "the Traefik log has $errs error lines: kubectl -n traefik logs deploy/traefik | grep -E ' ERR |^E[0-9]{4}'"
  else
    ok "the Traefik log has no errors"
  fi
}

verify_traefik() {
  local ctrl node errs code
  ctrl=$(kubectl get ingressclass traefik -o jsonpath='{.spec.controller}' 2>/dev/null)
  if [ "$ctrl" = "traefik.io/ingress-controller" ]; then
    ok "IngressClass traefik exists (controller $ctrl)"
  else
    bad "IngressClass traefik is missing or names another controller: '${ctrl}'"
  fi
  node=$(kubectl -n traefik get pods -l app=traefik -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  info "the Traefik Pod runs on: ${node:-unknown}"
  check_rbac
  code=$(wait_code 404 "nope.lab" 60)
  if [ "$code" = "404" ]; then
    ok "the door works: an unknown host gets a 404 from Traefik ($URL)"
  else
    bad "no 404 from $URL (last answer: $code). Check the pod network and the Service"
  fi
}

verify_routes() {
  local code body distinct ready want start wlimit
  ROUTE_OK=0
  code=$(wait_code 200 "whoami.lab" "$ROUTE_TIMEOUT")
  if [ "$code" = "200" ]; then
    ok "Host whoami.lab is routed (HTTP 200)"
    ROUTE_OK=1
    # Traefik learns the Pod addresses a moment after the Pods are Ready, so wait for them
    ready=$(kubectl -n ingress-lab get deploy whoami -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    want=${ready:-0}; [ "$want" -gt 10 ] && want=10
    start=$(date +%s)
    while :; do
      distinct=$(distinct_pods)
      [ "$distinct" -ge "$want" ] && break
      [ $(( $(date +%s) - start )) -ge "${LB_WAIT:-30}" ] && break
      sleep 3
    done
    if [ "$want" -ge 2 ]; then
      if [ "$distinct" -ge "$want" ]; then ok "the load is shared: 10 requests reached $distinct different whoami Pods"
      else warn "10 requests reached only $distinct of $want Ready whoami Pods after ${LB_WAIT:-30}s"; fi
    else info "only ${want} whoami Pod is Ready, so there is nothing to share yet"; fi
  else
    bad "Host whoami.lab answered HTTP $code after ${ROUTE_TIMEOUT}s: Traefik has not turned the Ingress into a route"
    diagnose_routing
  fi
  # web2: give it the full wait when whoami works (Traefik may still be catching up), a short one otherwise
  wlimit=$ROUTE_TIMEOUT; [ "$ROUTE_OK" = 1 ] || wlimit=${WEB2_FAIL_WAIT:-10}
  if body=$(wait_body web2.lab '^Hostname: web2-' "$wlimit"); then
    ok "Host web2.lab is routed to the web2 Pod"
    if printf '%s' "$body" | grep -q '^Name: app-two'; then ok "web2 answers as 'app-two' (its --name flag works)"; else
      warn "web2's answer has no 'Name: app-two' line: the --name flag may not be supported"; fi
  else
    bad "Host web2.lab did not reach a web2 Pod"
  fi
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: nope.lab' "$URL/")
  if [ "$code" = "404" ]; then ok "an unknown host gets 404"; else bad "an unknown host got HTTP $code, not 404"; fi
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$URL/")
  if [ "$code" = "404" ]; then ok "a request with no matching host (the bare address) gets 404"; else
    bad "the bare address got HTTP $code, not 404"; fi
  info "can Traefik's ServiceAccount list Secrets in every namespace? $(kubectl auth can-i list secrets -A --as="$SA" 2>/dev/null)"
}

summary() {
  say "Result"
  printf '  %d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
  if [ "$FAIL" -eq 0 ]; then
    echo "  The Ingress lab is up."
    echo
    echo "  Try it:"
    echo "    curl -H 'Host: whoami.lab' $URL/"
    echo "    curl -H 'Host: web2.lab'   $URL/"
    echo "    kubectl -n traefik logs deploy/traefik --tail=5     # one access-log line per request"
    echo "  Remove it:  bash ingress-lab.sh down"
    return 0
  fi
  echo "  Something is wrong. Read the FAIL lines above, and keep the full output."
  return 1
}

# ---------------------------------------------------------------- commands
cmd_up() {
  preflight
  say "1. Cluster"
  check_nodes
  say "2. Images on Docker Hub (nothing is downloaded)"
  check_tag library/traefik "$TRAEFIK_VERSION" TRAEFIK_VERSION
  check_tag traefik/whoami "$WHOAMI_VERSION" WHOAMI_VERSION
  say "3. NodePort"
  check_nodeport
  if [ "$FAIL" -gt 0 ]; then
    echo; echo "  Stopping before any change: nothing was applied."
    summary; return 1
  fi
  say "4. Traefik"
  apply_manifest "traefik.yaml (7 objects)" render_traefik || { summary; return 1; }
  wait_rollout traefik traefik || { summary; return 1; }
  verify_traefik
  say "5. Test apps and the Ingress"
  apply_manifest "apps.yaml (namespace, 2 Deployments, 2 Services, 1 Ingress)" render_apps || { summary; return 1; }
  wait_rollout ingress-lab whoami
  wait_rollout ingress-lab web2
  say "6. Routing"
  verify_routes
  check_log
  summary
}

cmd_status() {
  preflight
  say "1. Cluster"
  check_nodes
  say "2. Traefik"
  verify_traefik
  say "3. Routing"
  verify_routes
  check_log
  summary
}

cmd_down() {
  local obj
  preflight
  say "What exists now"
  for obj in $LAB_OBJECTS $STRAY_OBJECTS; do
    if kubectl get "$obj" >/dev/null 2>&1; then info "present: $obj"; else info "absent:  $obj"; fi
  done
  say "Removing the lab"
  render_apps | kubectl delete --ignore-not-found -f - 2>&1 | indent
  render_traefik | kubectl delete --ignore-not-found -f - 2>&1 | indent
  kubectl delete --ignore-not-found clusterrolebinding/traefik-nodes-reader clusterrole/traefik-nodes-reader 2>&1 | indent
  for obj in ingress-lab traefik; do kubectl wait --for=delete "ns/$obj" --timeout="${DELETE_TIMEOUT}s" >/dev/null 2>&1; done
  say "Check"
  for obj in $LAB_OBJECTS $STRAY_OBJECTS; do
    if kubectl get "$obj" >/dev/null 2>&1; then bad "$obj still exists (a namespace can take a minute to finish deleting)"; else ok "$obj is gone"; fi
  done
  say "Result"
  printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
  if [ "$FAIL" -eq 0 ]; then echo "  The lab is removed. The images stay cached on the nodes, which is harmless."; return 0; fi
  echo "  Run it again in a minute: deleting is safe to repeat."; return 1
}

cmd_reset() {
  cmd_down || {
    echo; echo "  Stopping: the cleanup did not finish, so a clean start is not possible yet."
    echo "  Nothing was applied. Run  bash ingress-lab.sh reset  again in a minute."; return 1; }
  PASS=0; FAIL=0; WARN=0
  echo; echo "================ clean start ================"
  cmd_up
}

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-up}" in
  up)            cmd_up ;;
  status|check)  cmd_status ;;
  down)          cmd_down ;;
  reset)         cmd_reset ;;
  render)        case "${2:-both}" in
                   traefik) render_traefik ;;
                   apps)    render_apps ;;
                   *)       render_traefik; echo '---'; render_apps ;;
                 esac ;;
  -h|--help|help) usage ;;
  *)             usage >&2; exit 2 ;;
esac
exit $?
