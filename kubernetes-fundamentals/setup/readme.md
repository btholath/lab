# Setting Up a Kubernetes Cluster on WSL2 — Beginner's Guide

This is a **linear, step-by-step walkthrough** for setting up a single-node Kubernetes cluster on WSL2 (Ubuntu 24.04), using two automation scripts. It's written for someone doing this for the first time — follow it top to bottom, run each command block, and compare your output to the "Expected output" shown after each one.

**What you'll end up with:** a working Kubernetes v1.35 cluster running locally inside WSL2, with Calico networking, ready for hands-on practice.

**Two scripts do the heavy lifting:**

- `install_k8s_stack.sh` — installs Docker, containerd, kubelet, kubeadm, kubectl, and Kind
- `bootstrap_cluster.sh` — initializes the actual Kubernetes cluster and installs networking

Both scripts are **safe to run more than once** — if something goes wrong partway through, you can just run the same script again.

---

## Step 0: Prerequisites

Before starting, make sure you have:

- Windows 10/11 with WSL2 installed, running **Ubuntu 24.04 LTS**
- At least 4 CPUs and 6 GB RAM allocated to WSL2 (8+ recommended)
- A working internet connection inside WSL2

---

## Step 1: Download the scripts

```bash
mkdir -p ~/kcsa/setup
cd ~/kcsa/setup

wget https://raw.githubusercontent.com/btholath/lab/main/kubernetes-fundamentals/setup/install_k8s_stack.sh
wget https://raw.githubusercontent.com/btholath/lab/main/kubernetes-fundamentals/setup/bootstrap_cluster.sh

chmod +x install_k8s_stack.sh bootstrap_cluster.sh
```

**Expected output:** two files downloaded successfully, no errors. Run `ls -la` to confirm both scripts are present and executable (`-rwxr-xr-x`).

---

## Step 2: Pre-Flight Validation

Before running any script, confirm your WSL2 environment is actually ready for Kubernetes. These checks catch the most common setup problems _before_ they cause a confusing failure mid-install.

### 2.1 Is systemd running?

```bash
ps --pid 1 -o comm=
```

**Expected output:**

```
systemd
```

If you see anything else (like `init`), stop here — add this to `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then from **PowerShell** (not WSL): `wsl --shutdown`, reopen your Ubuntu terminal, and re-run this check.

### 2.2 What kernel version do you have?

```bash
uname -r
```

**Expected output (example):**

```
6.6.87.2-microsoft-standard-WSL2
```

Any recent `6.x` kernel is fine. If yours looks much older, update it from PowerShell with `wsl --update`.

### 2.3 Kernel modules and cgroup version

```bash
sudo modprobe overlay && echo "overlay OK"
sudo modprobe br_netfilter && echo "br_netfilter OK"
lsmod | grep -E 'overlay|br_netfilter'

stat -fc %T /sys/fs/cgroup/

sudo sysctl net.bridge.bridge-nf-call-iptables
```

**Expected output:**

```
overlay OK
br_netfilter OK
br_netfilter           28672  0
bridge                282624  1 br_netfilter
cgroup2fs
net.bridge.bridge-nf-call-iptables = 1
```

This is the single most important check — if `cgroup2fs` or the sysctl line don't appear, run `wsl --update` from PowerShell and try again before proceeding.

### 2.4 Check for a Docker Desktop conflict

```bash
which docker
docker context ls 2>/dev/null
```

You might see `desktop-linux`/`desktop-windows` contexts listed even if you've never used them directly — that's normal if Docker Desktop is installed on Windows at all. What matters is whether it's actually intercepting _this_ WSL distro. Check:

```bash
sudo systemctl status docker 2>&1 | head -5
sudo systemctl status containerd 2>&1 | head -5
docker version --format '{{.Server.Platform.Name}}'
```

**Good expected output:**

```
● docker.service - Docker Application Container Engine
     Loaded: loaded (/usr/lib/systemd/system/docker.service; enabled; preset: enabled)
     Active: active (running) ...
● containerd.service - containerd container runtime
     Loaded: loaded (/usr/lib/systemd/system/containerd.service; enabled; preset: enabled)
     Active: active (running) ...
Docker Engine - Community
```

Seeing `docker.service`/`containerd.service` as real systemd units, and `Docker Engine - Community` (not "Docker Desktop"), means you're running a native Docker install — exactly what the install script expects. No action needed.

### 2.5 Resources, network, swap, DNS

```bash
free -h
nproc
hostname -I
swapon --show
nslookup google.com
```

**What to look for:**

- `free -h` → several GB free RAM
- `nproc` → 2 or more CPUs
- `hostname -I` → your first address (e.g. `192.168.155.98`) is your real WSL2 IP — the rest (`172.x.x.x`) are Docker's own internal bridge networks, ignore those
- `swapon --show` → ideally empty. If it shows a device, that's fine for now — the install script disables it automatically — but for a permanent fix, add this to `%UserProfile%\.wslconfig` on the **Windows** side:

  ```ini
  [wsl2]
  swap=0
  ```

  then run `wsl --shutdown` from PowerShell.

- `nslookup google.com` → should resolve to a real IP address with no errors

If every check above looks reasonable, you're ready to move on.

---

## Step 3: Run the Install Script

```bash
sudo ./install_k8s_stack.sh
```

This installs Docker, containerd, kubelet, kubeadm, kubectl, and Kind — 8 steps, each printed as it runs. **On a machine that already has some of this installed, most steps will show `[SKIP]` — that's expected and correct, not an error.**

**Expected output (example — yours may show `[DOING]`/`[FIXED]` instead of `[SKIP]` on a completely fresh machine):**

```
==========================================
 Kubernetes 1.35 Stack Installer (idempotent)
==========================================

[STEP 1/8] Pre-flight checks (systemd, kernel modules, cgroup v2, sysctl)
  [OK]   systemd is PID 1
  [SKIP] overlay filesystem support already active (already satisfied)
  [SKIP] br_netfilter module already loaded (already satisfied)
  [OK]   cgroup v2 active
  [OK]   bridge netfilter sysctl available

[STEP 2/8] System dependencies (apt packages)
  [SKIP] all base dependencies already installed (already satisfied)

[STEP 3/8] Kernel modules / sysctl persistence + swap
  [SKIP] /etc/modules-load.d/k8s.conf already correct (already satisfied)
  [SKIP] /etc/sysctl.d/k8s.conf already correct (already satisfied)
  [SKIP] swap already off (already satisfied)

[STEP 4/8] Docker Engine
  [SKIP] native Docker Engine already installed and running (Docker version 29.2.1, build a5c7197) (already satisfied)
  [SKIP] root already in docker group (already satisfied)

[STEP 5/8] containerd configuration (systemd cgroups + CRI enabled)
  [SKIP] containerd already configured correctly (CRI enabled, systemd cgroups) (already satisfied)

[STEP 6/8] kubelet, kubeadm, kubectl (pinned to 1.35.x)
  [SKIP] Kubernetes 1.35 apt repository already configured (already satisfied)
  [SKIP] kubelet/kubeadm/kubectl already at pinned version 1.35.6-1.1 (already satisfied)
  [SKIP] kubelet/kubeadm/kubectl already held (already satisfied)
  [SKIP] kubelet already enabled (already satisfied)

[STEP 7/8] Kind (optional lightweight alternative)
  [SKIP] Kind already at v0.26.0 (already satisfied)

[STEP 8/8] Verification summary
------------------------------------------------
Docker Version:   Docker version 29.2.1, build a5c7197
Kind Version:     kind version 0.26.0
Kubeadm Version:  v1.35.6
Kubectl Version:    gitVersion: v1.36.2
------------------------------------------------

Installation check complete. Safe to re-run this script any time.
Next: ./bootstrap_cluster.sh for a full kubeadm cluster,
      OR 'kind create cluster --image kindest/node:v1.35.0' for Kind.
```

If any step shows `[FAIL]`, stop and read the message — it will tell you exactly what to fix (usually something from Step 2 above).

> **Note:** don't worry if `Kubectl Version` shows a slightly different version number than `Kubeadm Version` (e.g. `v1.36.2` vs `v1.35.6`) — this can happen if another `kubectl` binary is earlier on your system's `$PATH`. It won't stop the cluster from working; it's just worth being aware of.

### 3.1 Apply group membership change

The install script added you to the `docker` group, but this only takes effect in a **new** shell session:

```bash
newgrp docker
docker ps
```

**Expected output:** an empty table header (no containers running yet) with **no permission error**:

```
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

### 3.2 Quick sanity check before moving on

```bash
sudo grep -A1 disabled_plugins /etc/containerd/config.toml
sudo grep SystemdCgroup /etc/containerd/config.toml
sudo systemctl is-active kubelet containerd docker
```

**What to look for:** `disabled_plugins = []` (empty list — CRI is enabled), `SystemdCgroup = true` present somewhere in the file, and all three services reporting `active`.

---

## Step 4: Run the Bootstrap Script

```bash
sudo ./bootstrap_cluster.sh
```

This actually creates the Kubernetes cluster: initializes the control plane, installs Calico networking, sets up your `kubectl` configuration, and prepares the node to run workloads. It prints 7 steps.

**What to watch for as it runs:**

- Early on it prints the **advertise address** it detected (e.g. `192.168.155.98`) — this should be your real WSL2 IP from Step 2.5, not one of the `172.x.x.x` Docker addresses
- The Calico installation step can take a minute or two — this is normal
- At the end it shows your node list and full pod list

**Expected final output (abbreviated):**

```
------------------------------------------------
NAME   STATUS   ROLES           AGE   VERSION
b      Ready    control-plane   1m    v1.35.6
------------------------------------------------
NAMESPACE          NAME                              READY   STATUS    RESTARTS   AGE
kube-system        coredns-...                       1/1     Running   0          1m
kube-system        etcd-b                            1/1     Running   0          1m
kube-system        kube-apiserver-b                  1/1     Running   0          1m
kube-system        kube-controller-manager-b         1/1     Running   0          1m
kube-system        kube-proxy-...                    1/1     Running   0          1m
kube-system        kube-scheduler-b                  1/1     Running   0          1m
calico-system      calico-node-...                   1/1     Running   0          1m
calico-system      calico-kube-controllers-...        1/1     Running   0          1m
...
tigera-operator    tigera-operator-...                1/1     Running   0          1m
------------------------------------------------

Bootstrap check complete. Safe to re-run this script any time.
Verify with: export KUBECONFIG=/home/youruser/.kube/config && kubectl get nodes
```

The key thing to confirm: your node's `STATUS` column says **`Ready`**. If it says `NotReady`, give it another minute or two (Calico can take a little while to fully settle) and check again with `kubectl get nodes`.

If the script reports pods stuck on the wrong network or not becoming ready, it will attempt to fix this automatically (you'll see a `[WARN]` followed by `[FIXED]` in the output) — this is a known WSL2 timing quirk with Calico's networking setup, and the script handles it without you needing to do anything.

---

## Step 5: Verify Everything Works

This is the real proof that your cluster is genuinely working end-to-end — not just "the scripts ran without errors."

### 5.1 Check the node is Ready

```bash
kubectl get nodes
```

**Expected output:**

```
NAME   STATUS   ROLES           AGE     VERSION
b      Ready    control-plane   3h32m   v1.35.6
```

### 5.2 Run a real workload

```bash
kubectl run nginx --image=nginx
```

**Expected output:**

```
pod/nginx created
```

Check that it actually started:

```bash
kubectl get pods
```

**Expected output:**

```
NAME    READY   STATUS    RESTARTS   AGE
nginx   1/1     Running   0          24s
```

`1/1 Running` means the container is genuinely up and healthy — this confirms scheduling, image pulling, and container runtime are all working together correctly.

Clean it up:

```bash
kubectl delete pod nginx
```

**Expected output:**

```
pod "nginx" deleted
```

### 5.3 Confirm Docker itself is working

```bash
docker ps
```

**Expected output:** an empty container list (Kubernetes manages its containers through containerd directly, not through the `docker` CLI, so this being empty is normal and expected):

```
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

### 5.4 Explore the cluster's namespaces

```bash
kubectl get namespaces
```

**Expected output:**

```
NAME              STATUS   AGE
calico-system     Active   7h9m
default           Active   7h22m
kube-node-lease   Active   7h22m
kube-public       Active   7h22m
kube-system       Active   7h22m
tigera-operator   Active   7h22m
```

Each of these holds a different piece of the cluster: `kube-system` is core Kubernetes components, `calico-system`/`tigera-operator` are your networking layer, `default` is where your own workloads land unless you specify otherwise.

### 5.5 (Optional) Peek at Calico's network policies

This is a nice way to see that Calico is doing real security enforcement, not just providing pod networking:

```bash
kubectl get netpol -n calico-system
```

**Expected output:**

```
NAME              POD-SELECTOR                      AGE
allow-apiserver   apiserver=true                    8h
goldmane          app.kubernetes.io/name=goldmane   8h
whisker           app.kubernetes.io/name=whisker    8h
```

Look at one in detail:

```bash
kubectl describe netpol allow-apiserver -n calico-system
```

**Expected output:**

```
Name:         allow-apiserver
Namespace:    calico-system
Spec:
  PodSelector:     apiserver=true
  Allowing ingress traffic:
    To Port: 5443/TCP
    From: <any> (traffic not restricted by source)
  Not affecting egress traffic
  Policy Types: Ingress
```

This is a real NetworkPolicy object — the same kind of resource you'll create yourself when studying Kubernetes network security concepts.

---

## ✅ You're Done

If Steps 5.1–5.4 all matched their expected output, you have a genuinely working single-node Kubernetes cluster running on WSL2:

- ✅ Node is `Ready`
- ✅ Workloads schedule and run successfully
- ✅ Calico networking and policies are active
- ✅ `kubectl` is correctly and automatically wired to your cluster (via `~/.kube/config`)

Both scripts can be safely re-run at any time — after a WSL restart, after a reboot, or just to double-check everything is still healthy. Neither will reinstall anything unnecessarily or damage a working setup.

---

## If Something Goes Wrong

- **Script fails at a `[FAIL]` line** → the message tells you exactly what to check; almost always traces back to something in Step 2.
- **`kubectl get nodes` hangs or refuses connection** → most commonly caused by WSL2 re-enabling swap after a restart. Fix: `sudo swapoff -a && sudo systemctl restart kubelet`.
- **Pods stuck in `CrashLoopBackOff` right after bootstrap** → re-run `sudo ./bootstrap_cluster.sh` — its self-heal step catches the most common cause automatically.
- **`kubeadm init` fails with "already exists"** → you're re-running against a partially broken previous attempt. Clean up first: `sudo kubeadm reset -f`, then re-run `bootstrap_cluster.sh`.

For anything not covered here, the fix almost always involves re-running the relevant script — both are designed to safely pick up where a previous attempt left off.
