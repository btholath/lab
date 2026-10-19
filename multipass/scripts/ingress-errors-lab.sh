#!/usr/bin/env bash
# ingress-errors-lab.sh
#
# Makes Traefik answer with 404, 503 and 502 on purpose, and records what it really does.
# It needs the Ingress lab to be up first (bash ingress-lab.sh). Safe to run again and again.
# Everything it creates lives in the namespace errors-lab, so the Ingress lab is untouched.
#
# Run it on the MASTER (it needs kubectl and curl):
#   bash ingress-errors-lab.sh           set up, run every case, run the timing tests
#   bash ingress-errors-lab.sh flag      turn Traefik's allowEmptyServices on, re-probe, turn it off again
#   bash ingress-errors-lab.sh down      remove errors-lab
#   bash ingress-errors-lab.sh render    print the manifest
#
# From PowerShell:
#   multipass transfer ingress-errors-lab.sh master:/home/ubuntu/
#   multipass exec master -- bash /home/ubuntu/ingress-errors-lab.sh
#
# Settings (environment variables, all optional):
#   NODEPORT          the port opened on every node            default 30080
#   LAB_IP            address used for the requests            default: the control-plane node's address
#   WHOAMI_IMAGE      image of the test apps                   default traefik/whoami:v1.11
#   CASE_WAIT         seconds to let each case settle          default 20
#   CHANGE_WAIT       seconds to wait for a status to come back  default 60
#   PERSIST_WAIT      seconds to keep watching after a scale-down default 15
#   DOOR_WAIT         seconds to wait for Traefik after a restart (flag)  default 60
#   ROLLOUT_TIMEOUT   seconds to wait for the Pods to start    default 300
#
# The predictions were first written BEFORE the first real run, which got two of them wrong
# (zero and notready answered 404, not 503, because Traefik's allowEmptyServices option is off by
# default). They now follow the documentation. A case that answers differently is a finding,
# not a failure: it is reported as DIFF and the script still exits 0.
#
# 'flag' changes Traefik's own Deployment (it adds one argument, restarts Traefik, and removes the
# argument again, even if the script fails halfway). Use it only when you want to see that option.
# Exit status: 0 = ran to the end, 1 = the setup failed, 2 = no cluster, or the Ingress lab is not up.
set -u

NODEPORT=${NODEPORT:-30080}
LAB_IP=${LAB_IP:-}
WHOAMI_IMAGE=${WHOAMI_IMAGE:-traefik/whoami:v1.11}
CASE_WAIT=${CASE_WAIT:-20}
CHANGE_WAIT=${CHANGE_WAIT:-60}
PERSIST_WAIT=${PERSIST_WAIT:-15}
DOOR_WAIT=${DOOR_WAIT:-60}
FLAG='--providers.kubernetesingress.allowemptyservices=true'
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-300}
URL=""

PASS=0; FAIL=0; MATCH=0; DIFF=0; DIFFS=""
ok()    { printf '  PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
warn()  { printf '  WARN  %s\n' "$*"; }
bad()   { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
info()  { printf '  info  %s\n' "$*"; }
say()   { printf '\n== %s\n' "$*"; }
indent() { sed 's/^/        /'; }

# ---------------------------------------------------------------- the manifest
render_manifest() {
cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: errors-lab
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ok
  namespace: errors-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ok
  template:
    metadata:
      labels:
        app: ok
    spec:
      containers:
      - name: whoami
        image: ${WHOAMI_IMAGE}
        args:
        - --name=ok
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
  name: ok
  namespace: errors-lab
spec:
  selector:
    app: ok
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zero
  namespace: errors-lab
spec:
  replicas: 0
  selector:
    matchLabels:
      app: zero
  template:
    metadata:
      labels:
        app: zero
    spec:
      containers:
      - name: whoami
        image: ${WHOAMI_IMAGE}
        args:
        - --name=zero
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: zero
  namespace: errors-lab
spec:
  selector:
    app: zero
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notready
  namespace: errors-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: notready
  template:
    metadata:
      labels:
        app: notready
    spec:
      containers:
      - name: whoami
        image: ${WHOAMI_IMAGE}
        args:
        - --name=notready
        ports:
        - containerPort: 80
        readinessProbe:
          tcpSocket:
            port: 81
          periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: notready
  namespace: errors-lab
spec:
  selector:
    app: notready
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: refused
  namespace: errors-lab
spec:
  selector:
    app: ok
  ports:
  - port: 80
    targetPort: 81
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: errors
  namespace: errors-lab
spec:
  ingressClassName: traefik
  rules:
  - host: ok.lab
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ok
            port:
              number: 80
  - host: zero.lab
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: zero
            port:
              number: 80
  - host: notready.lab
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: notready
            port:
              number: 80
  - host: refused.lab
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: refused
            port:
              number: 80
  - host: paths.lab
    http:
      paths:
      - path: /only
        pathType: Prefix
        backend:
          service:
            name: ok
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: errors-nosvc
  namespace: errors-lab
spec:
  ingressClassName: traefik
  rules:
  - host: nosvc.lab
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nosuchservice
            port:
              number: 80
EOF
}

# name|host|path|predicted status|why
CASES='ok|ok.lab|/|200|a healthy Pod behind the route
unknown|unknown.lab|/|404|no Ingress names this host, so no router matches
paths-only|paths.lab|/only|200|the host and the path both match the rule
paths-other|paths.lab|/other|404|the host matches but the path does not, so no router matches
zero|zero.lab|/|404|the Service has no Pods; with allowEmptyServices off (the default) Traefik builds no route for it
notready|notready.lab|/|404|the only Pod is not Ready, so the Service has no available endpoint and Traefik builds no route
refused|refused.lab|/|502|the route matches and a Ready Pod is chosen, but nothing listens on its port
nosvc|nosvc.lab|/|404|the Ingress names a Service that does not exist (a low-confidence prediction)'

# ---------------------------------------------------------------- helpers
preflight() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found. Run this script on the master." >&2; exit 2; }
  kubectl get nodes >/dev/null 2>&1 || { echo "kubectl cannot reach the API server. Run this script on the master." >&2; exit 2; }
  if [ -z "$LAB_IP" ]; then
    LAB_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    [ -n "$LAB_IP" ] || LAB_IP=$(kubectl get nodes \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  fi
  URL="http://${LAB_IP}:${NODEPORT}"
}

need_ingress_lab() {
  local ctrl
  ctrl=$(kubectl get ingressclass traefik -o jsonpath='{.spec.controller}' 2>/dev/null)
  if [ "$ctrl" != "traefik.io/ingress-controller" ]; then
    echo "The Ingress lab is not up (no IngressClass 'traefik'). Run  bash ingress-lab.sh  first." >&2; exit 2
  fi
}

code_of() {   # host path -> the HTTP status, 000 if nothing answered
  curl -s -m 8 -o /dev/null -w '%{http_code}' -H "Host: $1" "$URL$2" </dev/null
}

wait_code() {   # wanted host path seconds -> prints the last status; returns 0 if it was the wanted one
  local want=$1 host=$2 path=$3 limit=$4 start code
  start=$(date +%s)
  while :; do
    code=$(code_of "$host" "$path")
    if [ "$code" = "$want" ]; then echo "$code"; return 0; fi
    if [ $(( $(date +%s) - start )) -ge "$limit" ]; then echo "$code"; return 1; fi
    sleep 2
  done
}

# Sends one request, waits up to CASE_WAIT for the predicted status (Traefik may still be loading
# the Ingress), then shows what answered and what Traefik's access log says about the request.
probe_case() {   # name host path predicted why
  local name=$1 host=$2 path=$3 want=$4 why=$5 start code raw body line router backend waited first
  start=$(date +%s)
  while :; do
    raw=$(curl -s -m 8 -w '\n%{http_code}' -H "Host: $host" "$URL${path}?probe=$name" </dev/null)
    code=${raw##*$'\n'}; body=${raw%$'\n'*}
    if [ "$code" = "$want" ]; then break; fi
    if [ $(( $(date +%s) - start )) -ge "$CASE_WAIT" ]; then break; fi
    sleep 2
  done
  waited=$(( $(date +%s) - start ))
  first=$(printf '%s' "$body" | head -1 | cut -c1-60)
  line=$(kubectl -n traefik logs deploy/traefik --since=180s 2>/dev/null </dev/null | grep "probe=$name" | tail -1)
  router=$(printf '%s' "$line" | awk -F'"' '{print $8}')
  backend=$(printf '%s' "$line" | awk -F'"' '{print $10}')
  if [ "$code" = "$want" ]; then
    MATCH=$((MATCH + 1)); printf '  PASS  %-11s %-16s HTTP %s as predicted' "$name" "$host$path" "$code"
  else
    DIFF=$((DIFF + 1)); DIFFS="$DIFFS $name"; printf '  DIFF  %-11s %-16s HTTP %s, predicted %s' "$name" "$host$path" "$code" "$want"
  fi
  [ "$waited" -ge 2 ] && printf '  (settled after %ss)' "$waited"
  printf '\n'
  printf '        why: %s\n' "$why"
  printf '        body: %s\n' "${first:-(empty)}"
  if [ -n "$line" ]; then printf '        Traefik log: router=%s  backend=%s\n' "${router:-?}" "${backend:-?}"
  else printf '        Traefik log: (no access-log line found for this request)\n'; fi
}

# Scales a Deployment, then polls a host every half second and records every status it sees.
# With a final status: returns as soon as it is seen (PASS), or fails after CHANGE_WAIT seconds.
# With no final status: only watches for PERSIST_WAIT seconds and reports where the status settled.
watch_status() {   # label deployment replicas host final-status-or-empty
  local label=$1 dep=$2 reps=$3 host=$4 final=$5 start now t code last="" seen="" lastchange="0.0" limit
  limit=$CHANGE_WAIT; [ -z "$final" ] && limit=$PERSIST_WAIT
  start=$(date +%s.%N)
  kubectl -n errors-lab scale "deploy/$dep" --replicas="$reps" >/dev/null 2>&1 </dev/null
  info "$label: scaled $dep to $reps replicas, watching $host"
  while :; do
    code=$(code_of "$host" "/?probe=timing")
    now=$(date +%s.%N)
    t=$(awk -v a="$start" -v b="$now" 'BEGIN { printf "%.1f", b - a }')
    if [ "$code" != "$last" ]; then info "t=${t}s  HTTP $code"; last=$code; seen="$seen $code"; lastchange=$t; fi
    if [ -n "$final" ] && [ "$code" = "$final" ]; then
      ok "$label: HTTP $final after ${t}s (statuses seen in order:$seen)"; return 0; fi
    if awk -v t="$t" -v l="$limit" 'BEGIN { exit !(t >= l) }'; then
      if [ -n "$final" ]; then bad "$label: still not HTTP $final after ${limit}s (statuses seen in order:$seen)"; return 1; fi
      ok "$label: settled at HTTP $last (last change at t=${lastchange}s, watched ${limit}s, statuses seen in order:$seen)"; return 0
    fi
    sleep 0.5
  done
}

summary() {
  say "Result"
  printf '  %d of %d cases answered as predicted, %d differed\n' "$MATCH" $((MATCH + DIFF)) "$DIFF"
  [ -n "$DIFFS" ] && printf '  differed:%s   (these are findings: read the DIFF lines above)\n' "$DIFFS"
  printf '  %d checks passed, %d failed\n' "$PASS" "$FAIL"
  echo
  echo "  Remove it:  bash ingress-errors-lab.sh down"
  [ "$FAIL" -eq 0 ]
}

# ---------------------------------------------------------------- commands
cmd_run() {
  local out code line
  preflight; need_ingress_lab
  say "1. Preflight"
  if kubectl -n traefik rollout status deploy/traefik --timeout=5s >/dev/null 2>&1; then ok "Traefik is rolled out"; else bad "Traefik is not rolled out"; fi
  code=$(code_of nope.lab /)
  if [ "$code" = "404" ]; then ok "the door answers: an unknown host gets 404 ($URL)"; else bad "no 404 from $URL (got $code): is the Ingress lab healthy?"; fi
  if [ "$FAIL" -gt 0 ]; then echo; echo "  Stopping before any change."; summary; return 1; fi

  say "2. Setting up errors-lab"
  out=$(render_manifest | kubectl apply -f - 2>&1); local rc=$?
  printf '%s\n' "$out" | indent
  if [ $rc -ne 0 ]; then bad "kubectl apply failed"; summary; return 1; fi
  ok "errors-lab applied"
  # Put both replica counts back explicitly, so a repeat run (or an interrupted timing test) starts from a known
  # state. This does not rely on what kubectl apply would do with a manual scale, which was never tested here.
  kubectl -n errors-lab scale deploy/ok --replicas=1 >/dev/null 2>&1 </dev/null
  kubectl -n errors-lab scale deploy/zero --replicas=0 >/dev/null 2>&1 </dev/null
  if kubectl -n errors-lab rollout status deploy/ok --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null 2>&1; then ok "ok is Ready"; else
    bad "ok did not become Ready in ${ROLLOUT_TIMEOUT}s"; summary; return 1; fi
  local waited=0
  while [ "$waited" -lt "$ROLLOUT_TIMEOUT" ]; do
    line=$(kubectl -n errors-lab get pods -l app=notready \
      -o jsonpath='{range .items[*]}{.status.phase}{" ready="}{.status.containerStatuses[0].ready}{end}' 2>/dev/null)
    case "$line" in Running*) break ;; esac
    sleep 3; waited=$((waited + 3))
  done
  info "notready: its Pod is ${line:-not created yet} (it is meant to stay not Ready)"
  info "zero: $(kubectl -n errors-lab get pods -l app=zero --no-headers 2>/dev/null | wc -l) Pods (replicas 0, on purpose)"
  code=$(wait_code 200 ok.lab / 90)
  if [ "$code" = "200" ]; then ok "ok.lab is routed (HTTP 200): Traefik has loaded the Ingress"; else
    bad "ok.lab answered HTTP $code after 90s: Traefik did not load the Ingress. Try: bash ingress-lab.sh status"; summary; return 1; fi

  say "3. The status codes (one request per case; each case may wait up to ${CASE_WAIT}s to settle)"
  while IFS='|' read -r name host path want why; do
    probe_case "$name" "$host" "$path" "$want" "$why" </dev/null
  done <<< "$CASES"

  say "4. Change over time (every status is recorded, with the seconds since the scale command)"
  echo "  4a. A route that exists loses all its Pods: does the 503 last?"
  watch_status "ok to 0" ok 0 ok.lab ""
  watch_status "ok to 1" ok 1 ok.lab 200
  echo "  4b. A Service that never had a Pod gets its first one: does a route appear?"
  watch_status "zero to 1" zero 1 zero.lab 200
  watch_status "zero to 0" zero 0 zero.lab ""
  summary
}

flag_index() {   # the position of our flag in Traefik's arguments, counting from 1 (empty if absent)
  kubectl -n traefik get deploy traefik -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' 2>/dev/null </dev/null \
    | grep -n -x -- "$FLAG" | cut -d: -f1
}

flag_off() {   # removes the flag again, if it is there, and waits for Traefik to restart
  local idx
  idx=$(flag_index)
  [ -z "$idx" ] && return 0
  kubectl -n traefik patch deploy traefik --type=json \
    -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/args/$((idx - 1))\"}]" >/dev/null 2>&1 </dev/null
  kubectl -n traefik rollout status deploy/traefik --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null 2>&1
}

cmd_flag() {
  local we_added=0 code
  preflight; need_ingress_lab
  if ! kubectl get ns errors-lab >/dev/null 2>&1; then
    echo "errors-lab does not exist. Run  bash ingress-errors-lab.sh  first." >&2; exit 2; fi
  say "1. Before: Traefik as the Ingress lab configures it (allowEmptyServices off)"
  if [ -n "$(flag_index)" ]; then
    warn "the flag is ALREADY on in Traefik's Deployment, so this run cannot show the 'before' state, and it will leave the flag as it found it"
  fi
  probe_case zero zero.lab / 404 "no route is built for a Service with no Pods" </dev/null
  probe_case notready notready.lab / 404 "no route is built when the only Pod is not Ready" </dev/null
  probe_case nosvc nosvc.lab / 404 "the Service does not exist" </dev/null
  say "2. Turning allowEmptyServices on (this restarts Traefik: expect a brief interruption)"
  if [ -z "$(flag_index)" ]; then
    trap 'flag_off' EXIT
    we_added=1
    if kubectl -n traefik patch deploy traefik --type=json \
         -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"$FLAG\"}]" >/dev/null 2>&1 </dev/null; then
      ok "added $FLAG to Traefik's arguments"
    else bad "could not patch Traefik's Deployment"; summary; return 1; fi
  else
    info "leaving the flag as it is"
  fi
  if kubectl -n traefik rollout status deploy/traefik --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null 2>&1; then ok "Traefik restarted"; else
    bad "Traefik did not finish restarting in ${ROLLOUT_TIMEOUT}s"; summary; return 1; fi
  code=$(wait_code 404 nope.lab / "$DOOR_WAIT")
  if [ "$code" = "404" ]; then ok "the door answers again"; else bad "no 404 from the door after the restart (got $code)"; summary; return 1; fi
  say "3. After: allowEmptyServices on"
  probe_case ok ok.lab / 200 "the control: a healthy Pod" </dev/null
  probe_case zero zero.lab / 503 "a route now exists for the empty Service, and it has no servers: 503" </dev/null
  probe_case notready notready.lab / 503 "a route now exists, and its only Pod is not Ready: 503" </dev/null
  probe_case nosvc nosvc.lab / 404 "the Service does not exist at all, so there is nothing to make an empty route for (a prediction)" </dev/null
  if [ "$we_added" = 1 ]; then
    say "4. Turning it off again"
    flag_off; trap - EXIT
    if [ -z "$(flag_index)" ]; then ok "the flag is gone from Traefik's Deployment"; else bad "the flag is STILL in Traefik's Deployment: remove it by hand or run  bash ingress-lab.sh reset"; fi
    code=$(wait_code 404 nope.lab / "$DOOR_WAIT")
    if [ "$code" = "404" ]; then ok "the door answers again"; else bad "no 404 from the door after restoring (got $code)"; fi
    probe_case zero zero.lab / 404 "back to the default: no route for the empty Service" </dev/null
  fi
  summary
}

cmd_down() {
  preflight
  say "Removing errors-lab"
  kubectl delete namespace errors-lab --ignore-not-found 2>&1 | indent
  kubectl wait --for=delete ns/errors-lab --timeout=120s >/dev/null 2>&1
  if kubectl get ns errors-lab >/dev/null 2>&1; then bad "errors-lab still exists (a namespace can take a minute to finish deleting)"
  else ok "errors-lab is gone"; fi
  say "Result"
  printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

case "${1:-run}" in
  run|up)         cmd_run ;;
  down)           cmd_down ;;
  flag)           cmd_flag ;;
  render)         render_manifest ;;
  -h|--help|help) usage ;;
  *)              usage >&2; exit 2 ;;
esac
exit $?
