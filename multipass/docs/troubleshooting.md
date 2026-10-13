Everything from the last guide is cleaned up: the `cfg` namespace is gone, your context is back on `default`, and the namespace list is the five you started with. Your prompt still reads `~/cfg-lab`, though you deleted that directory, so type `cd ~` before anything else, or commands that use relative paths will fail with odd errors.

## The plan

Breaking a kubelet means breaking a node, so I want the rules clear first:

| Rule                                                | Why                                                                                                                                                                                                                                                             |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Only worker2 is ever touched**                    | The control plane (the master) stays healthy, so you can always run `kubectl` and diagnose                                                                                                                                                                      |
| **Each fault comes with its undo before you start** | I'll give the recovery command for each                                                                                                                                                                                                                         |
| **Baseline first**                                  | You read what a healthy node looks like, so a broken one stands out                                                                                                                                                                                             |
| **A last resort exists**                            | If a fault leaves worker2 unreachable, `multipass restart worker2` restarts the VM, and a clean boot brings the kubelet back, since it's enabled at boot. That is an assumption, since I haven't tested a reboot, and the earlier restarts of all VMs went well |

The faults, in order, each isolating a different cause of the same symptom, a `NotReady` node:

| Fault                                           | What I expect you to learn                                                                                                                                   |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **1. Stop the kubelet**                         | The node goes `NotReady` after about 40 s, but its **containers keep running**. `logs` and `exec` fail. Pods are replaced elsewhere, and the old ones linger |
| **2. Break its connection to the API server**   | The kubelet runs but can't report: the symptom looks the same, and the cause is in its journal                                                               |
| **3. Stop the container runtime**               | The kubelet reports the node unready for a different reason                                                                                                  |
| **4. Switch swap on, then restart the kubelet** | The kubelet **refuses to start**, a classic cause after a reboot                                                                                             |

This message is Part 0: read what a healthy node looks like, and set up the workload. Nothing is broken yet.

First, the clocks, since the faults are timed. In PowerShell:

```powershell
.\check-clocks.ps1
```

If a VM shows `OFF`, run it again with `-Fix`.

## Piece 1: the healthy node, from the master

Paste this in the **master shell**:

```bash
cd ~
kubectl get nodes -o wide
kubectl describe node worker2 | sed -n '/^Conditions:/,/^Addresses:/p'
kubectl get lease -n kube-node-lease
kubectl get lease worker2 -n kube-node-lease -o jsonpath='renewTime={.spec.renewTime}  duration={.spec.leaseDurationSeconds}s  holder={.spec.holderIdentity}{"\n"}'
date -u +%FT%TZ
```

| Item             | Prediction                                                                                                                                                                                                               |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `get nodes`      | All three `Ready`, version `v1.36.5`                                                                                                                                                                                     |
| The conditions   | `MemoryPressure False`, `DiskPressure False`, `PIDPressure False`, **`Ready True`** with reason `KubeletReady` and the message `kubelet is posting ready status`, and `NetworkUnavailable False` with `FlannelIsUp`      |
| `get lease`      | **Three** leases, named `master`, `worker1` and `worker2`, in the `kube-node-lease` namespace                                                                                                                            |
| The lease detail | `duration=40s`, `holder=worker2`, and a `renewTime` within about 10 seconds of the `date` line below it. As I recall it, the kubelet renews its lease about every 10 seconds, and **this lease is the node's heartbeat** |

## Piece 2: the healthy kubelet, from worker2

The kubelet is a system service on each node, not a pod, so its files and logs are on the node itself. Open a shell there, with `multipass shell worker2`, and paste this. **Don't `cat` the whole `kubelet.conf` file**: the patterns below print only paths and the server address, and never key data.

```bash
systemctl is-active kubelet containerd
systemctl cat kubelet | grep -vE '^\s*#|^\s*$'
sudo grep -E "^\s+server:|client-certificate:|client-key:|current-context" /etc/kubernetes/kubelet.conf
sudo grep -E "failSwapOn|cgroupDriver|staticPodPath|rotateCertificates|clusterDNS|serverTLSBootstrap" /var/lib/kubelet/config.yaml
sudo ls /var/lib/kubelet/pki
sudo ctr -n k8s.io tasks ls | wc -l
swapon --show | wc -l
free -m | grep -i swap
```

| Item               | Prediction                                                                                                                                                                                                                                                                                                                                                               |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `is-active`        | **`active`** twice (kubelet and containerd)                                                                                                                                                                                                                                                                                                                              |
| The unit file      | A service whose `ExecStart` is `/usr/bin/kubelet` with several variables, and a drop-in that sets `--kubeconfig=/etc/kubernetes/kubelet.conf` (the API server credentials), `--config=/var/lib/kubelet/config.yaml` (the settings), and reads extra flags from `/var/lib/kubelet/kubeadm-flags.env`. I recall that layout from kubeadm, and haven't seen it on this node |
| `kubelet.conf`     | A `server:` line with **`https://172.25.246.7:6443`**, the master's fixed address. The credentials are probably given as file paths, for example `/var/lib/kubelet/pki/kubelet-client-current.pem`, but they could be embedded, in which case those two lines simply won't appear                                                                                        |
| `config.yaml`      | `cgroupDriver: systemd`, `rotateCertificates: true`, `staticPodPath: /etc/kubernetes/manifests`, a `clusterDNS` address (probably `10.96.0.10`). **No `failSwapOn` line** (so the default applies), and **no `serverTLSBootstrap`** line: that absence is why metrics-server had to skip certificate verification                                                        |
| `pki`              | A client certificate with a date in its name, `kubelet-client-current.pem`, and the kubelet's own serving pair `kubelet.crt` and `kubelet.key`. The serving certificate is self-signed, which is what the metrics-server error complained about                                                                                                                          |
| `ctr ... tasks ls` | A number: the count of running containers, plus one for the header line, probably between 8 and 20                                                                                                                                                                                                                                                                       |
| Swap               | **`0`** lines from `swapon --show`, and `Swap: 0 0 0` from `free`                                                                                                                                                                                                                                                                                                        |

`exit` the worker2 shell when done.

## Piece 3: the workload

Back on the master. This Deployment of four pods tolerates the "node unreachable" taints for only **30 seconds** (the default, which you saw earlier, is 300), so the eviction in Fault 1 takes about a minute and not six. I'll check the manifest first:The manifest parses. It has two tolerations of 30 seconds, and a spread preference so the pods don't all land on one worker. Paste this in the master shell:

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
echo "--- everything on worker2:"
kubectl get pods -A -o wide --no-headers --field-selector spec.nodeName=worker2 | awk '{print $1"/"$2, $4}'
```

| Item                  | Prediction                                                                                                                                                                                                                                                                                                  |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The rollout           | Completes within seconds. `busybox` is cached on both workers                                                                                                                                                                                                                                               |
| `victim` pods         | **Two on worker1 and two on worker2**, as with the earlier `ScheduleAnyway` spread. Three and one would also be possible, since the rule is only a preference                                                                                                                                               |
| Everything on worker2 | Your pods, plus the system ones: `kube-flannel-ds-...`, `kube-proxy-...`, and probably some of the original `nginx` pods, **perhaps** `metrics-server` or a CoreDNS pod. During Fault 1, any of these could be affected, and a `kubectl top` call may fail while worker2 is down if metrics-server is there |

## What to paste back

Pieces 1, 2 and 3. Leave the `fault` namespace and `~/victim.yaml` in place. Fault 1 comes next: stopping the kubelet, with a timeline from the master. The recovery will be one command, `sudo systemctl start kubelet` on worker2, and I'll give it to you at that point as well.

ubuntu@master:~$ cd ~
ubuntu@master:~$ kubectl get nodes -o wide
NAME STATUS ROLES AGE VERSION INTERNAL-IP EXTERNAL-IP OS-IMAGE KERNEL-VERSION CONTAINER-RUNTIME
master Ready control-plane 7d20h v1.36.5 172.25.246.7 <none> Ubuntu 24.04.5 LTS 6.8.0-142-generic (amd64) containerd://2.2.1
worker1 Ready worker 7d18h v1.36.5 172.25.253.184 <none> Ubuntu 24.04.5 LTS 6.8.0-142-generic (amd64) containerd://2.2.1
worker2 Ready worker 7d18h v1.36.5 172.25.252.5 <none> Ubuntu 24.04.5 LTS 6.8.0-142-generic (amd64) containerd://2.2.1
ubuntu@master:~$ kubectl describe node worker2 | sed -n '/^Conditions:/,/^Addresses:/p'
Conditions:
Type Status LastHeartbeatTime LastTransitionTime Reason Message

---

NetworkUnavailable False Tue, 06 Oct 2026 14:52:34 -0700 Tue, 06 Oct 2026 14:52:34 -0700 FlannelIsUp Flannel is running on this node
MemoryPressure False Tue, 13 Oct 2026 11:05:04 -0700 Thu, 08 Oct 2026 22:19:52 -0700 KubeletHasSufficientMemory kubelet has sufficient memory available
DiskPressure False Tue, 13 Oct 2026 11:05:04 -0700 Thu, 08 Oct 2026 22:19:52 -0700 KubeletHasNoDiskPressure kubelet has no disk pressure
PIDPressure False Tue, 13 Oct 2026 11:05:04 -0700 Thu, 08 Oct 2026 22:19:52 -0700 KubeletHasSufficientPID kubelet has sufficient PID available
Ready True Tue, 13 Oct 2026 11:05:04 -0700 Thu, 08 Oct 2026 22:19:52 -0700 KubeletReady kubelet is posting ready status
Addresses:
ubuntu@master:~$ kubectl get lease -n kube-node-lease
NAME HOLDER AGE
master master 7d20h
worker1 worker1 7d18h
worker2 worker2 7d18h
ubuntu@master:~$ kubectl get lease worker2 -n kube-node-lease -o jsonpath='renewTime={.spec.renewTime} duration={.spec.leaseDurationSeconds}s holder={.spec.holderIdentity}{"\n"}'
renewTime=2026-10-13T18:10:16.439749Z duration=40s holder=worker2
ubuntu@master:~$
ubuntu@master:~$ date -u +%FT%TZ
2026-10-13T18:10:40Z
ubuntu@master:~$

ubuntu@worker2:~$ systemctl is-active kubelet containerd
active
active
ubuntu@worker2:~$ systemctl cat kubelet | grep -vE '^\s*#|^\s*$'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target
[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10
[Install]
WantedBy=multi-user.target
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
ubuntu@worker2:~$
ubuntu@worker2:~$ sudo grep -E "^\s+server:|client-certificate:|client-key:|current-context" /etc/kubernetes/kubelet.conf
server: https://172.25.246.7:6443
current-context: default-context
client-certificate: /var/lib/kubelet/pki/kubelet-client-current.pem
client-key: /var/lib/kubelet/pki/kubelet-client-current.pem
ubuntu@worker2:~$
ubuntu@worker2:~$ sudo grep -E "failSwapOn|cgroupDriver|staticPodPath|rotateCertificates|clusterDNS|serverTLSBootstrap" /var/lib/kubelet/config.yaml
cgroupDriver: systemd
clusterDNS:
rotateCertificates: true
staticPodPath: /etc/kubernetes/manifests
ubuntu@worker2:~$
ubuntu@worker2:~$ sudo ls /var/lib/kubelet/pki
kubelet-client-2026-10-05-16-43-43.pem kubelet-client-current.pem kubelet.crt kubelet.key
ubuntu@worker2:~$
ubuntu@worker2:~$ sudo ctr -n k8s.io tasks ls | wc -l
9
ubuntu@worker2:~$
ubuntu@worker2:~$ swapon --show | wc -l
0
ubuntu@worker2:~$
ubuntu@worker2:~$ free -m | grep -i swap
Swap: 0 0 0
ubuntu@worker2:~$

ubuntu@master:~$ cd ~
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
tolerations: - key: node.kubernetes.io/unreachable
operator: Exists
effect: NoExecute
tolerationSeconds: 30 - key: node.kubernetes.io/not-ready
operator: Exists
effect: NoExecute
tolerationSeconds: 30
topologySpreadConstraints: - maxSkew: 1
topologyKey: kubernetes.io/hostname
whenUnsatisfiable: ScheduleAnyway
labelSelector:
matchLabels:
app: victim
containers: - name: app
image: busybox
command: ["sh", "-c", "sleep 3600"]
EOF
kubectl apply -f victim.yaml
kubectl rollout status deployment/victim --timeout=90s
kubectl get pods -l app=victim -o wide
echo "--- everything on worker2:"
kubectl get pods -A -o wide --no-headers --field-selector spec.nodeName=worker2 | awk '{print $1"/"$2, $4}'
namespace/fault created
Context "kubernetes-admin@kubernetes" modified.
deployment.apps/victim created
Waiting for deployment "victim" rollout to finish: 0 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 0 of 4 updated replicas are available...
Waiting for deployment "victim" rollout to finish: 1 of 4 updated replicas are available...
Waiting for deployment "victim" rollout to finish: 2 of 4 updated replicas are available...
Waiting for deployment "victim" rollout to finish: 3 of 4 updated replicas are available...
deployment "victim" successfully rolled out
NAME                      READY   STATUS    RESTARTS   AGE   IP             NODE      NOMINATED NODE   READINESS GATES
victim-5f9b4c4696-4pvws   1/1     Running   0          4s    10.244.1.112   worker1   <none>           <none>
victim-5f9b4c4696-pb8zs   1/1     Running   0          4s    10.244.2.9     worker2   <none>           <none>
victim-5f9b4c4696-whrmb   1/1     Running   0          4s    10.244.1.111   worker1   <none>           <none>
victim-5f9b4c4696-z8htn   1/1     Running   0          4s    10.244.2.8     worker2   <none>           <none>
--- everything on worker2:
default/nginx-5577fb97b9-4pp2g Running
default/nginx-5577fb97b9-c8bgh Running
fault/victim-5f9b4c4696-pb8zs Running
fault/victim-5f9b4c4696-z8htn Running
kube-flannel/kube-flannel-ds-dszmf Running
kube-system/kube-proxy-wqc59 Running
ubuntu@master:~$


ubuntu@master:~$ cd ~
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
21:02:23  ready=True  lease_age=9s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:02:28  ready=True  lease_age=5s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:02:33  ready=True  lease_age=0s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:02:38  ready=True  lease_age=5s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
ubuntu@master:~$ tl 26 5
21:03:03  ready=True  lease_age=10s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:03:08  ready=True  lease_age=4s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:03:13  ready=True  lease_age=9s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:03:18  ready=True  lease_age=4s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:03:24  ready=True  lease_age=10s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:03:29  ready=True  lease_age=5s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:03:34  ready=True  lease_age=10s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:03:39  ready=True  lease_age=15s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:03:45  ready=True  lease_age=21s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:03:50  ready=True  lease_age=26s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:03:55  ready=True  lease_age=31s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:00  ready=True  lease_age=36s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:06  ready=True  lease_age=42s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:11  ready=True  lease_age=47s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:16  ready=True  lease_age=52s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:21  ready=Unknown  lease_age=57s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:26  ready=Unknown  lease_age=62s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:32  ready=Unknown  lease_age=68s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:37  ready=Unknown  lease_age=73s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:42  ready=Unknown  lease_age=78s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:47  ready=Unknown  lease_age=83s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[2xworker1:Running 2xworker2:Running ]
21:04:52  ready=Unknown  lease_age=88s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:04:58  ready=Unknown  lease_age=94s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:05:03  ready=Unknown  lease_age=99s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:05:08  ready=Unknown  lease_age=104s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:05:13  ready=Unknown  lease_age=109s  taints=[unreachable:NoSchedule unreachable:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
ubuntu@master:~$

PS C:\Users\bijut> multipass exec worker2 -- sudo systemctl stop kubelet
PS C:\Users\bijut> (Get-Date).ToUniversalTime().ToString("HH:mm:ss") + "  kubelet stopped"
21:03:32  kubelet stopped
PS C:\Users\bijut>


ubuntu@master:~$ P=$(kubectl get pods -l app=victim -o wide --no-headers | awk '$3=="Terminating" && $7=="worker2" {print $1; exit}')
echo "an old pod on worker2: $P"
kubectl logs $P
kubectl exec $P -- date
kubectl describe node worker2 | sed -n '/^Conditions:/,/^Addresses:/p'
kubectl get events -A --field-selector involvedObject.name=worker2 --sort-by=.lastTimestamp | tail -4
kubectl get pods -A -o wide --no-headers --field-selector spec.nodeName=worker2 | awk '{print $1"/"$2, $4}'
kubectl top nodes
an old pod on worker2: victim-5f9b4c4696-pb8zs
Error from server: Get "https://172.25.252.5:10250/containerLogs/fault/victim-5f9b4c4696-pb8zs/app": dial tcp 172.25.252.5:10250: connect: connection refused
error: unable to upgrade connection: error dialing backend: dial tcp 172.25.252.5:10250: connect: connection refused
Conditions:
  Type                 Status    LastHeartbeatTime                 LastTransitionTime                Reason              Message
  ----                 ------    -----------------                 ------------------                ------              -------
  NetworkUnavailable   False     Tue, 06 Oct 2026 14:52:34 -0700   Tue, 06 Oct 2026 14:52:34 -0700   FlannelIsUp         Flannel is running on this node
  MemoryPressure       Unknown   Tue, 13 Oct 2026 11:35:39 -0700   Tue, 13 Oct 2026 14:04:19 -0700   NodeStatusUnknown   Kubelet stopped posting node status.
  DiskPressure         Unknown   Tue, 13 Oct 2026 11:35:39 -0700   Tue, 13 Oct 2026 14:04:19 -0700   NodeStatusUnknown   Kubelet stopped posting node status.
  PIDPressure          Unknown   Tue, 13 Oct 2026 11:35:39 -0700   Tue, 13 Oct 2026 14:04:19 -0700   NodeStatusUnknown   Kubelet stopped posting node status.
  Ready                Unknown   Tue, 13 Oct 2026 11:35:39 -0700   Tue, 13 Oct 2026 14:04:19 -0700   NodeStatusUnknown   Kubelet stopped posting node status.
Addresses:
NAMESPACE   LAST SEEN   TYPE     REASON         OBJECT         MESSAGE
default     2m1s        Normal   NodeNotReady   node/worker2   Node worker2 status is now: NodeNotReady
default/nginx-5577fb97b9-4pp2g Running
default/nginx-5577fb97b9-c8bgh Running
fault/victim-5f9b4c4696-pb8zs Terminating
fault/victim-5f9b4c4696-z8htn Terminating
kube-flannel/kube-flannel-ds-dszmf Running
kube-system/kube-proxy-wqc59 Running
NAME      CPU(cores)   CPU(%)      MEMORY(bytes)   MEMORY(%)
master    155m         7%          899Mi           49%
worker1   41m          2%          573Mi           31%
worker2   <unknown>    <unknown>   <unknown>       <unknown>
ubuntu@master:~$

PS C:\Users\bijut> multipass exec worker2 -- systemctl is-active kubelet containerd
inactive
active
PS C:\Users\bijut> multipass exec worker2 -- sudo ctr -n k8s.io tasks ls
TASK                                                                PID       STATUS
8425fab4bc3f5600083bb4edd6ddb488f18c3a088daf53c4a0e72c33fa587462    111349    RUNNING
577d34c079f96e3b3506e049fa617a75c456b582e26fbd26dce51e4ff8a447c8    122497    RUNNING
c264f963e65b1e2f1559bcb254a2f45eb59cc0836d589d93f44c6e4bfb91bc7e    122644    RUNNING
da514a9b2717fa4f7703a7324021a4002edaeb0ab484ccbb204717aa6688b9f6    122670    RUNNING
d1773114d5a427b04937108b3fe61089ea29ec68b2a29848fff6c14041674922    713992    RUNNING
e048e32f25081cabb01aefef708c5672002901f5335ff8cdfbe943ac07cc5635    1356      RUNNING
9075ff565eb3748ed42d3be8ac758522327b778408cd31fe9648132257e77e3e    1623      RUNNING
9d77d5733db25fc016b7c9b149d65865457a30993df91fa1874983cbf0e1869b    122539    RUNNING
4037fbbca10b97cf6dfd00f0988a42e11349cfe6b2fbafdefd351316d643dbf8    713951    RUNNING
743ed2a5535a0b6431047934fd36be6c8b5d004405b00224d91a0279cae2d640    714016    RUNNING
a7bd413aa34c11cc96797b29d7851dd48c71cdcec2a637055e3010e54130a1a2    111324    RUNNING
45125cd7506dd3790557f3bc8e2ef7a832018cb38b67c1be168c9823ea54e6e6    713959    RUNNING
PS C:\Users\bijut> multipass exec worker2 -- sudo sh -c "ctr -n k8s.io containers ls | grep -c busybox"
2
PS C:\Users\bijut> multipass exec worker2 -- sudo systemctl start kubelet
PS C:\Users\bijut> (Get-Date).ToUniversalTime().ToString("HH:mm:ss") + "  kubelet started"
21:07:16  kubelet started
PS C:\Users\bijut>



ubuntu@master:~$ kubectl -n kube-system exec kube-controller-manager-master -- kube-controller-manager --help 2>/dev/null | grep -A2 -E -- '--node-monitor-(grace-period|period)'
      --node-monitor-period duration                       The period for syncing NodeStatus in cloud-node-lifecycle-controller. (default 5s)
      --route-reconciliation-period duration               The period for reconciling routes created for Nodes by cloud provider. (default 10s)
      --use-service-account-credentials                    If true, use individual service account credentials for each controller.
--
      --node-monitor-grace-period duration     Amount of time which we allow running Node to be unresponsive before marking it unhealthy. Must be N times more than kubelet's nodeStatusUpdateFrequency, where N means number of retries allowed for kubelet to post node status. This value should also be greater than the sum of HTTP2_PING_TIMEOUT_SECONDS and HTTP2_READ_IDLE_TIMEOUT_SECONDS (default 50s)
      --node-startup-grace-period duration     Amount of time which we allow starting Node to be unresponsive before marking it unhealthy. (default 1m0s)
      --secondary-node-eviction-rate float32   Number of nodes per second on which pods are deleted in case of node failure when a zone is unhealthy (see --unhealthy-zone-threshold for definition of healthy/unhealthy). Zone refers to entire cluster in non-multizone clusters. This value is implicitly overridden to 0 if the cluster size is smaller than --large-cluster-size-threshold. (default 0.01)
ubuntu@master:~$



ubuntu@master:~$ kubectl rollout restart deployment/victim
kubectl rollout status deployment/victim --timeout=90s
kubectl get pods -l app=victim -o wide --no-headers | awk '{print $1, $3, $7}'
deployment.apps/victim restarted
Waiting for deployment spec update to be observed...
Waiting for deployment "victim" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "victim" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "victim" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "victim" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "victim" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "victim" rollout to finish: 3 of 4 updated replicas are available...
Waiting for deployment "victim" rollout to finish: 3 of 4 updated replicas are available...
deployment "victim" successfully rolled out
victim-5f9b4c4696-4pvws Terminating worker1
victim-5f9b4c4696-szjv6 Error worker1
victim-5f9b4c4696-whrmb Terminating worker1
victim-6ff5ccf9fb-9pzgh Running worker2
victim-6ff5ccf9fb-bs6mb Running worker2
victim-6ff5ccf9fb-kxr5p Running worker2
victim-6ff5ccf9fb-z8cg5 Running worker1
ubuntu@master:~$

ubuntu@worker2:~$ sudo cp -p /etc/kubernetes/kubelet.conf /root/kubelet.conf.bak
sudo sha256sum /etc/kubernetes/kubelet.conf /root/kubelet.conf.bak
sudo grep -E "^\s+server:" /etc/kubernetes/kubelet.conf
93aef6cf715c7770c44298aaa93500c1be75cfa36a0d8b7d69bbe0f9a1bc666c  /etc/kubernetes/kubelet.conf
93aef6cf715c7770c44298aaa93500c1be75cfa36a0d8b7d69bbe0f9a1bc666c  /root/kubelet.conf.bak
    server: https://172.25.246.7:6443
ubuntu@worker2:~$


ubuntu@master:~$ tl 28 5
21:33:39  ready=True  lease_age=1s  taints=[]  victim=[1xworker1:Running 3xworker2:Running ]
21:33:44  ready=True  lease_age=6s  taints=[]  victim=[1xworker1:Running 3xworker2:Running ]
21:33:49  ready=True  lease_age=1s  taints=[]  victim=[1xworker1:Running 3xworker2:Running ]
21:33:55  ready=True  lease_age=7s  taints=[]  victim=[1xworker1:Running 3xworker2:Running ]


ubuntu@worker2:~$ sudo cp -p /etc/kubernetes/kubelet.conf /root/kubelet.conf.bak
sudo sha256sum /etc/kubernetes/kubelet.conf /root/kubelet.conf.bak
sudo grep -E "^\s+server:" /etc/kubernetes/kubelet.conf
93aef6cf715c7770c44298aaa93500c1be75cfa36a0d8b7d69bbe0f9a1bc666c  /etc/kubernetes/kubelet.conf
93aef6cf715c7770c44298aaa93500c1be75cfa36a0d8b7d69bbe0f9a1bc666c  /root/kubelet.conf.bak
    server: https://172.25.246.7:6443
ubuntu@worker2:~$ sudo sed -i 's#https://172.25.246.7:6443#https://172.25.246.7:6444#' /etc/kubernetes/kubelet.conf
sudo grep -E "^\s+server:" /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
date -u +%T
    server: https://172.25.246.7:6444
21:33:54
ubuntu@worker2:~$

ubuntu@worker2:~$ systemctl is-active kubelet
sudo journalctl -u kubelet --since "3 minutes ago" --no-pager | grep 6444 | tail -4 | cut -c1-260
curl -sk --max-time 5 -o /dev/null -w "port 6443: HTTP %{http_code}\n" https://172.25.246.7:6443/healthz
curl -sk --max-time 5 -o /dev/null -w "port 6444: HTTP %{http_code}\n" https://172.25.246.7:6444/healthz
sudo ctr -n k8s.io tasks ls | wc -l
active
Oct 13 14:34:14 worker2 kubelet[725357]: E1013 14:34:14.553563  725357 kubelet_node_status.go:108] "Unable to register node with API server" err="Post \"https://172.25.246.7:6444/api/v1/nodes\": dial tcp 172.25.246.7:6444: connect: connection refused" node="wo
Oct 13 14:34:16 worker2 kubelet[725357]: E1013 14:34:16.143948  725357 event.go:368] "Unable to write event (may retry after sleeping)" err="Post \"https://172.25.246.7:6444/api/v1/namespaces/default/events\": dial tcp 172.25.246.7:6444: connect: connection re
Oct 13 14:34:21 worker2 kubelet[725357]: E1013 14:34:21.334801  725357 controller.go:201] "Failed to ensure lease exists, will retry" err="Get \"https://172.25.246.7:6444/apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases/worker2?timeout=10s\": dial
Oct 13 14:34:21 worker2 kubelet[725357]: E1013 14:34:21.559418  725357 kubelet_node_status.go:108] "Unable to register node with API server" err="Post \"https://172.25.246.7:6444/api/v1/nodes\": dial tcp 172.25.246.7:6444: connect: connection refused" node="wo
port 6443: HTTP 200
port 6444: HTTP 000
15
ubuntu@worker2:~$

ubuntu@worker2:~$ sudo cp -p /root/kubelet.conf.bak /etc/kubernetes/kubelet.conf
sudo sha256sum /etc/kubernetes/kubelet.conf /root/kubelet.conf.bak
sudo grep -E "^\s+server:" /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
date -u +%T
93aef6cf715c7770c44298aaa93500c1be75cfa36a0d8b7d69bbe0f9a1bc666c  /etc/kubernetes/kubelet.conf
93aef6cf715c7770c44298aaa93500c1be75cfa36a0d8b7d69bbe0f9a1bc666c  /root/kubelet.conf.bak
    server: https://172.25.246.7:6443
21:35:05
ubuntu@worker2:~$


ubuntu@master:~$ tl 8 5
21:35:27  ready=True  lease_age=2s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:35:32  ready=True  lease_age=7s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:35:38  ready=True  lease_age=2s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:35:43  ready=True  lease_age=7s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:35:48  ready=True  lease_age=2s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:35:54  ready=True  lease_age=7s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:35:59  ready=True  lease_age=3s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
21:36:04  ready=True  lease_age=8s  taints=[]  victim=[2xworker1:Running 2xworker2:Running ]
ubuntu@master:~$

ubuntu@master:~$ tl 8 5
kubectl get pods -A -o wide --no-headers --field-selector spec.nodeName=worker2 | awk '{print $1"/"$2, $4, "restarts="$5}'
21:47:26  ready=False  lease_age=4s  taints=[not-ready:NoSchedule not-ready:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:47:32  ready=False  lease_age=9s  taints=[not-ready:NoSchedule not-ready:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:47:37  ready=False  lease_age=5s  taints=[not-ready:NoSchedule not-ready:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:47:42  ready=False  lease_age=10s  taints=[not-ready:NoSchedule not-ready:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:47:47  ready=False  lease_age=5s  taints=[not-ready:NoSchedule not-ready:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:47:53  ready=False  lease_age=0s  taints=[not-ready:NoSchedule not-ready:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:47:58  ready=False  lease_age=5s  taints=[not-ready:NoSchedule not-ready:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
21:48:03  ready=False  lease_age=0s  taints=[not-ready:NoSchedule not-ready:NoExecute ]  victim=[4xworker1:Running 2xworker2:Terminating ]
default/nginx-5577fb97b9-4pp2g Running restarts=0
default/nginx-5577fb97b9-c8bgh Running restarts=0
fault/victim-6ff5ccf9fb-5k62q Terminating restarts=0
fault/victim-6ff5ccf9fb-ft42p Terminating restarts=0
kube-flannel/kube-flannel-ds-dszmf Running restarts=2
kube-system/kube-proxy-wqc59 Running restarts=0
ubuntu@master:~$
