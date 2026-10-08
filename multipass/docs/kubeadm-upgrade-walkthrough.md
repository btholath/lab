# Upgrading a kubeadm cluster, step by step

## A real upgrade from Kubernetes v1.35.9 to v1.36.5, with the console output and what it means

This document walks through one complete upgrade of a three-node kubeadm cluster, in the order it was done. Every console block was captured from the real run. Each one is followed by an explanation of what it shows and why the step exists. The mistakes and surprises that happened along the way are included on purpose, because they teach as much as the commands.

**Contents**

1. How to read this document
2. The big picture
3. The lab and its starting state
4. What each pod does
5. Phase 0: pre-flight checks and a backup
6. Phase 1: new packages and the upgrade plan
7. Phase 2: pre-pulling the images
8. Phase 3: upgrading the control plane (`kubeadm upgrade apply`)
9. Phase 4: upgrading the master's kubelet and kubectl
10. Phase 5: upgrading worker1
11. Phase 6: upgrading worker2
12. Phase 7: verification, rebalancing and certificates
13. Timeline: what changed when
14. Mistakes and lessons
15. Troubleshooting guide
16. Rollback: what is and is not possible
17. Checklist
18. Command reference
19. Glossary
20. What was not tested

---

# 1. How to read this document

## The environment

| Item | Value |
|---|---|
| Cluster | 1 control plane (`master`) + 2 workers (`worker1`, `worker2`) built with kubeadm |
| Machines | Three Multipass virtual machines on a Windows laptop, Hyper-V driver, Ubuntu 24.04 |
| Starting version | Kubernetes v1.35.9, etcd 3.6.6, containerd 2.2.1 |
| Target version | Kubernetes v1.36.5 |
| Pod network | flannel (installed separately, not managed by kubeadm) |
| Master address | A fixed address `172.25.246.7` added next to its DHCP address |

## Which window a command runs in

Commands in this document run in one of three places. Mixing them up caused several errors in the real run (see Section 14).

| Prompt | Where you are | What runs there |
|---|---|---|
| `PS C:\Users\...>` | Windows PowerShell | Anything starting with `multipass`, and `multipass exec master -- kubectl ...` |
| `ubuntu@master:~$` | Inside the master VM (after `multipass shell master`) | Plain `kubectl`, `kubeadm`, `apt`, `etcdctl` |
| `ubuntu@worker1:~$` / `ubuntu@worker2:~$` | Inside a worker VM | `apt`, `kubeadm upgrade node`, `systemctl` |

> **Rule of thumb:** a command that starts with `multipass` only exists on Windows. A command with `~`, `$(...)`, `&&` or a pipe to a Linux tool belongs inside a VM shell. Never type plain `kubectl` in Windows PowerShell for this cluster, because the Windows `kubectl` points at a different cluster.

## About the console output

Outputs are copied from the run. Long, repetitive parts (package download lines, banners) are shortened and marked `[...]`. Private lab addresses such as `172.25.x.x` are left in, because they show how the pieces connect. They are not reachable from outside the lab.

---

# 2. The big picture

## The rules of a kubeadm upgrade

| Rule | Why |
|---|---|
| **One minor version at a time** (1.35 to 1.36 to 1.37) | kubeadm supports upgrading only to the next minor version, or to a newer patch inside the same minor. You cannot skip a minor |
| **Control plane first, workers after** | The API server must be at the same or a newer version than every kubelet |
| **Workers one at a time** | The cluster keeps serving traffic while one node at a time is out of rotation |
| **Kubelets may lag the control plane** | The cluster works in a mixed-version state while you are partway through |
| **Drain a node before upgrading its kubelet** | The official docs require it for a minor-version upgrade. A new kubelet can restart containers, so the pods should be moved away first |
| **Match kubeadm and kubelet versions** | Recommended by the project |

## The order of operations

```text
 1. Back up etcd                         (safety net)
 2. Point apt at the new version         (every node, before using its packages)
 3. Install the new kubeadm on the master
 4. kubeadm upgrade plan                 (read-only preview)
 5. Pre-pull the new images              (avoid slow downloads during the upgrade)
 6. kubeadm upgrade apply  <master>      (replaces etcd, API server, controller manager, scheduler, CoreDNS, kube-proxy)
 7. drain master -> upgrade kubelet+kubectl -> restart kubelet -> uncordon master
 8. For each worker, one at a time:
        install new kubeadm  ->  kubeadm upgrade node  ->  drain  ->
        upgrade kubelet+kubectl  ->  restart kubelet  ->  uncordon
 9. Verify, rebalance, check certificates
```

## What gets upgraded, and by whom

| Component | Upgraded by | Notes |
|---|---|---|
| kube-apiserver, kube-controller-manager, kube-scheduler | `kubeadm upgrade apply` | Static pods: kubeadm rewrites their manifest files and the kubelet restarts them |
| etcd | `kubeadm upgrade apply` | Upgraded only if the new release ships a different etcd version (here 3.6.6 to 3.6.8) |
| CoreDNS, kube-proxy | `kubeadm upgrade apply` | Add-ons that kubeadm manages |
| kubelet, kubectl | **You**, with apt, on every node | kubeadm only upgrades the kubelet's *configuration* (`kubeadm upgrade node`) |
| flannel | **Nobody, in this upgrade** | Installed separately, so it has its own release cycle |

## What `kubectl get nodes` shows at each stage

The `VERSION` column in `kubectl get nodes` is the **kubelet** version, not the API server's. This confuses almost everyone the first time. It is why the nodes still say `v1.35.9` right after the control plane is upgraded.

| Stage | API server | master kubelet | worker1 kubelet | worker2 kubelet |
|---|---|---|---|---|
| Before | 1.35.9 | 1.35.9 | 1.35.9 | 1.35.9 |
| After `kubeadm upgrade apply` | **1.36.5** | 1.35.9 | 1.35.9 | 1.35.9 |
| After the master's kubelet upgrade | 1.36.5 | **1.36.5** | 1.35.9 | 1.35.9 |
| After worker1 | 1.36.5 | 1.36.5 | **1.36.5** | 1.35.9 |
| After worker2 | 1.36.5 | 1.36.5 | 1.36.5 | **1.36.5** |

---

# 3. The lab and its starting state

## Cluster health before touching anything

Never start an upgrade on a cluster that is already unhealthy. These commands only read.

**Run in: Windows PowerShell**

```powershell
multipass exec master -- kubectl get nodes -o wide
multipass exec master -- kubectl get pods -A
```

```text
NAME      STATUS   ROLES           AGE   VERSION   INTERNAL-IP      EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
master    Ready    control-plane   41h   v1.35.9   172.25.246.7     <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic   containerd://2.2.1
worker1   Ready    worker          38h   v1.35.9   172.25.253.184   <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic   containerd://2.2.1
worker2   Ready    worker          38h   v1.35.9   172.25.252.5     <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic   containerd://2.2.1

NAMESPACE      NAME                             READY   STATUS    RESTARTS       AGE
default        nginx-758ff947b-kxp8r            1/1     Running   2 (16h ago)    20h
default        nginx-758ff947b-r7qgc            1/1     Running   2 (16h ago)    20h
default        nginx-758ff947b-w6pcr            1/1     Running   2 (16h ago)    20h
default        nginx-758ff947b-zrh2k            1/1     Running   2 (16h ago)    20h
kube-flannel   kube-flannel-ds-2sz9k            1/1     Running   2 (16h ago)    39h
kube-flannel   kube-flannel-ds-dszmf            1/1     Running   2 (16h ago)    39h
kube-flannel   kube-flannel-ds-mjmv8            1/1     Running   3 (16h ago)    23h
kube-system    coredns-7d764666f9-gr9t7         1/1     Running   2 (16h ago)    41h
kube-system    coredns-7d764666f9-q8bxf         1/1     Running   2 (16h ago)    41h
kube-system    etcd-master                      1/1     Running   0              41h
kube-system    kube-apiserver-master            1/1     Running   20 (15h ago)   41h
kube-system    kube-controller-manager-master   1/1     Running   3 (15h ago)    41h
kube-system    kube-proxy-d26vs                 1/1     Running   2 (16h ago)    39h
kube-system    kube-proxy-pzt5k                 1/1     Running   3 (16h ago)    39h
kube-system    kube-proxy-vch6x                 1/1     Running   2 (16h ago)    41h
kube-system    kube-scheduler-master            1/1     Running   3 (15h ago)    41h
```

### What to look for

- **All three nodes `Ready`**, all on `v1.35.9`. That is the baseline.
- **Every pod `Running`.** No `CrashLoopBackOff` and no `Pending`.
- **Restart counts that are old, not recent.** `kube-apiserver-master` shows 20 restarts, but the last was 15 hours earlier. Those restarts came from an earlier outage (the master's address went missing, and etcd could not start), and it has been stable since. A restart count that is still climbing would be a reason to stop.
- **The master's `INTERNAL-IP` is its fixed address** (`172.25.246.7`). The control plane binds to that address, so it must exist before you upgrade.

---

# 4. What each pod does

Understanding the pods shows what the upgrade touches and what it leaves alone.

## The control plane (static pods on the master)

These four pods are **static pods**. The kubelet starts them from YAML files in `/etc/kubernetes/manifests`, which is why their names end in the node name. The upgrade works by replacing those files.

```powershell
multipass exec master -- ls /etc/kubernetes/manifests
```

```text
etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

| Pod | Role |
|---|---|
| `kube-apiserver-master` | The front door. Every `kubectl` command and every component talks to it. It is the only component that reads and writes etcd |
| `etcd-master` | The database that stores every object in the cluster |
| `kube-scheduler-master` | Chooses which node a new pod runs on |
| `kube-controller-manager-master` | Runs the control loops that keep reality matching what you asked for, such as recreating a missing pod |

## Add-ons

| Pod | Kind | Role | Upgraded by |
|---|---|---|---|
| `kube-proxy-*` (3) | DaemonSet, one per node | Turns Services into network rules on each node | `kubeadm upgrade apply` |
| `coredns-*` (2) | Deployment | Cluster DNS | `kubeadm upgrade apply` |
| `kube-flannel-ds-*` (3) | DaemonSet, one per node | The pod network | Not touched |

## Your workload and the node services

| Item | Role |
|---|---|
| `nginx-*` (4) | The practice Deployment. Not part of Kubernetes |
| kubelet | A system service on every node (not a pod). Starts and watches pods |
| containerd | A system service on every node. Runs the containers |

---

# 5. Phase 0: pre-flight checks and a backup

## 5.1 Record the state and take an etcd snapshot

etcd holds everything. A snapshot taken before the upgrade is your way back if something goes badly wrong.

**Run in: master VM** (`multipass shell master`)

```bash
kubeadm version -o short
kubectl version
kubectl get pods -A -o wide > ~/pods-before-upgrade.txt

EC="sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"
sudo mkdir -p /opt/etcd-backup
SNAP=/opt/etcd-backup/pre-upgrade-$(date +%Y%m%d-%H%M%S).db
$EC snapshot save $SNAP
sudo etcdutl snapshot status $SNAP --write-out=table
```

```text
v1.35.9
Client Version: v1.35.9
Kustomize Version: v5.7.1
Server Version: v1.35.9
{"level":"info","ts":"2026-10-07T09:41:16.457422-0700","caller":"snapshot/v3_snapshot.go:83","msg":"created temporary db file","path":"/opt/etcd-backup/pre-upgrade-20261007-094116.db.part"}
[...]
{"level":"info","ts":"2026-10-07T09:41:16.501218-0700","caller":"snapshot/v3_snapshot.go:121","msg":"saved","path":"/opt/etcd-backup/pre-upgrade-20261007-094116.db"}
Snapshot saved at /opt/etcd-backup/pre-upgrade-20261007-094116.db
Server version 3.6.0
+----------+----------+------------+------------+---------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE | VERSION |
+----------+----------+------------+------------+---------+
| 42f2e6e9 |  1036435 |        313 |     3.7 MB |   3.6.0 |
+----------+----------+------------+------------+---------+
```

### Explanation

| Output | Meaning |
|---|---|
| `v1.35.9` (kubeadm) and `Client`/`Server Version: v1.35.9` | Everything starts at the same version |
| `Snapshot saved at ...` | etcd streamed a consistent copy of its data to a file |
| `HASH 42f2e6e9` | An integrity checksum. A restore refuses a file that does not match |
| `REVISION 1036435` | etcd's change counter. It is high because an earlier restore exercise deliberately raised it by one million |
| `TOTAL KEYS 313`, `TOTAL SIZE 3.7 MB` | The amount of data in the cluster |
| The `etcd-version: 3.6.0` in the JSON log and `VERSION 3.6.0` in the table | Most likely the snapshot's data format version, which appears to stay at 3.6.0 across 3.6 patch releases (not verified). The server itself is 3.6.6 |

The `etcdutl snapshot status` check is not optional. A snapshot that fails it cannot be restored.

## 5.2 Copy the snapshot off the VM and prove the copy is intact

A backup that lives only on the machine you may have to rebuild is not a backup.

**Run in: master VM**

```bash
sudo cp $SNAP /home/ubuntu/pre-upgrade.db && sudo chown ubuntu:ubuntu /home/ubuntu/pre-upgrade.db
exit
```

**Run in: Windows PowerShell**

```powershell
multipass transfer master:/home/ubuntu/pre-upgrade.db $HOME\etcd-backups\pre-upgrade.db
Get-FileHash $HOME\etcd-backups\pre-upgrade.db -Algorithm SHA256
multipass exec master -- sha256sum /home/ubuntu/pre-upgrade.db
```

```text
[2026-10-07T09:50:24.829] [error] [sftp] cannot set permissions for local file C:\Users\bijut\etcd-backups\pre-upgrade.db

SHA256          6845DF06EC3497E738B8D11E293BF7BFA9EAFC129B531ACD799D49CAE8C22185

6845df06ec3497e738b8d11e293bf7bfa9eafc129b531acd799d49cae8c22185  /home/ubuntu/pre-upgrade.db
```

### Explanation

- The two hashes are **identical** (Windows prints capitals, Linux lowercase). That proves the copy on Windows is an exact copy of the snapshot on the master.
- The `cannot set permissions` error is harmless. Windows cannot store Unix permissions, so Multipass's attempt to set them fails after the data has already been copied. The matching hash is the proof.
- **A snapshot contains every Secret in the cluster, unencrypted.** Keep it out of Git and out of screenshots.

## 5.3 A note on kubeadm's own backups

kubeadm also saves the manifests it replaces under `/etc/kubernetes/tmp/` (you will see the paths in Phase 3). In this run, the `upgrade apply` output showed backups of the **manifests only**, with no line about backing up the etcd data directory. That makes your snapshot the real safety net. You can look at what is there:

```bash
sudo ls /etc/kubernetes/tmp
```

---

# 6. Phase 1: new packages and the upgrade plan

## 6.1 Point apt at the new minor version

Each Kubernetes minor version has its own package repository. Upgrading to 1.36 means changing the repository line from `v1.35` to `v1.36`.

**Run in: master VM**

```bash
sudo sed -i 's#/core:/stable:/v1.35/#/core:/stable:/v1.36/#g' /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo apt-get update
VER=$(apt-cache madison kubeadm | awk '{print $3}' | grep '^1\.36\.' | sort -V | tail -1)
echo "package version: $VER"
TARGET=v${VER%%-*}
echo "target: $TARGET"
```

```text
Get:3 https://prod-cdn.packages.k8s.io/repositories/isv:/kubernetes:/core:/stable:/v1.36/deb  InRelease [1227 B]
Get:6 https://prod-cdn.packages.k8s.io/repositories/isv:/kubernetes:/core:/stable:/v1.36/deb  Packages [9460 B]
[...]
Fetched 7593 kB in 22s (353 kB/s)
Reading package lists... Done
package version: 1.36.5-1.1
target: v1.36.5
```

### Explanation

| Command | Purpose |
|---|---|
| `sed -i ...` | Switches the repository from 1.35 to 1.36. The `#` is the sed delimiter, because the pattern contains `/` |
| `curl ... Release.key \| gpg --dearmor ...` | Refreshes the signing key for the new repository. Harmless if the key is unchanged |
| `apt-cache madison kubeadm` | Lists every available kubeadm version. The pipeline picks the **newest 1.36.x** |
| `echo "package version"` | `1.36.5-1.1` is the apt package version (the `-1.1` is the packaging revision) |
| `TARGET=v${VER%%-*}` | Strips everything from the first `-`, giving `v1.36.5`, the Kubernetes version kubeadm expects |

Why read the version from apt instead of a web page? In this run, different websites listed different latest patch numbers for 1.36. The repository is what you will actually install, so it is the only reliable source.

## 6.2 Install only kubeadm

The three packages are **held** so that a routine `apt upgrade` cannot move them by accident. To change one deliberately, you unhold it, install it, and hold it again.

```bash
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=$VER
sudo apt-mark hold kubeadm
kubeadm version -o short
```

```text
Canceled hold on kubeadm.
[...]
The following packages will be upgraded:
  kubeadm
1 upgraded, 0 newly installed, 0 to remove and 11 not upgraded.
Need to get 12.6 MB of archives.
Get:1 https://prod-cdn.packages.k8s.io/repositories/isv:/kubernetes:/core:/stable:/v1.36/deb  kubeadm 1.36.5-1.1 [12.6 MB]
Unpacking kubeadm (1.36.5-1.1) over (1.35.9-1.1) ...
Setting up kubeadm (1.36.5-1.1) ...
kubeadm set on hold.
v1.36.5
```

`kubeadm` is now `v1.36.5`, but **nothing in the cluster has changed yet**. kubeadm is only a command-line tool. The running cluster is still entirely on 1.35.9.

## 6.3 Read the plan

```bash
sudo kubeadm upgrade plan
```

```text
[preflight] Running pre-flight checks.
[upgrade/config] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[upgrade/config] Use 'kubeadm init phase upload-config kubeadm --config your-config-file' to re-upload it.
[upgrade] Running cluster health checks
[upgrade] Fetching available versions to upgrade to
[upgrade/versions] Cluster version: 1.35.9
[upgrade/versions] kubeadm version: v1.36.5
I1007 09:42:49.739721   51657 version.go:260] remote version is much newer: v1.37.1; falling back to: stable-1.36
[upgrade/versions] Target version: v1.36.5
[upgrade/versions] Latest version in the v1.35 series: v1.35.9

Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   NODE      CURRENT   TARGET
kubelet     master    v1.35.9   v1.36.5
kubelet     worker1   v1.35.9   v1.36.5
kubelet     worker2   v1.35.9   v1.36.5

Upgrade to the latest stable version:

COMPONENT                 NODE      CURRENT   TARGET
kube-apiserver            master    v1.35.9   v1.36.5
kube-controller-manager   master    v1.35.9   v1.36.5
kube-scheduler            master    v1.35.9   v1.36.5
kube-proxy                          1.35.9    v1.36.5
CoreDNS                             v1.13.1   v1.14.2
etcd                      master    3.6.6-0   3.6.8-0

You can now apply the upgrade by executing the following command:

        kubeadm upgrade apply v1.36.5

_____________________________________________________________________

The table below shows the current state of component configs as understood by this version of kubeadm.
Configs that have a "yes" mark in the "MANUAL UPGRADE REQUIRED" column require manual config upgrade or
resetting to kubeadm defaults before a successful upgrade can be performed. The version to manually
upgrade to is denoted in the "PREFERRED VERSION" column.

API GROUP                 CURRENT VERSION   PREFERRED VERSION   MANUAL UPGRADE REQUIRED
kubeproxy.config.k8s.io   v1alpha1          v1alpha1            no
kubelet.config.k8s.io     v1beta1           v1beta1             no
_____________________________________________________________________
```

### Explanation, section by section

| Part of the output | Meaning |
|---|---|
| `Reading configuration from the "kubeadm-config" ConfigMap` | kubeadm learns how the cluster was built from a ConfigMap stored in the cluster itself |
| `Running cluster health checks` | It refuses to plan an upgrade for an unhealthy cluster |
| `Cluster version: 1.35.9` / `kubeadm version: v1.36.5` | The gap the upgrade will close |
| `remote version is much newer: v1.37.1; falling back to: stable-1.36` | kubeadm looked up the newest Kubernetes release (1.37.1) and **fell back to the 1.36 series**, because only the next minor version is allowed. This is the one-minor-at-a-time rule in action |
| `Latest version in the v1.35 series: v1.35.9` | There is no newer 1.35 patch, so a patch-only upgrade was not available here |
| "Components that must be upgraded manually" | **The kubelets.** kubeadm will not upgrade them for you. That is Phases 4 to 6 |
| "Upgrade to the latest stable version" | What `kubeadm upgrade apply` will change automatically |
| `etcd 3.6.6-0 to 3.6.8-0` | The database gets a patch update as part of the upgrade |
| `kube-proxy 1.35.9 to v1.36.5`, `CoreDNS v1.13.1 to v1.14.2` | The add-ons kubeadm manages |
| **No flannel row** | flannel is not managed by kubeadm and will not change |
| "MANUAL UPGRADE REQUIRED: no" for both rows | The kube-proxy and kubelet component configs convert automatically. A `yes` would mean hand-editing a config first |

`kubeadm upgrade plan` is read-only and safe to run as often as you like. Always read it before applying.

---

# 7. Phase 2: pre-pulling the images

## 7.1 Why pre-pull

`kubeadm upgrade apply` waits a limited time (5 minutes per component) for each control-plane pod to restart. If a slow download is part of that wait, the upgrade can time out halfway through. Downloading the images first removes that risk and shortens the time the API is unavailable.

## 7.2 On the master

```bash
sudo kubeadm config images list --kubernetes-version $TARGET
sudo kubeadm config images pull --kubernetes-version $TARGET
```

```text
registry.k8s.io/kube-apiserver:v1.36.5
registry.k8s.io/kube-controller-manager:v1.36.5
registry.k8s.io/kube-scheduler:v1.36.5
registry.k8s.io/kube-proxy:v1.36.5
registry.k8s.io/coredns/coredns:v1.14.2
registry.k8s.io/pause:3.10.2
registry.k8s.io/etcd:3.6.8-0

[config/images] Pulled registry.k8s.io/kube-apiserver:v1.36.5
[config/images] Pulled registry.k8s.io/kube-controller-manager:v1.36.5
E1007 10:58:10.532180   53930 remote_image.go:250] "PullImage from image service failed" err="rpc error: code = Unknown desc = failed to pull and unpack image \"registry.k8s.io/kube-scheduler:v1.36.5\": failed to copy: read tcp 172.25.242.252:49318->151.101.1.91:443: read: connection reset by peer" image="registry.k8s.io/kube-scheduler:v1.36.5"
```

### Explanation: a failed download

`connection reset by peer` means the server's side of the connection dropped in the middle of a download. It is a network problem and says nothing about the cluster or the upgrade. Two of seven images had arrived, and the third failed. The first attempt had been slow for a long time before it failed.

The fix is to repeat the pull. It is safe to repeat, and images that are already present are skipped. A loop with a short wait makes it automatic:

```bash
for i in 1 2 3 4 5; do
  sudo kubeadm config images pull --kubernetes-version $TARGET && break
  echo "attempt $i failed, retrying in 20 seconds"; sleep 20
done
```

```text
[config/images] Pulled registry.k8s.io/kube-apiserver:v1.36.5
[config/images] Pulled registry.k8s.io/kube-controller-manager:v1.36.5
[config/images] Pulled registry.k8s.io/kube-scheduler:v1.36.5
[config/images] Pulled registry.k8s.io/kube-proxy:v1.36.5
[config/images] Pulled registry.k8s.io/coredns/coredns:v1.14.2
[config/images] Pulled registry.k8s.io/pause:3.10.2
[config/images] Pulled registry.k8s.io/etcd:3.6.8-0
```

All seven images arrived, with no `attempt ... failed` line, so the retry succeeded on its first pass. The `&& break` stops the loop as soon as a pull succeeds.

## 7.3 On the workers

The workers will receive new **kube-proxy** pods (from the DaemonSet rollout) and possibly new **CoreDNS** pods (wherever the scheduler places them). Pull those two images on each worker in advance. Do them **one at a time** so two downloads do not share a slow link. The `timeout 300` stops a hung pull after five minutes:

**Run in: Windows PowerShell**

```powershell
multipass exec worker1 -- sudo timeout 300 ctr -n k8s.io images pull registry.k8s.io/kube-proxy:v1.36.5
multipass exec worker1 -- sudo timeout 300 ctr -n k8s.io images pull registry.k8s.io/coredns/coredns:v1.14.2
multipass exec worker2 -- sudo timeout 300 ctr -n k8s.io images pull registry.k8s.io/kube-proxy:v1.36.5
multipass exec worker2 -- sudo timeout 300 ctr -n k8s.io images pull registry.k8s.io/coredns/coredns:v1.14.2
```

```text
registry.k8s.io/kube-proxy:v1.36.5              saved
└──index (5f180e85f05b)                         complete        |++++++++++++++++++++++++++++++++++++++|
   [...]
Completed pull from OCI Registry (registry.k8s.io/kube-proxy:v1.36.5)   elapsed: 2.2 s  total:  16.5 M  (7.6 MiB/s)

registry.k8s.io/coredns/coredns:v1.14.2         saved
[...]
Completed pull from OCI Registry (registry.k8s.io/coredns/coredns:v1.14.2)      elapsed: 2.2 s  total:  22.2 M  (9.9 MiB/s)
(the CoreDNS lines above are from worker2; worker1's own CoreDNS pull was cut off on screen, see below)
```

Check that both images are present:

```powershell
multipass exec worker1 -- sudo ctr -n k8s.io images ls -q | Select-String "kube-proxy:v1.36.5|coredns:v1.14.2"
```

```text
registry.k8s.io/coredns/coredns:v1.14.2
registry.k8s.io/kube-proxy:v1.36.5
```

### Explanation, including a false alarm

- `ctr` is containerd's own command-line client. `-n k8s.io` selects the namespace that Kubernetes uses.
- The pull took **2.2 seconds at about 8 MiB/s**. Earlier, the same network had been slow and dropping connections, so the speed varies a lot over time.
- **A false alarm:** one pull window appeared to hang, with the progress bar only half drawn. A check showed the pull had actually finished. `ctr -n k8s.io content active` prints the downloads that are in progress, and it was empty:

  ```text
  REF     SIZE    AGE
  ```

  An empty list means nothing is downloading. The terminal had simply stopped redrawing. The image listing is the real evidence, so check it instead of trusting a frozen screen.
- These worker pre-pulls are optional. They only save waiting time. Without them, the replacement pods download the images as they start.

---

# 8. Phase 3: upgrading the control plane (`kubeadm upgrade apply`)

This is the step that changes the cluster. Check once more that everything is healthy, then run it **inside the master VM**. The `tee` saves a copy of the output to a file, and `-y` skips the confirmation question because you have already read the plan.

```bash
kubeadm version -o short
sudo kubeadm upgrade apply v1.36.5 -y 2>&1 | tee ~/upgrade-apply.log
```

```text
v1.36.5
[upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[upgrade] Use 'kubeadm init phase upload-config kubeadm --config your-config-file' to re-upload it.
[upgrade/preflight] Running preflight checks
[upgrade] Running cluster health checks
[upgrade/preflight] You have chosen to upgrade the cluster version to "v1.36.5"
[upgrade/versions] Cluster version: v1.35.9
[upgrade/versions] kubeadm version: v1.36.5
[upgrade/preflight] Pulling images required for setting up a Kubernetes cluster
[upgrade/preflight] This might take a minute or two, depending on the speed of your internet connection
[upgrade/preflight] You can also perform this action beforehand using 'kubeadm config images pull'
[upgrade/control-plane] Upgrading your static Pod-hosted control plane to version "v1.36.5" (timeout: 5m0s)...
[upgrade/staticpods] Writing new Static Pod manifests to "/etc/kubernetes/tmp/kubeadm-upgraded-manifests75312937"
[upgrade/staticpods] Preparing for "etcd" upgrade
[upgrade/staticpods] Renewing etcd-server certificate
[upgrade/staticpods] Renewing etcd-peer certificate
[upgrade/staticpods] Renewing etcd-healthcheck-client certificate
[upgrade/staticpods] Moving new manifest to "/etc/kubernetes/manifests/etcd.yaml" and backing up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-10-07-17-16-33/etcd.yaml"
[upgrade/staticpods] Waiting for the kubelet to restart the component
[upgrade/staticpods] This can take up to 5m0s
[apiclient] Found 1 Pods for label selector component=etcd
[upgrade/staticpods] Component "etcd" upgraded successfully!
[upgrade/etcd] Waiting for etcd to become available
[upgrade/staticpods] Preparing for "kube-apiserver" upgrade
[upgrade/staticpods] Renewing apiserver certificate
[upgrade/staticpods] Renewing apiserver-kubelet-client certificate
[upgrade/staticpods] Renewing front-proxy-client certificate
[upgrade/staticpods] Renewing apiserver-etcd-client certificate
[upgrade/staticpods] Moving new manifest to "/etc/kubernetes/manifests/kube-apiserver.yaml" and backing up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-10-07-17-16-33/kube-apiserver.yaml"
[upgrade/staticpods] Waiting for the kubelet to restart the component
[upgrade/staticpods] This can take up to 5m0s
[apiclient] Found 1 Pods for label selector component=kube-apiserver
[upgrade/staticpods] Component "kube-apiserver" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-controller-manager" upgrade
[upgrade/staticpods] Renewing controller-manager.conf certificate
[upgrade/staticpods] Moving new manifest to "/etc/kubernetes/manifests/kube-controller-manager.yaml" and backing up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-10-07-17-16-33/kube-controller-manager.yaml"
[upgrade/staticpods] Waiting for the kubelet to restart the component
[upgrade/staticpods] This can take up to 5m0s
[apiclient] Found 1 Pods for label selector component=kube-controller-manager
[upgrade/staticpods] Component "kube-controller-manager" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-scheduler" upgrade
[upgrade/staticpods] Renewing scheduler.conf certificate
[upgrade/staticpods] Moving new manifest to "/etc/kubernetes/manifests/kube-scheduler.yaml" and backing up old manifest to "/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-10-07-17-16-33/kube-scheduler.yaml"
[upgrade/staticpods] Waiting for the kubelet to restart the component
[upgrade/staticpods] This can take up to 5m0s
[apiclient] Found 1 Pods for label selector component=kube-scheduler
[upgrade/staticpods] Component "kube-scheduler" upgraded successfully!
[upgrade/control-plane] The control plane instance for this node was successfully upgraded!
[upload-config] Storing the configuration used in ConfigMap "kubeadm-config" in the "kube-system" Namespace
[kubelet] Creating a ConfigMap "kubelet-config" in namespace kube-system with the configuration for the kubelets in the cluster
[upgrade/kubeconfig] The kubeconfig files for this node were successfully upgraded!
W1007 17:19:04.831301  109160 postupgrade.go:105] Using temporary directory /etc/kubernetes/tmp/kubeadm-kubelet-config-2026-10-07-17-19-04 for kubelet config. To override it set the environment variable KUBEADM_UPGRADE_DRYRUN_DIR
[upgrade] Backing up kubelet config file to /etc/kubernetes/tmp/kubeadm-kubelet-config-2026-10-07-17-19-04/config.yaml
[patches] Applied patch of type "application/strategic-merge-patch+json" to target "kubeletconfiguration"
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[upgrade/kubelet-config] The kubelet configuration for this node was successfully upgraded!
[upgrade/bootstrap-token] Configuring bootstrap token and cluster-info RBAC rules
[bootstrap-token] Configured RBAC rules to allow Node Bootstrap tokens to get nodes
[bootstrap-token] Configured RBAC rules to allow Node Bootstrap tokens to post CSRs in order for nodes to get long term certificate credentials
[bootstrap-token] Configured RBAC rules to allow the csrapprover controller automatically approve CSRs from a Node Bootstrap Token
[bootstrap-token] Configured RBAC rules to allow certificate rotation for all node client certificates in the cluster
[bootstrap-token] Configured RBAC rules to allow the API server kubelet client certificate to access the kubelet API
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

[upgrade] SUCCESS! A control plane node of your cluster was upgraded to "v1.36.5".

[upgrade] Now please proceed with upgrading the rest of the nodes by following the right order.
```

## 8.1 The output, stage by stage

| Stage | What is happening |
|---|---|
| `Running preflight checks` and `Running cluster health checks` | kubeadm checks that the cluster is healthy and the requested version is a legal step |
| `Pulling images required ...` | It would download images here. They were pre-pulled, so this took no time |
| `Upgrading your static Pod-hosted control plane ... (timeout: 5m0s)` | The control plane runs as static pods, so the upgrade rewrites their manifest files. Each component has up to five minutes to come back |
| `Writing new Static Pod manifests to /etc/kubernetes/tmp/...` | The new manifests are prepared in a temporary folder first |
| `Renewing etcd-server certificate` (and others) | kubeadm renews the certificates of each component as it replaces it. This is why every certificate shows about 364 days left afterwards (see Phase 7) |
| `Moving new manifest to ... and backing up old manifest to ...kubeadm-backup-manifests-...` | The new file replaces the old one in `/etc/kubernetes/manifests`, and the old file is kept as a backup |
| `Waiting for the kubelet to restart the component` | The kubelet notices the changed manifest, stops the old pod and starts the new one |
| `Found 1 Pods for label selector component=etcd` / `Component "etcd" upgraded successfully!` | kubeadm confirms the new pod came up |
| `Waiting for etcd to become available` | etcd must be answering before the API server, which depends on it, is replaced |
| The same sequence for **kube-apiserver, kube-controller-manager, kube-scheduler** | One at a time, each confirmed before the next |
| `Storing the configuration used in ConfigMap "kubeadm-config"` | The cluster's recorded configuration is updated to the new version |
| `Creating a ConfigMap "kubelet-config"` | The kubelet configuration for the new version is stored, so the workers can fetch it later |
| `Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"` | This node's kubelet configuration file is updated. The kubelet binary itself is not |
| `Configuring bootstrap token and cluster-info RBAC rules` and the `[bootstrap-token]` lines | kubeadm re-applies the permission rules that let new nodes join. Nothing for you to do |
| `Applied essential addon: CoreDNS` and `kube-proxy` | The two add-ons are updated |
| **`SUCCESS! A control plane node of your cluster was upgraded to "v1.36.5"`** | The control plane is done |
| `Now please proceed with upgrading the rest of the nodes` | A reminder that kubelets and workers still need doing |

### How long it took

The backup folder name (`2026-10-07-17-16-33`) and the kubelet config folder (`17-19-04`) are timestamps in local time. They are about **two and a half minutes apart**, which is how long the apply took on a 2 GB VM with the images already present.

### What you may notice

- **The API server is unreachable for a short time** while etcd and then the API server restart. Pods running on the workers are not affected, because they do not need the API to keep running.
- **`kubeadm` rolls a component back by itself** if its new pod does not come up within the timeout. If the command fails, read the last lines for the cause, then read Section 15.
- **The `-y` flag** skipped the `[upgrade] Are you sure you want to proceed? [y/N]` question.

## 8.2 Check the control plane

```bash
kubectl version
kubectl get nodes
kubectl get pods -n kube-system
```

```text
Client Version: v1.35.9
Kustomize Version: v5.7.1
Server Version: v1.36.5

NAME      STATUS   ROLES           AGE    VERSION
master    Ready    control-plane   2d3h   v1.35.9
worker1   Ready    worker          2d1h   v1.35.9
worker2   Ready    worker          2d1h   v1.35.9

NAME                             READY   STATUS    RESTARTS   AGE
coredns-589f44dc88-kgrg2         1/1     Running   0          37m
coredns-589f44dc88-q5ptf         1/1     Running   0          37m
etcd-master                      1/1     Running   0          39m
kube-apiserver-master            1/1     Running   0          38m
kube-controller-manager-master   1/1     Running   0          38m
kube-proxy-mlzjg                 1/1     Running   0          37m
kube-proxy-s9st9                 1/1     Running   0          37m
kube-proxy-wqc59                 1/1     Running   0          37m
kube-scheduler-master            1/1     Running   0          37m
```

### Explanation

| What you see | Meaning |
|---|---|
| `Server Version: v1.36.5` | The API server is upgraded |
| `Client Version: v1.35.9` | The `kubectl` binary on the master is not upgraded yet. A client one minor version behind the server is within the supported range, so it keeps working |
| **Nodes still `v1.35.9`** | The `VERSION` column is each node's **kubelet**, and no kubelet has been upgraded yet. This is expected |
| etcd, API server, controller manager and scheduler are 37 to 39 minutes old, with **0 restarts** | They are brand-new pods, replaced cleanly. (The check was made some time after the apply finished, hence the minutes) |
| New CoreDNS names (`coredns-589f44dc88-*`) and three new kube-proxy pods | Both add-ons were rolled to the new versions. The new pod names show a new ReplicaSet and DaemonSet generation |
| No flannel in this namespace listing | flannel lives in its own namespace (`kube-flannel`) and was left alone |

The cluster is now in a **mixed-version state**: control plane 1.36.5, all kubelets 1.35.9. That is allowed, and the nginx pods kept running through it.

---

# 9. Phase 4: upgrading the master's kubelet and kubectl

## 9.1 Drain, upgrade, restart

The master also runs a kubelet, which needs upgrading like the workers' ones. The sequence is: drain the node, replace the packages, restart the kubelet, then uncordon.

**Run in: master VM**

```bash
VER=1.36.5-1.1
kubectl drain master --ignore-daemonsets --delete-emptydir-data
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=$VER kubectl=$VER
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

```text
node/master cordoned
Warning: ignoring DaemonSet-managed Pods: kube-flannel/kube-flannel-ds-2sz9k, kube-system/kube-proxy-s9st9
node/master drained
Canceled hold on kubelet.
Canceled hold on kubectl.
[...]
The following packages will be upgraded:
  kubectl kubelet
2 upgraded, 0 newly installed, 0 to remove and 9 not upgraded.
Need to get 25.2 MB of archives.
Get:1 https://prod-cdn.packages.k8s.io/repositories/isv:/kubernetes:/core:/stable:/v1.36/deb  kubectl 1.36.5-1.1 [11.8 MB]
Get:2 https://prod-cdn.packages.k8s.io/repositories/isv:/kubernetes:/core:/stable:/v1.36/deb  kubelet 1.36.5-1.1 [13.4 MB]
Fetched 25.2 MB in 1s (24.8 MB/s)
Unpacking kubectl (1.36.5-1.1) over (1.35.9-1.1) ...
Unpacking kubelet (1.36.5-1.1) over (1.35.9-1.1) ...
Setting up kubectl (1.36.5-1.1) ...
Setting up kubelet (1.36.5-1.1) ...
[...]
Restarting services...
 systemctl restart kubelet.service
[...]
kubelet set on hold.
kubectl set on hold.
```

### Explanation

| Output | Meaning |
|---|---|
| `node/master cordoned` | The node is marked unschedulable, so no new pods land on it |
| `Warning: ignoring DaemonSet-managed Pods: ...flannel..., ...kube-proxy...` | Expected. DaemonSet pods are meant to run on every node, so `--ignore-daemonsets` leaves them alone |
| **No `evicting pod` lines** | There was nothing ordinary on the master to evict. The new CoreDNS pods had already been scheduled onto the workers |
| `node/master drained` | The drain is complete |
| `Canceled hold on kubelet` / `kubelet set on hold` | The unhold, install, hold cycle. The holds stop accidental upgrades later |
| `Unpacking kubelet (1.36.5-1.1) over (1.35.9-1.1)` | The packages are replaced. The package script already restarted the kubelet, as `Restarting services ... kubelet.service` shows |
| `systemctl daemon-reload` and `restart kubelet` | Makes sure systemd re-reads the unit files and that the new binary is the one running |

The `Fetched 25.2 MB in 1s (24.8 MB/s)` line shows a fast network at this point. Earlier steps had been slow.

## 9.2 Check, then uncordon

Wait about 30 seconds for the kubelet to settle:

```bash
kubectl get nodes
kubectl version
```

```text
NAME      STATUS                     ROLES           AGE    VERSION
master    Ready,SchedulingDisabled   control-plane   2d3h   v1.36.5
worker1   Ready                      worker          2d1h   v1.35.9
worker2   Ready                      worker          2d1h   v1.35.9
Client Version: v1.36.5
Kustomize Version: v5.8.1
Server Version: v1.36.5
```

`Ready,SchedulingDisabled` is the cordon from the drain. The master is healthy, at **v1.36.5**, and `kubectl` now matches the server. Lift the cordon:

```bash
kubectl uncordon master
kubectl get nodes
kubectl get pods -A -o wide
```

```text
node/master uncordoned
NAME      STATUS   ROLES           AGE    VERSION
master    Ready    control-plane   2d3h   v1.36.5
worker1   Ready    worker          2d1h   v1.35.9
worker2   Ready    worker          2d1h   v1.35.9
NAMESPACE      NAME                             READY   STATUS    RESTARTS      AGE    IP               NODE      NOMINATED NODE   READINESS GATES
default        nginx-758ff947b-kxp8r            1/1     Running   2 (27h ago)   30h    10.244.1.19      worker1   <none>           <none>
default        nginx-758ff947b-r7qgc            1/1     Running   2 (27h ago)   30h    10.244.1.20      worker1   <none>           <none>
default        nginx-758ff947b-w6pcr            1/1     Running   2 (27h ago)   30h    10.244.2.28      worker2   <none>           <none>
default        nginx-758ff947b-zrh2k            1/1     Running   2 (27h ago)   30h    10.244.2.27      worker2   <none>           <none>
kube-flannel   kube-flannel-ds-2sz9k            1/1     Running   2 (27h ago)   2d1h   172.25.246.7     master    <none>           <none>
kube-flannel   kube-flannel-ds-dszmf            1/1     Running   2 (27h ago)   2d1h   172.25.252.5     worker2   <none>           <none>
kube-flannel   kube-flannel-ds-mjmv8            1/1     Running   3 (27h ago)   33h    172.25.253.184   worker1   <none>           <none>
kube-system    coredns-589f44dc88-kgrg2         1/1     Running   0             40m    10.244.2.29      worker2   <none>           <none>
kube-system    coredns-589f44dc88-q5ptf         1/1     Running   0             40m    10.244.1.23      worker1   <none>           <none>
kube-system    etcd-master                      1/1     Running   2 (74s ago)   80s    172.25.246.7     master    <none>           <none>
kube-system    kube-apiserver-master            1/1     Running   1 (80s ago)   80s    172.25.246.7     master    <none>           <none>
kube-system    kube-controller-manager-master   1/1     Running   0             69s    172.25.246.7     master    <none>           <none>
kube-system    kube-proxy-mlzjg                 1/1     Running   0             40m    172.25.253.184   worker1   <none>           <none>
kube-system    kube-proxy-s9st9                 1/1     Running   0             40m    172.25.246.7     master    <none>           <none>
kube-system    kube-proxy-wqc59                 1/1     Running   0             40m    172.25.252.5     worker2   <none>           <none>
kube-system    kube-scheduler-master            1/1     Running   0             69s    172.25.246.7     master    <none>           <none>
```

### Explanation

- **CoreDNS is on worker1 and worker2**, which is why the master's drain had nothing to evict. An uncordon never moves pods back.
- **The four control-plane pods are young again** (about 80 seconds old, with etcd at 2 restarts and the API server at 1). The kubelet upgrade made the new kubelet re-examine the static pods, and it recreated them. The API server's restart is consistent with it starting before etcd was ready and retrying. That is an interpretation, and what matters is the next check: that the counts then stop rising.
- The master's own pods report the host address `172.25.246.7`, because they run on the host network. That is the fixed address the control plane binds to.

## 9.3 Confirm the control plane is stable before touching a worker

```bash
sleep 120
kubectl get pods -n kube-system
kubectl get --raw='/readyz'
$EC endpoint health --write-out=table
```

```text
NAME                             READY   STATUS    RESTARTS        AGE
coredns-589f44dc88-kgrg2         1/1     Running   0               42m
coredns-589f44dc88-q5ptf         1/1     Running   0               42m
etcd-master                      1/1     Running   2 (3m57s ago)   4m3s
kube-apiserver-master            1/1     Running   1 (4m3s ago)    4m3s
kube-controller-manager-master   1/1     Running   0               3m52s
kube-proxy-mlzjg                 1/1     Running   0               42m
kube-proxy-s9st9                 1/1     Running   0               42m
kube-proxy-wqc59                 1/1     Running   0               42m
kube-scheduler-master            1/1     Running   0               3m52s
ok
+------------------------+--------+------------+-------+
|        ENDPOINT        | HEALTH |    TOOK    | ERROR |
+------------------------+--------+------------+-------+
| https://127.0.0.1:2379 |   true | 9.497511ms |       |
+------------------------+--------+------------+-------+
```

| Check | Result |
|---|---|
| Restart counts | Unchanged since the previous listing (etcd 2, API server 1). Nothing is flapping |
| `/readyz` | `ok`. The API server reports itself ready. (In a terminal the `ok` may run into the table's first line, because it has no trailing newline) |
| etcd health | `true` in 9.5 ms |

Only continue to the workers when these three agree. The workers depend on a stable API.

---

# 10. Phase 5: upgrading worker1

Each worker follows five steps. **The order matters:** `kubeadm upgrade node`, then drain, then the kubelet upgrade.

## Step 1 and 2: new kubeadm and `kubeadm upgrade node`

**Run in: worker1 VM** (`multipass shell worker1`)

```bash
sudo sed -i 's#/core:/stable:/v1.35/#/core:/stable:/v1.36/#g' /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo apt-get update
VER=1.36.5-1.1
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=$VER
sudo apt-mark hold kubeadm
kubeadm version -o short
sudo kubeadm upgrade node
```

```text
Get:1 https://prod-cdn.packages.k8s.io/repositories/isv:/kubernetes:/core:/stable:/v1.36/deb  InRelease [1227 B]
Get:5 https://prod-cdn.packages.k8s.io/repositories/isv:/kubernetes:/core:/stable:/v1.36/deb  Packages [9460 B]
[...]
Unpacking kubeadm (1.36.5-1.1) over (1.35.9-1.1) ...
Setting up kubeadm (1.36.5-1.1) ...
kubeadm set on hold.
v1.36.5
[upgrade] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[upgrade] Use 'kubeadm init phase upload-config kubeadm --config your-config-file' to re-upload it.
W1007 18:03:41.327893  112936 utils.go:69] The recommended value for "bindAddress" in "KubeProxyConfiguration" is: ::; the provided value is: 0.0.0.0
[upgrade/preflight] Running pre-flight checks
[upgrade/preflight] Skipping prepull. Not a control plane node.
[upgrade/control-plane] Skipping phase. Not a control plane node.
[upgrade/kubeconfig] Skipping phase. Not a control plane node.
W1007 18:03:41.377775  112936 postupgrade.go:105] Using temporary directory /etc/kubernetes/tmp/kubeadm-kubelet-config-2026-10-07-18-03-41 for kubelet config. To override it set the environment variable KUBEADM_UPGRADE_DRYRUN_DIR
[upgrade] Backing up kubelet config file to /etc/kubernetes/tmp/kubeadm-kubelet-config-2026-10-07-18-03-41/config.yaml
[patches] Applied patch of type "application/strategic-merge-patch+json" to target "kubeletconfiguration"
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[upgrade/kubelet-config] The kubelet configuration for this node was successfully upgraded!
[upgrade/addon] Skipping the addon/coredns phase. Not a control plane node.
[upgrade/addon] Skipping the addon/kube-proxy phase. Not a control plane node.
```

### Explanation

- **The apt steps** are the same as on the master. Every node needs its own repository change, because each machine has its own apt configuration.
- **`kubeadm upgrade node` is short on a worker.** The four `Skipping ... Not a control plane node` lines are expected, because a worker has no control-plane pods or add-ons to replace.
- What it **does** do: it backs up the old kubelet config, then writes the new one to `/var/lib/kubelet/config.yaml` (`The kubelet configuration for this node was successfully upgraded!`). That is all a worker needs from kubeadm before its kubelet binary is replaced.
- The `bindAddress` warning is harmless. It appeared when the worker joined the cluster too.
- After this step the worker's **running kubelet is still 1.35.9**. Only its configuration changed.

## Step 3: drain worker1

This happens from the control plane's point of view, so run it **from PowerShell** (or the master shell):

```powershell
multipass exec master -- kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data
```

```text
node/worker1 cordoned
Warning: ignoring DaemonSet-managed Pods: kube-flannel/kube-flannel-ds-mjmv8, kube-system/kube-proxy-mlzjg
evicting pod kube-system/coredns-589f44dc88-q5ptf
evicting pod default/nginx-758ff947b-r7qgc
evicting pod default/nginx-758ff947b-kxp8r
pod/nginx-758ff947b-r7qgc evicted
pod/nginx-758ff947b-kxp8r evicted
pod/coredns-589f44dc88-q5ptf evicted
node/worker1 drained
```

Two nginx pods and one CoreDNS pod were evicted. Their Deployments created replacements on other nodes. The other worker kept serving traffic the whole time.

## Step 4: upgrade the kubelet and kubectl

**Run in: worker1 VM**

```bash
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=$VER kubectl=$VER
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
exit
```

```text
Canceled hold on kubelet.
Canceled hold on kubectl.
[...]
Fetched 25.2 MB in 1s (24.0 MB/s)
Unpacking kubectl (1.36.5-1.1) over (1.35.9-1.1) ...
Unpacking kubelet (1.36.5-1.1) over (1.35.9-1.1) ...
[...]
Restarting services...
 systemctl restart kubelet.service
[...]
kubelet set on hold.
kubectl set on hold.
logout
```

## Step 5: check and uncordon

```powershell
Start-Sleep -Seconds 30
multipass exec master -- kubectl get nodes
multipass exec master -- kubectl uncordon worker1
multipass exec master -- kubectl get pods -A -o wide
```

```text
NAME      STATUS                     ROLES           AGE    VERSION
master    Ready                      control-plane   2d3h   v1.36.5
worker1   Ready,SchedulingDisabled   worker          2d1h   v1.36.5
worker2   Ready                      worker          2d1h   v1.35.9
node/worker1 uncordoned
NAMESPACE      NAME                             READY   STATUS    RESTARTS      AGE    IP               NODE      [...]
default        nginx-758ff947b-c7t26            1/1     Running   0             70s    10.244.2.31      worker2   [...]
default        nginx-758ff947b-nmrhg            1/1     Running   0             70s    10.244.2.30      worker2   [...]
default        nginx-758ff947b-w6pcr            1/1     Running   2 (27h ago)   30h    10.244.2.28      worker2   [...]
default        nginx-758ff947b-zrh2k            1/1     Running   2 (27h ago)   30h    10.244.2.27      worker2   [...]
kube-system    coredns-589f44dc88-5pt72         1/1     Running   0             70s    10.244.0.8       master    [...]
kube-system    coredns-589f44dc88-kgrg2         1/1     Running   0             47m    10.244.2.29      worker2   [...]
[...]
```

### Explanation

- worker1 is at **v1.36.5** (`Ready,SchedulingDisabled` is the cordon, lifted by the uncordon). The cluster now has two nodes on 1.36.5 and one on 1.35.9.
- **All four nginx pods are on worker2**, and CoreDNS is on the master and worker2. The drain moved them there, and an uncordon never moves them back. Rebalancing comes at the end.
- The control-plane pods show the same ages and restart counts as before, so the kubelet restart on worker1 did not disturb them.

## What actually happened in this run, versus the correct order

In the real run, the kubelet upgrade on worker1 (Step 4) was done **before** the drain (Step 3), because a command meant for PowerShell was typed inside the worker's shell (see Section 14). It worked out, and the pods showed no extra restarts. The official documentation says to drain first, though, and in a real cluster an in-place kubelet restart can disturb running pods. For worker2, the order was corrected.

---

# 11. Phase 6: upgrading worker2

The same five steps, with `worker2`. This time the drain came first.

## Steps 1 and 2: new kubeadm and `kubeadm upgrade node`

**Run in: worker2 VM** (`multipass shell worker2`)

```bash
sudo sed -i 's#/core:/stable:/v1.35/#/core:/stable:/v1.36/#g' /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo apt-get update
VER=1.36.5-1.1
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=$VER
sudo apt-mark hold kubeadm
kubeadm version -o short
sudo kubeadm upgrade node
exit
```

The output of these two steps on worker2 was **not captured** in this record. The commands are identical to worker1's, and the node ended up on kubelet v1.36.5 and `Ready`. On your own cluster, confirm that `kubeadm version -o short` prints the new version and that `kubeadm upgrade node` ends with `The kubelet configuration for this node was successfully upgraded!`.

## Step 3: drain worker2 before the kubelet upgrade

```powershell
multipass exec master -- kubectl drain worker2 --ignore-daemonsets --delete-emptydir-data
```

```text
node/worker2 cordoned
Warning: ignoring DaemonSet-managed Pods: kube-flannel/kube-flannel-ds-dszmf, kube-system/kube-proxy-wqc59
evicting pod kube-system/coredns-589f44dc88-kgrg2
evicting pod default/nginx-758ff947b-nmrhg
evicting pod default/nginx-758ff947b-c7t26
evicting pod default/nginx-758ff947b-w6pcr
evicting pod default/nginx-758ff947b-zrh2k
pod/nginx-758ff947b-c7t26 evicted
pod/nginx-758ff947b-w6pcr evicted
pod/nginx-758ff947b-nmrhg evicted
pod/nginx-758ff947b-zrh2k evicted
pod/coredns-589f44dc88-kgrg2 evicted
node/worker2 drained
```

### A weak spot this exposed

worker2 held **all four nginx replicas**. Draining it evicted every replica at the same moment, so for a few seconds nothing was serving the Service until the replacements started on worker1. The nginx image was already cached there, which kept the gap short. In a real cluster you would prevent this with a **PodDisruptionBudget**, which tells the drain to wait so that a minimum number of replicas stays available. It is a good topic to practice next.

## Step 4: upgrade the kubelet and kubectl

**Run in: worker2 VM** (a new shell)

```bash
VER=1.36.5-1.1
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=$VER kubectl=$VER
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
exit
```

A new shell does not remember variables from an old one, which is why `VER` is set again.

## Step 5: check and uncordon

```powershell
Start-Sleep -Seconds 30
multipass exec master -- kubectl get nodes
multipass exec master -- kubectl uncordon worker2
multipass exec master -- kubectl get pods -A -o wide
```

```text
NAME      STATUS                     ROLES           AGE    VERSION
master    Ready                      control-plane   2d3h   v1.36.5
worker1   Ready                      worker          2d1h   v1.36.5
worker2   Ready,SchedulingDisabled   worker          2d1h   v1.36.5
node/worker2 uncordoned
NAMESPACE      NAME                             READY   STATUS    RESTARTS      AGE    IP               NODE      [...]
default        nginx-758ff947b-dcfjm            1/1     Running   0             14m    10.244.1.25      worker1   [...]
default        nginx-758ff947b-ld8vt            1/1     Running   0             14m    10.244.1.24      worker1   [...]
default        nginx-758ff947b-vb8f5            1/1     Running   0             14m    10.244.1.28      worker1   [...]
default        nginx-758ff947b-vq8hh            1/1     Running   0             14m    10.244.1.26      worker1   [...]
kube-system    coredns-589f44dc88-2tpjr         1/1     Running   0             14m    10.244.1.27      worker1   [...]
kube-system    coredns-589f44dc88-5pt72         1/1     Running   0             17m    10.244.0.8       master    [...]
kube-system    etcd-master                      1/1     Running   2 (24m ago)   24m    172.25.246.7     master    [...]
[...]
```

All three nodes are at **v1.36.5**. All four nginx pods are now on worker1, which is the mirror image of the earlier state, and CoreDNS runs on worker1 and the master.

---

# 12. Phase 7: verification, rebalancing and certificates

## 12.1 Versions, the Service and the package holds

```powershell
multipass exec master -- kubectl version
curl.exe -s -o NUL -w "%{http_code}`n" http://172.25.246.7:31260
multipass exec master -- apt-mark showhold
multipass exec worker1 -- apt-mark showhold
multipass exec worker2 -- apt-mark showhold
```

```text
Client Version: v1.36.5
Kustomize Version: v5.8.1
Server Version: v1.36.5
200
kubeadm
kubectl
kubelet
(the same three lines for worker1 and worker2)
```

| Check | Meaning |
|---|---|
| Client and server `v1.36.5` | The whole cluster and its command-line tool agree |
| `200` | The NodePort Service answers through the master after the upgrade. (Draining worker2 did cause a brief gap, see Phase 6) |
| `showhold`: kubeadm, kubectl, kubelet on **every** node | The version pins are back in place on all three machines. A plain `apt upgrade` will not move these packages |

## 12.2 Rebalance the Deployment

All four nginx pods sat on one worker after the drains. Recreating them lets the scheduler spread them again:

```powershell
multipass exec master -- kubectl rollout restart deployment nginx
multipass exec master -- kubectl rollout status deployment nginx
multipass exec master -- kubectl get pods -o wide
```

```text
deployment.apps/nginx restarted
Waiting for deployment "nginx" rollout to finish: 2 out of 4 new replicas have been updated...
[...]
Waiting for deployment "nginx" rollout to finish: 1 old replicas are pending termination...
deployment "nginx" successfully rolled out
NAME                     READY   STATUS    RESTARTS   AGE   IP            NODE      NOMINATED NODE   READINESS GATES
nginx-5577fb97b9-2ljzz   1/1     Running   0          8s    10.244.1.30   worker1   <none>           <none>
nginx-5577fb97b9-4pp2g   1/1     Running   0          9s    10.244.2.32   worker2   <none>           <none>
nginx-5577fb97b9-c8bgh   1/1     Running   0          8s    10.244.2.33   worker2   <none>           <none>
nginx-5577fb97b9-fqrnr   1/1     Running   0          9s    10.244.1.29   worker1   <none>           <none>
```

Two pods per worker. The rolling restart replaces pods gradually, so the Service stays available. The scheduler spreads on a best-effort basis, so the result is usually, but not always, an even split.

## 12.3 The certificates were renewed

```powershell
multipass exec master -- sudo kubeadm certs check-expiration
```

```text
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Oct 08, 2027 00:16 UTC   364d            ca                      no
apiserver                  Oct 08, 2027 00:16 UTC   364d            ca                      no
apiserver-etcd-client      Oct 08, 2027 00:16 UTC   364d            etcd-ca                 no
apiserver-kubelet-client   Oct 08, 2027 00:16 UTC   364d            ca                      no
controller-manager.conf    Oct 08, 2027 00:16 UTC   364d            ca                      no
etcd-healthcheck-client    Oct 08, 2027 00:16 UTC   364d            etcd-ca                 no
etcd-peer                  Oct 08, 2027 00:16 UTC   364d            etcd-ca                 no
etcd-server                Oct 08, 2027 00:16 UTC   364d            etcd-ca                 no
front-proxy-client         Oct 08, 2027 00:16 UTC   364d            front-proxy-ca          no
scheduler.conf             Oct 08, 2027 00:16 UTC   364d            ca                      no
super-admin.conf           Oct 08, 2027 00:16 UTC   364d            ca                      no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Oct 02, 2036 21:29 UTC   9y              no
etcd-ca                 Oct 02, 2036 21:29 UTC   9y              no
front-proxy-ca          Oct 02, 2036 21:29 UTC   9y              no
```

### Explanation

- Every certificate that belongs to a control-plane component shows **364 days** left, all expiring at `00:16 UTC` on Oct 8, 2027. That is the minute of the upgrade (17:16 local time), so the upgrade **renewed them**. This is the `Renewing ... certificate` lines from Phase 3 in effect.
- The three **certificate authorities** last about 9 years and were not renewed.
- **Why this matters:** kubeadm certificates last a year unless renewed. A cluster that is never upgraded and never renewed sees its API server certificates expire, and then nothing can talk to it. Upgrading at least once a year renews them as a side effect. The command `kubeadm certs renew all` does it without an upgrade.
- `EXTERNALLY MANAGED: no` means kubeadm manages these certificates itself.

## 12.4 Your `kubeconfig` copy is not renewed automatically

`/etc/kubernetes/admin.conf` was renewed. But `~/.kube/config` is a **copy** made when the cluster was built, so it kept the old certificate. Compare the two (the commands print dates only):

**Run in: master VM**

```bash
echo "my copy:"; grep client-certificate-data ~/.kube/config | awk '{print $2}' | base64 -d | openssl x509 -noout -enddate
echo "admin.conf:"; sudo grep client-certificate-data /etc/kubernetes/admin.conf | awk '{print $2}' | base64 -d | openssl x509 -noout -enddate
```

```text
my copy:
notAfter=Oct  5 21:29:56 2027 GMT
admin.conf:
notAfter=Oct  8 00:16:29 2027 GMT
```

The copy expires about two days earlier. To bring it up to date:

```bash
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
kubectl get nodes
grep client-certificate-data ~/.kube/config | awk '{print $2}' | base64 -d | openssl x509 -noout -enddate
```

```text
NAME      STATUS   ROLES           AGE    VERSION
master    Ready    control-plane   2d3h   v1.36.5
worker1   Ready    worker          2d1h   v1.36.5
worker2   Ready    worker          2d1h   v1.36.5
notAfter=Oct  8 00:16:29 2027 GMT
```

The same rule applies to any other copy of `admin.conf`, such as one on another machine: **repeat the copy after every certificate renewal**.

---

# 13. Timeline: what changed when

| Step | Where | What changed | Cluster effect |
|---|---|---|---|
| Etcd snapshot | master | A backup file | None |
| `apt` repository to 1.36, install `kubeadm` | master | One package | None |
| `kubeadm upgrade plan` | master | Nothing (read-only) | None |
| Image pre-pull | master, workers | Images on disk | None |
| `kubeadm upgrade apply` | master | etcd, API server, controller manager, scheduler, CoreDNS, kube-proxy, certificates | **API briefly unavailable.** Workloads keep running |
| Master drain, `kubelet`/`kubectl` upgrade, uncordon | master | master kubelet 1.36.5 | Control-plane pods restart once more |
| worker1: `kubeadm`, `upgrade node`, drain, kubelet, uncordon | worker1 | worker1 kubelet 1.36.5 | nginx and CoreDNS pods move away from worker1 |
| worker2: same | worker2 | worker2 kubelet 1.36.5 | All nginx replicas move at once |
| `rollout restart` | cluster | nginx pods recreated | Pods spread across both workers |

---

# 14. Mistakes and lessons

Every row below happened in the real run.

| What happened | Error or symptom | Cause | Fix |
|---|---|---|---|
| Typed `kubectl get nodes` in Windows PowerShell | `connection refused` to `127.0.0.1:55170` | The Windows `kubectl` points at a different, stopped cluster | Use `multipass exec master -- kubectl ...`, or work inside the master shell |
| `multipass exec -- kubectl ...` (VM name left out) | `instance "kubectl" does not exist` | `multipass exec` needs the VM name before the `--` | `multipass exec master -- kubectl ...` |
| Typed `multipass exec master -- kubectl drain ...` **inside worker1's shell** | `multipass: command not found` | The `multipass` command exists only on Windows | Run `multipass ...` commands in PowerShell |
| Upgraded worker1's kubelet **before** draining it | Nothing visibly broke | The drain command had failed (previous row), and the next command was run anyway | Always drain first (Phase 5, Step 3), then upgrade the kubelet |
| Image pull failed | `connection reset by peer` | A dropped download on a slow network | Repeat the pull, with a retry loop (Section 7.2) |
| A pull appeared to hang | Half-drawn progress bar | A terminal display problem. The pull had finished | Check the image listing or `ctr content active`, not just the screen |
| Pasted `cp ... && chown ...` into PowerShell | `The token '&&' is not a valid statement separator` | Windows PowerShell 5.1 does not support `&&`, and the command belonged in the master shell | Run Linux commands inside the VM shell |

### Lessons

1. **Look at the prompt before you press Enter.** `PS C:\...>` and `ubuntu@master:~$` are two different worlds.
2. **Read the plan before you apply.** `kubeadm upgrade plan` told you the exact versions, the components, and that the kubelets are your job.
3. **Back up, and prove the backup.** Verify the snapshot with `etcdutl snapshot status` and compare checksums after copying it off the VM.
4. **Pre-pull the images.** It turns a possible timeout into a non-event.
5. **Stability checks between phases are cheap.** Restart counts, `readyz` and etcd health took half a minute and caught nothing, which is exactly the point.
6. **A drain of a node holding all replicas is a brief outage.** Spread replicas, or use a PodDisruptionBudget.

---

# 15. Troubleshooting guide

Items marked **(seen)** occurred in this run. The rest are common causes based on how the components work, and were not hit here.

| Symptom | Likely cause | What to do |
|---|---|---|
| `connection reset by peer` while pulling images **(seen)** | Dropped download | Repeat the pull. Use the retry loop |
| `kubectl` fails right after `kubeadm upgrade apply` starts | The API server is restarting. This is part of the upgrade | Wait a minute or two. Do not interrupt the command |
| `kubectl get nodes` shows the old version after `upgrade apply` **(seen)** | That column is the kubelet version | Expected. Continue with the kubelet upgrades |
| `kubeadm upgrade apply` fails with a timeout on one component | The new pod did not start in time (a slow image pull, or not enough memory) | kubeadm restores the old manifest by itself. Read the error, check `sudo journalctl -u kubelet -n 50 --no-pager`, fix the cause (pre-pull the image), and run it again |
| Apply fails and leaves a half-upgraded state | An interrupted or failed step | The official docs describe recovering with `sudo kubeadm upgrade apply --force`. Check the backups first under `/etc/kubernetes/tmp/` |
| The node stays `NotReady` after the kubelet upgrade | The kubelet did not restart cleanly | `sudo systemctl status kubelet --no-pager` and `sudo journalctl -u kubelet -n 30 --no-pager` |
| `multipass: command not found` inside a VM **(seen)** | A Windows command typed in the VM shell | Run it in PowerShell |
| `The token '&&' is not a valid statement separator` **(seen)** | Windows PowerShell 5.1 | Put commands on separate lines, or run them in a VM shell |
| Drain hangs | A pod cannot be evicted (for example, a PodDisruptionBudget blocks it, or a pod has no controller) | `kubectl get pods -A -o wide` to see which pod is stuck, then handle that pod |
| A pod is stuck in `ContainerCreating` after the upgrade | A slow image pull | `kubectl describe pod <name>` and read the Events at the bottom. Pre-pull the image |
| `Forbidden` right after a control-plane restart | The API server is still loading permissions | Wait a minute and retry |

---

# 16. Rollback: what is and is not possible

There is **no simple downgrade** of a kubeadm cluster. What you have in practice:

| Situation | What helps |
|---|---|
| `kubeadm upgrade apply` fails on a component | kubeadm restores the previous manifest for that component by itself |
| The control plane is upgraded but misbehaving | Backups of the old manifests are under `/etc/kubernetes/tmp/kubeadm-backup-manifests-*`. Your etcd snapshot is the data backup |
| Something is badly wrong and you must go back | Restore the pre-upgrade etcd snapshot and reinstall the old package versions. This was **not tested**. A snapshot taken on 1.35 holds data in that version's format, so restoring it onto upgraded binaries needs care |
| A lab cluster | Rebuilding is usually the fastest rollback, which is why you rehearse an upgrade on a lab first |

Keep the pre-upgrade snapshot for a few days. Delete it when you are satisfied, because it holds every Secret in the cluster.

---

# 17. Checklist

## Before

- [ ] All nodes `Ready`, all pods `Running`, restart counts old and stable
- [ ] Free disk space on every node (`df -h /`)
- [ ] Read the "Urgent Upgrade Notes" for the target release
- [ ] etcd snapshot taken, **verified** with `etcdutl snapshot status`, copied off the VM, checksums match
- [ ] `apt` repository switched to the new minor version, `TARGET` and `VER` known
- [ ] New `kubeadm` installed on the master, `kubeadm upgrade plan` read
- [ ] Images pre-pulled on the master and on the workers

## During

- [ ] `kubeadm upgrade apply` finished with `SUCCESS!`
- [ ] Master: drain, kubelet and kubectl upgrade, restart, uncordon
- [ ] Stability check: restart counts steady, `/readyz` is `ok`, etcd healthy
- [ ] Each worker, **one at a time**: new `kubeadm`, `kubeadm upgrade node`, **drain**, kubelet and kubectl, restart, uncordon

## After

- [ ] All nodes on the new version, client and server versions agree
- [ ] `apt-mark showhold` lists kubeadm, kubectl and kubelet on every node
- [ ] The application answers (the NodePort returned `200`)
- [ ] Deployments rebalanced with `rollout restart`
- [ ] `kubeadm certs check-expiration` shows about a year left
- [ ] Copies of `admin.conf` refreshed

---

# 18. Command reference

| Task | Command | Where |
|---|---|---|
| Switch the apt repository | `sudo sed -i 's#/core:/stable:/v1.35/#/core:/stable:/v1.36/#g' /etc/apt/sources.list.d/kubernetes.list` | Every node |
| Find the newest patch | `apt-cache madison kubeadm \| awk '{print $3}' \| grep '^1\.36\.' \| sort -V \| tail -1` | Master |
| Free a package for upgrade | `sudo apt-mark unhold kubeadm` | Each node |
| Pin it again | `sudo apt-mark hold kubeadm kubelet kubectl` | Each node |
| Preview the upgrade | `sudo kubeadm upgrade plan` | Master |
| List the needed images | `sudo kubeadm config images list --kubernetes-version v1.36.5` | Master |
| Pre-pull images | `sudo kubeadm config images pull --kubernetes-version v1.36.5` | Master |
| Pre-pull on a worker | `sudo timeout 300 ctr -n k8s.io images pull registry.k8s.io/kube-proxy:v1.36.5` | Worker |
| Upgrade the control plane | `sudo kubeadm upgrade apply v1.36.5` | Master |
| Upgrade a worker's config | `sudo kubeadm upgrade node` | Worker |
| Drain a node | `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` | Master or PowerShell |
| Re-enable a node | `kubectl uncordon <node>` | Master or PowerShell |
| Restart the kubelet | `sudo systemctl daemon-reload && sudo systemctl restart kubelet` | The node |
| Check the API server | `kubectl get --raw='/readyz'` | Master |
| Check certificate expiry | `sudo kubeadm certs check-expiration` | Master |
| Renew all certificates | `sudo kubeadm certs renew all` | Master |
| Rebalance pods | `kubectl rollout restart deployment <name>` | Master or PowerShell |

---

# 19. Glossary

| Term | Meaning |
|---|---|
| **Control plane** | The components that manage the cluster: API server, etcd, scheduler, controller manager |
| **Static pod** | A pod the kubelet runs directly from a file in `/etc/kubernetes/manifests`, without the API server |
| **Minor / patch version** | In `1.36.5`, `36` is the minor version and `5` is the patch version |
| **Version skew** | The allowed difference between the versions of cluster components |
| **Cordon** | Mark a node unschedulable. New pods avoid it, and existing pods stay |
| **Drain** | Cordon a node and evict its pods, so it can be worked on |
| **Uncordon** | Make a node schedulable again. It does not move pods back |
| **DaemonSet** | A workload that runs one pod on every node, such as kube-proxy and flannel |
| **ReplicaSet / Deployment** | The objects that keep a set number of pod copies running |
| **etcd snapshot** | A consistent copy of the cluster's database |
| **kubelet** | The agent on every node that starts and watches pods |
| **`apt-mark hold`** | Pins a package so a normal system upgrade cannot change it |
| **PodDisruptionBudget** | A rule that limits how many replicas a drain may take down at once |
| **`ctr`** | containerd's own command-line client, used here to pull images |

---

# 20. What was not tested

This document reports what was run. These parts were **not** run, so treat them as unverified:

- **The next hop, 1.36 to 1.37.** It would repeat the whole procedure with `v1.37` in the repository line. Read that release's upgrade notes first.
- **A real rollback.** Restoring a pre-upgrade snapshot onto upgraded binaries was not attempted.
- **Highly available control planes.** With more than one control-plane node, the documentation says the first runs `kubeadm upgrade apply` and the others run `kubeadm upgrade node`. This was not tested here.
- **The recovery commands** in Section 15 that are not marked **(seen)**, including `kubeadm upgrade apply --force`.
- **The cause of the `Forbidden` message** seen after an earlier etcd restore (not during this upgrade) was never identified.

The main source for the procedure is the official Kubernetes documentation page "Upgrading kubeadm clusters". Check it for the version you are upgrading to, because details can change between releases.
