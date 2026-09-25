# Lab: From Imperative Commands to Declarative YAML

**Goal:** understand the difference between imperative `kubectl` commands and
declarative YAML manifests, and see exactly how `kubectl apply` reconciles a
running object when you change it — including which changes apply live vs.
which require a full recreate.

**You'll create:** a single `nginx` pod, generate its manifest from an
imperative command, edit that manifest, and re-apply it — observing how
Kubernetes handles the update.

---

## Step 1: Generate YAML from an imperative command (dry-run)

Rather than hand-writing a Pod manifest from scratch, let Kubernetes generate
one for you based on an imperative command — **without actually creating
anything**:

```bash
kubectl run nginx-yaml --image=nginx --dry-run=client -o yaml
```

**Expected output:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    run: nginx-yaml
  name: nginx-yaml
spec:
  containers:
  - image: nginx
    name: nginx-yaml
    resources: {}
  dnsPolicy: ClusterFirst
  restartPolicy: Always
status: {}
```

`--dry-run=client` means: *build the object and show me what it would look
like, but don't send it to the API server.* Nothing exists in the cluster
yet — this is purely a generation step.

---

## Step 2: Save the generated YAML to a file

```bash
kubectl run nginx-yaml --image=nginx --dry-run=client -o yaml > nginx.yaml
```

```bash
ls -lrt
```

**Expected output (example):**
```
total 20
-rw-r--r-- 1 bijut bijut 8722 Sep 25 09:55 readme-what-is-kubernetes.md
drwxr-xr-x 2 bijut bijut 4096 Sep 25 10:19 setup
-rw-r--r-- 1 bijut bijut  247 Sep 25 15:14 nginx.yaml
```

You now have a reusable, version-controllable manifest — this file can be
committed to Git, reviewed in a pull request, or reused to recreate the same
Pod on any cluster.

---

## Step 3: Create the pod declaratively

```bash
kubectl apply -f nginx.yaml
```

**Expected output:**
```
pod/nginx-yaml created
```

Confirm it's running:

```bash
kubectl get pods
```

**Expected output:**
```
NAME         READY   STATUS    RESTARTS   AGE
nginx-yaml   1/1     Running   0          34s
```

---

## Step 4: Inspect the running pod

```bash
kubectl describe pod nginx-yaml
```

**Expected output (abbreviated):**
```
Name:             nginx-yaml
Namespace:        default
Node:             b/192.168.155.98
Labels:           run=nginx-yaml
Status:           Running
IP:               192.168.78.75
Containers:
  nginx-yaml:
    Image:          nginx
    State:          Running
      Started:      Fri, 25 Sep 2026 15:16:00 -0700
    Ready:          True
    Restart Count:  0
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  71s   default-scheduler  Successfully assigned default/nginx-yaml to b
  Normal  Pulling    70s   kubelet            Pulling image "nginx"
  Normal  Pulled     69s   kubelet            Successfully pulled image "nginx" in 851ms
  Normal  Created    69s   kubelet            Container created
  Normal  Started    69s   kubelet            Container started
```

Note the real Calico-assigned pod IP (`192.168.78.75`) and a clean event
history — image pull, container create, container start, no errors. This
confirms scheduling, image pull, and the container runtime are all working
together correctly, not just that the API object was accepted.

---

## Step 5: Edit the manifest and add a new label

Open the file:

```bash
vi nginx.yaml
```

Add a second label under `metadata.labels`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    run: nginx-yaml
    method: fromcode
  name: nginx-yaml
spec:
  containers:
  - image: nginx
    name: nginx-yaml
```

Save and exit.

---

## Step 6: Re-apply and observe the reconciliation

```bash
kubectl apply -f nginx.yaml
```

**Expected output:**
```
pod/nginx-yaml configured
```

### Why "configured" and not "created" or "unchanged"

`kubectl apply` reports one of three outcomes by comparing your file against
the live object in the cluster:

| Result | Meaning |
|---|---|
| `created` | The resource didn't exist yet; it was created |
| `unchanged` | The resource exists and matches your file exactly — nothing to do |
| `configured` | The resource exists, but your file differs from the live object, so Kubernetes patched the live object to match |

Since you changed the labels, Kubernetes detected the difference and applied
a patch — without deleting or recreating the pod.

---

## Step 7: Confirm the label landed — and that nothing else changed

```bash
kubectl describe pod nginx-yaml
```

**Expected output (key lines):**
```
Labels:           method=fromcode
                  run=nginx-yaml
...
Containers:
  nginx-yaml:
    State:          Running
      Started:      Fri, 25 Sep 2026 15:16:00 -0700
    Restart Count:  0
```

Or more simply:

```bash
kubectl get pod nginx-yaml --show-labels
```

**Expected output:**
```
NAME         READY   STATUS    RESTARTS   AGE   LABELS
nginx-yaml   1/1     Running   0          4m    method=fromcode,run=nginx-yaml
```

**The important thing to notice:** the container's `Started` timestamp and
`Restart Count: 0` are **unchanged** from Step 4 — the label patch was
applied to the live object *without restarting the container at all*.

---

## The Concept This Demonstrates

This is the core distinction to internalize:

- **Metadata fields (labels, annotations) are mutable** — Kubernetes
  reconciles them in-place on the running object. No restart, no downtime.
- **Most of the pod *spec* is immutable on a running Pod** — you generally
  cannot change the container image, ports, or resource limits on an
  already-running bare Pod via `apply`. Kubernetes will either reject the
  change or (for certain fields) force a delete-and-recreate.

This is precisely **why Deployments exist**: a Deployment manages the
delete/recreate cycle for you automatically, as a controlled **rolling
update** — spinning up new pods with the updated spec and terminating old
ones gradually, rather than you manually deleting and recreating a bare Pod
yourself.

---

## Cleanup

```bash
kubectl delete -f nginx.yaml
```

**Expected output:**
```
pod "nginx-yaml" deleted
```

Note that `kubectl delete -f <file>` deletes whatever resource(s) that file
describes — a nice symmetry with `apply -f`, since the same file drives both
creation and deletion.

---

## Summary — Commands Used in This Lab

```bash
# Generate a manifest from an imperative command (nothing created yet)
kubectl run nginx-yaml --image=nginx --dry-run=client -o yaml > nginx.yaml

# Create the pod declaratively from the file
kubectl apply -f nginx.yaml

# Inspect it
kubectl get pods
kubectl describe pod nginx-yaml

# Edit nginx.yaml to add a label, then re-apply
kubectl apply -f nginx.yaml

# Confirm the live object was patched, not recreated
kubectl get pod nginx-yaml --show-labels

# Clean up
kubectl delete -f nginx.yaml
```
