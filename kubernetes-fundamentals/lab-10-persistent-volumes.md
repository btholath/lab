# Lab 10: Persistent Volumes and Claims — Making Data Survive a Pod

**Goal:** understand why `emptyDir` (Lab 9) isn't good enough for real data,
what a `PersistentVolumeClaim` actually requests, why it can sit `Pending`
forever on a bare cluster, how to satisfy it by hand with a
`PersistentVolume`, and then prove — with real log evidence — that data
genuinely survives a pod being deleted and replaced.

**Time:** about 45 minutes.

**Where the outputs come from:** everything below is real output from this
WSL2 kubeadm cluster, captured while building it, including Mealie's own
application logs as the final proof.

**Builds on:** Lab 5 (Deployments — this is the exact data-loss problem
flagged there), Lab 9 (Volumes — same `volumes`/`volumeMounts` shape, a
different volume source).

---

## The Big Idea

In Lab 9, `emptyDir` proved that containers can share storage — but it also
came with a deliberate limitation: delete the pod, and the volume is gone
with it. That's fine for scratch space, and it's exactly why every Mealie
upgrade in Lab 5 started completely fresh.

A **PersistentVolume (PV)** and **PersistentVolumeClaim (PVC)** exist to
break that link — to give a pod storage whose lifetime is **independent of
the pod's own lifetime**.

The two objects have a deliberate division of labor:

| Object | Written by | Represents |
|---|---|---|
| **PersistentVolume (PV)** | A cluster admin, or an automatic provisioner | An actual piece of storage that exists somewhere — a disk, a directory, a cloud volume |
| **PersistentVolumeClaim (PVC)** | An application developer | A **request** for storage — "I need 500Mi, read-write by one pod" — without needing to know or care *where* it physically comes from |

A pod never references a PV directly. It mounts a **PVC**, and the PVC is
matched ("bound") to a PV behind the scenes. This is the same separation of
concerns you've already seen elsewhere in this series: a Service decouples
"which pod" from "how to reach it"; a PVC decouples "where the storage
physically is" from "what the application asks for."

---

## Step 1: Create the claim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mealie-data
  namespace: mealie
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: 500Mi
```

```bash
kubectl apply -f storage.yaml
kubectl get pvc -n mealie
```

**Output from the real session:**
```
persistentvolumeclaim/mealie-data created

NAME          STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
mealie-data   Pending                                                     <unset>                 92s
```

**Reading the spec:**

| Field | Meaning |
|---|---|
| `accessModes: [ReadWriteOnce]` | Only **one node** can mount this volume read-write at a time. (Other modes: `ReadOnlyMany`, `ReadWriteMany` — not every storage type supports every mode) |
| `volumeMode: Filesystem` | Mounted as a normal directory (the alternative, `Block`, hands the pod a raw block device) |
| `resources.requests.storage: 500Mi` | The minimum size being requested |

**`STATUS Pending`** is the first thing to notice, and it's not an error yet
— it just means nothing has satisfied this request so far.

---

## Step 2: Attach the claim to the Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: mealie
  name: mealie
  namespace: mealie
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mealie
  template:
    metadata:
      labels:
        app: mealie
    spec:
      containers:
      - image: ghcr.io/mealie-recipes/mealie:v3.28.0
        name: mealie
        ports:
        - containerPort: 9000
        volumeMounts:
        - mountPath: /app/data
          name: mealie-data
      volumes:
      - name: mealie-data
        persistentVolumeClaim:
          claimName: mealie-data
```

This is exactly the same `volumes`/`volumeMounts` shape from Lab 9 — the
only thing that changed is the volume **source**. Instead of
`emptyDir: {}`, it's `persistentVolumeClaim: {claimName: mealie-data}`.

```bash
kubectl apply -f deployment.yaml
kubectl get pods -n mealie
```

**Output from the real session:**
```
deployment.apps/mealie configured

NAME                      READY   STATUS    RESTARTS   AGE
mealie-6754cc7b44-dpb2q   1/1     Running   0          2d7h
mealie-fc9694b48-8flvw    0/1     Pending   0          52s
```

Two things to notice, both familiar from earlier labs:

- **A new ReplicaSet hash appeared** (`fc9694b48`) — changing `volumes` is a
  pod-template change, so this triggered a rolling update exactly like an
  image change would (Lab 5).
- **The new pod is `Pending`, not `ContainerCreating`.** That's a
  meaningful difference — `Pending` here means the pod can't even be
  scheduled/started yet, because it's waiting on a volume that doesn't
  exist.

---

## Step 3: Diagnose why it's stuck

```bash
kubectl get storageclass
```

**Output from the real session:**
```
No resources found
```

```bash
kubectl describe pvc mealie-data -n mealie
```

**Output from the real session** (key section):
```
Name:          mealie-data
Namespace:     mealie
StorageClass:
Status:        Pending
...
Used By:       mealie-fc9694b48-8flvw
Events:
  Type    Reason         Age                 From                         Message
  ----    ------         ----                ----                         -------
  Normal  FailedBinding  52s (x82 over 20m)  persistentvolume-controller  no persistent volumes available for this claim and no storage class is set
```

**What this means:** a PVC doesn't create storage on its own. Something
has to fulfill the request, and there are exactly two ways that happens:

1. **Dynamic provisioning** — a `StorageClass` exists with a provisioner
   that automatically creates a matching PV the moment a PVC asks for one.
   Managed clusters (EKS, GKE, AKS) and local tools like Kind/k3s ship with
   this by default.
2. **Static provisioning** — an admin creates a PV by hand ahead of time,
   and the PVC binds to it if the size and access mode are compatible.

This kubeadm cluster has **neither** — no StorageClass at all
(`kubectl get storageclass` returned nothing), so the PVC has nothing to
bind to and sits `Pending` indefinitely. The event message says this
explicitly: *"no persistent volumes available for this claim and no
storage class is set."* The `(x82 over 20m)` shows the controller retrying
roughly every 15 seconds the whole time, exactly like kubelet's retry
pattern for other stuck conditions elsewhere in this series.

---

## Step 4: Static provisioning — create the PersistentVolume by hand

Since there's no provisioner, create the storage yourself.

```bash
sudo mkdir -p /mnt/mealie-data
```

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mealie-data-pv
spec:
  capacity:
    storage: 500Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /mnt/mealie-data
```

**Reading the spec:**

| Field | Meaning |
|---|---|
| `capacity.storage: 500Mi` | Must be **≥** what the PVC requests, for binding to succeed |
| `accessModes: [ReadWriteOnce]` | Must match (or be compatible with) what the PVC asks for |
| `persistentVolumeReclaimPolicy: Retain` | What happens to the data when the PVC is deleted. `Retain` keeps it (you'd have to clean it up manually); `Delete` would wipe it automatically |
| `hostPath.path: /mnt/mealie-data` | The actual storage: a plain directory on **this node's own disk** |

⚠️ **`hostPath` only makes sense on a single-node cluster.** On a real
multi-node cluster, if the pod got rescheduled to a *different* node, that
node wouldn't have this directory at all, and the mount would fail. This
is a lab-only shortcut standing in for a real backend (cloud disks, NFS,
Ceph, etc.).

```bash
kubectl apply -f mealie-pv.yaml
kubectl get pv
```

**Output from the real session:**
```
persistentvolume/mealie-data-pv created

NAME             CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
mealie-data-pv   500Mi      RWO            Retain           Available                          <unset>                          1s
```

`STATUS Available` with an empty `CLAIM` column means the PV exists,
unclaimed, waiting for a matching PVC.

---

## Step 5: Watch the binding happen

```bash
kubectl get pvc -n mealie
```

**Output from the real session:**
```
NAME          STATUS   VOLUME           CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
mealie-data   Bound    mealie-data-pv   500Mi      RWO                           <unset>                 22m
```

`Bound` on the very next check — no delay. **This is the entire binding
mechanism**: the PVC's `accessModes` and `resources.requests.storage`
matched the PV's `accessModes` and `capacity.storage` exactly, and the
`persistentvolume-controller` connected them. No provisioner, no
automation — just two specs that satisfy each other.

```bash
kubectl get pods -n mealie
```

**Output from the real session:**
```
NAME                      READY   STATUS    RESTARTS   AGE
mealie-6754cc7b44-dpb2q   1/1     Running   0          2d7h
mealie-fc9694b48-8flvw    1/1     Running   0          9m2s
```

`mealie-fc9694b48-8flvw` moved from `Pending` to `Running` the instant the
volume it was waiting on became available.

Confirm the ReplicaSet history, since this is now the **third** distinct
version of Mealie across this whole series:

```bash
kubectl get replicasets -n mealie
```

**Output from the real session:**
```
NAME                DESIRED   CURRENT   READY   AGE
mealie-58d548ff48   0         0         0       2d8h
mealie-6754cc7b44   0         0         0       2d7h
mealie-fc9694b48    1         1         1       9m15s
```

| ReplicaSet | What changed |
|---|---|
| `mealie-58d548ff48` | v1.2.0 (Lab 5, very first Mealie deployment) |
| `mealie-6754cc7b44` | v3.28.0 (Lab 5, live rolling update) |
| `mealie-fc9694b48` | v3.28.0 + PVC (this lab) — **current** |

Each is a real, distinct pod-template change, each preserved at zero
replicas for instant rollback — `kubectl rollout history deployment/mealie
-n mealie` would show all three as numbered revisions.

---

## Step 6: The real test — does data survive a pod deletion?

### Reach Mealie and create something real

```bash
kubectl port-forward svc/mealie 9000:9000 -n mealie
```

At `http://localhost:9000`, since this was a brand-new, empty PVC, Mealie
showed its first-run setup screen. An admin account was created, then a
real recipe was imported from a URL.

**Mealie's own log confirms the first-run initialization:**
```
[INFO|init_db|L134] 2026-09-30T07:21:26: Database contains no users, initializing...
[INFO|init_db|L44]  2026-09-30T07:21:26: Generating Default Group and Household
[INFO|init_users|L62] 2026-09-30T07:21:27: Generating Default User
```

### Delete the pod

```bash
kubectl delete pod -n mealie -l app=mealie
kubectl get pods -n mealie -w
```

**Output from the real session:**
```
pod "mealie-fc9694b48-8flvw" deleted

NAME                     READY   STATUS    RESTARTS   AGE
mealie-fc9694b48-s7tdl   1/1     Running   0          3s
```

Same ReplicaSet hash (`fc9694b48`) — no template change this time, just a
plain pod replacement, the same self-healing mechanism from Lab 5. A brand
new pod, a brand new container, a brand new writable layer... but the same
mounted PVC.

### Check: does the new pod re-run first-time setup?

```bash
kubectl exec -it mealie-fc9694b48-s7tdl -n mealie -- cat /app/data/mealie.log
```

**Output from the real session** (the second startup, right after the
delete):
```
[INFO|server|L282] 2026-09-30T07:24:11: Shutting down
[INFO|app|L95]     2026-09-30T07:24:11: -----SYSTEM SHUTDOWN-----
...
[INFO|server|L103] 2026-09-30T07:24:20: Started server process [1]
[INFO|init_db|L97]  2026-09-30T07:24:20: Database connection established.
[INFO|app|L67]     2026-09-30T07:24:20: end: database initialization
[INFO|app|L71]     2026-09-30T07:24:20: -----SYSTEM STARTUP-----
```

**This is the proof.** Compare the two startups side by side:

| First startup (old pod, empty volume) | Second startup (new pod, same PVC) |
|---|---|
| `Database contains no users, initializing...` | *(this line never appears)* |
| `Generating Default Group and Household` | *(skipped — already exists)* |
| `Generating Default User` | *(skipped — already exists)* |

The single **missing** line is the whole story: Mealie checked for an
existing database at `/app/data/mealie.db`, found one, and skipped
first-run setup entirely — because that file lives on the PVC, not in the
container's own writable layer that was destroyed along with the old pod.

### Confirm by actually logging in

```bash
kubectl port-forward svc/mealie 9000:9000 -n mealie
```

**Output from the real session's log, moments after reconnecting:**
```
[INFO|httptools_impl|L482] 2026-09-30T07:25:18: 127.0.0.1:36052 - "POST /api/auth/token HTTP/1.1" 200
[INFO|httptools_impl|L482] 2026-09-30T07:25:18: 127.0.0.1:36052 - "GET /api/users/self HTTP/1.1" 200
```

A successful login (`200`) with the **same account credentials created
before the pod was deleted** — no signup flow, no "database not
initialized" redirect. Then, to push the point further, a brand new recipe
was imported straight into this post-deletion pod:

```
[INFO|httptools_impl|L482] 2026-09-30T07:28:15: 127.0.0.1:38950 - "POST /api/recipes/create/url/stream HTTP/1.1" 200
[INFO|_client|L1740] 2026-09-30T07:28:15: HTTP Request: GET https://www.bbc.co.uk/food/recipes/cajun_chicken_wedges_61950 "HTTP/2 200 OK"
[INFO|minify|L193] 2026-09-30T07:28:17: /app/data/recipes/7b026ceb-4182-4226-8118-91ca28ec6bb8/images/original.webp created
```

That new recipe's images were written straight into `/app/data/recipes/` —
the same mounted PVC — proving the volume isn't just *readable* across pod
replacement, it's fully **read-write** and immediately usable by whatever
pod happens to be mounting it at any given moment.

### One more confirmation, from inside the container

```bash
kubectl exec -it mealie-fc9694b48-s7tdl -n mealie -- bash
ls /app/data/users
```

**Output from the real session:**
```
c5779d05-98fb-414e-a78c-8ff8069f9754
```

That user UUID is the **same** admin account created before the pod was
deleted. A fresh, empty volume would have shown either nothing, or a
*different* UUID generated by a new first-run setup.

---

## Step 7: A Stronger Test — Delete the Entire Deployment, Not Just the Pod

Step 6 proved data survives a single **pod** being replaced. This step goes
one level further: what happens if the **whole Deployment object** is
deleted and recreated?

### Delete everything except the storage

```bash
kubectl delete deployment mealie -n mealie
kubectl delete pod nginx-storage -n mealie
kubectl get pvc -n mealie
kubectl get pv
```

**Output from the real session:**
```
deployment.apps "mealie" deleted
pod "nginx-storage" deleted

NAME          STATUS   VOLUME           CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
mealie-data   Bound    mealie-data-pv   500Mi      RWO                           <unset>                 35m

NAME             CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
mealie-data-pv   500Mi      RWO            Retain           Bound    mealie/mealie-data                  <unset>                          13m
```

**Both the PVC and PV are completely unaffected**, still `Bound` to each
other, even with the Deployment — and every pod it ever created — gone
entirely.

**Why:** a `PersistentVolumeClaim` is not owned by the Deployment. Nothing
about deleting a Deployment cascades to the PVCs its pods happened to
mount. The `CLAIM` column on the PV (`mealie/mealie-data`) still points at
the PVC object itself, not at any specific pod — the PV only becomes
`Available` again if the **PVC** is deleted, and even then, this PV's
`persistentVolumeReclaimPolicy: Retain` means the actual files at
`/mnt/mealie-data` would be left on disk regardless, not automatically
wiped.

### The Service survived too, for the same reason

```bash
kubectl get all -n mealie
```

**Output from the real session:**
```
NAME             TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
service/mealie   LoadBalancer   10.96.241.203   <pending>     9000:30315/TCP   37h
```

No Deployment, no ReplicaSet, no pods — but the Service's `37h` age shows
it never blinked. A Service selects pods by **label**, not by owning them,
so it's just as independent of the Deployment's lifecycle as the PVC is.

### Recreate the Deployment from the same file

```bash
kubectl apply -f deployment.yaml
kubectl get pods -n mealie -w
```

**Output from the real session:**
```
deployment.apps/mealie created

NAME                     READY   STATUS              RESTARTS   AGE
mealie-fc9694b48-6sjz7   0/1     ContainerCreating   0          1s
mealie-fc9694b48-6sjz7   1/1     Running             0          2s
```

**A surprise worth explaining:** the ReplicaSet hash — `fc9694b48` — is
**identical** to the one from before the deletion. That's not the old
object somehow surviving; it's because the hash is a fingerprint of the
pod template's *contents*, not a random value assigned at creation time.
Since `deployment.yaml` was applied unchanged, Kubernetes computed the same
hash both times. Confirm this is genuinely a new object:

```bash
kubectl get deployment mealie -n mealie -o jsonpath='{.metadata.uid}{"\n"}{.metadata.creationTimestamp}{"\n"}'
```

**Output from the real session:**
```
7520763b-d51b-458c-8a62-7c4ed4209b54
2026-09-30T07:35:26Z
```

A fresh `uid`, and a `creationTimestamp` of *right now* — not the original
creation time from days earlier. This confirms it: a brand-new Deployment
object, in etcd, with a new identity, that simply happens to produce
identically-named children because nothing about the template changed.

### The final proof

```bash
kubectl exec -it mealie-fc9694b48-6sjz7 -n mealie -- \
  grep -c "Database contains no users" /app/data/mealie.log
```

**Output from the real session:**
```
1
```

Still exactly **one** occurrence — the original first-run line from days
ago, in Step 6. This brand-new pod, under this brand-new Deployment object,
mounted the same PVC, found the same existing database, and skipped
first-run setup entirely, exactly like every pod before it that happened
to mount `mealie-data`.

### What this proves that Step 6 didn't

| | Step 6 | Step 7 |
|---|---|---|
| What was deleted | One Pod | The entire Deployment (and every Pod/ReplicaSet under it) |
| What survived | The PVC (implicitly, since it was never touched) | The PVC **and** the Service, explicitly confirmed independent |
| What it proves | Pod replacement doesn't lose data | **The whole application can be torn down and rebuilt from scratch, and the data — plus its stable network address — are completely unaffected** |

This is the practical shape of a real-world pattern: application code and
configuration (the Deployment) are treated as disposable and easily
rebuilt, while data (the PVC) and networking (the Service) are treated as
durable state that outlives any particular version of the workload sitting
in front of them.

---

This is the exact scenario Lab 5 flagged and deliberately left unresolved:

> *"This Deployment has no persistent storage. Anything you add to Mealie
> lives only in the container's own writable layer, which is thrown away
> when the pod is replaced, including during a rollout... After the
> upgrade, Mealie started fresh."*

That was true for every Mealie pod in this series **until this lab**. The
only thing that changed is the presence of a PVC sitting between the pod
and the node's disk — the pod's own lifetime and the data's lifetime are
now fully decoupled.

---

## Key Takeaways

1. **A PVC is a request, not storage itself.** It describes what an application needs (size, access mode); something else has to fulfill it.
2. **A PV is the actual storage**, created either automatically (a StorageClass + provisioner) or by hand (static provisioning, this lab).
3. **Binding is just spec-matching.** A PVC binds to any PV whose `accessModes` and `capacity` satisfy the request — no magic beyond that.
4. **No StorageClass means PVCs stay `Pending` forever** unless a matching PV is created manually. `kubectl describe pvc` names this exact reason in its Events.
5. **Changing a Deployment's `volumes` is a template change** — it triggers a new ReplicaSet, the same rolling-update mechanism as an image change.
6. **The proof of persistence is a missing log line.** "Database contains no users, initializing" appearing only once, on the very first startup, is direct evidence the data survived every subsequent pod replacement.
7. **`hostPath` PVs are single-node-only.** They stand in for a real backend in a lab; a production cluster needs storage that isn't tied to one specific node's disk.
8. **PVCs and Services are not owned by the Deployment that uses them.** Deleting and recreating an entire Deployment leaves both completely untouched — data and networking outlive any particular version of the workload sitting in front of them.
9. **This is the same `volumes`/`volumeMounts` shape as Lab 9's `emptyDir`.** Only the volume *source* changed — the pattern you already know carries over directly.

---

## Command Reference

```bash
# Create a claim
kubectl apply -f storage.yaml
kubectl get pvc -n <namespace>
kubectl describe pvc <name> -n <namespace>

# Diagnose a Pending claim
kubectl get storageclass
kubectl describe pvc <name> -n <namespace>   # check Events

# Static provisioning
sudo mkdir -p /mnt/<some-dir>
kubectl apply -f pv.yaml
kubectl get pv

# Attach a claim to a Deployment (in the pod template)
#   volumes:
#   - name: <volume-name>
#     persistentVolumeClaim:
#       claimName: <pvc-name>

# Verify binding and rollout
kubectl get pvc -n <namespace>
kubectl get pods -n <namespace>
kubectl get replicasets -n <namespace>

# Prove persistence across a single pod replacement
kubectl delete pod -n <namespace> -l app=<label>
kubectl get pods -n <namespace> -w
kubectl exec -it <new-pod> -n <namespace> -- cat <path-to-app-log>

# Prove persistence across a full Deployment deletion/recreation
kubectl delete deployment <name> -n <namespace>
kubectl get pvc -n <namespace>   # still Bound
kubectl get svc -n <namespace>   # still there
kubectl apply -f deployment.yaml
kubectl get deployment <name> -n <namespace> -o jsonpath='{.metadata.uid}{"\n"}'
```
