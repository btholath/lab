# Kubernetes Probes: Readiness, Liveness and Startup

## How Kubernetes decides whether a container is ready, alive, or still starting, tested on a real cluster

A container can be running and still be useless: stuck, not yet listening, or too slow to start. **Probes** are how Kubernetes tells the difference. This guide explains the three kinds, and tests each on a real kubeadm cluster (1 control plane, 2 workers, Kubernetes v1.36.5). The console output after each lab is copied from the run. Where a prediction was wrong, the guide says so, and explanations marked as inferences are best guesses, not results.

**Contents**

1. The three probes
2. Readiness: controlling traffic
3. Readiness is asymmetric
4. Liveness: restarting a stuck container
5. The cost of ignoring the termination signal
6. Startup probes: protecting a slow start
7. What counts as a failure
8. Every event message seen
9. Choosing settings
10. Traps
11. Practical tips for running these labs
12. Troubleshooting
13. Command cheat sheet
14. Glossary
15. What was run, and what was not

---

# 1. The three probes

| Probe | The question it answers | If it fails |
|---|---|---|
| **Readiness** | "Should this pod receive traffic right now?" | The pod is taken out of the Service's endpoints. It is **not restarted** |
| **Liveness** | "Is this container stuck?" | The kubelet **restarts the container** |
| **Startup** | "Has this slow application finished starting?" | While it runs, the other two probes are held off. If it never succeeds, the container is restarted |

## How a probe checks

| Mechanism | Success means |
|---|---|
| `exec` | The command exits with status 0 |
| `httpGet` | The response status is 2xx or 3xx |
| `tcpSocket` | The port accepts a connection |
| `grpc` | A gRPC health check succeeds (not tested here) |

## Tuning fields

These are the documented defaults, as I recall them:

| Field | Default | Meaning |
|---|---|---|
| `initialDelaySeconds` | 0 | Wait before the first probe |
| `periodSeconds` | 10 | Time between probes |
| `timeoutSeconds` | 1 | How long one probe may take |
| `successThreshold` | 1 | Consecutive successes needed to count as healthy again |
| `failureThreshold` | 3 | Consecutive failures needed to count as failed |

```yaml
readinessProbe:
  httpGet:
    path: /
    port: 80
  periodSeconds: 3
livenessProbe:
  exec:
    command: ["cat", "/tmp/healthy"]
  initialDelaySeconds: 5
  periodSeconds: 5
startupProbe:
  exec:
    command: ["cat", "/tmp/ok"]
  periodSeconds: 5
  failureThreshold: 12
```

## You have already seen readiness at work

In the workload controllers guide (Section 9), the `rolling` Deployment had a readiness probe with a 10-second `initialDelaySeconds`. Each new pod took about 12 seconds to count as available, and a four-pod rollout took 51 seconds. The `web` Deployment in Section 7 had **no** probe, so a pod counted as ready the instant its container started, and its rollouts finished in about 4 seconds. A readiness probe is what gives a rolling update something to wait for.

---

# 2. Readiness: controlling traffic

This lab uses a probe you control by hand. A pod is "ready" only while the file `/tmp/ready` exists in it, and you create and remove that file yourself. The pods just run `sleep`, so there is no real server: a Service's endpoints depend on readiness, not on whether anything listens.

```bash
kubectl create namespace probes
kubectl config set-context --current --namespace=probes
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ready-demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ready-demo
  template:
    metadata:
      labels:
        app: ready-demo
    spec:
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "sleep 3600"]
        readinessProbe:
          exec:
            command: ["cat", "/tmp/ready"]
          periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: ready-svc
spec:
  selector:
    app: ready-demo
  ports:
  - port: 80
    targetPort: 80
EOF
```

A small helper prints each pod's readiness and restart count, and the Service's endpoints:

```bash
show() { echo "--- $1"; kubectl get pods -l app=ready-demo --no-headers -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount; echo "ready endpoints=[$(kubectl get endpoints ready-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)] notReady=[$(kubectl get endpoints ready-svc -o jsonpath='{.subsets[*].notReadyAddresses[*].ip}' 2>/dev/null)]"; }
sleep 12
kubectl get deployment ready-demo
show "starting state: no pod has /tmp/ready"
```

Then make pods ready and unready by hand:

```bash
P1=$(kubectl get pods -l app=ready-demo -o name | sed -n 1p)
P2=$(kubectl get pods -l app=ready-demo -o name | sed -n 2p)
kubectl exec $P1 -- touch /tmp/ready; sleep 6; show "after P1 gets /tmp/ready"
kubectl exec $P2 -- touch /tmp/ready; sleep 6; show "after P2 gets /tmp/ready"
kubectl exec $P1 -- rm /tmp/ready; sleep 6; show "after P1 loses /tmp/ready"
kubectl get deployment ready-demo
kubectl get events --field-selector reason=Unhealthy | tail -3
```

### Observed on the real cluster

```text
NAME         READY   UP-TO-DATE   AVAILABLE   AGE
ready-demo   0/3     3            0           28s
--- starting state: no pod has /tmp/ready
ready-demo-857976c8cb-bn6ld   false   0
ready-demo-857976c8cb-njb46   false   0
ready-demo-857976c8cb-p4jkz   false   0
ready endpoints=[] notReady=[10.244.1.95 10.244.2.234 10.244.2.235]

--- after P1 gets /tmp/ready
ready-demo-857976c8cb-bn6ld   true    0
ready-demo-857976c8cb-njb46   false   0
ready-demo-857976c8cb-p4jkz   false   0
ready endpoints=[10.244.2.235] notReady=[10.244.1.95 10.244.2.234]

--- after P2 gets /tmp/ready
ready-demo-857976c8cb-bn6ld   true    0
ready-demo-857976c8cb-njb46   true    0
ready-demo-857976c8cb-p4jkz   false   0
ready endpoints=[10.244.1.95 10.244.2.235] notReady=[10.244.2.234]

NAME         READY   UP-TO-DATE   AVAILABLE   AGE
ready-demo   2/3     3            2           2m28s
Warning   Unhealthy   pod/ready-demo-857976c8cb-bn6ld   Readiness probe failed: cat: can't open '/tmp/ready': No such file or directory
```

| Step | Predicted | Observed |
|---|---|---|
| Starting state | `READY 0/3`, all pods `false`, no ready endpoints | Exactly that, with all three IPs in `notReady` |
| After P1 gets the file | P1 turns `true`, with one ready endpoint | One ready endpoint, and two in `notReady` |
| After P2 gets it | Two ready endpoints | Two ready endpoints |
| `RESTARTS` | 0 throughout | **0 for every pod, every time.** A readiness failure never restarts a container |
| The event wording | `Readiness probe failed: cat: can't open '/tmp/ready': No such file or directory` | **Exactly that** |

A pod that is not ready is **still listed in the Service's endpoints object**, in `notReadyAddresses`, and traffic is never sent to it. That is the mechanism behind a rolling update waiting for new pods.

---

# 3. Readiness is asymmetric

After `rm /tmp/ready`, P1 was still `true` six seconds later, which I had not expected. I had forgotten my own table: `failureThreshold` defaults to 3, and the probe ran every 3 seconds. A follow-up measured both directions on P2, with one reading per second:

```bash
P2=$(kubectl get pods -l app=ready-demo -o name | sed -n 2p)
kubectl exec $P2 -- rm /tmp/ready
t0=$(date +%s)
for i in $(seq 1 16); do echo "t+$(( $(date +%s) - t0 ))s  ready=$(kubectl get $P2 -o jsonpath='{.status.containerStatuses[0].ready}')"; sleep 1; done
kubectl exec $P2 -- touch /tmp/ready
t0=$(date +%s)
for i in $(seq 1 10); do echo "t+$(( $(date +%s) - t0 ))s  ready=$(kubectl get $P2 -o jsonpath='{.status.containerStatuses[0].ready}')"; sleep 1; done
```

### Observed on the real cluster

| Direction | Result |
|---|---|
| File removed | `ready=true` until `t+7s`, then **`false` from `t+8s`**: about **7 to 8 seconds** |
| File restored | `ready=false` at `t+1s`, then **`true` from `t+2s`**: about **2 seconds** |

| Direction | What it needs | Expected with `periodSeconds: 3` | Observed |
|---|---|---|---|
| Ready to not ready | `failureThreshold` = 3 failures in a row | about 6 to 9 s | **7 to 8 s** |
| Not ready to ready | `successThreshold` = 1 success | within about 3 s | **about 2 s** |

The pattern is deliberate: it stops a single slow or failed probe from taking a pod out of service, and brings a healthy pod back fast. A consequence: **a probe's period and threshold set how long an unhealthy pod keeps receiving traffic.** With the defaults (10 s and 3), that is up to 30 seconds. The measurement is of the pod's own `ready` flag, and the endpoint list changes a moment later.

---

# 4. Liveness: restarting a stuck container

A liveness failure makes the kubelet **restart the container**. Two identical pods, `live-a` and `live-b`, each create `/tmp/healthy`, remove it after 30 seconds, and have a liveness probe that checks for it. The only difference: `live-b` handles the termination signal (`trap 'exit 0' TERM`), and `live-a` does not.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: live-a
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "touch /tmp/healthy; sleep 30; rm -f /tmp/healthy; sleep 600"]
    livenessProbe:
      exec:
        command: ["cat", "/tmp/healthy"]
      initialDelaySeconds: 5
      periodSeconds: 5
---
apiVersion: v1
kind: Pod
metadata:
  name: live-b
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "trap 'exit 0' TERM; touch /tmp/healthy; sleep 30; rm -f /tmp/healthy; sleep 600 & wait"]
    livenessProbe:
      exec:
        command: ["cat", "/tmp/healthy"]
      initialDelaySeconds: 5
      periodSeconds: 5
EOF
t0=$(date +%s)
for i in $(seq 1 26); do echo "t+$(( $(date +%s) - t0 ))s  $(kubectl get pods live-a live-b --no-headers -o custom-columns=N:.metadata.name,S:.status.phase,R:.status.containerStatuses[0].restartCount | awk '{printf "%s restarts=%s  ", $1, $3}')"; sleep 5; done
```

Then read the evidence:

```bash
for p in live-a live-b; do
  echo "=== $p ==="
  kubectl get pod $p -o jsonpath='restarts={.status.containerStatuses[0].restartCount}{"\n"}last: reason={.status.containerStatuses[0].lastState.terminated.reason} exit={.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}last started={.status.containerStatuses[0].lastState.terminated.startedAt}{"\n"}last finished={.status.containerStatuses[0].lastState.terminated.finishedAt}{"\n"}'
done
kubectl get events --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,POD:.involvedObject.name,REASON:.reason,MSG:.message | grep -E "live-"
```

### Observed on the real cluster

```text
t+45s  live-a restarts=0  live-b restarts=0
t+50s  live-a restarts=0  live-b restarts=1
t+76s  live-a restarts=0  live-b restarts=1
t+81s  live-a restarts=1  live-b restarts=1
t+96s  live-a restarts=1  live-b restarts=2

=== live-a ===
restarts=1
last: reason=Error exit=137
last started=2026-10-10T22:49:26Z
last finished=2026-10-10T22:50:38Z
=== live-b ===
restarts=3
last: reason=Completed exit=0
last started=2026-10-10T22:50:55Z
last finished=2026-10-10T22:51:38Z

22:51:23Z   live-a   Killing     Container app failed liveness probe, will be restarted
22:51:23Z   live-a   Unhealthy   Liveness probe failed: cat: can't open '/tmp/healthy': No such file or directory
22:51:38Z   live-b   Killing     Container app failed liveness probe, will be restarted
22:51:38Z   live-b   Unhealthy   Liveness probe failed: cat: can't open '/tmp/healthy': No such file or directory
```

| Item | Predicted | Observed |
|---|---|---|
| Both pods `restarts=0` until about 45 s | Yes | Yes |
| **`live-b`** (handles the signal) restarts at about t+50 s | Yes | **`restarts=1` at `t+50s`** |
| **`live-a`** restarts about 30 s later, at about t+80 s | Yes | **`restarts=1` at `t+81s`** |
| `lastState`, `live-b` | `Completed`, exit 0 | `Completed`, exit 0 |
| `lastState`, `live-a` | `Error`, exit 137 | `Error`, exit 137 |
| Last container run time | About 46 s for `live-b`, about 75 s for `live-a` | **43 s** and **72 s** |

The file is removed at 30 seconds, and three probe failures at 5-second intervals end at about 45 seconds. For `live-b`, the `Killing` event and the container's finish time are the **same second** (`22:51:38`): it exited as soon as it was told to. For `live-a`, the last run lasted 72 seconds, which is about 42 seconds to detect the failure plus **30 seconds of grace period**.

Exit code **137** alone does not tell you the cause: an out-of-memory kill also exits with 137. The `reason` does (`Error` here, `OOMKilled` there).

Each restart starts a new container filesystem, so `/tmp/healthy` is recreated, and both pods went around the cycle again. The events also show `Pulling image "busybox"` on **every restart**: an image with no tag, or the `latest` tag, is checked against the registry on every start, and I recall the default pull policy being `Always` for those. That was not checked here.

---

# 5. The cost of ignoring the termination signal

When Kubernetes stops a container, it sends the termination signal and waits for the **grace period** (30 seconds by default) before killing it forcibly. A shell running as a container's main process ignores the signal unless it installs a handler, so the wait is always the full 30 seconds. The same container, with one `trap`, is a direct test. Deleting the two pods from the previous lab:

| Command | Result |
|---|---|
| `time kubectl delete pod live-b` (handles the signal) | **0.365 s** |
| `time kubectl delete pod live-a` (shell as main process) | **30.601 s** |

The 30 seconds is the default grace period, waiting on a container that ignores the signal. It added about 30 seconds to the liveness kill in Section 4 and to this delete. In the workload controllers guide it showed up in a Job deadline and a DaemonSet rolling update (and probably in a DaemonSet pod removed by a label change, which was not timed). It applies to every restart, rolling update, drain, scale-down and delete.

**Handle the signal in your application, or lower `terminationGracePeriodSeconds`.** A setting that applies only to liveness kills exists, but it was not tested here.

---

# 6. Startup probes: protecting a slow start

A liveness probe on its own can kill an application that is merely slow to start. A **startup probe** is a separate budget for starting: it holds the other probes off, and when it runs out, the container is restarted.

Three pods run the same kind of application. They handle the signal, so kills are immediate. `slow-a` needs 40 seconds to start and has only a liveness probe. `slow-b` is the same, plus a startup probe with a 60-second budget (12 failures of 5 seconds). `slow-c` needs 90 seconds, with the same 60-second budget.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: slow-a
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "trap 'exit 0' TERM; sleep 40 & wait $!; touch /tmp/ok; sleep 3600 & wait"]
    livenessProbe:
      exec:
        command: ["cat", "/tmp/ok"]
      initialDelaySeconds: 5
      periodSeconds: 5
---
apiVersion: v1
kind: Pod
metadata:
  name: slow-b
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "trap 'exit 0' TERM; sleep 40 & wait $!; touch /tmp/ok; sleep 3600 & wait"]
    startupProbe:
      exec:
        command: ["cat", "/tmp/ok"]
      periodSeconds: 5
      failureThreshold: 12
    livenessProbe:
      exec:
        command: ["cat", "/tmp/ok"]
      periodSeconds: 5
---
apiVersion: v1
kind: Pod
metadata:
  name: slow-c
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "trap 'exit 0' TERM; sleep 90 & wait $!; touch /tmp/ok; sleep 3600 & wait"]
    startupProbe:
      exec:
        command: ["cat", "/tmp/ok"]
      periodSeconds: 5
      failureThreshold: 12
    livenessProbe:
      exec:
        command: ["cat", "/tmp/ok"]
      periodSeconds: 5
EOF
t0=$(date +%s)
for i in $(seq 1 28); do echo "t+$(( $(date +%s) - t0 ))s  $(kubectl get pods slow-a slow-b slow-c -o jsonpath='{range .items[*]}{.metadata.name}{" r="}{.status.containerStatuses[0].restartCount}{" s="}{.status.containerStatuses[0].started}{"   "}{end}')"; sleep 4; done
```

`r` is the restart count, and `s` is the `started` flag, which stays `false` until a startup probe succeeds.

### Observed on the real cluster

```text
t+24s   slow-a r=1     t+45s   slow-a r=2     t+65s   slow-a r=3     t+81s   slow-a r=4
t+49s   slow-b s=true  (r=0 throughout)
t+65s   slow-c r=1 s=false
```

| Pod | Predicted | Observed |
|---|---|---|
| **`slow-a`** (a 40 s start, liveness only) | Killed over and over, 3 to 5 restarts | **4 restarts in 110 s**, at 24, 45, 65 and 81 s. It never lived long enough to finish starting |
| **`slow-b`** (a 60 s startup budget) | `r=0` throughout, `s=true` at about 40 to 45 s | **`r=0` throughout**, and `s=true` by `t+49s` |
| **`slow-c`** (a 90 s start, a 60 s budget) | First kill at about 60 to 65 s | **`r=1` at `t+65s`**, and `s=false` the whole time |

The numbers add up. `slow-a`'s liveness probe starts at 5 seconds and needs three 5-second failures, so it kills at about 20 seconds (observed 24), and then does the same after every restart, so it never reaches 40 seconds. `slow-c`'s budget is 12 × 5 s = **60 s**, and it was killed at 65 s.

Left running, the pods showed more:

| Pod | `describe` | Events |
|---|---|---|
| `slow-a` | `Restart Count: 9`, `Last State: Terminated`, `Reason: Completed`, `Exit Code: 0` | `Liveness probe failed: cat: can't open '/tmp/ok': No such file or directory` |
| `slow-b` | **`Restart Count: 0`**, started at 15:55:39 and still running more than 10 minutes later | `Startup probe failed: cat: can't open '/tmp/ok'...`, from its first 40 seconds only |
| `slow-c` | `Restart Count: 7`, `CrashLoopBackOff`, `Completed`, exit 0 | `Startup probe failed: cat: can't open '/tmp/ok'...` |

Both killed pods show `Completed` with exit 0 (not 137), because their shells handle the signal.

A later 110-second window, taken from the already running pods, showed `slow-a` held at 7 restarts and `slow-c` at 6 the whole time, so the kubelet was waiting between restarts. That fits its restart back-off, which as I recall doubles up to a cap of 5 minutes. The early gaps (about 21, 20 and 16 seconds) do not show a clean doubling, so treat the back-off pattern as an inference.

---

# 7. What counts as a failure

Five pods, each with a differently broken probe. nginx serves `/` and returns 404 for `/nope`.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: http-ok
spec:
  containers:
  - name: web
    image: nginx
    readinessProbe:
      httpGet:
        path: /
        port: 80
      periodSeconds: 3
---
apiVersion: v1
kind: Pod
metadata:
  name: http-404
spec:
  containers:
  - name: web
    image: nginx
    readinessProbe:
      httpGet:
        path: /nope
        port: 80
      periodSeconds: 3
---
apiVersion: v1
kind: Pod
metadata:
  name: live-404
spec:
  containers:
  - name: web
    image: nginx
    livenessProbe:
      httpGet:
        path: /nope
        port: 80
      initialDelaySeconds: 2
      periodSeconds: 3
---
apiVersion: v1
kind: Pod
metadata:
  name: tcp-bad
spec:
  containers:
  - name: web
    image: nginx
    readinessProbe:
      tcpSocket:
        port: 9999
      periodSeconds: 3
---
apiVersion: v1
kind: Pod
metadata:
  name: probe-timeout
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    readinessProbe:
      exec:
        command: ["sh", "-c", "sleep 3"]
      timeoutSeconds: 1
      periodSeconds: 5
EOF
sleep 45
kubectl get pods
kubectl get events --field-selector reason=Unhealthy -o custom-columns=POD:.involvedObject.name,MSG:.message | sort -u
```

### Observed on the real cluster

```text
NAME            READY   STATUS             RESTARTS      AGE
http-404        0/1     Running            0             46s
http-ok         1/1     Running            0             46s
live-404        0/1     CrashLoopBackOff   2 (12s ago)   46s
probe-timeout   0/1     Running            0             46s
tcp-bad         0/1     Running            0             46s
```

| Pod | Predicted | Observed |
|---|---|---|
| `http-ok` | `1/1` | **`1/1`** |
| `http-404` | `0/1`, 0 restarts, a 404 event | **`0/1 Running`, 0 restarts**: a 404 is a failure |
| `live-404` | Restarted about every 11 s, with 3 or 4 restarts by 45 s | **`CrashLoopBackOff`, 2 restarts.** Fewer than predicted: my arithmetic ignored the restart back-off |
| `tcp-bad` | `0/1`, `connection refused` | **`0/1`**, as predicted |
| `probe-timeout` | `0/1`, with unknown wording | **`0/1`**: a probe that takes 3 s against a 1 s timeout fails |

An HTTP probe counts **only 2xx and 3xx as success**, so a 404 fails it, and the same page that makes a readiness probe fail makes a liveness probe kill the container. `live-404` shows `0/1` in the listing only because it was in `CrashLoopBackOff` at that moment. Whether it was `1/1` between restarts was not captured, but with no readiness probe it should count as ready whenever its container runs.

**Healthy pods log failed probes too.** `http-ok`, which ended `1/1`, has a `Readiness probe failed: ... connect: connection refused` event, and so does `http-404`: the first probe ran before nginx was listening. It recovered, so it is harmless, but it is why you may see `Unhealthy` events on healthy pods. A startup probe, or an `initialDelaySeconds`, avoids it.

---

# 8. Every event message seen

| Probe | Message |
|---|---|
| exec, readiness | `Readiness probe failed: cat: can't open '/tmp/ready': No such file or directory` |
| exec, liveness | `Liveness probe failed: cat: can't open '/tmp/healthy': No such file or directory`, then `Killing: Container app failed liveness probe, will be restarted` |
| exec, startup | `Startup probe failed: cat: can't open '/tmp/ok': No such file or directory` |
| HTTP, a bad status | `Readiness probe failed: HTTP probe failed with statuscode: 404` (and the same with `Liveness`) |
| HTTP, not listening yet | `Readiness probe failed: Get "http://10.244.1.98:80/nope": dial tcp 10.244.1.98:80: connect: connection refused` |
| TCP | `Readiness probe failed: dial tcp 10.244.1.99:9999: connect: connection refused` |
| Timeout | `Readiness probe failed: command timed out: "sh -c sleep 3" timed out after 1s` |
| In flight at teardown | `Readiness probe errored and resulted in unknown state: rpc error: code = Canceled desc = context canceled` |

The last message appeared once, for a `ready-demo` pod. I think a probe was in flight when its container was torn down, but that was not verified. The kubelet also limits how many `Unhealthy` events it emits, so the list is not a complete record of the failures.

---

# 9. Choosing settings

| What you want to know | Rule | Seen in the labs |
|---|---|---|
| How long a failing pod keeps getting traffic | about `failureThreshold` × `periodSeconds` | 3 × 3 s gave 7 to 8 s (Section 3) |
| How long until a stuck container is restarted | the same formula, then the grace period | 3 × 5 s, then 30 s without a signal handler (Section 4) |
| The budget for a slow start | `failureThreshold` × `periodSeconds` of the startup probe | 12 × 5 s = 60 s, and a container needing 90 s was killed at 65 s (Section 6) |
| How fast a healthy pod returns | at most one `periodSeconds` | about 2 s (Section 3) |

Guidelines, partly from the labs and partly general practice (the general parts were not tested):

- **Always set a readiness probe** on anything behind a Service. Without one, a pod is ready the moment its container starts, and rolling updates have nothing to wait for.
- **Use a startup probe for slow applications**, so the liveness probe can stay quick and strict.
- **Keep liveness checks cheap and local.** A liveness probe that depends on another service can restart a healthy container whenever that service is down.
- **Make the application handle the termination signal**, or lower the grace period. It decides how long every restart, delete and rollout takes.

---

# 10. Traps

| Trap | What happens |
|---|---|
| A liveness probe with **no readiness probe** | The pod receives traffic until the liveness probe kills it (`live-404`) |
| A liveness probe that is stricter than the application can bear | Restarts in a loop, with growing waits (`slow-a`) |
| A probe on a path that returns 404 or 5xx | Readiness never passes, and liveness restarts the container (`http-404`, `live-404`) |
| `timeoutSeconds` shorter than the check takes | The probe fails even though the check is healthy (`probe-timeout`) |
| A probe port that nothing listens on | `connection refused`, forever (`tcp-bad`) |
| An application that ignores the termination signal | Every restart and delete takes 30 seconds longer |
| Reading `Unhealthy` events as proof of a problem | A healthy pod logs one when its first probe runs before the application listens |

---

# 11. Practical tips for running these labs

- **Paste commands, not results.** Once, a line copied from a results table (`time kubectl delete pod live-b   ->   real 0m0.365s`) was run as a command. The shell read `->` as a redirect, created a stray file called `real`, and tried to delete pods named `-` and `0m0.365s`. Nothing was harmed, but keep results out of code blocks you paste.
- **Paste long blocks in pieces.** The terminal wrapped long lines and fused commands into manifests more than once. The pods were still created correctly, but a re-run of a garbled manifest said `unchanged`, so its timeline measured pods that were already running.
- **A restart count that stops changing is back-off, not health.** Check the container's `lastState` and the events before drawing a conclusion.
- **Clean up:** `kubectl delete namespace probes` and `kubectl config set-context --current --namespace=default`.

---

# 12. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| A pod is `Running` but `0/1` | Its readiness probe is failing | `kubectl describe pod NAME`, and read the `Unhealthy` events |
| A container restarts again and again, and `RESTARTS` climbs | A liveness probe is failing, or the app is crashing | Read `Last State` and the events: `Liveness probe failed` versus an exit code |
| `Startup probe failed`, then a restart | The startup budget (`failureThreshold` × `periodSeconds`) is shorter than the start | Raise `failureThreshold` |
| `connection refused` events on a healthy pod | The first probe ran before the app listened | Harmless, or add `initialDelaySeconds` or a startup probe |
| `HTTP probe failed with statuscode: 404` | Wrong path, or the path needs authentication | Probe a path that returns 200, such as a health endpoint |
| `command timed out ... after 1s` | The check takes longer than `timeoutSeconds` | Raise `timeoutSeconds`, or make the check cheaper |
| Pods take 30 s longer than expected to stop | The container ignores the termination signal | Handle the signal, or lower `terminationGracePeriodSeconds` |
| A rolling update completes instantly | There is no readiness probe | Add one (Section 1) |
| Exit code 137 | A forced kill, or `OOMKilled` | Check `reason`: `Error` means a forced kill, `OOMKilled` means memory |

---

# 13. Command cheat sheet

| Task | Command |
|---|---|
| Probe failures | `kubectl get events --field-selector reason=Unhealthy` |
| Why a pod is not ready | `kubectl describe pod NAME` |
| Restart count | `kubectl get pod NAME -o jsonpath='{.status.containerStatuses[0].restartCount}'` |
| Is it ready | `kubectl get pod NAME -o jsonpath='{.status.containerStatuses[0].ready}'` |
| Has it started (startup probe) | `kubectl get pod NAME -o jsonpath='{.status.containerStatuses[0].started}'` |
| Why the last container ended | `kubectl get pod NAME -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'` |
| Ready and not-ready endpoints | `kubectl get endpoints SVC -o jsonpath='{.subsets[*].addresses[*].ip}'` and `...notReadyAddresses[*].ip` |
| Run a command in a pod | `kubectl exec POD -- touch /tmp/ready` |

---

# 14. Glossary

| Term | Meaning |
|---|---|
| **Probe** | A periodic check the kubelet runs against a container |
| **Readiness** | Whether a pod should receive traffic |
| **Liveness** | Whether a container is stuck and should be restarted |
| **Startup probe** | A budget for a slow start, which holds the other probes off |
| **Endpoints** | The list of pod addresses behind a Service, with ready and not-ready sets |
| **Threshold** | The consecutive successes or failures needed to change state |
| **Grace period** | The wait between the termination signal and a forced kill, 30 s by default |
| **CrashLoopBackOff** | The kubelet waiting, with growing delays, before restarting a failing container |

---

# 15. What was run, and what was not

## Run on the real cluster (the output above is from these)

- Readiness with a hand-controlled file: the endpoints and `notReadyAddresses`, and no restarts
- The asymmetry of readiness: 7 to 8 seconds to leave, about 2 seconds to return
- Liveness restarts, with a signal-handling pod against one without, using `lastState`, exit codes and the kubelet's event times
- The grace period measured on a delete: 0.365 s against 30.601 s
- Startup probes: a slow start killed by liveness alone, protected by a startup probe, and killed when it overran the budget
- An HTTP probe returning 404 as readiness and as liveness, a TCP probe on a closed port, and a probe that times out

## Not run

- **gRPC probes**, and `successThreshold` above 1
- **Probe-level `terminationGracePeriodSeconds`**, which shortens a liveness kill
- **Named ports and HTTP headers in probes**
- **The restart back-off in detail**: the doubling up to 5 minutes is from the documentation, and the labs only showed that restarts slow down
- **The image pull policy** behind the repeated `Pulling image "busybox"` events
- **Probes under a real rolling update with a PodDisruptionBudget**

The explanations marked as inferences in the text are the best fit to the evidence, and not verified. Check the official Kubernetes documentation for the version you run.

## Clean up everything from this guide

```bash
kubectl delete namespace probes
kubectl config set-context --current --namespace=default
```

The first command deletes every object created in the labs, and the second puts your kubeconfig back on the `default` namespace.
