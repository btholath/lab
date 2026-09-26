# Lab 4: Diagnosing a Stale CNI Token — "Unauthorized" on New Pods

**Incident summary:** after the cluster had been running untouched for
roughly 19–20 hours, creating a new Deployment produced pods that got stuck
in `ContainerCreating` indefinitely. The existing pods (`httpd`,
`nginx-yaml`) kept running fine the whole time — only **newly created** pods
were affected. This lab documents the full diagnosis, the root cause, the
fix, and — since the root cause lives inside `calico-node` — a full
explanation of what `calico-node` actually is and why it's built the way it
is.

---

## Step 1: Notice the symptom

```bash
kubectl create deployment test --image=httpd --replicas=3
```

**Output:**
```
deployment.apps/test created
```

```bash
kubectl get pods
```

**Output (checked repeatedly over several minutes):**
```
NAME                    READY   STATUS              RESTARTS   AGE
httpd                   1/1     Running             0          19h
nginx-yaml              1/1     Running             0          20h
test-77c4c4df6c-4r9qw   0/1     ContainerCreating   0          5m56s
test-77c4c4df6c-q2gfg   0/1     ContainerCreating   0          5m56s
test-77c4c4df6c-qlbb6   0/1     ContainerCreating   0          5m56s
```

**Why this is suspicious:** `httpd` is a small, already-cached image on this
node (it was pulled hours earlier). Three replicas of it sitting in
`ContainerCreating` for 5+ minutes is far outside normal image-pull time —
something is actively blocking sandbox creation, not just running slowly.

---

## Step 2: Get the real error from pod events

```bash
kubectl describe pod test-77c4c4df6c-4r9qw
```

**Key output:**
```
Events:
  Type     Reason                  Age    From      Message
  ----     ------                  ----   ----      -------
  Normal   Scheduled               7m     default-scheduler  Successfully assigned default/test-77c4c4df6c-4r9qw to b
  Warning  FailedCreatePodSandBox  6m59s  kubelet   Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "368c38e9...": plugin type="calico" failed (add): error getting ClusterInformation: connection is unauthorized: Unauthorized
  ... (repeated ~17 times over several minutes) ...
```

**What this tells us:**
- The pod **was successfully scheduled** to the node (`PodScheduled: True`) — the API server, scheduler, and etcd are all fine.
- The failure happens specifically in **sandbox creation** — the step where containerd asks the CNI plugin (`calico`) to set up networking for the new pod.
- The Calico CNI plugin itself is failing to authenticate to the Kubernetes API: `connection is unauthorized: Unauthorized`.
- Kubelet is **retrying automatically** (visible from the repeated events) — this is a transient-looking failure from kubelet's perspective, not a hard failure it gives up on.

This immediately narrows the problem to **the CNI plugin's own credentials**, not the pod, the image, the scheduler, or general cluster health.

---

## Step 3: Rule out clock drift (a known WSL2 gotcha)

Kubernetes tokens are JWTs with expiry timestamps — if the WSL2 VM's clock had drifted from real time, a genuinely valid token could *look* expired to the API server.

```bash
date
```

**Output:**
```
Sat Sep 26 12:01:20 PM PDT 2026
```

This matched real-world time exactly — **clock drift ruled out**. The problem is something else.

---

## Step 4: Check whether `calico-node` itself is healthy

```bash
kubectl get pods -n calico-system -o wide
```

**Output:**
```
NAME                                       READY   STATUS    RESTARTS   AGE
calico-apiserver-98745df58-87f6x           1/1     Running   0          4d
calico-apiserver-98745df58-cs6fd           1/1     Running   0          4d
calico-kube-controllers-54698dfc77-lm8sh   1/1     Running   0          4d
calico-node-zwgb5                          1/1     Running   0          4d
calico-typha-77c88f9f5d-xm6wz              1/1     Running   0          4d
csi-node-driver-rz25n                      2/2     Running   0          4d
goldmane-c7cfb995d-v4twp                   1/1     Running   0          4d
whisker-7d75948596-p82t7                   2/2     Running   0          4d
```

Everything shows `Running`, `0` restarts, **4 days of continuous uptime**.
At first glance this looks healthy — but that 4-day uptime number turns out
to be the actual root cause, explained in Step 6.

```bash
kubectl logs -n calico-system -l k8s-app=calico-node --tail=50
```

The logs showed only routine Felix reconciliation summaries — no errors, no
authentication failures, nothing alarming:
```
2026-09-26 19:01:27.279 [INFO][83] felix/summary.go 100: Summarising 6 dataplane reconciliation loops over 1m23.4s: avg=16ms longest=43ms (resync-calico-v4)
```

**This is the confusing part of the incident:** `calico-node`'s own logs
look completely clean, yet the CNI plugin it's responsible for is failing
auth. The explanation requires understanding that `calico-node` is not one
single process — see Step 6.

---

## Step 5: Rule out `kubectl-neat`/plugin issues, confirm this is a fresh problem

Since `nginx-yaml`, `httpd`, and the earlier `httpd` exec/networking labs
had all worked fine hours to days earlier, this confirms the failure is
**time-based** — something that was working stopped working purely because
time passed, with no configuration change in between. That's a strong
signal pointing at an expiring credential, not a one-time misconfiguration.

---

## Step 6: Root cause — a static CNI token snapshot, not a live mounted token

This is the key insight of the whole incident.

`calico-node` is not a single container — its own pod definition contains
**multiple containers**, confirmed directly in the `kubectl describe pod`
output from an earlier lab:
```
Defaulted container "calico-node" out of: calico-node, flexvol-driver (init), ebpf-bootstrap (init), install-cni (init)
```

The important one here is **`install-cni`**, an **init container** — meaning
it runs **once**, to completion, when the `calico-node` pod first starts,
and then never runs again for the lifetime of that pod.

`install-cni`'s job includes writing a file to the **node's own
filesystem** (not inside any pod): `/etc/cni/net.d/calico-kubeconfig`. This
file contains a **snapshot** of a service account token, used by the
standalone `calico` CNI binary — a plain executable that containerd invokes
directly on the host every time *any* pod's network sandbox needs to be
created.

**The critical distinction:**

| | Tokens mounted *inside* a running pod | The CNI plugin's token file |
|---|---|---|
| **Location** | `/var/run/secrets/kubernetes.io/serviceaccount/token` inside the container | `/etc/cni/net.d/calico-kubeconfig` on the **node's** filesystem |
| **Refresh behavior** | Kubelet actively rotates this file in place roughly every hour, for as long as the pod runs | Written **once** by an init container at pod startup; **never refreshed** afterward |
| **Why it matters here** | This is why `calico-node`'s own Felix process (the main container) never had an auth problem — it uses the live, auto-rotating mount | This is exactly why the **CNI plugin binary** started failing — after `calico-node` had been running 4 days straight, its one-time token snapshot had aged past validity |

This explains every observation from this incident:
- `calico-node` itself looked perfectly healthy (Felix uses the live, rotating token — unaffected)
- Only **new pod creation** was affected (only new pod creation invokes the CNI binary, which reads the stale on-disk snapshot)
- Already-running pods (`httpd`, `nginx-yaml`) were completely unaffected (their networking was already set up; nothing re-reads the CNI token for pods that already exist)
- The failure appeared purely because of elapsed time (4 days of `calico-node` uptime without a restart), with zero configuration changes

---

## Step 7: Apply the fix — force a fresh token snapshot

```bash
kubectl delete pod -n calico-system -l k8s-app=calico-node
```

Deleting the `calico-node` pod causes Kubernetes to recreate it, which
re-runs all of its init containers — including `install-cni`, which writes
a **brand new** token snapshot to `/etc/cni/net.d/calico-kubeconfig`.

```bash
kubectl get pods -n calico-system -w
```

**Output:**
```
NAME                                       READY   STATUS    RESTARTS   AGE
calico-node-2vwnb                          0/1     Running   0          8s
...
calico-node-2vwnb                          1/1     Running   0          37s
```

The ~37 seconds between "Running, 0/1" and "Running, 1/1" is exactly the
init container sequence (`flexvol-driver` → `ebpf-bootstrap` → `install-cni`)
completing before the main `calico-node` container is considered ready.

---

## Step 8: Verify — did the stuck pods self-heal?

```bash
kubectl get pods --watch
```

**Output:**
```
NAME                    READY   STATUS    RESTARTS   AGE
httpd                   1/1     Running   0          19h
nginx-yaml              1/1     Running   0          20h
test-77c4c4df6c-4r9qw   1/1     Running   0          12m
test-77c4c4df6c-q2gfg   1/1     Running   0          12m
test-77c4c4df6c-qlbb6   1/1     Running   0          12m
```

**All three `test-*` pods transitioned to `1/1 Running` without any manual
deletion.** This is kubelet's own retry logic at work — it had been retrying
`FailedCreatePodSandBox` roughly every 10-15 seconds the entire time (visible
as the repeated events in Step 2), and the very next retry after the fresh
CNI token existed succeeded immediately.

---

## Incident Summary

| | |
|---|---|
| **Symptom** | New pods stuck indefinitely in `ContainerCreating`; existing pods unaffected |
| **Trigger** | `calico-node` had been running continuously for 4 days without restarting |
| **Root cause** | `install-cni` init container writes a one-time, non-rotating service account token snapshot to `/etc/cni/net.d/calico-kubeconfig` on the node; that snapshot expired |
| **Diagnosis path** | `describe pod` events → ruled out clock drift → checked `calico-node` health (looked fine) → recognized `calico-node` is multi-container, with a non-restarting init container responsible for the stale file |
| **Fix** | `kubectl delete pod -n calico-system -l k8s-app=calico-node` — forces `install-cni` to re-run and write a fresh token |
| **Verification** | Stuck pods self-recovered via kubelet's existing retry loop, no manual pod deletion needed |
| **Recurrence** | Expect this again any time the cluster sits idle for an extended period (this WSL2 environment being suspended/resumed, or simply long uptime) before the next new pod is created |

---

## What Is `calico-node`, Really? (And What Does Each Container Do?)

The confusion in this incident came directly from treating `calico-node` as
"one thing." It's actually a **DaemonSet** (one pod per node — trivial here
since you have one node, but this runs on *every* node in a real cluster),
and that pod bundles together several distinct responsibilities as separate
containers within it.

### The main container: `calico-node`

This is the actual long-running per-node agent, and it bundles two
historically separate Calico components into one process:

- **Felix** — the policy enforcement engine. Felix watches the Calico/Kubernetes
  datastore (via the API server) for changes to pods, NetworkPolicies, and IP
  pools, and translates that desired state into actual `iptables`/`ipset`
  rules (or eBPF programs, in eBPF dataplane mode) on the node. This is what
  actually enforces the `NetworkPolicy` objects you inspected earlier in this
  lab series (`allow-apiserver`, etc.) — Felix is the component reading those
  and programming the kernel accordingly.
- **BIRD** (in BGP mode) — a BGP routing daemon that exchanges pod-network
  routes with other nodes, so traffic between pods on *different* nodes
  knows how to get there without an overlay network. On a single-node
  cluster like yours, BIRD has nothing to peer with, so this part is largely
  dormant — its importance shows up in multi-node clusters.
- **Health reporting** — `calico-node` exposes liveness/readiness endpoints
  that kubelet uses to determine the `1/1 Running` status you see in
  `kubectl get pods`.

### Init container 1: `install-cni`

Runs once at pod startup. Responsible for:
- Copying the actual `calico` CNI plugin binary into `/opt/cni/bin/` on the
  host, so containerd can find and execute it
- Writing the CNI configuration file (`/etc/cni/net.d/10-calico.conflist`) —
  this is the file from earlier labs that determines which CNI plugin wins
  when multiple configs exist in that directory
- **Writing the CNI kubeconfig/token snapshot** (`/etc/cni/net.d/calico-kubeconfig`) — the file at the center of this entire incident

Because this is an **init container**, none of this re-runs unless the whole
`calico-node` pod restarts — which is exactly why the token inside it goes
stale silently over time.

### Init container 2: `flexvol-driver`

Installs a small binary supporting Calico's (largely legacy) FlexVolume
integration, historically used to support certain application-layer policy
integrations (e.g., exposing a Unix domain socket for sidecar-based policy
enforcement in some Calico/Istio integration scenarios). For most standard
setups like this lab, it does minimal work and completes almost instantly.

### Init container 3: `ebpf-bootstrap`

Prepares the node for Calico's optional **eBPF dataplane mode** — mounting
the BPF filesystem and setting up prerequisites the main `calico-node`
container would need *if* eBPF mode is enabled. If the cluster is running
in standard iptables mode (the default, and what this cluster uses), this
container still runs as part of the standard startup sequence but has
little to do.

### Why this container split matters (the KCSA-relevant takeaway)

Splitting one-time setup work (`install-cni`, `flexvol-driver`,
`ebpf-bootstrap`) from the long-running agent (`calico-node` main container)
is a deliberate and common Kubernetes pattern — **init containers for setup,
main container for ongoing operation**. It's efficient and normally
invisible. But it has a real operational consequence worth remembering:
**anything written by an init container is a point-in-time snapshot, not a
continuously managed resource** — unlike volumes mounted directly into a
running pod (which kubelet actively keeps fresh), files written once by an
init container will silently age, and nothing will proactively tell you when
they become invalid. Recognizing *which category* a given file falls into is
exactly the kind of operational judgment this incident forced into the
open.

---

## Prevention / Monitoring Ideas for the Future

- **Immediate practical habit:** if you return to this cluster after it's
  been idle for a long stretch and try to create something new, and it
  hangs in `ContainerCreating`, check `describe pod` events for
  `Unauthorized` first — you'll likely recognize this exact pattern
  immediately next time.
- **Possible automation:** `bootstrap_cluster.sh`'s existing self-heal logic
  (which already detects pods on the wrong CNI network) could be extended
  to also check for `FailedCreatePodSandBox` + `Unauthorized` in recent
  events, and automatically cycle `calico-node` when found — turning this
  entire diagnostic process into another automatic fix, the same way the
  earlier CNI-race issue was handled.
