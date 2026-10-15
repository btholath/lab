# Kubernetes Scheduling: Where Pods Run, and Why

## Requests, limits, QoS, node selection and spreading, tested on a real three-node cluster

A pod is created, and one of your nodes ends up running it. This guide explains how that choice is made, how to see it, and how to steer it. Every lab was run on a real kubeadm cluster (1 control plane, 2 workers, Kubernetes v1.36.5), and the console output after each lab is copied from the run. Where a prediction was wrong, the guide says so. Explanations marked as inferences are best guesses and not results.

**Contents**

1. How scheduling works
2. Seeing where a pod went, and why
3. Requests and limits
4. QoS classes
5. A memory limit: `OOMKilled`
6. A CPU limit: throttling
7. Reading `FailedScheduling` messages
8. Choosing nodes: `nodeSelector` and node affinity
9. Topology spread constraints
10. Taints and tolerations, in brief
11. Practical tips for running these labs
12. Common mistakes and troubleshooting
13. Command cheat sheet
14. Glossary
15. What was run, and what was not

---

# 1. How scheduling works

A new pod starts with an empty `spec.nodeName`. The **kube-scheduler** on the master notices it, chooses a node, and writes the node's name into the pod. It does not start anything. The **kubelet** on that node then sees a pod assigned to it and starts the containers.

```text
 pod created, no node yet
        |
 kube-scheduler: FILTER   remove nodes that cannot run it
        |
 kube-scheduler: SCORE    rank the nodes that remain
        |
 best node chosen  ->  spec.nodeName is set
        |
 kubelet on that node starts the containers
```

**Filtering** removes every node that cannot take the pod. Typical reasons:

- The pod's resource **requests** do not fit in what is left on the node.
- The node's **taint** is not tolerated.
- A `nodeSelector` or node affinity does not match the node's labels.
- The node is **cordoned** (`SchedulingDisabled`).
- A topology spread constraint would be violated.

**Scoring** ranks the nodes that remain, using factors such as how balanced the load would be and any soft preferences (a preferred affinity adds to a node's score). The best score wins.

If **no** node passes filtering, the pod stays `Pending`, and an event explains each node (Section 7).

## Containers are not scheduled, pods are

All containers in one pod run on the **same node**. You cannot split a pod across nodes, and you cannot schedule a container on its own. Which pods exist is decided by whatever created them (a Deployment's template, a DaemonSet, a Job, or you directly).

## Bypassing the scheduler

Setting `spec.nodeName` yourself assigns the pod to a node directly, and the scheduler is not involved. It also skips the scheduler's checks, so use it only for testing.

---

# 2. Seeing where a pod went, and why

**Where did it land:**

```bash
kubectl get pods -o wide
kubectl get pod NAME -o jsonpath='{.spec.nodeName}{"\n"}'
kubectl get pods -A -o wide --field-selector spec.nodeName=worker1
```

`-o wide` adds the `NODE` column. The last form lists every pod on one node. On the real cluster it listed five pods on worker1, and `kubectl describe node worker1` agreed (`Non-terminated Pods: (5 in total)`).

`NAME` is a placeholder: replace it with a real pod name.

**Why that node:** the `Events` section of `kubectl describe pod NAME` usually has a line like `Scheduled ... Successfully assigned <namespace>/<pod> to <node>` (this line was not captured in these labs). It does not explain the ranking.

**Why no node** is the more useful case, and Section 7 decodes those messages.

## What a node can hold

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory
kubectl describe node worker1
```

### Observed on the real cluster

```text
NAME      CPU   MEMORY
master    2     1845588Ki
worker1   2     1845584Ki
worker2   2     1845588Ki

Capacity:
  cpu:                2
  memory:             1947984Ki
  pods:               110
Allocatable:
  cpu:                2
  memory:             1845584Ki
  pods:               110

Non-terminated Pods:          (5 in total)
  Namespace      Name                       CPU Requests  CPU Limits  Memory Requests  Memory Limits
  default        nginx-5577fb97b9-2ljzz     0 (0%)        0 (0%)      0 (0%)           0 (0%)
  default        nginx-5577fb97b9-fqrnr     0 (0%)        0 (0%)      0 (0%)           0 (0%)
  kube-flannel   kube-flannel-ds-mjmv8      100m (5%)     0 (0%)      50Mi (2%)        0 (0%)
  kube-system    coredns-589f44dc88-2tpjr   100m (5%)     0 (0%)      70Mi (3%)        170Mi (9%)
  kube-system    kube-proxy-mlzjg           0 (0%)        0 (0%)      0 (0%)           0 (0%)
Allocated resources:
  cpu                200m (10%)  0 (0%)
  memory             120Mi (6%)  170Mi (9%)
```

| Observation | Meaning |
|---|---|
| Allocatable memory is **102,400 Ki less than capacity** | That is exactly 100 Mi, which matches the kubelet's default memory reserve for eviction. The match suggests that is the cause, but the kubelet's configuration was not checked |
| About **1.76 GiB** allocatable per node | Everything the scheduler can hand out on a node |
| The two nginx pods show `0 (0%)` requests | The scheduler counts **requests**, not real usage. A pod with no requests looks free |
| flannel and CoreDNS have requests | These are the only reservations on worker1 |
| `pods: 110` | A node also has a pod-count limit |

---

# 3. Requests and limits

| | Requests | Limits |
|---|---|---|
| Who uses them | The **scheduler**, when it picks a node | The **kubelet**, while the container runs |
| What a node counts | The **sum of requests** against allocatable resources. Real usage is ignored | |
| If exceeded | Not applicable | Memory: the container is killed (`OOMKilled`). CPU: it is throttled, not killed |

```yaml
resources:
  requests:
    cpu: 100m          # 100 millicores = a tenth of a core
    memory: 64Mi
  limits:
    cpu: 100m
    memory: 64Mi
```

`1` CPU is one core, and `100m` is 100 millicores. Memory units are `Mi` (mebibytes) and `Gi`.

## Lab 1: what the scheduler counts

Run these labs in a `sched` namespace so that cleanup is one command:

```bash
kubectl create namespace sched
kubectl config set-context --current --namespace=sched
```

Look at the reserved requests on each node, create three pods, and look again:

```bash
for n in master worker1 worker2; do echo "-- $n"; kubectl describe node $n | sed -n '/Allocated resources/,/ephemeral-storage/p' | grep -E "cpu|memory"; done
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: qos-besteffort
spec:
  containers:
  - name: app
    image: nginx
---
apiVersion: v1
kind: Pod
metadata:
  name: qos-burstable
spec:
  containers:
  - name: app
    image: nginx
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: qos-guaranteed
spec:
  containers:
  - name: app
    image: nginx
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 64Mi
EOF
sleep 10
kubectl get pods -o wide
for p in qos-besteffort qos-burstable qos-guaranteed; do echo "$p -> $(kubectl get pod $p -o jsonpath='{.status.qosClass}')"; done
for n in master worker1 worker2; do echo "-- $n"; kubectl describe node $n | sed -n '/Allocated resources/,/ephemeral-storage/p' | grep -E "cpu|memory"; done
```

### Observed on the real cluster

```text
(baseline)                            (after the three pods)
-- master                             -- master
  cpu     850m (42%)   0 (0%)           cpu     850m (42%)   0 (0%)
  memory  220Mi (12%)  170Mi (9%)       memory  220Mi (12%)  170Mi (9%)
-- worker1                            -- worker1
  cpu     200m (10%)   0 (0%)           cpu     300m (15%)   0 (0%)
  memory  120Mi (6%)   170Mi (9%)       memory  184Mi (10%)  170Mi (9%)
-- worker2                            -- worker2
  cpu     100m (5%)    0 (0%)           cpu     200m (10%)   100m (5%)
  memory  50Mi (2%)    0 (0%)           memory  114Mi (6%)   64Mi (3%)

NAME             READY   STATUS    RESTARTS   AGE   IP             NODE
qos-besteffort   1/1     Running   0          10s   10.244.2.217   worker2
qos-burstable    1/1     Running   0          10s   10.244.1.74    worker1
qos-guaranteed   1/1     Running   0          10s   10.244.2.218   worker2
qos-besteffort -> BestEffort
qos-burstable -> Burstable
qos-guaranteed -> Guaranteed
```

| Prediction | Observed |
|---|---|
| Requests rise by exactly **200m CPU and 128Mi memory** in total, and the pod with no requests adds nothing | worker1 gained 100m and 64Mi (the Burstable pod), worker2 gained 100m and 64Mi (the Guaranteed pod). **+200m and +128Mi** overall. The BestEffort pod changed no column |
| All three on the workers | Yes: none on the master, whose taint keeps ordinary pods off it |

The Guaranteed pod also moved worker2's **limits** from `0` to `100m` CPU and `64Mi` memory.

The baseline is worth noting: the **master** already has **850m CPU (42%)** reserved before any workload runs. That fits the control-plane pods' typical requests (the sum of the usual figures for the API server, controller manager, scheduler, etcd, CoreDNS and flannel is exactly 850m, though each pod was not checked).

## Lab 2: the sum of requests decides, not usage

Five pods each *ask* for 800Mi, though nginx uses only a few megabytes:

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hog
spec:
  replicas: 5
  selector:
    matchLabels:
      app: hog
  template:
    metadata:
      labels:
        app: hog
    spec:
      containers:
      - name: app
        image: nginx
        resources:
          requests:
            memory: 800Mi
EOF
sleep 15
kubectl get deployment hog
kubectl get pods -l app=hog -o wide
kubectl describe $(kubectl get pods -l app=hog --field-selector=status.phase=Pending -o name | head -1) | tail -6
for n in worker1 worker2; do echo "-- $n"; kubectl describe node $n | sed -n '/Allocated resources/,/ephemeral-storage/p' | grep -E "cpu|memory"; done
```

In PowerShell, compare with the real memory use:

```powershell
multipass exec worker1 -- free -m
multipass exec worker2 -- free -m
```

### Observed on the real cluster

```text
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
hog    4/5     5            4           15s
NAME                   READY   STATUS    RESTARTS   AGE   IP             NODE
hog-7798d5896f-7sr9m   1/1     Running   0          15s   10.244.1.76    worker1
hog-7798d5896f-9pp5j   0/1     Pending   0          15s   <none>         <none>
hog-7798d5896f-kftlc   1/1     Running   0          15s   10.244.2.220   worker2
hog-7798d5896f-vk82s   1/1     Running   0          15s   10.244.1.75    worker1
hog-7798d5896f-xscfl   1/1     Running   0          15s   10.244.2.219   worker2

-- worker1
  cpu                300m (15%)    0 (0%)
  memory             1784Mi (98%)  170Mi (9%)
-- worker2
  cpu                200m (10%)    100m (5%)
  memory             1714Mi (95%)  64Mi (3%)

worker1:  Mem:  total 1902  used 557  free 234  buff/cache 1306  available 1344
worker2:  Mem:  total 1902  used 563  free 200  buff/cache 1335  available 1338
```

| Prediction | Observed |
|---|---|
| `READY 4/5`, two pods on each worker, one `Pending` | Exactly that |
| Each worker around 95% reserved | worker1 **98%**, worker2 **95%** |

The arithmetic is exact: worker1 had 184Mi reserved, plus 2 × 800Mi, is **1784Mi**. worker2: 114Mi + 2 × 800Mi = **1714Mi**. A worker's allocatable memory is about 1,802Mi, so only about 18Mi is left on worker1 and 88Mi on worker2. A third 800Mi pod fits nowhere.

**Reserved against real use:** the scheduler sees worker1 as **98% full**, while the kernel reports about **557 MB used** and **1,344 MB available**. The four `hog` pods reserve memory they never use. A request is a **reservation**, so an over-generous request wastes capacity, and a pod can be refused by a node that is mostly idle.

---

# 4. QoS classes

Kubernetes labels every pod with a **Quality of Service** class, derived from its requests and limits.

| Class | Rule | Lab 1 pod |
|---|---|---|
| **Guaranteed** | Every container has CPU and memory requests **and** limits, with requests equal to limits | `qos-guaranteed` |
| **Burstable** | At least one request or limit is set, but not the Guaranteed pattern | `qos-burstable` |
| **BestEffort** | No requests or limits at all | `qos-besteffort` |

Read the class with `kubectl get pod NAME -o jsonpath='{.status.qosClass}'`. The three classes in Lab 1 came out as predicted.

The class matters under **node memory pressure**: as I understand it, BestEffort pods are evicted first, and Guaranteed pods last. That eviction order was not tested here.

---

# 5. A memory limit: `OOMKilled`

A container that exceeds its **memory** limit is killed. `polinux/stress` is a third-party image used in the Kubernetes documentation's memory examples. This pod tries to allocate **250MB** against a **100Mi** limit:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: oom-demo
spec:
  containers:
  - name: stress
    image: polinux/stress
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
    resources:
      requests:
        memory: 50Mi
      limits:
        memory: 100Mi
EOF
for i in $(seq 1 12); do echo "$(date -u +%T)  $(kubectl get pod oom-demo --no-headers 2>&1 | awk '{print $2, $3, $4}')"; sleep 5; done
kubectl describe pod oom-demo | sed -n '/Last State/,/Ready:/p'
kubectl get pod oom-demo -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{" exit="}{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
kubectl get pod oom-demo -o jsonpath='{.status.qosClass}{"\n"}'
```

### Observed on the real cluster

```text
23:15:56  0/1 ContainerCreating 0
23:16:01  0/1 OOMKilled 1
23:16:07  0/1 CrashLoopBackOff 1
23:16:17  0/1 OOMKilled 2
23:16:37  0/1 CrashLoopBackOff 2
23:16:42  0/1 OOMKilled 3
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Fri, 09 Oct 2026 16:16:13 -0700
      Finished:     Fri, 09 Oct 2026 16:16:13 -0700
OOMKilled exit=137
Burstable
```

| Prediction | Observed |
|---|---|
| `OOMKilled`, then `CrashLoopBackOff`, with restarts climbing | Yes: restarts 1, 2, 3, alternating between the two statuses |
| Waits between restarts growing | Restarts at about 23:16:01, 23:16:17 and 23:16:42, so gaps of about **16 and 25 seconds**. I predicted about 10, 20, 40. The sample ended before a third gap |
| Exit code **137** | **137**, which is 128 plus 9, the kill signal |
| QoS class Burstable | **Burstable** |

`Started` and `Finished` are the **same second**: the tool tried to allocate 250MB against 100Mi and was killed in under a second. The times in `describe` are local (PDT), so `16:16:13 -0700` matches `23:16:13` UTC. The node had plenty of free memory: the kill came from the container's own limit, not from node pressure. The pod keeps restarting indefinitely, since the default restart policy is `Always`.

---

# 6. A CPU limit: throttling

A container that exceeds its **CPU** limit is not killed. It is **throttled**, slowed down. CPU use is invisible without `metrics-server`, so this reads the container's own cgroup counters (cgroup v2, the default on Ubuntu 24.04). Both pods run a shell loop that burns a full core. One has a limit of 100m, and the other has no limit:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cpu-limited
spec:
  containers:
  - name: burn
    image: busybox
    command: ["sh", "-c", "while :; do :; done"]
    resources:
      requests:
        cpu: 50m
      limits:
        cpu: 100m
---
apiVersion: v1
kind: Pod
metadata:
  name: cpu-free
spec:
  containers:
  - name: burn
    image: busybox
    command: ["sh", "-c", "while :; do :; done"]
    resources:
      requests:
        cpu: 50m
EOF
sleep 15
kubectl get pods -o wide
for p in cpu-limited cpu-free; do
  echo "=== $p ==="
  echo "cpu.max (quota, period): $(kubectl exec $p -- cat /sys/fs/cgroup/cpu.max)"
  a=$(kubectl exec $p -- sh -c 'grep "^usage_usec" /sys/fs/cgroup/cpu.stat' | awk '{print $2}')
  t0=$(date +%s.%N)
  sleep 10
  b=$(kubectl exec $p -- sh -c 'grep "^usage_usec" /sys/fs/cgroup/cpu.stat' | awk '{print $2}')
  t1=$(date +%s.%N)
  awk -v a=$a -v b=$b -v t0=$t0 -v t1=$t1 'BEGIN {printf "CPU used over the window: %.2f cores\n", (b-a)/1000000/(t1-t0)}'
  kubectl exec $p -- cat /sys/fs/cgroup/cpu.stat
done
```

### Observed on the real cluster

```text
=== cpu-limited ===
cpu.max (quota, period): 10000 100000
CPU used over the window: 0.10 cores
nr_periods 209
nr_throttled 27
throttled_usec 303546

=== cpu-free ===
cpu.max (quota, period): max 100000
CPU used over the window: 1.00 cores
nr_periods 0
nr_throttled 0
throttled_usec 0
```

| Prediction | `cpu-limited` | `cpu-free` |
|---|---|---|
| `cpu.max` | `10000 100000`: 10,000 µs of CPU per 100,000 µs period, a tenth of a core | `max 100000`: no quota |
| CPU used | **0.10 cores** | **1.00 cores** |
| Status | `Running`, never killed | `Running` |

The main result: `cpu-free` asked for only **50m** and used a **full core**. A request is not a cap. It affects where the scheduler places the pod and how CPU is shared under contention, and a pod with no limit takes whatever is idle. The limited pod was held to exactly its limit, and throttled, not killed.

**What did not match.** I predicted "large and climbing" throttle counters. They read `nr_throttled 27` of `nr_periods 209`, with only 0.3 seconds of throttled time. A busy loop held to 10 ms of every 100 ms should be stopped in nearly **every** period, so those counters look too low, even though the usage figure proves the limit was enforced. The reason is not known. One untested guess: the quota is enforced at two levels, the container's cgroup and its parent pod cgroup, and the counters I read are only the container's. Reading the pod-level `cpu.stat` on the node would check it.

---

# 7. Reading `FailedScheduling` messages

When no node passes filtering, the pod stays `Pending`, and the event explains every node. The numbers add up to your node count, and the first part names each reason. These are the four messages the labs produced:

| Pod | Message (the first sentence) | What it means |
|---|---|---|
| `too-big` (requested 8 Gi) | `0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient memory.` | The master is rejected for its taint, the workers for too little memory |
| `hog` (800Mi, when each worker already held two such pods) | `0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient memory.` | The same words, although this pod **would fit on an empty worker** |
| `aff-nvme` (a required affinity no node meets) | `0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector.` | Taint for the master, label mismatch for the workers |
| `spread-a` (Section 9) | `0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match pod topology spread constraints.` | Taint for the master, the spread rule for the workers |

Notice that the master is reported for its **taint** in each case, whatever else was true of it. The `Insufficient memory` message gives no hint that the memory is reserved but idle.

## The preemption sentence

Each message continues with a note about **preemption**, where the scheduler checks whether evicting a lower-priority pod would make room. The wording differs, and the difference carries information:

| Pod | The preemption part |
|---|---|
| `too-big` | `3 Preemption is not helpful for scheduling` |
| `hog` | `1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod` |
| `aff-nvme` | `3 Preemption is not helpful for scheduling` |

As I read them, which is an inference from the wording:

- **"Preemption is not helpful"** means evicting pods could not make the pod fit. For `too-big` that holds on every node, since even an empty worker cannot hold 8 Gi, and for `aff-nvme` since evicting pods cannot change a node's labels. For `hog` it applies only to the master (excluded by its taint).
- **"No preemption victims found"** means the pod *would* fit on that node if something were evicted, but nothing there may be evicted, because every pod has the same or a higher priority. All the pods here have the default priority, so none is a candidate.

So the message tells you whether the problem is "this will never fit there" or "it would fit if something less important were removed". A higher-priority class would change the second case. That was not tested.

---

# 8. Choosing nodes: `nodeSelector` and node affinity

## The tools

| Tool | What it does |
|---|---|
| `nodeName` | Names the node directly, bypassing the scheduler |
| `nodeSelector` | The pod runs only on nodes with matching labels (equality only) |
| Node affinity, **required** | A flexible selector, a hard rule, with operators such as `In` |
| Node affinity, **preferred** | A soft rule with a weight, added to the node's score |
| Taints and tolerations | A node repels pods, and a pod opts in (Section 10) |

The long field names carry a meaning: `requiredDuringScheduling` is a hard rule at scheduling time, `preferredDuringScheduling` is a soft one, and `IgnoredDuringExecution` means **a running pod is not moved if the labels change later**.

## Lab 3: required and preferred affinity

Label the two workers, create five pods, and then remove a label from a running pod's node:

```bash
kubectl label node worker1 disk=ssd
kubectl label node worker2 disk=hdd
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: sel-ssd
spec:
  nodeSelector:
    disk: ssd
  containers:
  - name: app
    image: nginx
---
apiVersion: v1
kind: Pod
metadata:
  name: aff-hdd
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disk
            operator: In
            values: ["hdd"]
  containers:
  - name: app
    image: nginx
---
apiVersion: v1
kind: Pod
metadata:
  name: aff-nvme
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disk
            operator: In
            values: ["nvme"]
  containers:
  - name: app
    image: nginx
---
apiVersion: v1
kind: Pod
metadata:
  name: pref-ssd
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: disk
            operator: In
            values: ["ssd"]
  containers:
  - name: app
    image: nginx
---
apiVersion: v1
kind: Pod
metadata:
  name: pref-nvme
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: disk
            operator: In
            values: ["nvme"]
  containers:
  - name: app
    image: nginx
EOF
sleep 12
kubectl get pods -o wide
kubectl describe pod aff-nvme | tail -4
kubectl label node worker1 disk-
sleep 5
kubectl get pod sel-ssd -o wide
kubectl label node worker1 disk=ssd
```

### Observed on the real cluster

```text
NAME        READY   STATUS    RESTARTS   AGE   IP             NODE
aff-hdd     1/1     Running   0          12s   10.244.2.225   worker2
aff-nvme    0/1     Pending   0          12s   <none>         <none>
pref-nvme   1/1     Running   0          12s   10.244.2.226   worker2
pref-ssd    1/1     Running   0          12s   10.244.1.81    worker1
sel-ssd     1/1     Running   0          12s   10.244.1.80    worker1

Warning  FailedScheduling  12s   default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.

(after removing worker1's label)
sel-ssd   1/1   Running   0   17s   10.244.1.80   worker1
```

| Pod | Predicted | Observed |
|---|---|---|
| `sel-ssd` (a `nodeSelector`) | worker1 | **worker1** |
| `aff-hdd` (required, `hdd`) | worker2 | **worker2** |
| `aff-nvme` (required, a label no node has) | `Pending` | **Pending**, with the event above |
| `pref-ssd` (preferred, `ssd`) | worker1 | **worker1** |
| `pref-nvme` (preferred, a label no node has) | Runs, on either worker | **Runs, on worker2** |
| `sel-ssd` after worker1's label was removed | Stays `Running` | **Stays `Running` on worker1** |

A **required** rule can leave a pod `Pending` forever, while a **preferred** rule never blocks scheduling. And `IgnoredDuringExecution` is demonstrated: `sel-ssd` stayed on worker1 after the label was removed, so both `nodeSelector` and affinity are checked **only when the pod is scheduled**.

## Lab 4: how soft is a preference?

One pod landing on the preferred node could be chance. Two experiments test it. The first creates six small pods that prefer `ssd`, and the second creates six 600Mi pods that prefer `ssd`, more than worker1 can hold:

```bash
kubectl label node worker1 disk=ssd
kubectl label node worker2 disk=hdd
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: soft-small
spec:
  replicas: 6
  selector:
    matchLabels:
      app: soft-small
  template:
    metadata:
      labels:
        app: soft-small
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: disk
                operator: In
                values: ["ssd"]
      containers:
      - name: app
        image: nginx
EOF
sleep 15
kubectl get pods -l app=soft-small -o custom-columns=NODE:.spec.nodeName --no-headers | sort | uniq -c
kubectl delete deployment soft-small
```

Then the second experiment:

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: soft-big
spec:
  replicas: 6
  selector:
    matchLabels:
      app: soft-big
  template:
    metadata:
      labels:
        app: soft-big
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: disk
                operator: In
                values: ["ssd"]
      containers:
      - name: app
        image: nginx
        resources:
          requests:
            memory: 600Mi
EOF
sleep 15
kubectl get pods -l app=soft-big -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
kubectl delete deployment soft-big
```

### Observed on the real cluster

```text
(six small pods)
      6 worker1

(the baseline reserved memory: worker1 120Mi, worker2 50Mi)
soft-big-7d68d4b6bf-2s2xs   Running   worker1
soft-big-7d68d4b6bf-ck7fq   Pending   <none>
soft-big-7d68d4b6bf-hsvml   Running   worker2
soft-big-7d68d4b6bf-j5qmp   Running   worker1
soft-big-7d68d4b6bf-srrgv   Pending   <none>
soft-big-7d68d4b6bf-tlhn4   Running   worker2
```

| Experiment | Predicted | Observed |
|---|---|---|
| Six small pods that prefer `ssd` | Most or all on worker1 | **All six on worker1**, so the preference outweighed the default balancing |
| Six 600Mi pods that prefer `ssd` | 4 Running (two per worker), 2 Pending | **Exactly that** |

The second result follows from arithmetic: about 1,802Mi is allocatable per worker, with 120Mi and 50Mi already reserved. Two 600Mi pods fit on each (1,320Mi and 1,250Mi), and a third does not (1,920Mi and 1,850Mi). worker1 filled first because of the preference, and the overflow went to worker2. **A preference is a weight, and it gives way to capacity.**

---

# 9. Topology spread constraints

A **topology spread constraint** asks the scheduler to keep a deployment's pods evenly spread across failure domains, such as nodes or zones.

```yaml
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: kubernetes.io/hostname
  whenUnsatisfiable: DoNotSchedule
  labelSelector:
    matchLabels:
      app: spread-a
```

| Field | Meaning |
|---|---|
| `topologyKey` | The node label that defines a domain. `kubernetes.io/hostname` makes each node a domain |
| `maxSkew` | The largest allowed difference between the busiest domain and the emptiest one |
| `whenUnsatisfiable` | `DoNotSchedule` is a hard rule, and `ScheduleAnyway` is a preference |
| `labelSelector` | Which pods are counted |
| `nodeTaintsPolicy` | Whether nodes a pod cannot run on, because of an untolerated taint, are counted. `Honor` excludes them. The default, as I understand it, counts them |

## Lab 5: the master as an empty domain

Three Deployments of four pods each, differing only in how they handle the spread. The tainted master takes no pods, which matters:

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-a
spec:
  replicas: 4
  selector:
    matchLabels:
      app: spread-a
  template:
    metadata:
      labels:
        app: spread-a
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: spread-a
      containers:
      - name: app
        image: nginx
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-b
spec:
  replicas: 4
  selector:
    matchLabels:
      app: spread-b
  template:
    metadata:
      labels:
        app: spread-b
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        nodeTaintsPolicy: Honor
        labelSelector:
          matchLabels:
            app: spread-b
      containers:
      - name: app
        image: nginx
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-c
spec:
  replicas: 4
  selector:
    matchLabels:
      app: spread-c
  template:
    metadata:
      labels:
        app: spread-c
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app: spread-c
      containers:
      - name: app
        image: nginx
EOF
sleep 15
for a in spread-a spread-b spread-c; do echo "== $a =="; kubectl get pods -l app=$a -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName; done
kubectl get events --field-selector reason=FailedScheduling | tail -2
```

### Observed on the real cluster

```text
== spread-a ==
spread-a-7fdf9b6fc-9bqnq   Running   worker2
spread-a-7fdf9b6fc-d97jk   Pending   <none>
spread-a-7fdf9b6fc-prd9x   Pending   <none>
spread-a-7fdf9b6fc-s5tdj   Running   worker1
== spread-b ==
spread-b-59cf755bfd-cldg9   Running   worker2
spread-b-59cf755bfd-fmxp5   Running   worker2
spread-b-59cf755bfd-qjzlc   Running   worker1
spread-b-59cf755bfd-sfckv   Running   worker1
== spread-c ==
spread-c-6dc9c75678-4xmjr   Running   worker1
spread-c-6dc9c75678-8k7w4   Running   worker2
spread-c-6dc9c75678-x2w58   Running   worker1
spread-c-6dc9c75678-xl9xp   Running   worker2

0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match pod topology spread constraints. ...
```

| Deployment | Predicted | Observed |
|---|---|---|
| `spread-a` (`DoNotSchedule`) | 2 Running (one per worker), 2 Pending | **1 on each worker, and 2 `Pending`** |
| `spread-b` (`Honor`) | All 4 Running, two per worker | **4 Running, two on each worker** |
| `spread-c` (`ScheduleAnyway`) | All 4 Running | **4 Running, two on each worker** |

My explanation of `spread-a`, which is an inference: by default the tainted master still counts as a spread domain, with **zero pods that it can never receive**. With `maxSkew: 1`, a worker holding two pods would be at a skew of 2 against that minimum of 0, so each worker is limited to one pod. `Honor` removes the master from the calculation, so the workers can hold two each, and `ScheduleAnyway` makes the rule a preference, so nothing stays Pending. The results fit this reading, but the scheduler's internals were not inspected.

A common trap on clusters with tainted control-plane nodes: a hard spread rule can leave pods `Pending` for a reason that the message names only as "didn't match pod topology spread constraints".

---

# 10. Taints and tolerations, in brief

Covered in detail in the workload controllers guide (the DaemonSet labs), and the key facts are:

| Fact | Evidence |
|---|---|
| The master's taint `node-role.kubernetes.io/control-plane:NoSchedule` keeps ordinary pods off it | Every lab above placed pods only on the workers |
| A pod runs there only if it **tolerates** the taint | A DaemonSet with the toleration got a pod on the master |
| flannel tolerates any `NoSchedule` taint (`operator: Exists`, `effect: NoSchedule`) | Read from its DaemonSet template |
| kube-proxy tolerates **every** taint (a bare `operator: Exists`) | Read from its DaemonSet template |
| A taint's effect decides what happens: `NoSchedule` blocks new pods, `NoExecute` also evicts running ones | The earlier taint labs |

Every `FailedScheduling` event above names the master's taint first. That is the master doing what it is meant to do.

---

# 11. Practical tips for running these labs

- **Paste long blocks in pieces.** On the real run, the terminal wrapped a very long paste and fused two commands together (for example `kubectl label node worker1 disk=ssdat scheduling time ===`). The results survived, but it is safer to paste one piece at a time and wait for its output.
- **Clean up after each block.** `kubectl delete namespace sched` removes the pods, but **node labels are not in a namespace**, so remove them yourself: `kubectl label node worker1 disk-` and `kubectl label node worker2 disk-`. Then check with `kubectl get nodes --show-labels | grep disk`, which should print nothing.
- **Wait for a namespace to disappear** before creating it again (`kubectl get ns sched` should say `NotFound`).
- **Check the VM clocks after the laptop sleeps.** Several timing results in these guides were distorted by a clock problem (see the workload controllers guide, Section 15).

---

# 12. Common mistakes and troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| A pod is `Pending` with `Insufficient memory` or `Insufficient cpu`, but the node looks idle | Requests are a **reservation**. The sum of requests is full, not the usage | Compare `Allocated resources` in `kubectl describe node` with real use (`free -m`). Lower the requests |
| A pod is `Pending` with `didn't match Pod's node affinity/selector` | A required label rule that no node meets | Check the labels (`kubectl get nodes --show-labels`), or use a preferred rule |
| A pod is `Pending` with `didn't match pod topology spread constraints` | A hard spread rule, possibly counting a tainted node as an empty domain | Use `nodeTaintsPolicy: Honor`, or `ScheduleAnyway` |
| A pod is `Pending` with `untolerated taint(s)` | The node has a taint the pod does not tolerate | Add a toleration, or use another node |
| A container restarts again and again with `OOMKilled` and exit code 137 | It exceeds its memory limit | Raise the limit or fix the memory use |
| A container is slow but not killed | It is being CPU-throttled by its limit | Raise the CPU limit, or remove it (and mind the requests) |
| A pod with a tiny CPU request uses a whole core | A request is not a cap. Only a limit caps | Set a limit if you need a cap |
| An affinity change does not move running pods | `IgnoredDuringExecution`: affinity is checked only at scheduling time | Delete the pod so it is rescheduled |
| `kubectl describe pod pod/NAME` fails with `there is no need to specify a resource type` | `-o name` already prints `pod/NAME` | Use `kubectl describe $(... -o name)` with no extra `pod` |
| Node labels remain after a lab | Node labels are not part of a namespace | `kubectl label node NAME key-` |

---

# 13. Command cheat sheet

| Task | Command |
|---|---|
| Where did pods go | `kubectl get pods -o wide` |
| Pods on one node | `kubectl get pods -A -o wide --field-selector spec.nodeName=NODE` |
| Why a pod is Pending | `kubectl describe pod NAME` (read `Events`) |
| All scheduling failures | `kubectl get events --field-selector reason=FailedScheduling` |
| What a node holds | `kubectl describe node NODE` (read `Allocated resources`) |
| A pod's QoS class | `kubectl get pod NAME -o jsonpath='{.status.qosClass}'` |
| Last termination reason | `kubectl get pod NAME -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'` |
| Label a node | `kubectl label node NODE key=value` |
| Remove a node label | `kubectl label node NODE key-` |
| Pods per node | `kubectl get pods -l app=NAME -o custom-columns=NODE:.spec.nodeName --no-headers \| sort \| uniq -c` |
| CPU quota in a container | `kubectl exec POD -- cat /sys/fs/cgroup/cpu.max` |
| Real memory on a node | `multipass exec NODE -- free -m` |

---

# 14. Glossary

| Term | Meaning |
|---|---|
| **Scheduler** | The component that assigns pods to nodes |
| **Filtering / scoring** | The two stages: drop unsuitable nodes, then rank the rest |
| **Request** | The resources a pod reserves. The scheduler counts requests |
| **Limit** | The most a container may use. The kubelet enforces it |
| **Allocatable** | A node's capacity minus what Kubernetes reserves for itself |
| **QoS class** | `Guaranteed`, `Burstable` or `BestEffort`, derived from requests and limits |
| **OOMKilled** | A container killed for exceeding its memory limit (exit code 137) |
| **Throttling** | Slowing a container that exceeds its CPU limit, without killing it |
| **Node affinity** | A flexible rule matching node labels, hard or soft |
| **Topology spread** | A rule to keep pods evenly spread over domains |
| **Skew** | The difference in pod count between the busiest and emptiest domain |
| **Preemption** | Evicting lower-priority pods to make room for a higher-priority one |
| **Taint / toleration** | A node's repelling mark, and a pod's permission to ignore it |

---

# 15. What was run, and what was not

## Run on the real cluster (the output above is from these)

- The scheduler's accounting: reserved requests per node before and after three pods, and five pods requesting 800Mi (4 Running, 1 Pending, 98% and 95% reserved against about 557 MB really used)
- The three QoS classes, and an `OOMKilled` pod (exit code 137, restarts with growing waits)
- CPU throttling: a limited pod held at 0.10 cores, and an unlimited pod with a 50m request using 1.00 cores
- Four `FailedScheduling` messages, including the difference in their preemption sentences
- `nodeSelector`, required and preferred node affinity, and a running pod staying put after its node's label was removed
- A preference tested with six pods (all on the preferred node) and with more pods than fit (overflow to the other node)
- Topology spread with `DoNotSchedule`, with `nodeTaintsPolicy: Honor`, and with `ScheduleAnyway`

## Not run

- **Pod priority and preemption**, so the "No preemption victims found" explanation is an inference
- **Pod affinity and anti-affinity** (placing pods near or away from other pods)
- **Eviction order under real node memory pressure**, so the QoS ordering is from documentation, not from a test
- **`LimitRange` and `ResourceQuota`**, which set defaults and caps per namespace
- **The pod-level cgroup check** that would explain the low throttle counters, and a cluster with several zones
- **Other node-affinity operators** (`NotIn`, `Exists`, `Gt`, `Lt`), and `nodeAffinityPolicy`

The explanations marked as inferences or guesses in the text (the low throttle counters, the preemption wording, the master counting as an empty domain) are the best fit to the evidence, and not verified. Check the official Kubernetes documentation for the version you run.

## Clean up everything from this guide

```bash
kubectl delete namespace sched
kubectl config set-context --current --namespace=default
kubectl label node worker1 disk-
kubectl label node worker2 disk-
kubectl get nodes --show-labels | grep disk
```

The first command deletes every object created in the labs, the second puts your kubeconfig back on the `default` namespace, and the label commands remove the node labels. The last command should print nothing.
