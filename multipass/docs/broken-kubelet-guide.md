# Kubernetes: When a Node Goes NotReady

## Four ways to break a kubelet, how each looks from the control plane, and how to find the cause on the node, tested on a real cluster

A node that stops being `Ready` can have many causes, and from the master they can look alike. This guide breaks one worker four different ways, records exactly what the control plane shows each time, and then shows where the real cause is written down. It was run on a real kubeadm cluster (1 control plane, 2 workers, Kubernetes v1.36.5, containerd 2.2.1). The console output after each lab is copied from the run. Where a prediction was wrong, the guide says so, and explanations marked as inferences are best guesses, not results.

Only **worker2** was ever broken, and each fault had its undo ready before it started.

**Contents**

1. How the control plane judges a node
2. A healthy node: what to read
3. The test workload and a timeline function
4. Fault 1: the kubelet is stopped
5. Fault 2: the kubelet can't reach the API server
6. Fault 3: the container runtime is stopped
7. Fault 4: swap is on, and the kubelet refuses to start
8. The four faults side by side
9. A triage procedure
10. What I got wrong
11. Practical tips for running these labs
12. Troubleshooting
13. Command cheat sheet
14. Glossary
15. What was run, and what was not

---

# 1. How the control plane judges a node

The master never looks at a node directly. It watches **signals the kubelet sends**, and decides from their absence or content.

| Signal | What it is | How often |
|---|---|---|
| The **lease** | An object `kube-node-lease/<node>` whose `renewTime` the kubelet updates. It is the node's **heartbeat** | **Every 10 seconds** (observed) |
| The **node status** | The `Ready`, `MemoryPressure`, `DiskPressure` and `PIDPressure` conditions | On changes, and on a long timer (see Section 10) |

The controller manager decides:

| Situation | `Ready` becomes | Reason | Taints added |
|---|---|---|---|
| No lease renewal for the **grace period** | **`Unknown`** | `NodeStatusUnknown` | `unreachable:NoSchedule` and `unreachable:NoExecute` |
| The kubelet reports a problem itself | **`False`** | `KubeletNotReady` | `not-ready:NoSchedule` and `not-ready:NoExecute` |

The grace period is **50 seconds** on this cluster, confirmed from the controller manager's own help:

```bash
kubectl -n kube-system exec kube-controller-manager-master -- kube-controller-manager --help 2>/dev/null | grep -A2 -E -- '--node-monitor-(grace-period|period)'
```

```text
--node-monitor-grace-period duration     Amount of time which we allow running Node to be unresponsive before marking it unhealthy. ... (default 50s)
```

A tainted node keeps its pods until each pod's **toleration** for the `NoExecute` taint runs out. Pods get a default toleration of **300 seconds** for both taints (an inference from the `nginx` pods in Fault 3), and the lab Deployment lowers it to **30 seconds** to shorten the waits. Pods of DaemonSets tolerate the taints indefinitely.

**Two things to remember:** `Unknown` means the control plane **stopped hearing** from the kubelet. `False` means the kubelet **is talking**, and reporting that something is wrong. That one distinction narrows the cause before you touch the node.

---

# 2. A healthy node: what to read

Read the healthy state first, so a broken one stands out. From the master:

```bash
kubectl get nodes -o wide
kubectl describe node worker2 | sed -n '/^Conditions:/,/^Addresses:/p'
kubectl get lease -n kube-node-lease
kubectl get lease worker2 -n kube-node-lease -o jsonpath='renewTime={.spec.renewTime}  duration={.spec.leaseDurationSeconds}s  holder={.spec.holderIdentity}{"\n"}'
```

### Observed on the real cluster

```text
worker2   Ready   worker   7d18h   v1.36.5   172.25.252.5   ...   containerd://2.2.1

  NetworkUnavailable   False   ...   FlannelIsUp                  Flannel is running on this node
  MemoryPressure       False   ...   KubeletHasSufficientMemory   kubelet has sufficient memory available
  DiskPressure         False   ...   KubeletHasNoDiskPressure     kubelet has no disk pressure
  PIDPressure          False   ...   KubeletHasSufficientPID      kubelet has sufficient PID available
  Ready                True    ...   KubeletReady                 kubelet is posting ready status

NAME      HOLDER    AGE
master    master    7d20h
worker1   worker1   7d18h
worker2   worker2   7d18h
renewTime=2026-10-13T18:10:16.439749Z  duration=40s  holder=worker2
```

Then the kubelet itself, **on the node** (`multipass shell worker2`). The kubelet is a system service, not a pod, so its files and logs are on the node. `kubectl` does not work there: a worker has no admin credentials, and it falls back to `localhost:8080`. **Never `cat` the whole `kubelet.conf`**; the patterns below print only paths and the address:

```bash
systemctl is-active kubelet containerd
systemctl cat kubelet | grep -vE '^\s*#|^\s*$'
sudo grep -E "^\s+server:|client-certificate:|client-key:|current-context" /etc/kubernetes/kubelet.conf
sudo grep -E "failSwapOn|cgroupDriver|staticPodPath|rotateCertificates|clusterDNS|serverTLSBootstrap" /var/lib/kubelet/config.yaml
sudo ls /var/lib/kubelet/pki
sudo ctr -n k8s.io tasks ls | wc -l
swapon --show | wc -l
```

### Observed on the real cluster

```text
active
active
[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS

    server: https://172.25.246.7:6443
current-context: default-context
    client-certificate: /var/lib/kubelet/pki/kubelet-client-current.pem
    client-key: /var/lib/kubelet/pki/kubelet-client-current.pem

cgroupDriver: systemd
clusterDNS:
rotateCertificates: true
staticPodPath: /etc/kubernetes/manifests

kubelet-client-2026-10-05-16-43-43.pem  kubelet-client-current.pem  kubelet.crt  kubelet.key
9
0
```

| Item | What it tells you |
|---|---|
| **`Restart=always`, `RestartSec=10`** | systemd restarts the kubelet **10 seconds after it exits**, unless it was stopped with `systemctl stop`. That is why a crashing kubelet loops (Fault 4), and a stopped one stays down (Fault 1) |
| `--kubeconfig=/etc/kubernetes/kubelet.conf` | The file holding the **API server address**. A wrong address here is Fault 2 |
| `--config=/var/lib/kubelet/config.yaml` | The kubelet's settings |
| `server: https://172.25.246.7:6443` | The master's fixed address |
| `client-certificate` and `client-key` | The **same** file, `kubelet-client-current.pem` |
| **No `failSwapOn` line** | The default applies, and the default refuses to run with swap (Fault 4) |
| **No `serverTLSBootstrap` line** | The kubelet's serving certificate is self-signed, which is why metrics-server needed `--kubelet-insecure-tls` (the HPA guide) |
| 9 task lines | A header plus 8 tasks: 4 pods with 2 each (sandbox and container) |

---

# 3. The test workload and a timeline function

Four pods that tolerate the `unreachable` and `not-ready` taints for only **30 seconds**, so the evictions come quickly:

```bash
cd ~
kubectl create namespace fault
kubectl config set-context --current --namespace=fault
cat > victim.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: victim
spec:
  replicas: 4
  selector:
    matchLabels:
      app: victim
  template:
    metadata:
      labels:
        app: victim
    spec:
      terminationGracePeriodSeconds: 1
      tolerations:
      - key: node.kubernetes.io/unreachable
        operator: Exists
        effect: NoExecute
        tolerationSeconds: 30
      - key: node.kubernetes.io/not-ready
        operator: Exists
        effect: NoExecute
        tolerationSeconds: 30
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app: victim
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "sleep 3600"]
EOF
kubectl apply -f victim.yaml
kubectl rollout status deployment/victim --timeout=90s
kubectl get pods -l app=victim -o wide
```

### Observed on the real cluster

```text
victim-5f9b4c4696-4pvws   1/1   Running   0   4s   10.244.1.112   worker1
victim-5f9b4c4696-pb8zs   1/1   Running   0   4s   10.244.2.9     worker2
victim-5f9b4c4696-whrmb   1/1   Running   0   4s   10.244.1.111   worker1
victim-5f9b4c4696-z8htn   1/1   Running   0   4s   10.244.2.8     worker2
```

Two pods on each worker, as predicted. A timeline function prints the control plane's view every 5 seconds: the `Ready` status, the age of the lease, the taints and where the `victim` pods are:

```bash
tl() {
  for i in $(seq 1 $1); do
    r=$(kubectl get node worker2 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    t=$(kubectl get node worker2 -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{" "}{end}' | sed 's#node.kubernetes.io/##g')
    rt=$(kubectl get lease worker2 -n kube-node-lease -o jsonpath='{.spec.renewTime}')
    age=$(( $(date +%s) - $(date -d "$rt" +%s) ))
    p=$(kubectl get pods -l app=victim -o wide --no-headers | awk '{print $7":"$3}' | sort | uniq -c | awk '{printf "%sx%s ", $1, $2}')
    echo "$(date -u +%T)  ready=$r  lease_age=${age}s  taints=[$t]  victim=[$p]"
    sleep ${2:-5}
  done
}
tl 4 5
```

### Observed on the real cluster

```text
21:02:23  ready=True  lease_age=9s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:02:28  ready=True  lease_age=5s  ...
21:02:33  ready=True  lease_age=0s  ...
21:02:38  ready=True  lease_age=5s  ...
```

The lease ages run 0, 5, 9, 10, 4...: **a renewal every 10 seconds**. Each loop line takes about 5.3 seconds, so times from it are accurate to about ±5 seconds. Where the node object recorded an exact time, the guide uses that instead.

---

# 4. Fault 1: the kubelet is stopped

The simplest fault. Start the loop in the master shell, and then stop the kubelet from PowerShell:

```bash
tl 26 5
```

```powershell
multipass exec worker2 -- sudo systemctl stop kubelet
(Get-Date).ToUniversalTime().ToString("HH:mm:ss") + "  kubelet stopped"
```

### Observed on the real cluster

```text
21:03:24  (the last lease renewal: lease_age=10s at 21:03:34)
21:03:32  kubelet stopped
21:03:34  ready=True  lease_age=10s
21:03:39  ready=True  lease_age=15s    <- and keeps climbing: 21, 26, 31, 36, 42, 47, 52
21:04:16  ready=True  lease_age=52s  taints=[]
21:04:21  ready=Unknown  lease_age=57s  taints=[unreachable:NoSchedule unreachable:NoExecute ]
21:04:47  ready=Unknown  lease_age=83s  victim=[2xworker1:Running 2xworker2:Running ]
21:04:52  ready=Unknown  lease_age=88s  victim=[4xworker1:Running 2xworker2:Terminating ]
```

| Item | Predicted | Observed |
|---|---|---|
| The lease after the stop | Climbs without resetting | **Yes** |
| `Unknown` | 35 to 50 s after the stop | **47 s after the stop, 55 s after the last renewal** (the node object stamps it 21:04:19) |
| `lease_age` at that moment | About 40 | **Wrong: 57.** The grace period is 50 s (Section 1), and the controller checks every 5 s |
| The taints | The `unreachable` pair, at the same moment | **Exactly that** |
| Eviction | About 30 s after the taints | **About 30 s**: `Running` at 21:04:47, `Terminating` at 21:04:52 |
| Replacements | A line or two to start | **Immediately**: four `Running` on worker1 in the same sample |

## Diagnose it, while it's down

```bash
P=$(kubectl get pods -l app=victim -o wide --no-headers | awk '$3=="Terminating" && $7=="worker2" {print $1; exit}')
kubectl logs $P
kubectl exec $P -- date
kubectl describe node worker2 | sed -n '/^Conditions:/,/^Addresses:/p'
kubectl get events -A --field-selector involvedObject.name=worker2 --sort-by=.lastTimestamp | tail -4
kubectl get pods -A -o wide --no-headers --field-selector spec.nodeName=worker2 | awk '{print $1"/"$2, $4}'
kubectl top nodes
```

### Observed on the real cluster

```text
Error from server: Get "https://172.25.252.5:10250/containerLogs/fault/victim-5f9b4c4696-pb8zs/app": dial tcp 172.25.252.5:10250: connect: connection refused
error: unable to upgrade connection: error dialing backend: dial tcp 172.25.252.5:10250: connect: connection refused

  MemoryPressure  Unknown  Tue, 13 Oct 2026 11:35:39 -0700  Tue, 13 Oct 2026 14:04:19 -0700  NodeStatusUnknown  Kubelet stopped posting node status.
  DiskPressure    Unknown  ...                                                                NodeStatusUnknown  Kubelet stopped posting node status.
  PIDPressure     Unknown  ...                                                                NodeStatusUnknown  Kubelet stopped posting node status.
  Ready           Unknown  ...                                                                NodeStatusUnknown  Kubelet stopped posting node status.

default   2m1s   Normal   NodeNotReady   node/worker2   Node worker2 status is now: NodeNotReady
default/nginx-5577fb97b9-4pp2g Running
default/nginx-5577fb97b9-c8bgh Running
fault/victim-5f9b4c4696-pb8zs Terminating
fault/victim-5f9b4c4696-z8htn Terminating
kube-flannel/kube-flannel-ds-dszmf Running
kube-system/kube-proxy-wqc59 Running

worker2   <unknown>   <unknown>   <unknown>   <unknown>
```

The API server reaches a pod's **logs and shell through the kubelet**, so a dead kubelet cuts both off, whatever the container is doing. `kubectl top` shows `<unknown>` for the node, since metrics-server can't scrape it. `NetworkUnavailable` stayed `False`: flannel set it, and not the kubelet.

## What is really running on the node

```powershell
multipass exec worker2 -- systemctl is-active kubelet containerd
multipass exec worker2 -- sudo ctr -n k8s.io tasks ls
multipass exec worker2 -- sudo sh -c "ctr -n k8s.io containers ls | grep -c busybox"
```

### Observed on the real cluster

```text
inactive
active
TASK    PID     STATUS
[12 tasks, every one RUNNING]
2
```

**Stopping the kubelet doesn't stop containers.** The two old `victim` containers (the `busybox` count is 2) were still running, while the API said they were terminating and had already started replacements on worker1. For those minutes there were **two copies** of each evicted pod. A `sleep` doesn't mind. A database would, which is why Kubernetes has stricter rules for StatefulSets (not tested here).

## Recover

```powershell
multipass exec worker2 -- sudo systemctl start kubelet
```

```text
21:07:16  kubelet started
21:07:34  ready=True  lease_age=9s  taints=[]  victim=[4xworker1:Running ]
```

The first sample, 18 seconds after the start, already showed `Ready`, with the taints removed by the control plane, and the old `Terminating` pods gone: the kubelet saw their deletion timestamps and cleaned up. The `victim` pods stayed on worker1: **a Deployment doesn't rebalance after a node returns.**

The outage lasted 3 minutes 44 seconds, so the `nginx` pods on worker2 (default toleration 300 s) were never evicted.

---

# 5. Fault 2: the kubelet can't reach the API server

The kubelet is running, but its configuration points at the wrong port. This is the classic case in real clusters. The undo is a saved copy of the file, verified with a checksum.

```bash
# worker2 shell
sudo cp -p /etc/kubernetes/kubelet.conf /root/kubelet.conf.bak
sudo sha256sum /etc/kubernetes/kubelet.conf /root/kubelet.conf.bak
sudo grep -E "^\s+server:" /etc/kubernetes/kubelet.conf
```

```text
93aef6cf...666c  /etc/kubernetes/kubelet.conf
93aef6cf...666c  /root/kubelet.conf.bak
    server: https://172.25.246.7:6443
```

Break it, with the loop running in the master shell:

```bash
# worker2 shell
sudo sed -i 's#https://172.25.246.7:6443#https://172.25.246.7:6444#' /etc/kubernetes/kubelet.conf
sudo grep -E "^\s+server:" /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
date -u +%T
```

### Observed on the real cluster

```text
    server: https://172.25.246.7:6444
21:33:54                                  (the restart)
21:34:38  ready=True     lease_age=49s
21:34:43  ready=Unknown  lease_age=55s  taints=[unreachable:NoSchedule unreachable:NoExecute ]
```

`Unknown` came 49 seconds after the restart, with the node object stamping the transition at 21:34:39: the same 50-second grace period as in Fault 1. From the control plane, **this fault looks identical to a stopped kubelet.**

## Diagnose it, on the node

```bash
systemctl is-active kubelet
sudo journalctl -u kubelet --since "3 minutes ago" --no-pager | grep 6444 | tail -4 | cut -c1-260
curl -sk --max-time 5 -o /dev/null -w "port 6443: HTTP %{http_code}\n" https://172.25.246.7:6443/healthz
curl -sk --max-time 5 -o /dev/null -w "port 6444: HTTP %{http_code}\n" https://172.25.246.7:6444/healthz
sudo ctr -n k8s.io tasks ls | wc -l
```

### Observed on the real cluster

```text
active
Oct 13 14:34:14 worker2 kubelet[725357]: E1013 ... "Unable to register node with API server" err="Post \"https://172.25.246.7:6444/api/v1/nodes\": dial tcp 172.25.246.7:6444: connect: connection refused" node="wo
Oct 13 14:34:16 worker2 kubelet[725357]: E1013 ... "Unable to write event (may retry after sleeping)" err="Post \"https://172.25.246.7:6444/api/v1/namespaces/default/events\": dial tcp 172.25.246.7:6444: connect: connection re
Oct 13 14:34:21 worker2 kubelet[725357]: E1013 ... "Failed to ensure lease exists, will retry" err="Get \"https://172.25.246.7:6444/apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases/worker2?timeout=10s\": dial
port 6443: HTTP 200
port 6444: HTTP 000
15
```

| Item | What it shows |
|---|---|
| `is-active` is **`active`** | The process runs. This is what distinguishes the fault from Fault 1 |
| The same URL in every error | Three different things the kubelet tries to do (register, write events, renew the lease) **all fail at the same address**, and that points at the configuration |
| `6443` answers **200** | The API server is healthy, and the network is fine |
| `6444` gives **000** | No connection at all: nothing listens there. If 6443 had failed too, the fault would be the master or the network |
| 15 tasks | The containers keep running |

## Fix it

```bash
# worker2 shell
sudo cp -p /root/kubelet.conf.bak /etc/kubernetes/kubelet.conf
sudo sha256sum /etc/kubernetes/kubelet.conf /root/kubelet.conf.bak
sudo grep -E "^\s+server:" /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
date -u +%T
```

```text
93aef6cf...666c  /etc/kubernetes/kubelet.conf
93aef6cf...666c  /root/kubelet.conf.bak
    server: https://172.25.246.7:6443
21:35:05
21:35:27  ready=True  lease_age=2s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
```

The node object stamps `Ready` at **21:35:05**, the second of the restart, and the first loop line was 22 seconds later.

## Recovery doesn't save pods whose toleration is expiring

The events show what happened to the three `victim` pods that were on worker2:

```text
21:34:39  NodeNotReady            victim-...-9pzgh, bs6mb, kxr5p
21:35:05  (the fix: the node is Ready)
21:35:09  TaintManagerEviction    victim-...-kxr5p, 9pzgh, bs6mb      <- all three
21:35:09  SuccessfulCreate        (three replacements)
21:35:12  Started                 victim-...-5k62q
```

All three pods were evicted at **21:35:09: exactly 30 seconds after `NodeNotReady`**, the length of their toleration. That is **4 seconds after the node had become `Ready` again.** My reading, an inference: the control plane removes the taints on its next pass, so at the toleration deadline the taint was still there and the eviction went ahead. Two of the replacements were then scheduled back onto worker2. The lesson: **a node that recovers in the same few seconds a toleration expires can still lose its pods.**

---

# 6. Fault 3: the container runtime is stopped

The kubelet stays up, but can't reach containerd:

```powershell
multipass exec worker2 -- sudo systemctl stop containerd
```

### Observed on the real cluster

```text
21:44:37  containerd stopped
21:45:07  (Ready=False, as stamped by the node object: 30 seconds later)
21:47:26  ready=False  lease_age=4s   taints=[not-ready:NoSchedule not-ready:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:47:32  ready=False  lease_age=9s   ...
21:47:42  ready=False  lease_age=10s  ...
21:47:53  ready=False  lease_age=0s   ...
```

| Item | Predicted | Observed |
|---|---|---|
| `lease_age` | Stays under 10 s: the kubelet is alive | **0, 4, 5, 9, 10**: renewed every 10 s |
| `ready` | **`False`**, not `Unknown` | **`False`** |
| The taints | **`not-ready`**, not `unreachable` | **`not-ready:NoSchedule not-ready:NoExecute`** |
| Time to unready | 5 to 40 s | **30 s** |
| The old `victim` pods | `Terminating` | **`Terminating` and staying that way**: the kubelet is alive but can't kill containers without the runtime |

## Diagnose it

```bash
kubectl describe node worker2 | sed -n '/^Conditions:/,/^Addresses:/p'
kubectl get events -A --field-selector involvedObject.name=worker2 --sort-by=.lastTimestamp | tail -4
N=$(kubectl get pods -n default -o wide --no-headers | awk '$7=="worker2" {print $1; exit}')
kubectl logs -n default $N | head -3
kubectl exec -n default $N -- date
```

```powershell
multipass exec worker2 -- systemctl is-active kubelet containerd
multipass exec worker2 -- sudo journalctl -u kubelet --since "10 minutes ago" --no-pager | Select-String -Pattern "containerd|runtime|CRI" | Select-Object -Last 3
multipass exec worker2 -- sudo sh -c "pgrep -c -f '[s]leep 3600'"
```

### Observed on the real cluster

```text
  Ready  False  Tue, 13 Oct 2026 14:54:09 -0700  Tue, 13 Oct 2026 14:45:07 -0700  KubeletNotReady  [container runtime is down, PLEG is not healthy: pleg was last seen active 9m39.941622118s ago; threshold is 3m0s]
  (the other three conditions: False, with their usual messages)

default   9m6s   Normal    NodeNotReady       node/worker2   Node worker2 status is now: NodeNotReady
default   4m8s   Warning   ImageGCFailed      node/worker2   rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial unix /var/run/containerd/containerd.sock: connect: no such file or directory"
default   8s     Warning   ContainerGCFailed  node/worker2   rpc error: code = Unavailable desc = ...

unable to retrieve container logs for containerd://9d77d57...
error: unable to upgrade connection: rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial unix /var/run/containerd/containerd.sock: connect: no such file or directory"

inactive      (containerd)
active        (kubelet)
Oct 13 14:54:22 ... "ListPodSandbox with filter from runtime service failed" err="rpc error: code = Unavailable ... dial unix /var/run/containerd/containerd.sock: connect: no such file or directory"
Oct 13 14:54:22 ... "GenericPLEG: Unable to retrieve pods" err="rpc error: code = Unavailable ..."
2
```

| Item | Predicted | Observed |
|---|---|---|
| The reason and message | `KubeletNotReady`, about the runtime | **`container runtime is down, PLEG is not healthy`** |
| The events | `NodeNotReady` | **`NodeNotReady`, plus `ImageGCFailed` and `ContainerGCFailed`**, both ending in the missing socket |
| **`kubectl logs`** | **Unknown** | **Fails**: the kubelet asks the runtime for them |
| `kubectl exec` | Fails | **Fails**, with the socket error |
| The socket error | `connection refused` or `no such file` | **`no such file or directory`**: the socket **file disappears** when containerd stops |
| `pgrep` | 2: containers survive | **2** |

The message holds two causes of different ages. The node turned `False` 30 seconds after the stop, which can only be the "container runtime is down" check, since the PLEG check has a **3-minute threshold**. The PLEG text was added later, when its timer expired. That reading is my inference, because only the final message was captured. **PLEG** is the kubelet's pod lifecycle event generator, which lists containers through the runtime, so it fails when the runtime does.

## Recover

```powershell
multipass exec worker2 -- sudo systemctl start containerd
```

```text
21:54:35  containerd started
21:54:41  ready=True  lease_age=10s  taints=[not-ready:NoExecute ]  victim=[4xworker1:Running ]
21:54:46  ready=True  lease_age=5s   taints=[]
```

`Ready` within **6 seconds**, with the taints cleared on the next pass. After the outage the `nginx` pods were all on worker1: the two that had been on worker2 were **evicted and replaced** (`4pp2g` and `c8bgh` were gone, and two new names appeared). The outage lasted almost 10 minutes, past their 300-second toleration, which supports the default. Of the pods still on worker2, flannel (2 restarts) and kube-proxy (0) kept their restart counts, so the containers survived the runtime's outage and were re-adopted.

---

# 7. Fault 4: swap is on, and the kubelet refuses to start

This is the common real-world version: a node reboots, swap returns, and the kubelet won't start. The kubelet checks swap **only when it starts**.

```bash
# worker2 shell
sudo dd if=/dev/zero of=/swapfile bs=1M count=128 status=none
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
swapon --show
free -m | grep -i swap
systemctl is-active kubelet
```

```text
Setting up swapspace version 1, size = 128 MiB (134213632 bytes)
no label, UUID=342eaa7b-0c4f-4563-94db-cfdd6aa47d8f
NAME      TYPE SIZE USED PRIO
/swapfile file 128M   0B   -2
Swap:            127           0         127
active
```

With swap on, the running kubelet is **unaffected**: the fault is latent until a restart. Restart it:

```bash
sudo systemctl restart kubelet
date -u +%T
```

### Observed on the real cluster

```text
21:58:35                                  (the restart)
21:59:20  ready=True     lease_age=53s
21:59:25  ready=Unknown  lease_age=59s  taints=[unreachable:NoSchedule unreachable:NoExecute ]
[... Unknown, with the lease age climbing: 100 s, 150 s, 200 s ...]
22:01:48  ready=Unknown  lease_age=202s
```

**From the control plane, this fault looks exactly like Fault 1**: `Unknown`, the `unreachable` taints, and a lease that stops renewing, 50 seconds after the restart. (Eviction wasn't visible: none of the `victim` pods were on worker2 at that point.)

## Diagnose it, on the node

```bash
systemctl is-active kubelet
systemctl show kubelet -p ActiveState -p SubState -p Result -p NRestarts -p ExecMainStatus
sudo journalctl -u kubelet --since "2 minutes ago" --no-pager | grep -i swap | tail -2 | cut -c1-260
sudo journalctl -u kubelet --since "2 minutes ago" --no-pager | grep -E "restart counter|Main process exited" | tail -3 | cut -c1-200
```

### Observed on the real cluster

```text
activating
Result=exit-code
NRestarts=1
ExecMainStatus=1
ActiveState=activating
SubState=auto-restart
Oct 13 14:58:45 worker2 kubelet[733289]: E1013 14:58:45.738190 ... "command failed" err="failed to run Kubelet: running with swap on is not supported, please disable swap or set --fail-swap-on flag to false"
Oct 13 14:58:35 worker2 systemd[1]: kubelet.service: Main process exited, code=exited, status=1/FAILURE
Oct 13 14:58:45 worker2 systemd[1]: kubelet.service: Scheduled restart job, restart counter is at 1.
Oct 13 14:58:45 worker2 systemd[1]: kubelet.service: Main process exited, code=exited, status=1/FAILURE
```

| Item | Predicted | Observed |
|---|---|---|
| `is-active` | `activating` | **`activating`**: neither `active` nor `failed`, but between attempts |
| `systemctl show` | `activating`, `auto-restart`, `exit-code`, status 1 | **Exactly that** |
| The swap error | Something like `running with swap on is not supported` | **`failed to run Kubelet: running with swap on is not supported, please disable swap or set --fail-swap-on flag to false`**: my recalled wording was exact |
| The restart cycle | About 10 s | **14:58:35, 14:58:45**: 10 seconds apart, the `RestartSec=10` |
| `NRestarts` | About 10 to 12 after two minutes | **1**, because the check ran only 15 seconds after the restart. It kept climbing |
| The task count | Unchanged | **5**: the two pods then on worker2, with their containers still running |

The kubelet even printed the swap devices it found just before it failed. The restart counter later read **28** at 22:03:23, matching a cycle of about 10 seconds from 21:58:45.

## Fix it

```bash
# worker2 shell
systemctl show kubelet -p NRestarts -p ActiveState
sudo swapoff /swapfile
sudo rm -f /swapfile
swapon --show | wc -l
ls /swapfile 2>&1
date -u +%T
```

```text
NRestarts=28
ActiveState=activating
0
ls: cannot access '/swapfile': No such file or directory
22:03:23
```

Later, from the master and the node:

```text
Ready since: 2026-10-13T22:03:32Z
NRestarts=29
ActiveState=active
```

**No manual start was needed.** The kubelet came back at systemd's next attempt, the 29th restart, which by the counter arithmetic was due at about 22:03:25: 21:58:45 plus 280 seconds. The node was `Ready` at 22:03:32, **9 seconds after the `swapoff`**. The recovery depends on where systemd's 10-second timer happens to be, so the best case is a few seconds, and the worst is about 17.

The whole crash loop lasted **4 minutes 50 seconds** (21:58:35 to 22:03:25) of failed attempts, and the control plane could only see a stale lease.

---

# 8. The four faults side by side

| | **1: kubelet stopped** | **2: wrong API port** | **3: runtime stopped** | **4: swap on** |
|---|---|---|---|---|
| `Ready` | `Unknown` | `Unknown` | **`False`** | `Unknown` |
| Reason | `NodeStatusUnknown` | `NodeStatusUnknown` | **`KubeletNotReady`** | `NodeStatusUnknown` |
| Taints | `unreachable` | `unreachable` | **`not-ready`** | `unreachable` |
| The lease | **Stale**, climbing | **Stale**, climbing | **Fresh** (under 10 s) | **Stale**, climbing |
| Time to unready | 47 s after the stop | 49 s after the restart | **30 s** after the stop | 50 s after the restart |
| `is-active kubelet` | `inactive` | `active` | `active` | **`activating`** |
| `kubectl logs` / `exec` | `10250 ... connection refused` | Not tested | `containerd.sock ... no such file or directory` | Not tested |
| Where the clue is | The service state | The kubelet's journal: the same wrong URL in every error | The kubelet's journal, and `ImageGCFailed` / `ContainerGCFailed` events | The kubelet's journal: `running with swap on is not supported` |
| Recovers by itself? | No | No | No | **No, but it is retrying** every 10 s |
| Recovery time | Under 18 s | Within 22 s (stamped at 0 s) | 6 s | 9 s |
| Containers during the fault | Keep running | Keep running | Keep running | Keep running |

---

# 9. A triage procedure

Four faults taught the same order of questions. Everything here comes from the faults above. Other causes (disk pressure, expired certificates, network partitions) were not tested.

1. **`kubectl get nodes`**: which node is `NotReady`?
2. **`kubectl describe node NODE`**: read the `Ready` line. **`Unknown`** means the control plane stopped hearing from the kubelet. **`False`** means the kubelet is talking, and the message says what it reports.
3. **The lease age**: `kubectl get lease NODE -n kube-node-lease -o jsonpath='{.spec.renewTime}'`. Stale means the kubelet is down, crashing, or can't reach the API server. Fresh with `False` means the kubelet is alive.
4. **On the node**: `systemctl is-active kubelet containerd`.
   - `inactive`: stopped (Fault 1, or Fault 3 for containerd).
   - `activating`: **crash-looping** (Fault 4). Run `systemctl show kubelet -p NRestarts -p ExecMainStatus`.
   - `active`: the process runs, so the problem is what it can't reach.
5. **The kubelet's journal**: `sudo journalctl -u kubelet --since "5 minutes ago" --no-pager | tail -20`, and search for the words that matched: `swap`, `containerd.sock`, or a URL repeated in every error.
6. **Separate the network from the configuration**: `curl -sk https://MASTER:6443/healthz` from the node. A `200` means the API server and the network are fine.
7. **Fix, and verify**: the node is `Ready`, the taints are gone, and the lease renews. Pods that were evicted **do not return** by themselves.

---

# 10. What I got wrong

| Claim | What the labs showed |
|---|---|
| The control plane waits 40 seconds | The default is **50 seconds** (confirmed from the controller manager's help). In practice the node went `Unknown` 55 to 59 s after the last renewal |
| The node status is posted "about every 5 minutes" | The conditions showed a last post at 11:35:39 and the stop at 14:03:32: **2 hours 28 minutes** with no post while the lease renewed every 10 s. The practical point stands: **the lease is the heartbeat**. What governs status posting I did not determine. My guess is that it happens on changes and on a long timer, and a timer frozen during VM sleep could stretch it |
| After Fault 2, one pod was evicted | **All three** were evicted, at 21:35:09, 4 s after the node was `Ready` |
| Fault 4 would evict pods | None could be: the pods had already moved to worker1 |
| The `lease_age` at `Unknown` would be about 40 | 52 to 59 s |
| `kubectl` instructions | Two of my instructions didn't say which shell to use, and one command forgot a namespace flag. Those cost a round trip each |

---

# 11. Practical tips for running these labs

- **Break only one node, and keep the control plane out of it.** You can always run `kubectl` and read what happened.
- **Back up the file and check the hash before editing it**, and print only the line you changed, never the whole file.
- **`kubectl` doesn't work on a worker.** A worker has no admin credentials, so it tries `localhost:8080`. Run it on the master.
- **`systemctl stop` versus a crash.** A stopped kubelet stays down, and `Restart=always` restarts one that exits with an error, every 10 seconds.
- **A loop's timestamps are good to about ±5 s.** Use the node object's transition times and the events when you need an exact figure.
- **Keep the laptop awake.** A VM pause stretches every timer in this guide.
- **The last resort** is `multipass restart worker2`: a clean boot starts the kubelet. It was not needed.

---

# 12. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Node `Unknown`, lease stale, `kubelet` `inactive` | The kubelet is stopped | `sudo systemctl start kubelet` |
| Node `Unknown`, kubelet `activating`, `NRestarts` growing | The kubelet crashes at startup | Read `journalctl -u kubelet`: for `swap`, run `swapoff -a` and remove the swap from `/etc/fstab` |
| Node `Unknown`, kubelet `active`, the same URL in every error | A wrong API server address or port in `kubelet.conf` | Fix `server:` and restart the kubelet |
| `curl` to the API server fails from the node | The master or the network, not the kubelet's configuration | Check the master and the route |
| Node `False`, `container runtime is down` | containerd stopped | `sudo systemctl start containerd` |
| `logs` or `exec` fail with `10250 ... connection refused` | The kubelet is stopped | Start it |
| `logs` or `exec` fail with `containerd.sock` | The runtime is down | Start containerd |
| Pods `Terminating` that never go away | Their node can't confirm the deletion | Recover the node: the kubelet then finishes the job |
| Pods didn't return after the node recovered | Evicted pods are replaced elsewhere, and nothing moves them back | `kubectl rollout restart deployment/NAME` to rebalance |

---

# 13. Command cheat sheet

| Task | Command |
|---|---|
| Node status | `kubectl get nodes -o wide` |
| Why a node is not ready | `kubectl describe node NODE \| sed -n '/^Conditions:/,/^Addresses:/p'` |
| The lease | `kubectl get lease NODE -n kube-node-lease -o jsonpath='{.spec.renewTime}'` |
| When a condition last changed | `kubectl get node NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}'` |
| Node events | `kubectl get events -A --field-selector involvedObject.name=NODE --sort-by=.lastTimestamp` |
| Service state | `systemctl is-active kubelet containerd` |
| The crash counter | `systemctl show kubelet -p NRestarts -p ActiveState -p ExecMainStatus` |
| The kubelet's journal | `sudo journalctl -u kubelet --since "5 minutes ago" --no-pager` |
| Running containers on a node | `sudo ctr -n k8s.io tasks ls` |
| API server reachable? | `curl -sk --max-time 5 -o /dev/null -w "%{http_code}\n" https://MASTER:6443/healthz` |
| Why pods were evicted | `kubectl get events -n NS --sort-by=.lastTimestamp` and look for `TaintManagerEviction` |

---

# 14. Glossary

| Term | Meaning |
|---|---|
| **kubelet** | The agent on each node that runs the pods and reports to the control plane. A system service, not a pod |
| **Lease** | An object the kubelet renews every 10 s. The node's heartbeat |
| **Node condition** | A status the kubelet reports: `Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure` |
| **Grace period** | How long the control plane waits without a lease renewal before marking the node `Unknown` (50 s here) |
| **Taint** | A mark on a node that repels pods. `NoExecute` also evicts them |
| **Toleration** | A pod's permission to stay on a tainted node, for a given time |
| **Eviction** | The control plane deleting pods from a node whose taints they no longer tolerate |
| **PLEG** | The pod lifecycle event generator: how the kubelet notices container changes, through the runtime |
| **containerd** | The container runtime that actually runs the containers |
| **`Restart=always`** | A systemd setting that restarts a service whenever it exits, except after an explicit stop |

---

# 15. What was run, and what was not

## Run on the real cluster (the output above is from these)

- Reading a healthy node: the conditions, the leases, the kubelet's unit and configuration
- **Fault 1**: a stopped kubelet, with the timeline, the failing `logs` and `exec`, the containers still running, the duplicate pods, and recovery
- **Fault 2**: a wrong API server port, the three journal messages, the `curl` comparison, recovery, and the eviction events
- **Fault 3**: a stopped containerd, `False` against `Unknown`, the socket errors, the surviving containers, and recovery
- **Fault 4**: swap on and a restart, the crash loop and its counter, the exact error, and recovery with no manual start
- The grace period's default, read from the controller manager

## Not run

- **A bad `config.yaml`** (invalid YAML or an unknown field)
- **An expired or invalid kubelet client certificate**, and certificate rotation
- **Disk, memory or PID pressure** and the evictions they cause
- **A network partition or a firewall** between a node and the API server
- **A CNI failure** (`NetworkUnavailable`)
- **A full node reboot**: whether swap or the kubelet comes back at boot
- **The `--fail-swap-on=false` workaround**, and how swap is managed in newer releases
- **StatefulSet behavior** when a node fails
- **`kubectl drain`, cordon and the node shutdown feature**
- **The default 300-second toleration**, measured directly: it is inferred from the `nginx` pods
- **Whether `logs` works during Fault 2**: I expect it to, and did not test it

The explanations marked as inferences in the text (the toleration races at recovery, the two causes in the PLEG message, the status-posting timer) are the best fit to the evidence, and not verified. Check the official Kubernetes documentation for the version you run.

## Clean up everything from this guide

```bash
# master shell
kubectl delete namespace fault
kubectl config set-context --current --namespace=default
rm -f ~/victim.yaml
```

```bash
# worker2 shell
sudo rm -f /root/kubelet.conf.bak
ls /swapfile /root/kubelet.conf.bak 2>&1
swapon --show | wc -l
```

The first block removes the test workload. The second removes the `kubelet.conf` backup, which holds the same configuration as the live file, and confirms that no swap file or swap remains. Afterwards the four original `nginx` pods are all on worker1, since nothing moves them back. `kubectl rollout restart deployment/nginx` rebalances them if you want.
