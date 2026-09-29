# Kubernetes CLI Command Reference — Cluster to Services

**What this file is.** Every command that actually builds and operates the
WSL2 kubeadm cluster used across this lab series, collected in **one file**,
in the **order you'd run them** on a brand-new machine. Each command answers:

| Column | Meaning |
|---|---|
| **What** | What the command does |
| **Why** | Why you'd run it |
| **How** | How to read the result |
| **When** | When you'd reach for it in real life |

**What this file is not.** It is not a replacement for the labs. Each
section below is deliberately short and links to the lab that explains the
*why it works that way* in depth. Use this file as the thing you run;
use the labs when something surprises you.

**Ingress is not in this file.** It's still a dashed placeholder on the
networking mind map — nothing in this whole series has actually built an
Ingress yet, so there are no real commands to give you for it. Everything
else the title mentions (cluster, pods, services) is here.

**Scope check before you run anything:**
```bash
kubectl config view --minify | grep namespace:
```
Several commands below assume you're in a specific namespace. If this
prints something unexpected, that's Lab 7's namespace lesson catching you
again — fix it with `kubectl config set-context --current --namespace=default`
before continuing.

---

## Part 1 — Build the Cluster

### 1.1 Pre-flight checks (do these once, before installing anything)

**What:**
```bash
ps --pid 1 -o comm=                                    # systemd?
uname -r                                                # kernel version
sudo modprobe overlay && sudo modprobe br_netfilter     # required kernel modules
stat -fc %T /sys/fs/cgroup/                             # cgroup v2?
sudo sysctl net.bridge.bridge-nf-call-iptables          # bridge netfilter sysctl
free -h; nproc                                          # resources
hostname -I                                              # find the real WSL2 IP
swapon --show                                            # swap must be off
```

**Why:** kubeadm and containerd need a specific set of kernel and OS
conditions, and WSL2 doesn't guarantee all of them by default. Checking
first avoids a confusing failure halfway through installation.

**How:** you want `systemd`, a recent `6.x` kernel, both modules loading
without error, `cgroup2fs`, a real value (not an error) from the sysctl,
several GB of free RAM, 2+ CPUs, and `swapon --show` printing **nothing**.

**When:** once per machine, and again any time something in the stack
starts behaving strangely after a long idle period or a Windows update.

Full detail, including what to do when each check fails: **Setup Guide,
§1**.

### 1.2 Install the stack

**What:**
```bash
git clone <your repo>   # or however you got install_k8s_stack.sh onto this machine
chmod +x install_k8s_stack.sh bootstrap_cluster.sh
sudo ./install_k8s_stack.sh
```

**Why:** this one script installs and configures Docker, containerd
(systemd cgroup driver, CRI enabled), kubelet, kubeadm, kubectl (pinned
version), and Kind — the entire pre-cluster toolchain, in the right order.

**How:** it prints 8 numbered steps. `[OK]` or `[SKIP]` means that piece was
already correct. `[DOING]`/`[FIXED]` means it changed something. `[FAIL]`
stops the script and tells you what to fix in §1.1 before retrying.

**When:** on a fresh machine, and it's **safe to re-run any time** — every
check is idempotent, so running it again on an already-configured machine
just prints a fast column of `[SKIP]`.

Full walkthrough of a real run, including two real bugs (overlay detection,
apt lock contention) and their fixes: **Setup Guide, §2**.

### 1.3 Apply group membership and sanity-check containerd

**What:**
```bash
newgrp docker
docker ps
sudo grep -A1 disabled_plugins /etc/containerd/config.toml
sudo grep SystemdCgroup /etc/containerd/config.toml
sudo systemctl is-active kubelet containerd docker
```

**Why:** the install script adds you to the `docker` group, but that only
takes effect in a *new* shell session. The containerd checks confirm the
CRI plugin is enabled and the cgroup driver matches what kubelet expects —
the exact two things that silently break a kubeadm cluster if wrong.

**How:** `docker ps` should run without `sudo`. `disabled_plugins` should be
`[]` (empty). `SystemdCgroup` should be `true` somewhere in the file. All
three services should say `active`.

**When:** right after installing, once, before bootstrapping.

### 1.4 Bootstrap the cluster

**What:**
```bash
sudo ./bootstrap_cluster.sh
```

**Why:** this is the script that actually runs `kubeadm init`, installs
Calico as the CNI, sets up your `~/.kube/config`, and — as of the most
recent version — automatically detects and fixes two known failure modes
(pods stuck on the wrong CNI network, and a stale Calico token) before you
ever see them.

**How:** 8 steps print. Watch for the **advertise IP** it detects early on —
it should match your real WSL2 IP from `hostname -I` in §1.1, not a Docker
bridge address (`172.x.x.x`). At the end it prints the full node and pod
list; the node should say `Ready`.

**When:** once, to create the cluster. It's also **safe to re-run** — if the
cluster already exists and is healthy, it skips `kubeadm init` entirely and
just re-verifies everything (including the two self-heal checks).

Full walkthrough, including the real CNI-startup race and the stale-token
incident this script now catches automatically: **Setup Guide, §3–4**,
**Lab 4**.

### 1.5 Verify the cluster is really up

**What:**
```bash
kubectl get nodes
kubectl get pods -A
kubectl get pods -n calico-system -o wide
```

**Why:** "the script finished with no errors" and "the cluster actually
works" are different claims. This checks the second one.

**How:** the node should show `Ready`. Every pod across every namespace
should be `Running` with all containers `Ready` (e.g. `1/1`, `2/2`). Pod
IPs in `calico-system` should be in your pod CIDR (`192.168.x.x`), not
`10.88.x.x` — that specific mismatch is the CNI race from Lab 4/setup §4.

**When:** immediately after bootstrap, and any time something feels wrong
before you go pod-hunting for a cause.

---

## Part 2 — Working with Pods

### 2.1 Create a pod imperatively

**What:**
```bash
kubectl run nginx-yaml --image=nginx
kubectl get pods
```

**Why:** the fastest way to get a single container running, for a quick
test.

**How:** `pod/nginx-yaml created` means the API accepted the object — it
says nothing about whether the container actually started. Check with
`kubectl get pods`; `1/1 Running` is success.

**When:** throwaway tests, quick debugging pods, never for anything you
intend to keep or reuse.

### 2.2 Generate YAML without creating anything (dry-run)

**What:**
```bash
kubectl run nginx-yaml --image=nginx --dry-run=client -o yaml
kubectl run nginx-yaml --image=nginx --dry-run=client -o yaml > nginx.yaml
```

**Why:** rather than hand-writing a Pod manifest, let Kubernetes generate
one from the same command you'd run imperatively. `--dry-run=client` means
"show me what would be created, but don't send it to the API server" —
**nothing is created**.

**How:** the output is a full Pod manifest, with `status: {}` and
`creationTimestamp: null`, both signs it never touched the real API.

**When:** every time you're about to hand-write a manifest from scratch —
generate a starting point first, then edit it.

### 2.3 Create declaratively from a file, then re-apply after edits

**What:**
```bash
kubectl apply -f nginx.yaml
kubectl get pods
# edit the file (add a label, etc.)
vim nginx.yaml
kubectl apply -f nginx.yaml
kubectl get pod nginx-yaml --show-labels
```

**Why:** a file is reviewable, versionable, and reusable — the imperative
command is not.

**How:** the first `apply` prints `created`. The second, after an edit,
prints **`configured`** (not `created`, not `unchanged`) — meaning the
object already existed and Kubernetes patched the live object to match
your file. `unchanged` would mean your file already matched the live
object exactly.

**When:** for anything beyond a one-off test — this is the normal way to
manage real resources.

Full walkthrough of `created`/`unchanged`/`configured` and what's mutable
on a running Pod vs. what forces a recreate: **Lab 2**.

### 2.4 Inspect a pod in detail

**What:**
```bash
kubectl describe pod nginx-yaml
kubectl logs nginx-yaml
kubectl get pod nginx-yaml -o wide
```

**Why:** `get pods` tells you *that* something's wrong; `describe` and
`logs` tell you *what*.

**How:** in `describe`, the **Events** section at the bottom is almost
always where the real answer lives — scheduling failures, image pull
errors, CNI errors, all show up there with a timestamp and a message.

**When:** the very first thing to run whenever a pod isn't `Running` as
expected.

### 2.5 Exec into a running container

**What:**
```bash
kubectl exec -it nginx-yaml -- /bin/bash
kubectl exec -it nginx-yaml -- whoami
kubectl exec -it nginx-yaml -- id
```

**Why:** to look inside a running container — check config files, test
network reachability, confirm what user it's running as.

**How:** `-i` keeps stdin open, `-t` allocates a terminal, `--` marks
everything after it as *the command to run inside the container*, not a
`kubectl` flag. Forgetting `--` and a command gives
`you must specify at least one command for the container`.

**When:** live debugging. Never for permanent changes — anything installed
this way (`apt install`, edited files) disappears the moment the container
restarts, because it only exists in that container's writable layer.

### 2.6 Export a live pod as clean YAML

**What:**
```bash
kubectl get pod nginx-yaml -o yaml > nginx-raw.yaml    # noisy: full live object
kubectl get pod nginx-yaml -o yaml | kubectl neat > nginx-clean.yaml   # trimmed
```

**Why:** a *running* pod's object has a lot of server-added fields
(`status`, `resourceVersion`, `uid`, timestamps) you don't want in a
manifest meant for reuse. `kubectl-neat` (a `kubectl` plugin, installed via
`krew`) strips the obvious ones automatically.

**How:** compare the neat output against a `--dry-run=client` version of the
same object — the difference is exactly what Kubernetes auto-injects at
creation time (service account volumes, tolerations, scheduling defaults),
which `kubectl-neat` doesn't know to remove and you have to judge by hand.

**When:** whenever you want to turn something you created ad hoc into a
real, reusable manifest.

Installing `krew`/`kubectl-neat`, and the full field-by-field cleanup
exercise: **Lab 3**.

### 2.7 Delete a pod

**What:**
```bash
kubectl delete pod nginx-yaml
```

**Why:** clean up test resources.

**How:** `pod "nginx-yaml" deleted`. If it hangs on `Terminating` for a long
time, that's usually the stale-CNI-token issue from Lab 4 (the network
teardown, not the container itself, is stuck).

**When:** whenever you're done with something you created imperatively or
for testing.

---

## Part 3 — Namespaces

### 3.1 Create and switch into a namespace

**What:**
```bash
kubectl create namespace mealie
kubectl config set-context --current --namespace=mealie
kubectl config view --minify | grep namespace:
```

**Why:** namespaces are separate, non-overlapping "drawers" for organizing
resources on one cluster. Switching your default namespace saves typing
`-n mealie` on every command — **but it's a permanent change to your
kubeconfig**, not a one-off flag.

**How:** after switching, any command with no `-n` acts on `mealie`. This
is exactly what caused the `frontend` deployment to land in the wrong
namespace in Lab 7 — the saved default silently decided where it went.

**When:** any time you're about to do sustained work in one namespace.
**Always switch back when you're done:**
```bash
kubectl config set-context --current --namespace=default
```

### 3.2 Check where something actually lives

**What:**
```bash
kubectl get pods -A
kubectl get deployments -A | grep <name>
```

**Why:** the single most useful habit for avoiding the namespace mix-up
above — `-A` (all-namespaces) shows you the truth regardless of your saved
default.

**When:** any time something "disappeared" after a namespace switch.

Full namespace mix-up story, real output included: **Lab 7, Step 3**.

---

## Part 4 — Deployments

### 4.1 Create a Deployment imperatively

**What:**
```bash
kubectl create deployment test --image=httpd --replicas=3
kubectl get pods
kubectl get deployments
kubectl get replicasets
```

**Why:** a bare Pod has nothing watching it — if it dies, it stays dead. A
Deployment adds a controller that continuously keeps the declared number of
copies running.

**How:** one command creates **three layers**: the Deployment, a
ReplicaSet (name = Deployment name + a hash of the pod template), and N
Pods (ReplicaSet name + a random suffix each). `READY 3/3` on the
Deployment means all three are up and passing readiness.

**When:** this is the default way to run anything in Kubernetes — you
should reach for a Deployment, not a bare Pod, for basically everything
that isn't a one-off test.

### 4.2 Watch self-healing happen

**What:**
```bash
kubectl get pods --watch
# in another terminal:
kubectl delete pod <one-of-the-three-pod-names>
```

**Why:** to see, concretely, the difference a Deployment makes versus a
bare Pod.

**How:** the deleted pod disappears, and within seconds a **new** pod (new
random suffix, same ReplicaSet hash) appears and reaches `Running` — the
ReplicaSet controller noticed the count dropped below 3 and fixed it
without you doing anything.

**When:** the first time you set up a Deployment, just to confirm the
behavior for yourself.

### 4.3 Scale

**What:**
```bash
kubectl scale deployment test --replicas=10
kubectl scale deployment test --replicas=2
```

**Why:** change how many copies are running, on demand.

**How:** Kubernetes creates or removes pods to match; you never choose
*which* pods survive a scale-down — individual pods are disposable, the
count is what matters.

**When:** traffic changes, load testing, or just practicing.

### 4.4 Generate, edit, and apply Deployment YAML

**What:**
```bash
kubectl create deployment test --image=httpd --replicas=10 --dry-run=client -o yaml > deploy.yaml
vim deploy.yaml
kubectl apply -f deploy.yaml
```

**Why:** same reasoning as pods — a file is the reusable, reviewable
source of truth.

**How:** the critical rule in the file: `spec.selector.matchLabels` must
match `spec.template.metadata.labels`, or the Deployment can't find its
own pods. The generator keeps these consistent for you; if you hand-edit
labels later, keep both in sync.

**When:** for anything beyond a quick imperative test.

### 4.5 Trigger and watch a rolling update

**What:**
```bash
# edit deploy.yaml: change the image line
kubectl apply -f deploy.yaml
kubectl get pods
kubectl get replicasets
kubectl rollout status deployment/test
```

**Why:** to change what's running (a new image version) without downtime.

**How:** the pod name's middle hash changes (new ReplicaSet), because
changing the image changed the pod template's fingerprint. The **old**
ReplicaSet is kept at `0` replicas, not deleted — that's what makes
rollback instant. `rollout status` streams progress:
`X out of N new replicas have been updated...` until it says
`successfully rolled out`.

**How the pace is controlled:** `maxSurge`/`maxUnavailable` (default 25%
each, or set explicit numbers in `spec.strategy.rollingUpdate`) decide how
many extra pods can exist and how many can be missing during the
transition. With `replicas: 1` and defaults, `maxUnavailable` rounds down
to `0` — meaning the **new** pod must be Ready before the **old** one is
removed. That's the zero-downtime guarantee, made concrete.

**When:** any time you change a Deployment's image or other pod-template
field. **Only template changes trigger this** — changing `replicas` or
`strategy` alone updates the object but restarts nothing.

### 4.6 Set an image directly (without editing the file first)

**What:**
```bash
kubectl set image deployment/test httpd=httpd:2.4-alpine
```

**Why:** a quick way to trigger an update without opening an editor.

**How:** the part before `=` is the **container name** from the pod spec
(`name: httpd`), not the image — get it wrong and Kubernetes says the
container wasn't found.

**When:** quick manual updates; for anything you want to keep as
infrastructure-as-code, prefer editing the YAML.

### 4.7 Roll back a bad update

**What:**
```bash
kubectl annotate deployment/test kubernetes.io/change-cause="switch to httpd 2.4-alpine"
kubectl rollout history deployment/test
kubectl rollout undo deployment/test
```

**Why:** if a new version is broken, get back to the last working one
immediately — no rebuild needed, since the old ReplicaSet is still sitting
at 0 replicas.

**How:** `annotate` before a change makes `rollout history` show *why* each
revision happened (`CHANGE-CAUSE`), which is otherwise blank. `undo` scales
the previous ReplicaSet back up using the same safe, gradual rules.

**When:** any time an update goes wrong — broken image, crash loop,
unexpected behavior. This is the single most valuable safety net
Deployments give you over bare Pods.

Full walkthrough — the surge/unavailable math worked out with real
numbers, the missing-space YAML bug, and a live Mealie v1→v3 upgrade with
timestamps: **Lab 5**.

---

## Part 5 — Services

### 5.1 Expose a Deployment (the quick way — and its trap)

**What:**
```bash
kubectl expose deployment frontend --port 8080
kubectl get svc -o wide
```

**Why:** pods are ephemeral and their IPs change every time they're
replaced. A Service gives a set of pods **one stable address and DNS name**
that never changes, no matter how many times the pods behind it come and
go.

**How — and the trap:** `kubectl expose --port X` with no `--target-port`
sets **both** to X. If your container listens on a different port (e.g.
`httpd` on 80, but you exposed `--port 8080`), the Service looks perfectly
healthy — endpoints populate, no error anywhere — but every connection gets
refused, because nothing is listening on the port it forwards to.

**When:** the fast path for exposing something inside the cluster. Always
double-check `targetPort` matches what the container actually listens on:
```bash
kubectl get svc <name> -o jsonpath='{.spec.ports[0]}{"\n"}'
```

### 5.2 Fix a wrong targetPort without recreating the Service

**What:**
```bash
kubectl patch svc frontend --type json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'
```

**Why:** a surgical, one-field fix that keeps the existing ClusterIP intact
(deleting and re-exposing would hand out a new one).

**When:** exactly the trap above, or any single-field correction to a live
object.

### 5.3 Check what a Service actually resolved to

**What:**
```bash
kubectl describe svc frontend
kubectl get endpointslices -l kubernetes.io/service-name=frontend
```

**Why:** a Service is really three things working together: a stable
address, a label **selector**, and a live list of matching pod IPs (an
EndpointSlice). This checks the third piece.

**How:** `Endpoints:` (in `describe`) or the `ENDPOINTS` column (in
`get endpointslices`) should list one IP:port per matching, Ready pod. If
it says `<none>`, either the selector doesn't match the pod labels, or the
pods are in a different namespace than the Service (Services only select
pods in their own namespace).

**When:** first thing to check whenever a Service "isn't working."

*(Note: `kubectl get endpoints` — the older API — is deprecated as of
Kubernetes 1.33+ and prints a warning; use `endpointslices`.)*

### 5.4 Test a Service from inside the cluster

**What:**
```bash
kubectl run curl -n default --image=curlimages/curl --restart=Never -- sleep 600
kubectl wait -n default --for=condition=Ready pod/curl --timeout=60s
kubectl exec -n default curl -- curl -s -m 5 -o /dev/null -w "%{http_code}\n" \
  http://<service>.<namespace>.svc.cluster.local:<port>
kubectl delete pod curl -n default
```

**Why:** a throwaway pod with `curl` inside is the standard way to test
in-cluster reachability without needing an external route.

**How:** `200` means it worked end-to-end. Curl exit code **7**
("connection refused") means the packet reached the pod but nothing was
listening — check `targetPort`. Exit code **28** (timeout) usually means a
NetworkPolicy is dropping the traffic (Part 6) or nothing is answering on
the network path at all — these two failures look different and mean
different things.

**When:** the standard diagnostic step for "is my Service actually working"
before ever touching a browser or an external tool.

### 5.5 NodePort — open a port on every node

**What:**
```bash
kubectl expose deployment frontend --name frontend-np --port 8080 --target-port 80 --type NodePort
kubectl get svc frontend-np
```

**Why:** to reach something from outside the cluster network without a
cloud load balancer.

**How:** `PORT(S)` reads `port:nodePort` — the second number (from the
30000–32767 range) is open on **every** node, and kube-proxy forwards to a
matching pod wherever it actually runs. A NodePort Service **also** gets a
ClusterIP — the types stack.

**When:** bare-metal or local clusters with no cloud load balancer
available (exactly this WSL2 setup).

### 5.6 LoadBalancer — and why it shows `<pending>` here

**What:**
```bash
kubectl expose deployment mealie --port 9000 --target-port 9000 --type LoadBalancer -n mealie
kubectl get svc -n mealie
kubectl describe svc mealie -n mealie | grep -A3 Events
kubectl get svc mealie -n mealie -o jsonpath='{.status.loadBalancer}{"\n"}'
```

**Why:** `LoadBalancer` asks the *environment* to provision a real external
load balancer. On a cloud (AKS/EKS/GKE), a cloud controller manager does
this automatically. **This kubeadm cluster has none**, so nothing ever
fulfills the request.

**How:** `EXTERNAL-IP <pending>` forever; `Events: <none>`; `status`
returns `{}`. None of that means the Service is broken — it still works
fully through its ClusterIP and its (automatically assigned) NodePort. Test
both, same pattern as §5.4/§5.5.

**When:** you'll hit `<pending>` on any self-managed cluster with no load
balancer provider. The fix (if you want a real external IP) is something
like MetalLB, not a change to the Service itself.

### 5.7 Trace a Service's traffic through the actual firewall rules

**What:**
```bash
sudo iptables -t nat -L KUBE-SERVICES -n | grep <service-name>
sudo iptables -t nat -L KUBE-SVC-<id-from-above> -n
sudo iptables -t nat -L KUBE-SEP-<id-from-above> -n
sudo iptables -t nat -L KUBE-NODEPORTS -n | grep <nodePort>
```

**Why:** a ClusterIP is **virtual** — no interface owns it, no process
listens on it. `kube-proxy` (running on every node) is what makes it work,
by writing NAT rules that rewrite the destination address to a real pod IP.

**How:** `KUBE-SERVICES` holds one rule per Service address; it jumps to a
`KUBE-SVC-...` chain that picks a backend pod (roughly at random per
connection), which jumps to a `KUBE-SEP-...` chain holding the actual
**DNAT** to `<pod-ip>:<port>`. `KUBE-NODEPORTS` is the parallel entry point
for node-port traffic, which adds an extra masquerade step before joining
the same `KUBE-SVC` chain.

**When:** debugging a Service issue that survives the checks in §5.3/§5.4,
or just to understand what's actually happening under the hood — the
mechanism, not just the abstraction.

Both Services deep-dives, with real output for every command above, the
full port-mixup story, and the packet-by-packet trace with counters:
**Lab 7**, **Lab 8**.

### 5.8 Clean up test Services

**What:**
```bash
kubectl delete svc frontend frontend-np -n default
kubectl delete svc mealie -n mealie
```

**Why/When:** remove test Services once you're done with an exercise — they
don't disappear on their own the way a `sleep`-based test pod's purpose
naturally ends.

---

## Part 6 — Network Policy (Calico enforcement)

*(Brief — see Lab 6 for the full depth-first walkthrough.)*

### 6.1 See what's already enforced

**What:**
```bash
kubectl get networkpolicy -A
kubectl describe networkpolicy <name> -n <namespace>
sudo iptables -L -n | grep cali
```

**Why:** a NetworkPolicy is just an API object — something has to translate
it into real enforcement. On this cluster, that's **Felix**, the agent
inside `calico-node`, which writes the iptables rules directly.

**How:** a pod **no policy selects** gets an `ACCEPT`-everything namespace
profile — that's why this cluster is allow-all by default. A pod **any
policy selects** gets a `Start of tier default` / `End of tier default`
section that ends in `DROP` unless something explicitly allowed the
traffic.

**When:** before writing any policy, check what's already there so you
know your starting point.

### 6.2 Apply a default-deny, then a specific allow

**What:**
```bash
kubectl apply -n <namespace> -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
  - Ingress
EOF
```

**Why:** the standard hardening pattern — start by blocking everything,
then allow specific, intentional traffic back in.

**How:** `podSelector: {}` matches every pod in the namespace. With no
`ingress:` rules listed, nothing gets in. Test with `curl` from another
pod — the result is a **timeout** (curl exit 28), not a refusal, because
Calico drops rather than rejects.

**When:** securing any namespace with real, sensitive workloads —
databases, internal APIs, anything that shouldn't be reachable from
"every other pod in the cluster" by default.

Full policy lab, including how label selectors become live-updating
ipsets: **Lab 6**.

---

## Part 7 — Full Cleanup and Rebuild From Scratch

Two levels here: **application cleanup** (fast, keeps the cluster) and
**full cluster reset** (nukes everything, rebuilds from the ground up).
Use the level that matches what you actually need.

### 7.1 Application-level cleanup (keep the cluster)

**What:**
```bash
kubectl delete deployment test frontend -n default --ignore-not-found
kubectl delete deployment mealie -n mealie --ignore-not-found
kubectl delete svc frontend frontend-np -n default --ignore-not-found
kubectl delete svc mealie -n mealie --ignore-not-found
kubectl delete networkpolicy --all -n mealie --ignore-not-found
kubectl delete namespace mealie netlab --ignore-not-found
kubectl delete pod --all -n default --ignore-not-found
kubectl config set-context --current --namespace=default
kubectl get all -A
```

**Why:** removes everything built across these labs without touching the
underlying kubeadm cluster, Calico, or node setup — useful when you just
want a clean slate to redo the exercises.

**How:** the final `get all -A` should show only the core system
namespaces (`kube-system`, `calico-system`, `tigera-operator`) and the
built-in `kubernetes` Service in `default`.

**When:** between practice runs of the labs, or before redoing an exercise
cleanly.

### 7.2 Full cluster teardown (start completely over)

**What:**
```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo rm -rf /var/lib/cni
sudo rm -rf /var/lib/etcd
sudo rm -rf $HOME/.kube
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

**Why:** `kubeadm reset` unwinds the control plane (stops static pods,
removes certs and manifests) but **deliberately leaves CNI state,
containerd's CNI directories, and your kubeconfig behind** — these extra
`rm -rf` commands clear those too, so the next `kubeadm init` starts on
genuinely clean ground instead of inheriting stale Calico config or an old
admin.conf.

**How:** after this, `kubectl get nodes` should fail outright (no
kubeconfig, no cluster) — that's the expected, correct result.

**When:** the cluster is in a state you don't trust (a botched manual
`kubeadm init` outside the scripts, a Kubernetes version you want to
change, or you just want to verify the whole bootstrap process works from
absolute zero again).

⚠️ **This destroys every workload, namespace, and Service you've created.**
It does **not** touch the installed packages (Docker, kubelet, kubeadm,
kubectl, Kind) from Part 1.1/1.2 — only the cluster's own state.

### 7.3 Rebuild from scratch

**What:**
```bash
cd ~/repos/lab/kubernetes-fundamentals/setup   # wherever your scripts live
sudo ./install_k8s_stack.sh
sudo ./bootstrap_cluster.sh
kubectl get nodes
kubectl get pods -A
```

**Why:** both scripts are idempotent, so re-running them after a full
teardown does exactly what it did the very first time — `install_k8s_stack.sh`
will mostly `[SKIP]` (the packages are still installed), and
`bootstrap_cluster.sh` will see no existing cluster and run a full
`kubeadm init` again, followed by Calico installation.

**How:** same success criteria as Part 1.5 — `Ready` node, every pod
`Running`, no pods on the wrong CNI network.

**When:** immediately after 7.2, to get back to a known-good empty cluster,
ready to redo any of the exercises in Parts 2–6 above.

---

## Full Sequence, Start to Finish (copy-paste order)

For reference, here's every phase in the order you'd actually run it on a
brand new machine:

```bash
# 1. Pre-flight (Part 1.1) — fix anything that fails before continuing
ps --pid 1 -o comm=
sudo modprobe overlay && sudo modprobe br_netfilter
stat -fc %T /sys/fs/cgroup/
hostname -I
swapon --show

# 2. Install + bootstrap (Part 1.2–1.4)
sudo ./install_k8s_stack.sh
newgrp docker
sudo ./bootstrap_cluster.sh
kubectl get nodes

# 3. Try a pod (Part 2)
kubectl run nginx-yaml --image=nginx
kubectl get pods

# 4. Try a namespace + Deployment (Part 3–4)
kubectl create namespace mealie
kubectl config set-context --current --namespace=mealie
kubectl create deployment mealie --image=<your-image> --replicas=1

# 5. Expose it (Part 5)
kubectl expose deployment mealie --port <port>
kubectl get svc

# 6. (Optional) lock it down (Part 6)
kubectl apply -n mealie -f default-deny-ingress.yaml

# 7. Clean up when done (Part 7.1), or reset everything (Part 7.2–7.3)
```

---

## Cross-Reference: Which Lab Explains What

| This file's section | Full depth in |
|---|---|
| Pre-flight, install, bootstrap | **Setup Guide** |
| Stale CNI token (create *and* delete hanging) | **Lab 4** |
| Imperative vs. declarative, `created`/`configured` | **Lab 2** |
| `kubectl-neat`, `krew`, auto-injected fields | **Lab 3** |
| Deployments, self-healing, scaling, rolling updates, rollback | **Lab 5** |
| Calico NetworkPolicy enforcement, iptables internals | **Lab 6** |
| Services — ClusterIP/NodePort/LoadBalancer, the port-mixup, EndpointSlices | **Lab 7** |
| Tracing a Service through kube-proxy's actual iptables rules | **Lab 8** |
| Not yet covered | **Ingress** (still a placeholder on the mind map) |
