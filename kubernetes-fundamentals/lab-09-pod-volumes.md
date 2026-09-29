# Lab 9: Volumes — Sharing Storage Inside and Between Containers

**Goal:** understand what a Pod volume actually is, how `volumes` and
`volumeMounts` connect to each other, why a Pod's container list can't be
changed once it exists, and how two containers in one Pod can share files
through a common volume — the sidecar pattern.

**Time:** about 30 minutes.

**Where the outputs come from:** everything in this lab is real output from
this WSL2 kubeadm cluster, captured while building it.

---

## The Big Idea

Every container normally has its own private filesystem, completely
invisible to every other container — even other containers in the same Pod.
A **volume** is the one deliberate exception: it's a directory that one or
more containers in a Pod can mount, so they see the *same* underlying
storage.

This is a second, separate kind of sharing inside a Pod, alongside the
`localhost` network sharing from the networking mind map. Containers in a
Pod already share one IP and one port space (they can call each other on
`localhost:<port>`). Volumes are what let them **share files** the same way.

---

## Part 1: A Single-Container Pod With Its Own Volume

### Step 1: The manifest

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-storage
  labels:
    app: nginx-storage
spec:
  containers:
  - name: nginx
    image: nginx
    ports:
    - containerPort: 80
    volumeMounts:
    - name: scratch-volume
      mountPath: /scratch
  volumes:
  - name: scratch-volume
    emptyDir:
      sizeLimit: 500Mi
```

**The two sections, and how they connect:**

| Section | Level | What it does |
|---|---|---|
| `spec.volumes` | Pod level | **Declares** a volume exists and where its storage comes from |
| `spec.containers[].volumeMounts` | Container level | **Attaches** a declared volume, by name, at a chosen path inside that specific container |

The `name: scratch-volume` in both places is the link. Declare a volume
once in `spec.volumes`, then reference that same name in as many
containers' `volumeMounts` as you want it shared with.

`emptyDir: {}` is the simplest possible volume: kubelet just gives the Pod
a fresh, empty directory on the node. `sizeLimit: 500Mi` isn't a hard
partition — it's a threshold kubelet monitors, and if a container's usage
exceeds it, the **Pod gets evicted**, not a normal "disk full" filesystem
error.

### Step 2: Apply it and confirm the mount

```bash
kubectl apply -f nginx-pod.yaml
kubectl get pods
```

**Output from the real session:**
```
pod/nginx-storage created

NAME                      READY   STATUS    RESTARTS   AGE
mealie-6754cc7b44-dpb2q   1/1     Running   0          44h
nginx-storage             1/1     Running   0          9s
```

```bash
kubectl describe pod nginx-storage
```

**Output from the real session** (relevant sections):
```
Mounts:
  /scratch from scratch-volume (rw)
  /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-rqwfz (ro)
...
Volumes:
  scratch-volume:
    Type:       EmptyDir (a temporary directory that shares a pod's lifetime)
    Medium:
    SizeLimit:  500Mi
```

Two things worth noticing:

- **`(a temporary directory that shares a pod's lifetime)`** is Kubernetes
  telling you directly: this storage exists exactly as long as the Pod
  does. Delete the Pod, and the volume's contents are gone with it —
  `emptyDir` is not persistent storage.
- **The `kube-api-access-...` volume is also listed here.** Every Pod
  automatically gets one of these (a projected volume holding a service
  account token) — you've been looking at this in every `describe pod`
  output since Lab 2 without necessarily connecting it to "this is also
  just a volume."

### Step 3: Look inside

```bash
kubectl exec -it nginx-storage -- bash
ls /
```

**Output from the real session:**
```
bin  boot  dev  docker-entrypoint.d  docker-entrypoint.sh  etc  home  lib  lib64  media  mnt  opt  proc  root  run  sbin  scratch  srv  sys  tmp  usr  var
```

`scratch` sits right there as a normal-looking directory at the container's
root — from inside the container, a mounted volume is indistinguishable
from a regular directory. Nothing about `ls` reveals that `/scratch` is
backed by kubelet-managed storage rather than the container image itself.

---

## Part 2: The Immutability Rule (Hit For Real)

### Step 4: Try to turn it into a two-container Pod

Edit the same file to add a second container, a `busybox` sidecar meant to
write a file for nginx to serve:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-storage
  labels:
    app: nginx-storage
spec:
  containers:
  - name: nginx
    image: nginx
    ports:
    - containerPort: 80
    volumeMounts:
    - name: scratch-volume
      mountPath: /scratch
  - name: busybox
    image: busybox
    command: ["sh", "-c", "echo 'Hello from BusyBox!' > /scratch/busybox/index.html && sleep 3600"]
    volumeMounts:
    - name: scratch-volume
      mountPath: /scratch
    ports:
    - containerPort: 81
    volumeMounts:
    - name: scratch-volume
      mountPath: /scratch
  volumes:
  - name: scratch-volume
    emptyDir:
      sizeLimit: 500Mi
```

```bash
kubectl apply -f nginx-pod.yaml
```

**Output from the real session:**
```
The Pod "nginx-storage" is invalid: spec.containers: Forbidden: pod updates may not add or remove containers
```

**Why this happens:** a Pod's container list is fixed the moment the Pod is
created. You can update some fields *inside* an existing container (its
image, in many Kubernetes versions), but you can never add, remove, or
reorder containers on a live Pod. `kubectl apply` tries to patch the live
object to match your file, sees the container count changed, and refuses
outright rather than doing something destructive silently.

This is the concrete, hands-on version of the "pod spec is largely
immutable" rule from Lab 2 — and it's exactly why Deployments exist. A
Deployment never patches a Pod like this in place; it creates a **new** Pod
(via a new ReplicaSet) and retires the old one, the same rolling-update
mechanism from Lab 5. A bare Pod has no such mechanism, so it just refuses.

### Step 5: The only way forward — delete, then apply

```bash
kubectl delete pod nginx-storage
kubectl apply -f nginx-pod.yaml
kubectl get pods
```

**Expected output:**
```
pod "nginx-storage" deleted
pod/nginx-storage created

NAME            READY   STATUS              RESTARTS   AGE
nginx-storage   0/2     ContainerCreating   0          2s
```

---

## Part 3: Three Real Bugs in the Sidecar Version

The manifest above has three mistakes, found by actually running it. Each
one is worth understanding, not just fixing.

### Bug 1: A duplicated YAML key

```yaml
  - name: busybox
    ...
    volumeMounts:
    - name: scratch-volume
      mountPath: /scratch
    ports:
    - containerPort: 81
    volumeMounts:          # ← the same key, a second time, in the same container
    - name: scratch-volume
      mountPath: /scratch
```

YAML mappings don't merge repeated keys — the parser silently keeps the
**last** one and discards the first. Nothing here errors, because both
copies happen to say the same thing, which makes this trap easy to miss:
if the two ever disagreed, the first would vanish with no warning from
`kubectl apply` at all.

### Bug 2: Writing to a directory that doesn't exist

```bash
kubectl get pods
kubectl logs nginx-storage -c busybox
```

**Expected output:**
```
NAME            READY   STATUS             RESTARTS   AGE
nginx-storage   1/2     CrashLoopBackOff   1          8s
```
```
sh: can't create /scratch/busybox/index.html: No such file or directory
```

The command was:
```bash
echo 'Hello from BusyBox!' > /scratch/busybox/index.html && sleep 3600
```

`/scratch` exists (that's the mounted volume), but `/scratch/busybox/`
does not — an `emptyDir` only guarantees the mount point itself, not any
subdirectories inside it. Because the two commands are joined with `&&`,
the failed `echo` short-circuits the whole line, so `sleep 3600` never
runs and the container exits immediately — which is why it crash-loops.

### Bug 3: Writing where nginx never looks

Even with the path fixed to `/scratch/index.html`, nginx still won't serve
it. Nginx's actual document root is `/usr/share/nginx/html`, not
`/scratch`. Two containers mounting the same volume at the *same path*
(`/scratch`) doesn't connect that volume to nginx's web root — for nginx to
serve shared content, **nginx's own mount** has to point at the shared
volume from nginx's side.

### The corrected manifest

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-storage
  labels:
    app: nginx-storage
spec:
  containers:
  - name: nginx
    image: nginx
    ports:
    - containerPort: 80
    volumeMounts:
    - name: scratch-volume
      mountPath: /usr/share/nginx/html   # nginx's real document root
  - name: busybox
    image: busybox
    command: ["sh", "-c", "echo 'Hello from BusyBox!' > /scratch/index.html && sleep 3600"]
    volumeMounts:
    - name: scratch-volume
      mountPath: /scratch
  volumes:
  - name: scratch-volume
    emptyDir:
      sizeLimit: 500Mi
```

Note the duplicate `ports`/`volumeMounts` block under `busybox` is gone
entirely — a sidecar that only writes a file doesn't need to expose a port.

---

## Part 4: Verify the Sidecar Pattern Actually Works

```bash
kubectl delete pod nginx-storage
kubectl apply -f nginx-pod.yaml
kubectl get pods -w
```

**Output from the real session:**
```
NAME            READY   STATUS    RESTARTS   AGE
nginx-storage   2/2     Running   0          13m
```

`2/2` — both containers up, no crash-loop this time.

```bash
kubectl exec nginx-storage -c nginx -- curl -s localhost
```

**Output from the real session:**
```
Hello from BusyBox!
```

This is the whole point, proven: **busybox wrote a file into the shared
volume, and nginx served that exact content from its own document root** —
two containers, two completely separate container filesystems, connected
only through the one thing they both explicitly chose to mount.

### Confirm the isolation is still real everywhere else

```bash
kubectl exec nginx-storage -c busybox -- ls /usr/share/nginx/html
```

**Expected output:**
```
ls: /usr/share/nginx/html: No such file or directory
```

Busybox has no idea that path exists — it only mounted the volume at
`/scratch`. **Only the volume's contents are shared**, not each container's
entire filesystem. This is the important boundary: sharing is opt-in, and
scoped to exactly the mount points each container declares.

### Confirm `emptyDir` really doesn't persist

```bash
kubectl delete pod nginx-storage
kubectl apply -f nginx-pod.yaml
kubectl wait --for=condition=Ready pod/nginx-storage --timeout=30s
kubectl exec nginx-storage -c nginx -- curl -s localhost
```

**Expected output:**
```
Hello from BusyBox!
```

It still says the same thing — but **not** because the old volume
survived. The Pod was fully deleted and recreated, which means the old
`emptyDir` was destroyed along with it, and busybox's startup command wrote
the identical text fresh into a **brand-new** empty directory in the new
Pod. If busybox's command wrote something different, that's what you'd see
here instead — proof the storage is genuinely new every time, not
persisting across Pod recreation.

---

## Key Takeaways

1. **A volume is declared once, at the Pod level (`spec.volumes`), and mounted per-container (`volumeMounts`)**, linked by a shared `name`.
2. **`emptyDir` is the simplest volume type** — a fresh, empty directory that lives exactly as long as the Pod. Deleting the Pod destroys it.
3. **A Pod's container list is fixed at creation.** You cannot add or remove containers with `kubectl apply` on a live Pod — you must delete and recreate it. This is exactly why Deployments (which handle that delete/recreate cycle safely) exist.
4. **Repeated YAML keys silently collide.** The parser keeps only the last one, with no warning.
5. **An `emptyDir` mount point exists, but subdirectories inside it don't** — a container writing to a nested path must create that path itself first.
6. **Mounting the same volume at the same path in two containers doesn't connect it to what either container "does" with that path** — nginx only serves from `/usr/share/nginx/html`, so that's specifically where the shared volume needs to be mounted on nginx's side.
7. **Sharing between containers is scoped to the mount, not the whole filesystem.** Each container only sees the paths it explicitly mounted; everything else stays private, exactly like the network-namespace isolation from the Pods branch of the networking mind map.

---

## Command Reference

```bash
# Apply a Pod with a volume
kubectl apply -f nginx-pod.yaml

# Inspect the volume and its mount
kubectl describe pod <pod-name>

# Look inside a container
kubectl exec -it <pod-name> -- bash
kubectl exec <pod-name> -c <container-name> -- <command>

# Check a specific container's logs (multi-container pod)
kubectl logs <pod-name> -c <container-name>

# The only way to change a Pod's container list
kubectl delete pod <pod-name>
kubectl apply -f <file>
```
