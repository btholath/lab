# Kubernetes Horizontal Pod Autoscaling

## metrics-server, the HPA's arithmetic, scaling up and down, missing requests and the `behavior` settings, tested on a real cluster

The **Horizontal Pod Autoscaler** (HPA) changes the number of pods in a Deployment according to a measured metric, usually CPU. This guide installs the component it depends on, explains the rule it follows, and tests that rule on a real kubeadm cluster (1 control plane, 2 workers, Kubernetes v1.36.5). The console output after each lab is copied from the run. Where a prediction was wrong, the guide says so, and explanations marked as inferences are best guesses, not results.

**Contents**

1. What an HPA does
2. Installing metrics-server on a kubeadm cluster
3. A test workload that burns CPU
4. Creating the HPA
5. Scaling up under load
6. Scaling down
7. HPAs and missing CPU requests
8. The `behavior` settings
9. How the numbers work
10. Choosing settings, and traps
11. Clock problems during these labs
12. Practical tips for running these labs
13. Troubleshooting
14. Command cheat sheet
15. Glossary
16. What was run, and what was not

---

# 1. What an HPA does

An HPA is a control loop inside the controller manager. It reads a metric for the pods of a Deployment, compares it with a target, and changes the Deployment's replica count. As I recall the documentation, its core rule is:

```text
desired replicas = ceil( current replicas × current metric ÷ target metric )
```

For a CPU target given as a **percentage**, the "metric" is each pod's CPU use **as a fraction of its CPU request**. That is why the scheduling guide's lesson applies here: a container without a CPU request gives the HPA nothing to divide by (Section 7).

The pieces:

| Piece | Role |
|---|---|
| **metrics-server** | Collects CPU and memory from every kubelet and serves them through the metrics API. Without it the HPA has no data |
| **The HPA object** | Names the Deployment, the target, and the minimum and maximum replica counts |
| **The HPA controller** | Checks about every 15 seconds and changes the Deployment's replica count |
| **The Deployment** | Does the actual scaling, with the usual rolling behavior |

A pod that has just been created has no metrics for a short time, which the HPA has to tolerate (Section 7 shows its messages).

---

# 2. Installing metrics-server on a kubeadm cluster

## Which version, and what is needed

The standard install is a manifest from the project's releases page. Reading it first shows the version and the arguments:

```bash
curl -fsSL -o /tmp/metrics-components.yaml https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
grep -nE "image:|--kubelet|--secure-port|--cert-dir|--metric-resolution" /tmp/metrics-components.yaml
grep -nE -A3 "requests:" /tmp/metrics-components.yaml
grep -nE "readinessProbe|livenessProbe|/readyz|/livez|initialDelaySeconds|periodSeconds|failureThreshold" /tmp/metrics-components.yaml
```

### Observed on the real cluster

```text
136:        - --cert-dir=/tmp
137:        - --secure-port=10250
138:        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
139:        - --kubelet-use-node-status-port
140:        - --metric-resolution=15s
141:        image: registry.k8s.io/metrics-server/metrics-server:v0.9.0

164:          requests:
165-            cpu: 100m
166-            memory: 200Mi

143:        livenessProbe:   failureThreshold: 3, path: /livez, periodSeconds: 10
155:        readinessProbe:  failureThreshold: 3, path: /readyz, initialDelaySeconds: 20, periodSeconds: 10
```

| Setting | Meaning |
|---|---|
| `metrics-server:v0.9.0` | The version installed here. I could not confirm its compatibility with Kubernetes 1.36 beforehand. It turned out to work (below) |
| `--metric-resolution=15s` | It collects every 15 seconds, which limits how quickly the HPA can react |
| Requests of 100m CPU and 200Mi | Small, so it schedules on a worker. The master's taint keeps it off the master |
| Separate liveness and readiness probes | Failing scrapes make the pod **not ready**, but do not restart it (the probes guide's distinction, in a real manifest) |
| **No `--kubelet-insecure-tls`** | The default manifest verifies the kubelets' certificates |

## Applying it without the flag: the expected failure

```bash
kubectl apply -f /tmp/metrics-components.yaml
sleep 60
kubectl -n kube-system get pods -l k8s-app=metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
kubectl -n kube-system logs deploy/metrics-server --tail=6
```

### Observed on the real cluster

```text
serviceaccount/metrics-server created
[... nine objects in all, ending with ...]
apiservice.apiregistration.k8s.io/v1beta1.metrics.k8s.io created

NAME                              READY   STATUS              RESTARTS   AGE
metrics-server-687f9dc499-784ft   0/1     ContainerCreating   0          60s
v1beta1.metrics.k8s.io   kube-system/metrics-server   False (MissingEndpoints)   61s
error: Metrics API not available
```

After the image had finished downloading:

```text
Pulled   ...  Successfully pulled image "registry.k8s.io/metrics-server/metrics-server:v0.9.0" in 2m26.202s ... Image size: 23258428 bytes.
Warning  Unhealthy  7s (x18 over 2m48s)  Readiness probe failed: HTTP probe failed with statuscode: 500

metrics-server-687f9dc499-784ft   0/1   Running   0   6m29s

Failed to scrape node ... "https://172.25.246.7:10250/metrics/resource": tls: failed to verify certificate: x509: cannot validate certificate for 172.25.246.7 because it doesn't contain any IP SANs   (master)
[... the same for 172.25.253.184 (worker1) and 172.25.252.5 (worker2) ...]
Failed probe  probe="metric-storage-ready"  err="no metrics to serve"
```

The whole chain, with each link visible:

```text
the kubelet's certificate names no IP address
  -> every scrape fails ("cannot validate certificate for <IP> because it doesn't contain any IP SANs")
  -> metrics-server has no data ("no metrics to serve")
  -> its readiness probe returns HTTP 500
  -> the pod is Running but not ready, and has no endpoints
  -> the APIService is "MissingEndpoints"
  -> "kubectl top" says "Metrics API not available"
```

It is the same readiness mechanism as the `ready-demo` lab in the probes guide, with a real application. The IP-SAN check fails first, so these errors do not show whether the certificates would **also** be rejected for not being signed by the cluster CA. The flag skips verification altogether, so it fixes either.

### Two things that went wrong along the way

- **A slow image pull, misdiagnosed.** The pod sat in `ContainerCreating` for more than 5 minutes. Reading an empty `ctr -n k8s.io content active` as "nothing is downloading", I called it stalled. It wasn't: the pull finished by itself after 2 minutes 26 seconds. I don't know why that listing was empty during a pull in progress. A guess is that the kubelet's pulls take a path that `ctr` doesn't show. The `Pulled` event, with its duration, is the reliable evidence.
- **Pull speeds from `registry.k8s.io` varied about a hundredfold on the same network.** Earlier in the day, two images of 16.5 and 22.2 MB downloaded in 2.2 seconds each, at 7.6 and 9.9 MiB/s. The 22.2 MB metrics-server image took 146 seconds through the kubelet (about 155 KiB/s) and **251.7 seconds** by hand on the other worker (90.3 KiB/s). The cause is unknown. A slow route to the registry is a guess. If a manual pull is given a timeout, give it more than you think it needs.

## Adding the flag

```bash
kubectl -n kube-system patch deployment metrics-server --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server --timeout=240s
sleep 45
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
kubectl top pods -A
```

The flag skips verification of the kubelets' certificates, which is acceptable in a lab. The proper fix is for the kubelets to request serving certificates signed by the cluster CA (`serverTLSBootstrap: true` in the kubelet configuration, then approving the requests). That was not tried.

### Observed on the real cluster

```text
Waiting for deployment "metrics-server" rollout to finish: 1 old replicas are pending termination...
deployment "metrics-server" successfully rolled out
v1beta1.metrics.k8s.io   kube-system/metrics-server   True   18m
NAME      CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
master    103m         5%       921Mi           51%
worker1   30m          1%       700Mi           38%
worker2   25m          1%       499Mi           27%
```

| Prediction | Observed |
|---|---|
| The rollout completes, the old pod staying until the new one is ready | Yes |
| `AVAILABLE True` | **True** |
| All three nodes, the master using the most, nothing above about 50% CPU | **Yes**: the highest CPU is 5% |

So metrics-server v0.9.0 runs, scrapes all three kubelets and serves the metrics API on Kubernetes v1.36.5. That is evidence of basic compatibility, not a full check.

## Reading `kubectl top`

The percentages are fractions of the node's **allocatable** resources: 921Mi out of about 1,802Mi is 51.1%, and 103m out of 2,000m is 5.15%. They also look **truncated**, not rounded: worker1's 700Mi is 38.8%, and `top` shows 38%.

`top` reports **actual use**, and the scheduler counts **requests**. On the master they point in opposite directions:

| | What the scheduler reserved | What it really uses |
|---|---|---|
| master CPU | 850m (42%) | **103m (5%)** |
| master memory | 220Mi (12%) | **921Mi (51%)** |

The control-plane pods request a lot of CPU and little memory. `kube-apiserver` used 273Mi with no memory request at all. Requests can understate as easily as overstate. metrics-server itself used **3m CPU and 15Mi** against requests of 100m and 200Mi, which is 3% and 7.5% of what it asked for. That ratio, usage divided by request, is exactly what an HPA computes.

---

# 3. A test workload that burns CPU

The usual HPA walkthrough uses a PHP image, `hpa-example`. I avoided it: I recall it being several hundred megabytes (not checked), and the pull speeds above made that risky. This lab builds its own server from `busybox`, which is already cached on the workers: a small HTTP server whose every request burns a little CPU.

```bash
kubectl create namespace hpa
kubectl config set-context --current --namespace=hpa
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: burn
spec:
  replicas: 1
  selector:
    matchLabels:
      app: burn
  template:
    metadata:
      labels:
        app: burn
    spec:
      containers:
      - name: web
        image: busybox
        command: ["sh", "-c"]
        args:
        - |
          mkdir -p /www/cgi-bin
          cat > /www/cgi-bin/burn.sh <<'EOS'
          #!/bin/sh
          echo "Content-type: text/plain"
          echo ""
          i=0
          while [ $i -lt 20000 ]; do i=$((i+1)); done
          echo done
          EOS
          chmod +x /www/cgi-bin/burn.sh
          exec httpd -f -p 8080 -h /www
        ports:
        - containerPort: 8080
        readinessProbe:
          tcpSocket:
            port: 8080
          periodSeconds: 3
        resources:
          requests:
            cpu: 100m
          limits:
            cpu: 500m
---
apiVersion: v1
kind: Service
metadata:
  name: burn-svc
spec:
  selector:
    app: burn
  ports:
  - port: 80
    targetPort: 8080
EOF
kubectl rollout status deployment/burn
kubectl run probe-once --rm -i --restart=Never --image=busybox -- wget -qO- http://burn-svc/cgi-bin/burn.sh
```

The readiness probe is a `tcpSocket` check on purpose: an HTTP probe against the burning script would cost CPU on every probe. The request is 100m and the limit 500m, so one pod can use up to 5 times its request.

### Observed on the real cluster

```text
deployment "burn" successfully rolled out
burn-65d4c76cdf-q767l   1/1   Running   0   8s   10.244.2.243   worker2
done
```

The `done` proves the whole path: the script runs, the busybox web server serves it, and the Service forwards to the pod.

## Measuring what one request costs

The HPA's behavior depends on the total CPU demand, so the first step is to measure the cost of a single request. This reads the server's own CPU counter before and after 50 sequential requests:

```bash
P=$(kubectl get pod -l app=burn -o name)
a=$(kubectl exec $P -- sh -c 'grep "^usage_usec" /sys/fs/cgroup/cpu.stat' | awk '{print $2}')
kubectl run calib --rm -i --restart=Never --image=busybox -- sh -c 'for i in $(seq 1 50); do wget -q -O /dev/null http://burn-svc/cgi-bin/burn.sh; done; echo sent 50'
b=$(kubectl exec $P -- sh -c 'grep "^usage_usec" /sys/fs/cgroup/cpu.stat' | awk '{print $2}')
awk -v a=$a -v b=$b 'BEGIN {printf "CPU per request: %.1f ms  (total %.2f s for 50 requests)\n", (b-a)/50/1000, (b-a)/1000000}'
kubectl exec $P -- cat /sys/fs/cgroup/cpu.stat | grep -E "nr_throttled|throttled_usec"
```

### Observed on the real cluster

```text
sent 50
CPU per request: 23.9 ms  (total 1.20 s for 50 requests)
nr_throttled 23
throttled_usec 1006289
```

| Prediction | Observed |
|---|---|
| A guess of 20 to 60 ms per request | **23.9 ms**, at the low end |
| `nr_throttled` above 0 | **23**, with about 1.0 s of throttled time |

The throttle counters follow the arithmetic this time: a 500m limit gives the server 50 ms of CPU per 100 ms period, and 1.20 s of CPU needs at least 24 periods. This makes the low counters in the scheduling guide's CPU lab, where the quota was much smaller, more puzzling, and a tiny quota is only a guess for the difference.

The demand follows from the cost: at `r` requests per second, the total CPU is about `23.9 ms × r`. Six loops, each sending a request and sleeping a second, give about 5.7 requests per second, so I expected about **136m**. The pods actually used about 170 to 230m across the runs, so the real cost per request was probably higher than the calibration, which was taken under throttling. That was not tested.

---

# 4. Creating the HPA

A helper prints the HPA's view every 15 seconds. Keep its lines short, since a terminal can garble long pastes:

```bash
watch_hpa() {
  for i in $(seq 1 $1); do
    u=$(kubectl get hpa burn -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')
    c=$(kubectl get hpa burn -o jsonpath='{.status.currentReplicas}')
    d=$(kubectl get hpa burn -o jsonpath='{.status.desiredReplicas}')
    p=$(kubectl get pods -l app=burn --no-headers | wc -l)
    m=$(kubectl top pod -l app=burn --no-headers 2>/dev/null | awk '{printf "%s ", $2}')
    echo "$(date -u +%T)  util=${u}% current=$c desired=$d pods=$p cpu=[$m]"
    sleep ${2:-15}
  done
}
```

Then:

```bash
kubectl autoscale deployment burn --cpu=50% --min=1 --max=5
kubectl get hpa burn
watch_hpa 8 15
kubectl describe hpa burn | sed -n '/Conditions:/,$p'
```

The older flag `--cpu-percent` still works, but prints a deprecation warning: `--cpu` accepts either a percentage (`50%`) or an absolute quantity (`500m`).

### Observed on the real cluster

```text
horizontalpodautoscaler.autoscaling/burn autoscaled
NAME   REFERENCE         TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
burn   Deployment/burn   cpu: <unknown>/50%   1         5         0          0s
00:22:51  util=% current= desired=0 pods=1 cpu=[1m ]
00:23:06  util=1% current=1 desired=1 pods=1 cpu=[1m ]
00:23:21  util=1% current=1 desired=1 pods=1 cpu=[1m ]

Conditions:
  Type            Status  Reason              Message
  AbleToScale     True    ReadyForNewScale    recommended size matches current size
  ScalingActive   True    ValidMetricFound    the HPA was able to successfully calculate a replica count from cpu resource utilization (percentage of request)
  ScalingLimited  False   DesiredWithinRange  the desired count is within the acceptable range
Events:           <none>
```

| Prediction | Observed |
|---|---|
| `<unknown>/50%` at first | Yes, with `REPLICAS 0` and `AGE 0s`: its status had not been filled in |
| `util` empty for 15 to 60 s | Empty for **one sample only**: the first metric arrived faster than I had allowed for |
| `util=1%`, `cpu=[1m]` when idle | **Exactly that**: 1m against a 100m request is 1% |

The `ScalingActive` message names the rule in full: the count is computed from **"cpu resource utilization (percentage of request)"**.

---

# 5. Scaling up under load

A load generator sends six streams of requests, each one pausing a second between requests. Its termination grace period is 2 seconds, because its main process is a shell that ignores the termination signal, and the default would make deleting it take 30 seconds (the probes guide, Section 5):

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: loadgen
spec:
  terminationGracePeriodSeconds: 2
  containers:
  - name: gen
    image: busybox
    command: ["sh", "-c"]
    args:
    - |
      for i in 1 2 3 4 5 6; do
        ( while true; do wget -q -T 5 -O /dev/null http://burn-svc/cgi-bin/burn.sh; sleep 1; done ) &
      done
      wait
EOF
watch_hpa 22 15
kubectl describe hpa burn | sed -n '/Events:/,$p'
```

### Observed on the real cluster (default behavior)

```text
00:37:29  util=1% current=1 desired=1 pods=1 cpu=[1m ]
00:38:00  util=1% current=1 desired=1 pods=1 cpu=[100m ]
00:38:15  util=100% current=1 desired=2 pods=2 cpu=[162m ]
00:38:30  util=162% current=2 desired=4 pods=4 cpu=[119m 70m ]
00:38:46  util=94% current=4 desired=4 pods=4 cpu=[39m 37m 56m 39m ]
00:39:01  util=44% current=4 desired=4 pods=4 cpu=[40m 37m 42m 39m ]
[... between 36% and 50% for the next 3.5 minutes, always 4 pods ...]

Events:
  Normal  SuccessfulRescale  5m7s   horizontal-pod-autoscaler  New size: 2; reason: cpu resource utilization (percentage of request) above target
  Normal  SuccessfulRescale  4m52s  horizontal-pod-autoscaler  New size: 4; reason: cpu resource utilization (percentage of request) above target
```

| Prediction | Observed |
|---|---|
| `util` rises to about 100 to 150% | **100%, then 162%** |
| `desired` jumps to **3** | **Wrong: 2, then 4.** The two decisions came 15 seconds apart |
| Settles near 45% with three pods | **Four pods at about 43%** |

My estimate of the demand (136m) was too low, since the pods used about 170m. The right answer for 170m was ceil(170 ÷ 50) = 3.4, so **4 pods**, and the HPA got it right.

The arithmetic behind the two steps:

| Decision | Calculation | Result |
|---|---|---|
| 00:38:15 | ceil(1 × 100 ÷ 50) | **2** |
| 00:38:30 | ceil(1 × 162 ÷ 50) = ceil(3.24) | **4** |

The second can also be read with the new pod counted as using nothing, which as I recall is how the HPA treats a pod without metrics when scaling up: the average over two pods is 81%, and ceil(2 × 81 ÷ 50) = 4 as well. Both readings give the same answer here. The `cpu=[...]` column shows the effect: at 00:38:15 it lists one value, because the second pod had not been scraped yet.

Two more observations:

- **The HPA's view lags what `top` shows.** At 00:38:00 `top` reports 100m while `util` is still 1%. The metric is collected every 15 seconds and the HPA checks every 15 seconds, so a reading can be 15 to 30 seconds old.
- **The pods started within seconds** because `busybox` was cached on both workers. An uncached image would add its pull time (Section 2) before the new pod can take load.

---

# 6. Scaling down

Stop the load and watch:

```bash
kubectl delete pod loadgen
date -u +%T
watch_hpa 8 15
kubectl describe hpa burn | sed -n '/Conditions:/,/Events:/p'
watch_hpa 24 15
kubectl describe hpa burn | sed -n '/Events:/,$p'
```

### Observed on the real cluster (default behavior)

```text
00:51:12  (load deleted)
00:51:12  util=40% current=4 desired=4 pods=4 cpu=[56m 48m 40m 52m ]
00:51:27  util=49% current=4 desired=4 pods=4 cpu=[14m 25m 31m 4m ]
00:51:43  util=18% current=4 desired=4 pods=4 cpu=[1m 1m 1m 4m ]
00:51:58  util=1% current=4 desired=4 pods=4 cpu=[1m 1m 1m 1m ]
[... 1%, still 4 replicas, until 00:56:19 ...]
00:56:34  util=1% current=2 desired=1 pods=4 cpu=[1m 1m 1m 1m ]
00:56:50  util=1% current=1 desired=1 pods=3 cpu=[1m 1m ]
00:57:05  util=1% current=1 desired=1 pods=1 cpu=[1m ]

  AbleToScale     True    ScaleDownStabilized  recent recommendations were higher than current one, applying the highest recent recommendation

  Normal  SuccessfulRescale  3m4s   horizontal-pod-autoscaler  New size: 2; reason: All metrics below target
  Normal  SuccessfulRescale  2m49s  horizontal-pod-autoscaler  New size: 1; reason: All metrics below target
```

| Prediction | Observed |
|---|---|
| `util` falls to about 1% in 15 to 30 s | **46 s**: the metric lags by a collection period |
| The replicas **stay at 4** for about 5 minutes | **Yes**: the first drop was at about 00:56:19, **5 min 7 s** after the load stopped |
| The condition reads `ScaleDownStabilized` | **Yes**, with that message |
| One step from 4 straight to 1 | **Wrong: 4 → 2 → 1**, in two steps 15 seconds apart |

Scaling up took about 90 seconds, and scaling down took about 6 minutes. The asymmetry is deliberate: a slow scale-down avoids flapping when load arrives in waves.

The message says "applying the highest recent recommendation". My reading, which is an inference: every 15 seconds the HPA computes a recommended size, and during a scale-down it uses the **highest recommendation from the last 5 minutes**:

| Reading | `util` | Recommendation: ceil(4 × util ÷ 50) |
|---|---|---|
| 00:51:12 | 40% | **4** |
| 00:51:27 | 49% | **4** |
| 00:51:43 | 18% | **2** |
| 00:51:58 onward | 1% | **1** |

The last "4" left the 5-minute window at about 00:56:20, and the highest recommendation fell to **2** (from the 18% reading), which matches the scale to 2. About 15 seconds later that 2 left the window too, leaving 1. So the two steps record how the metric fell over the minute after the load stopped. The controller's own logs were not read to confirm it.

---

# 7. HPAs and missing CPU requests

A Deployment whose container has **no CPU request**:

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: norequest
spec:
  replicas: 1
  selector:
    matchLabels:
      app: norequest
  template:
    metadata:
      labels:
        app: norequest
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "sleep 3600"]
EOF
kubectl autoscale deployment norequest --cpu=50% --min=1 --max=3
sleep 60
kubectl get hpa norequest
kubectl describe hpa norequest | sed -n '/Conditions:/,$p'
kubectl top pod -l app=norequest
```

### Observed on the real cluster

```text
NAME        REFERENCE              TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
norequest   Deployment/norequest   cpu: <unknown>/50%   1         3         1          60s

  AbleToScale    True    SucceededGetScale        the HPA controller was able to get the target's current scale
  ScalingActive  False   FailedGetResourceMetric  the HPA was unable to compute the replica count: failed to get cpu utilization: missing request for cpu in container app of Pod norequest-c5f944849-kfj7x

  Warning  FailedGetResourceMetric       45s  failed to get cpu utilization: unable to get metrics for resource cpu: no metrics returned from resource metrics API
  Warning  FailedGetResourceMetric       0s (x3 over 30s)  failed to get cpu utilization: missing request for cpu in container app of Pod norequest-c5f944849-kfj7x

NAME                        CPU(cores)   MEMORY(bytes)
norequest-c5f944849-kfj7x   0m           0Mi
```

The HPA refuses: it does not guess a default request or treat it as zero. `AbleToScale` is `True`, so the HPA can read the Deployment's scale, and the problem is purely the metric. `kubectl top` still works, because it reports raw usage and needs no requests.

## Three "no metrics" messages, three meanings

| Message | When it appeared | Persistent? |
|---|---|---|
| `no metrics returned from resource metrics API` | A brand-new pod: the metrics API had nothing for it yet | **No**, it clears after one collection cycle |
| `did not receive metrics for targeted pods (pods might be unready)` | Just after a rollout: the new pod had not been scraped yet | **No**, it appeared twice over 45 s and stopped |
| `missing request for cpu in container app of Pod ...` | The container has no CPU request | **Yes**, until a request is added |

The first two are the HPA waiting for a new pod. Only the third is a configuration error.

## An absolute target needs no request

```bash
kubectl delete hpa norequest
kubectl apply -f - <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: norequest
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: norequest
  minReplicas: 1
  maxReplicas: 3
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: AverageValue
        averageValue: 50m
EOF
sleep 60
kubectl get hpa norequest
kubectl describe hpa norequest | sed -n '/Conditions:/,$p'
```

### Observed on the real cluster

```text
NAME        REFERENCE              TARGETS      MINPODS   MAXPODS   REPLICAS   AGE
norequest   Deployment/norequest   cpu: 0/50m   1         3         1          60s
  AbleToScale     True    ReadyForNewScale  recommended size matches current size
  ScalingActive   True    ValidMetricFound  the HPA was able to successfully calculate a replica count from cpu resource
  ScalingLimited  True    TooFewReplicas    the desired replica count is less than the minimum replica count
Events:           <none>
```

The same pod, the same metric and the same controller work with `AverageValue`, which compares raw usage with a figure like `50m` and has no ratio to compute. The message no longer says "percentage of request".

`ScalingLimited True ... TooFewReplicas` is explained, I think, by usage being **0m**: the computed count is ceil(0) = 0, below `minReplicas: 1`, so the HPA clamps it and says so. The idle `burn` HPA used 1m and showed `DesiredWithinRange` instead.

## The fix: add a request

```bash
kubectl delete hpa norequest
kubectl set resources deployment norequest -c app --requests=cpu=100m
kubectl rollout status deployment/norequest
kubectl autoscale deployment norequest --cpu=50% --min=1 --max=3
sleep 60
kubectl get hpa norequest
```

### Observed on the real cluster

```text
NAME        REFERENCE              TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
norequest   Deployment/norequest   cpu: 0%/50%   1         3         1          60s
  ScalingActive   True    ValidMetricFound   ... cpu resource utilization (percentage of request)
  Warning  FailedGetResourceMetric  30s (x2 over 45s)  did not receive metrics for targeted pods (pods might be unready)
```

| HPA target | Needs a request? | Result on the same pod |
|---|---|---|
| `averageUtilization: 50` with no request | **Yes** | `<unknown>`, `missing request for cpu` |
| `averageValue: 50m` with no request | **No** | `cpu: 0/50m`, working |
| `averageUtilization: 50` after adding a request | Satisfied | `cpu: 0%/50%`, working |

One prediction here was wrong: I expected `ScalingLimited True`, as with the absolute target, and it read `False, DesiredWithinRange`, alongside `ScaleDownStabilized`. I don't know why. A guess: the window that keeps the highest recent recommendation still held a recommendation of 1 from the first seconds. That was not verified.

---

# 8. The `behavior` settings

The defaults (a 5-minute scale-down window, and quick scale-up) are only defaults. This HPA changes both:

```bash
kubectl delete hpa burn
kubectl apply -f - <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: burn
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: burn
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleUp:
      policies:
      - type: Pods
        value: 1
        periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 30
      policies:
      - type: Pods
        value: 1
        periodSeconds: 15
EOF
kubectl get hpa burn -o jsonpath='{.spec.behavior}{"\n"}'
```

### Observed on the real cluster

```text
{"scaleDown":{"policies":[{"periodSeconds":15,"type":"Pods","value":1}],"selectPolicy":"Max","stabilizationWindowSeconds":30},"scaleUp":{"policies":[{"periodSeconds":30,"type":"Pods","value":1}],"selectPolicy":"Max","stabilizationWindowSeconds":0}}
```

The API filled in two defaults: `selectPolicy: Max` on both sides (which, as I recall it, matters only when there are several policies) and `stabilizationWindowSeconds: 0` for scale-up.

## Scaling up with one pod per 30 seconds

Run with the load generator from Section 5. The events carry exact times, so capture them within the hour (Section 12):

```bash
watch_hpa 12 15
kubectl get events --field-selector involvedObject.name=burn,reason=SuccessfulRescale --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,MSG:.message
```

### Observed on the real cluster

```text
22:45:26  util=81% current=1 desired=2 pods=2 cpu=[81m ]
22:45:41  util=159% current=2 desired=2 pods=2 cpu=[159m ]
22:45:56  util=117% current=2 desired=3 pods=3 cpu=[106m 128m ]
22:46:27  util=61% current=3 desired=4 pods=4 cpu=[84m 46m 53m ]
22:46:58  util=55% current=4 desired=4 pods=4 cpu=[49m 62m 69m 42m ]
22:47:13  util=57% current=4 desired=5 pods=5 cpu=[51m 64m 58m 58m ]
22:47:44  util=32% current=5 desired=5 pods=5 cpu=[31m 38m 26m 21m 34m ]

2026-10-11T22:45:16Z   New size: 2; reason: cpu resource utilization (percentage of request) above target
2026-10-11T22:45:46Z   New size: 3; reason: cpu resource utilization (percentage of request) above target
2026-10-11T22:46:16Z   New size: 4; reason: cpu resource utilization (percentage of request) above target
2026-10-11T22:47:01Z   New size: 5; reason: cpu resource utilization (percentage of request) above target
```

| Prediction | Observed |
|---|---|
| Steps of 30 to 45 s | **Exactly 30 s** twice (22:45:16, :46, 22:46:16), then 45 s |
| Without `behavior`, 2 → 4 took 15 s | **60 s** from the first step to the third, so the policy changed the pace |
| It settles at 4 | **Wrong: it went to 5**, the maximum |

The step to 5 follows the arithmetic: at four pods the reading was 57%, and ceil(4 × 57 ÷ 50) = 5. The readings at 55% and 54% (in an earlier run with the same settings) did not move it, so the tolerance sits at about 10%: 55 ÷ 50 is exactly 1.10, and 57 ÷ 50 is 1.14.

## The flapping, with a 30-second window

```text
2026-10-11T22:47:46Z   New size: 4; reason: All metrics below target       <- 5 pods, util 32%: ceil(5 × 32 ÷ 50) = 4
2026-10-11T22:48:01Z   New size: 3; reason: All metrics below target       <- 4 pods, util 37%: ceil(4 × 37 ÷ 50) = 3
22:48:12   the load generator was deleted
```

Both scale-downs happened **while the load was still running**. The HPA went 4 → 5 → 4 → 3 under constant load, and three pods would have been at about 55%, which would trigger a scale-up again. The default 5-minute window would have held 5 for 5 minutes, as it held 4 in Section 6. A short window saves time, and allows exactly this oscillation. The total demand fluctuated between about 160m and 230m over these minutes, which I cannot explain.

## Scaling down one pod at a time

```text
22:48:13  util=37% current=4 desired=3 pods=5 cpu=[13m 38m 31m 38m 44m ]
22:48:28  util=46% current=3 desired=3 pods=4 cpu=[68m 36m 69m 34m ]
22:48:43  util=31% current=3 desired=3 pods=3 cpu=[5m 47m 41m ]
22:48:58  util=2% current=3 desired=2 pods=3 cpu=[1m 1m 1m ]
22:49:14  util=1% current=2 desired=1 pods=3 cpu=[1m 1m 1m ]
22:49:44  util=1% current=1 desired=1 pods=1 cpu=[1m ]

2026-10-11T22:47:46Z   New size: 4
2026-10-11T22:48:01Z   New size: 3
2026-10-11T22:48:46Z   New size: 2
2026-10-11T22:49:01Z   New size: 1
```

| Observation | Meaning |
|---|---|
| Every step is **one pod** | The policy `Pods 1 per 15 s` limits the descent. Section 6 went 4 → 2 → 1 with the default |
| Gaps of **exactly 15 s** (22:47:46 to 22:48:01, and 22:48:46 to 22:49:01) | The 15-second period is visible |
| A 45-second pause before 3 → 2 | The draining load: at 22:48:28 the reading was 46%, which recommends 3, and only the 31% reading at 22:48:43 recommended 2 |
| Pods reached 1 at 22:49:44, **92 s** after the delete | Terminating pods are still counted in `pods=` for a few seconds, so `pods` lags `current` |

Because two scale-downs had already happened under load, this run does **not** isolate the time from stopping the load to the first drop. The default 5-minute result in Section 6 is unaffected.

---

# 9. How the numbers work

| Rule | Evidence from the labs |
|---|---|
| The HPA decides about every **15 s** | Every event time fell on a multiple of 15 seconds from the first one |
| `desired = ceil(current × util ÷ target)` | Every decision in Sections 5 and 8 reproduces (for example ceil(4 × 57 ÷ 50) = 5, ceil(5 × 32 ÷ 50) = 4) |
| About a **10% tolerance** around the target | 54% and 55% at four pods changed nothing, and 57% scaled up |
| A new pod has no metrics at first, and the HPA is cautious about it | The first sample after a scale-up lists one value fewer than there are pods |
| Scale-up has no window by default, scale-down keeps the **highest recommendation of the last 5 minutes** | 5 min 7 s before the first drop (Section 6) |
| Policies limit the **size** of each step | +1 per 30 s up, and -1 per 15 s down (Section 8) |
| The metric is **15 to 30 s old** | `top` showed 100m at 00:38:00 while `util` still read 1% |

The defaults named here are as I recall them from the documentation, and the labs agree with them. The default scale-up policy, as I recall it, allows doubling or 4 pods per 15 seconds, whichever is more, and the first run went 1 → 2 → 4, which fits.

---

# 10. Choosing settings, and traps

| Choice | Guidance |
|---|---|
| The CPU request | It is the **denominator** of the percentage. Set it near what a pod really needs. Too high and the HPA never scales (the pod looks idle), too low and it scales eagerly. Compare `kubectl top` with the request |
| The target | 50% leaves room for a burst while new pods start. 80 to 90% leaves little |
| `minReplicas` | At least 2 if a single pod's failure matters. The HPA cannot help while the minimum is 1 and that pod is down |
| `maxReplicas` | A hard ceiling. At the maximum, the HPA keeps recommending more, and nothing happens. Check `ScalingLimited` |
| The scale-down window | Short saves resources, and invites **flapping** (Section 8). The default is deliberate |
| New pods | Add readiness probes (the probes guide), and make the image small or cached: a pod that takes minutes to start does not help a short spike |

| Trap | What happens |
|---|---|
| A container with no CPU request and a **percentage** target | `<unknown>`, `missing request for cpu` (Section 7) |
| Reading `<unknown>` right after creating an HPA | Often just the first collection cycle. Wait, then read the message |
| A short stabilization window under noisy load | The count oscillates (Section 8) |
| The maximum too low | The HPA saturates and the pods stay overloaded |
| Expecting instant scaling | There is a 15 to 30 s metric delay, plus the new pods' start-up time |
| A Deployment with a fixed `replicas` in its manifest | Re-applying the manifest resets the count and fights the HPA. This was not tested here, but is a widely known problem, so omit `replicas` when an HPA owns the count |

---

# 11. Clock problems during these labs

Time-based labs are sensitive to VM clock drift, and three episodes interrupted these:

| When | What the check showed |
|---|---|
| Before installing metrics-server | master **−35.9 s**, the workers within noise. Corrected by restarting `systemd-timesyncd` on the master |
| During the first idle HPA watch | The watch loop printed lines **582 seconds** apart instead of 15, and a later check found **worker2 at −582.2 s**, to the second |
| Before the last runs, 19 hours later | All three within about 1 s |

The match between the 582-second gap in the watch and worker2's offset is my evidence that all three VMs were **paused together** (probably by the laptop sleeping) for about 9.7 minutes: the master and worker1 corrected their clocks when they resumed, and worker2 had not yet. That is an inference. `NTPSynchronized = yes` is not reliable evidence. Compare each VM with Windows instead (the check is in the workload controllers guide, Section 15).

The HPA reads timestamps from the nodes, and I don't know how it reacts to a node whose clock is minutes off, so the labs were run only after the clocks agreed.

---

# 12. Practical tips for running these labs

- **Check the clocks before each timed block**, and again after the laptop has slept.
- **Capture events within the hour.** An events query returned only its header for scaling events that were 19 hours old. As I recall, the API server keeps events for about an hour by default. `kubectl get events` showing nothing does not mean nothing happened.
- **Paste long blocks in pieces.** The terminal wrapped long lines and fused commands into manifests more than once. A manifest garbled on the screen was still applied correctly, and its Service worked.
- **`pod/loadgen unchanged`** means the pod already existed, probably because the block was pasted twice.
- **Delete the load generator with a short grace period**, or the shell that runs it takes 30 seconds to stop.
- **Keep the namespace until the end**, and clean up with `kubectl delete namespace hpa` and `kubectl config set-context --current --namespace=default`. metrics-server lives in `kube-system` and stays installed. It uses about 3m CPU and 15Mi.

---

# 13. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `kubectl top` says `Metrics API not available` | metrics-server is missing, not ready, or cannot scrape the kubelets | `kubectl -n kube-system get pods -l k8s-app=metrics-server`, then read its logs. On kubeadm, look for the x509 error (Section 2) |
| The metrics-server pod is `0/1 Running` | It cannot scrape, and its readiness probe returns 500 | Read the logs for the scrape error |
| The pod sits in `ContainerCreating` for minutes | A slow image pull | `kubectl describe pod` and look for `Pulled ... in N`. Wait |
| `TARGETS` shows `<unknown>` | No metrics yet, or a missing request | Wait a cycle, then read `kubectl describe hpa` |
| `missing request for cpu in container X` | The container has no CPU request | Add a request, or use an `AverageValue` target |
| `no metrics returned from resource metrics API` or `did not receive metrics for targeted pods` | A new pod that has not been scraped yet | Wait. It clears |
| The replicas are stuck below the load | `maxReplicas` reached | `ScalingLimited` and the HPA's `desired` show it |
| The replicas oscillate | A short stabilization window with noisy load | Lengthen `scaleDown.stabilizationWindowSeconds` |
| The replicas do not drop after the load ends | The 5-minute default window | Wait, or shorten it |
| A scale-up is slow | A `behavior` policy limits the step, or the new pods start slowly | `kubectl get hpa -o jsonpath='{.spec.behavior}'`, and the new pods' events |
| An events query shows nothing for old scaling | Events expire after about an hour | Capture them while fresh |

---

# 14. Command cheat sheet

| Task | Command |
|---|---|
| Install metrics-server | `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml` |
| Skip kubelet certificate checks (lab only) | `kubectl -n kube-system patch deployment metrics-server --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'` |
| Node usage | `kubectl top nodes` |
| Pod usage | `kubectl top pods -A` |
| Create an HPA | `kubectl autoscale deployment NAME --cpu=50% --min=1 --max=5` |
| See HPAs | `kubectl get hpa` |
| Why an HPA does what it does | `kubectl describe hpa NAME` |
| Scaling events | `kubectl get events --field-selector involvedObject.name=NAME,reason=SuccessfulRescale --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,MSG:.message` |
| The `behavior` of an HPA | `kubectl get hpa NAME -o jsonpath='{.spec.behavior}'` |
| Add a CPU request | `kubectl set resources deployment NAME -c CONTAINER --requests=cpu=100m` |

---

# 15. Glossary

| Term | Meaning |
|---|---|
| **HPA** | The Horizontal Pod Autoscaler: changes a Deployment's replica count according to a metric |
| **metrics-server** | The component that collects CPU and memory and serves the metrics API |
| **APIService** | A registration that sends requests for an API group, here `metrics.k8s.io`, to a Service |
| **Utilization** | CPU use as a percentage of the pod's **request** |
| **AverageValue** | A target in absolute units per pod, such as `50m` |
| **Tolerance** | The band around the target (about 10%) inside which the HPA does nothing |
| **Stabilization window** | The period over which the HPA keeps the highest (for scale-down) recent recommendation |
| **Policy** | A limit on how many pods the HPA may add or remove per period |
| **Flapping** | The replica count oscillating up and down under steady load |
| **Working set** | The memory figure `kubectl top` reports, which differs from the `used` column of `free` |

---

# 16. What was run, and what was not

## Run on the real cluster (the output above is from these)

- Installing metrics-server v0.9.0 on kubeadm: the x509 failure and its full chain, the slow pulls, and the fix with `--kubelet-insecure-tls`
- `kubectl top` on nodes and pods, and its percentages
- Measuring a request's CPU cost (23.9 ms) and the throttle counters
- An idle HPA, scaling up under load (1 → 2 → 4), and scaling down after 5 minutes (4 → 2 → 1)
- The HPA with no CPU request: the failure, the three "no metrics" messages, an absolute target that works, and the fix
- The `behavior` settings: one pod per 30 s up (exact event times), the overshoot to 5, the flapping with a 30-second window, and one pod per 15 s down

## Not run

- **Memory as a metric**, and several metrics at once
- **Custom and external metrics**, and per-container metrics
- **`Percent` policies**, `selectPolicy` other than the default, and a scale-up stabilization window
- **Scaling to zero**
- **The interaction of an HPA with a Deployment whose manifest fixes `replicas`**
- **How the HPA treats pods that are not ready**, beyond the first-sample behavior seen here
- **Serving certificates signed by the cluster CA** (`serverTLSBootstrap`)
- **The Vertical Pod Autoscaler and the Cluster Autoscaler**
- **An isolated measurement** of the first drop after the load stops with the 30-second window

The explanations marked as inferences in the text (the two-step scale-down, the pause that caused the clock gaps, the empty `ctr content active`) are the best fit to the evidence, and not verified. Check the official Kubernetes documentation for the version you run.

## Clean up everything from this guide

```bash
kubectl delete namespace hpa
kubectl config set-context --current --namespace=default
```

The first command deletes the test workload, the HPAs and the load generator. metrics-server in `kube-system` stays installed. To remove it as well, run `kubectl delete -f /tmp/metrics-components.yaml`.
