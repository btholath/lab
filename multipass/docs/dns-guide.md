# Kubernetes DNS: CoreDNS, the Search Path, and What Happens When It Breaks

## Reading the setup, counting queries, taking DNS down, a typo in the Corefile, and customising names, tested on a real cluster

Every pod finds Services by name, and the machinery behind that is CoreDNS plus a few lines in each pod's `/etc/resolv.conf`. This guide reads that setup on a real kubeadm cluster (1 control plane, 2 workers, Kubernetes v1.36.5, CoreDNS v1.14.2), counts the queries one lookup really makes, breaks DNS two ways, and customises it. The console output after each lab is copied from the run. Where a prediction was wrong, the guide says so, and explanations marked as inferences are best guesses, not results.

**Contents**

1. How cluster DNS works
2. Reading CoreDNS
3. A pod's view
4. Names that resolve, and names that don't
5. How many queries does one lookup make?
6. DNS down is not the network down
7. A typo in the Corefile
8. Customising DNS
9. DNS and the pod network
10. What I got wrong
11. Practical tips for running these labs
12. Troubleshooting
13. Command cheat sheet
14. Glossary
15. What was run, and what was not

---

# 1. How cluster DNS works

| Piece | What it is |
|---|---|
| **CoreDNS** | A Deployment in `kube-system` that answers DNS queries for the cluster. Here: 2 replicas |
| **The `kube-dns` Service** | A ClusterIP, `10.96.0.10`, in front of the CoreDNS pods. It is called `kube-dns` for historical reasons |
| **The kubelet** | Writes `nameserver 10.96.0.10` into every pod's `/etc/resolv.conf` (the kubelet's `clusterDNS` setting) |
| **The search path** | A list of suffixes in `resolv.conf` that the resolver adds to short names |
| **`ndots`** | A number in `resolv.conf`: a name with **fewer** dots than this is tried with the search suffixes **first** |

A Service `web` in namespace `shop` has the name `web.shop.svc.cluster.local`. The search path lets a pod in `shop` say just `web`, and a pod anywhere say `web.shop`.

---

# 2. Reading CoreDNS

```bash
kubectl -n kube-system get deployment coredns
kubectl -n kube-system get deployment coredns -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system get svc kube-dns
kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'; echo
```

I use EndpointSlices because plain `Endpoints` print a deprecation warning on recent releases.

### Observed on the real cluster

```text
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
coredns   2/2     2            2           8d
registry.k8s.io/coredns/coredns:v1.14.2

coredns-589f44dc88-2tpjr   1/1   Running   0   5d21h   10.244.1.27   worker1
coredns-589f44dc88-5pt72   1/1   Running   0   5d21h   10.244.0.8    master

kube-dns   ClusterIP   10.96.0.10   <none>   53/UDP,53/TCP,9153/TCP   8d

kube-dns-ggp9m   IPv4   53,53,9153   10.244.0.8,10.244.1.27   8d
```

```text
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
```

| Plugin | What it does here |
|---|---|
| `kubernetes cluster.local ...` | Answers names for Services and pods, and reverse lookups for their addresses |
| `forward . /etc/resolv.conf` | Sends everything else (external names) to the node's upstream resolver |
| `cache 30 { disable ... cluster.local }` | Caches external answers for 30 seconds, but **nothing under `cluster.local`**, neither answers nor "no such name" replies. That exception was not in the standard Corefile I expected. My guess about the reason is that stale cluster answers cause confusing failures after a Service changes. I haven't confirmed it |
| `health { lameduck 5s }` | On shutdown, keeps serving for 5 seconds before exiting (see Section 6) |
| `reload` | Re-reads the Corefile when it changes, with no restart (Section 7) |
| `loop`, `loadbalance`, `errors`, `ready`, `prometheus` | Loop detection, rotating answers, error logging, a readiness endpoint, metrics |

Everything else matched my expectation: the prediction that failed was `cache 30` without the block.

The two CoreDNS pods sit on **different nodes**, one on the master (the control-plane taint doesn't stop them) and one on a worker. A pod on any node reaches whichever replica kube-proxy picks for that flow.

---

# 3. A pod's view

A throwaway pod in a new namespace:

```bash
kubectl create namespace dns
kubectl config set-context --current --namespace=dns
cat > probe.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: probe
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
EOF
kubectl apply -f probe.yaml
kubectl wait --for=condition=Ready pod/probe --timeout=60s
kubectl exec probe -- cat /etc/resolv.conf
```

### Observed on the real cluster

```text
search dns.svc.cluster.local svc.cluster.local cluster.local mshome.net
nameserver 10.96.0.10
options ndots:5
```

| Line | Meaning |
|---|---|
| `search dns.svc.cluster.local ...` | The first entry is the pod's **own namespace** (`dns`), then the cluster suffixes, then **`mshome.net`**, a search domain inherited from the host's Hyper-V network |
| `nameserver 10.96.0.10` | The `kube-dns` Service |
| `options ndots:5` | Any name with **fewer than 5 dots** tries all four search suffixes before the name as typed |

---

# 4. Names that resolve, and names that don't

```bash
for n in kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local kube-dns.kube-system; do echo "$n -> $(kubectl exec probe -- ping -c1 -W1 $n 2>&1 | head -1)"; done
kubectl exec probe -- nslookup kubernetes.default.svc.cluster.local
kubectl exec probe -- nslookup kube-dns.kube-system.svc.cluster.local
kubectl exec probe -- nslookup 10.96.0.10
kubectl exec probe -- nslookup nosuchname.default.svc.cluster.local
```

I use `ping` as a resolver test: the `PING name (address)` line shows the name resolved, even without a reply (a Service address doesn't answer ICMP). `ping` uses the C library's resolver, so it honours the search path.

### Observed on the real cluster

```text
kubernetes -> ping: bad address 'kubernetes'
kubernetes.default -> PING kubernetes.default (10.96.0.1): 56 data bytes
kubernetes.default.svc -> PING kubernetes.default.svc (10.96.0.1): 56 data bytes
kubernetes.default.svc.cluster.local -> PING kubernetes.default.svc.cluster.local (10.96.0.1): 56 data bytes
kube-dns.kube-system -> PING kube-dns.kube-system (10.96.0.10): 56 data bytes

Name:   kubernetes.default.svc.cluster.local
Address: 10.96.0.1

Name:   kube-dns.kube-system.svc.cluster.local
Address: 10.96.0.10

10.0.96.10.in-addr.arpa name = kube-dns.kube-system.svc.cluster.local

** server can't find nosuchname.default.svc.cluster.local: NXDOMAIN
** server can't find nosuchname.default.svc.cluster.local: NXDOMAIN
command terminated with exit code 1
```

| Result | Why |
|---|---|
| **`kubernetes` fails** from namespace `dns` | The short name works only from the namespace holding that Service (`default`). From `dns`, the expansions `kubernetes.dns.svc.cluster.local`, `kubernetes.svc.cluster.local` and the rest don't exist |
| `kubernetes.default`, `.svc` and the full name all resolve to `10.96.0.1` | Three spellings of the same record, because the search path adds the missing suffixes |
| The reverse lookup works | The `kubernetes` plugin also answers reverse queries for Service addresses |
| `NXDOMAIN`, printed twice | BusyBox's `nslookup` asks for both A and AAAA and prints a failure for each. That is my inference from the output |

`kubernetes.<namespace>` works from anywhere, and a short name only from the same namespace.

---

# 5. How many queries does one lookup make?

CoreDNS's `log` plugin prints every query it answers. It is off by default. This part turns it on through the ConfigMap, with no restart, then counts the queries for `example.com`.

```bash
cd ~
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > ~/Corefile.orig
wc -l ~/Corefile.orig
cat > ~/coredns-log-patch.yaml <<'EOF'
data:
  Corefile: |
    .:53 {
        errors
        log
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30 {
           disable success cluster.local
           disable denial cluster.local
        }
        loop
        reload
        loadbalance
    }
EOF
kubectl -n kube-system patch configmap coredns --type merge --patch-file ~/coredns-log-patch.yaml
```

The patch differs from the original by exactly one line, `log`. I verified that with a parser before use. The original is saved first so it can be restored exactly.

### The reload takes about a minute

```text
t+0s    pods that reloaded: 0/2
t+41s   pods that reloaded: 0/2
t+51s   pods that reloaded: 1/2
t+61s   pods that reloaded: 2/2        (CoreDNS pods: 0 restarts)
```

Two delays stack: the **ConfigMap volume update** (about 40 seconds in the ConfigMaps guide) and the `reload` plugin's own poll. The loop started a little after the patch, so the true delay is at least that long. The pods never restarted.

### The queries

```bash
kubectl exec probe -- ping -c1 -W2 example.com
kubectl exec probe -- ping -c1 -W2 example.com.
kubectl -n kube-system logs -l k8s-app=kube-dns --since=30s | grep -E "example\.com"
```

The second `ping` has a **trailing dot**, which marks the name as complete and skips the search path.

### Observed on the real cluster

```text
[INFO] 10.244.2.15:42039 - 3672  "AAAA IN example.com.cluster.local. udp 43 false 512" NXDOMAIN qr,aa,rd 136 0.000358s
[INFO] 10.244.2.15:42039 - 36438 "A IN example.com.cluster.local. udp 43 false 512"    NXDOMAIN qr,aa,rd 136 0.000450s
[INFO] 10.244.2.15:58679 - 8805  "AAAA IN example.com.mshome.net. udp 40 false 512"    NXDOMAIN qr,rd 40 0.034362s
[INFO] 10.244.2.15:58679 - 64866 "A IN example.com.mshome.net. udp 40 false 512"       NXDOMAIN qr,rd 40 0.040058s
[INFO] 10.244.2.15:50660 - 55900 "AAAA IN example.com. udp 29 false 512"               NOERROR qr,rd 107 0.002199s
[INFO] 10.244.2.15:50660 - 94    "A IN example.com. udp 29 false 512"                  NOERROR qr,rd 83 0.002314s
[INFO] 10.244.2.15:53527 - 6759  "A IN example.com.dns.svc.cluster.local. udp 51 false 512"    NXDOMAIN qr,aa,rd 144 0.000240s
[INFO] 10.244.2.15:53527 - 3688  "AAAA IN example.com.dns.svc.cluster.local. udp 51 false 512" NXDOMAIN qr,aa,rd 144 0.000368s
[INFO] 10.244.2.15:35080 - 5490  "AAAA IN example.com.svc.cluster.local. udp 47 false 512"     NXDOMAIN qr,aa,rd 140 0.000091s
[INFO] 10.244.2.15:35080 - 24693 "A IN example.com.svc.cluster.local. udp 47 false 512"        NXDOMAIN qr,aa,rd 140 0.000043s
[INFO] 10.244.2.15:50616 - 9791  "AAAA IN example.com. udp 29 false 512"               NOERROR qr,rd 107 0.021250s
[INFO] 10.244.2.15:50616 - 47928 "A IN example.com. udp 29 false 512"                  NOERROR qr,rd 83 0.021135s
```

The log mixes the two CoreDNS pods' output, so the lines aren't in the order the resolver asked them, but each pod's own lines follow the search order.

| Name asked | Types | Answer | Time |
|---|---|---|---|
| `example.com.dns.svc.cluster.local.` | A, AAAA | NXDOMAIN, **`aa`** | 0.24 and 0.37 ms |
| `example.com.svc.cluster.local.` | A, AAAA | NXDOMAIN, `aa` | 0.04 and 0.09 ms |
| `example.com.cluster.local.` | A, AAAA | NXDOMAIN, `aa` | 0.36 and 0.45 ms |
| `example.com.mshome.net.` | A, AAAA | NXDOMAIN, no `aa` | **34 and 40 ms** |
| `example.com.` (once per `ping`) | A, AAAA | NOERROR | 2.2 ms and 21 ms |

| Fact | Evidence |
|---|---|
| A bare `example.com` makes **10 queries** | 5 names × 2 types, from the first `ping` |
| `example.com.` (trailing dot) makes **2** | A and AAAA, with no search suffixes: the second `ping` |
| The total in the log: **12** | 10 + 2 |
| **`aa`** marks an authoritative answer from the `kubernetes` plugin | The three cluster suffixes |
| The missing `aa` marks a **forwarded** reply | `example.com.mshome.net.` went **upstream**: Hyper-V's resolver answered NXDOMAIN, after **34 to 40 ms**, against under half a millisecond for the cluster misses |
| A and AAAA are asked together | Same source port, a few microseconds apart |

So a bare external name costs four wasted lookups (eight packets), and one of them is a real network round trip. The six name-queries spread across both CoreDNS pods, three in each, since each query came from a different source port and kube-proxy picks a backend per flow.

## Restore the original

```bash
cat > ~/coredns-orig-patch.yaml <<'EOF'
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30 {
           disable success cluster.local
           disable denial cluster.local
        }
        loop
        reload
        loadbalance
    }
EOF
kubectl -n kube-system patch configmap coredns --type merge --patch-file ~/coredns-orig-patch.yaml
diff <(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}') ~/Corefile.orig && echo "identical to the original"
```

```text
configmap/coredns patched
identical to the original
```

---

# 6. DNS down is not the network down

Scale CoreDNS to zero, and test by name and by address:

```bash
NGINX=$(kubectl get svc nginx -n default -o jsonpath='{.spec.clusterIP}')
kubectl exec probe -- sh -c "wget -q -O /dev/null -T 3 http://$NGINX && echo 'before, by IP:   ok'"
kubectl exec probe -- sh -c "wget -q -O /dev/null -T 3 http://nginx.default && echo 'before, by name: ok'"
kubectl -n kube-system scale deployment coredns --replicas=0
sleep 5
kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers | wc -l
time kubectl exec probe -- nslookup kubernetes.default.svc.cluster.local 2>&1 | tail -3
time kubectl exec probe -- ping -c1 -W1 kubernetes.default 2>&1 | head -1
kubectl exec probe -- sh -c "wget -q -O /dev/null -T 3 http://$NGINX && echo 'during, by IP:   ok'"
kubectl exec probe -- sh -c "wget -q -O /dev/null -T 3 http://nginx.default && echo 'during, by name: ok' || echo 'during, by name: FAILED'"
```

### Observed on the real cluster

```text
nginx ClusterIP: 10.107.185.30
before, by IP:   ok
before, by name: ok
deployment.apps/coredns scaled
2                                                  <- pods still listed 5 s later
;; connection timed out; no servers could be reached     real 0m5.143s
ping: bad address 'kubernetes.default'                    real 0m0.118s
during, by IP:   ok
wget: bad address 'nginx.default'
during, by name: FAILED
```

| Item | Predicted | Observed |
|---|---|---|
| Pods 5 s after `scale 0` | **0** | **2**: wrong. They were still `Terminating`. As I recall, `lameduck 5s` keeps CoreDNS serving for 5 seconds after the shutdown signal. That is my explanation, and I haven't checked it |
| `nslookup` while down | Fails | **Failed after 5.143 s** |
| `ping` while down | Fails | **Failed after 0.118 s** |
| By IP while down | `ok` | **`ok`** |
| By name while down | `FAILED` | **`FAILED`** |

The two tools **disagree about timing for the same outage**. My reading, an inference: with no endpoints behind the Service, kube-proxy **rejects** the packets and the sender gets an immediate error. The C library's resolver (behind `ping` and `wget`) gives up at once, while BusyBox's `nslookup` waits out its own 5-second timeout whatever it hears. Most applications use the C library, so they fail **fast**, while an `nslookup` makes it look like a hang. I haven't confirmed the rejection.

**The `nginx` Service answered by IP throughout.** Only the names broke.

## Recovery

```bash
t0=$(date +%s)
kubectl -n kube-system scale deployment coredns --replicas=2
for i in $(seq 1 20); do
  r=$(kubectl -n kube-system get deployment coredns -o jsonpath='{.status.readyReplicas}')
  d=$(kubectl exec probe -- nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -c "10.96.0.1$")
  echo "t+$(( $(date +%s) - t0 ))s  ready=${r:-0}  lookup_ok=$d"
  [ "${r:-0}" -ge 2 ] && [ "$d" -ge 1 ] && break
  sleep 3
done
```

```text
t+0s   ready=0  lookup_ok=0
t+4s   ready=0  lookup_ok=0
t+7s   ready=0  lookup_ok=0
t+10s  ready=0  lookup_ok=0
t+13s  ready=2  lookup_ok=1
coredns-589f44dc88-7pj55 1/1 master
coredns-589f44dc88-grc8x 1/1 worker2
```

**13 seconds** to two ready replicas and a working lookup. The image was already on every node: worker2 held both `v1.13.1` and `v1.14.2` (a pull said `already exists` for every layer), so there was no download to wait for. The new replicas landed on the master and **worker2**, different nodes than before.

---

# 7. A typo in the Corefile

The patch changes one word: `forward` becomes `forwrd`. Everything else is the original.

### Observed on the real cluster

```text
configmap/coredns patched                                  22:31:32 UTC
t+1s ... t+71s   log lines mentioning the typo: 0
t+81s            log lines mentioning the typo: 4

[INFO] plugin/reload: Running configuration SHA512 = 1b226df7...
[INFO] Reloading
[ERROR] Restart failed: /etc/coredns/Corefile:13 - Error during parsing: Unknown directive 'forwrd'
[ERROR] plugin/reload: Corefile changed but reload failed: starting with listener file descriptors: /etc/coredns/Corefile:13 - Error during parsing: Unknown directive 'forwrd'

coredns-589f44dc88-7pj55 1/1 Running 0
coredns-589f44dc88-grc8x 1/1 Running 0
Address: 10.96.0.1                                         <- lookups still work
```

| Item | Predicted | Observed |
|---|---|---|
| The error | Something like `Unknown directive 'forwrd'` | **Exactly that**, in two `[ERROR]` lines per pod (4 lines for 2 pods) |
| The line number | I guessed 15 | **13** |
| The pods | Both `1/1`, 0 restarts | **Both `1/1 Running 0`**: a failed reload keeps the **old configuration running** (the log names the config still in force) |
| Lookups | Still work | **Still work** |

For **at least 81 seconds** after the bad edit, **nothing was visibly broken**. The only sign was two error lines per pod in the logs. The loop started a little after the patch, so the true delay is longer.

## The fault surfaces at the next restart

```bash
V=$(kubectl -n kube-system get pods -l k8s-app=kube-dns -o name | head -1)
kubectl -n kube-system delete $V
sleep 25
kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers | awk '{print $1, $2, $3, $4}'
NEW=$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers | awk '$3!="Running" {print $1; exit}')
kubectl -n kube-system logs $NEW | tail -3 | cut -c1-200
kubectl exec probe -- nslookup kubernetes.default.svc.cluster.local | tail -2
```

```text
coredns-589f44dc88-grc8x 1/1 Running 0
coredns-589f44dc88-zrc5w 0/1 CrashLoopBackOff 2
/etc/coredns/Corefile:13 - Error during parsing: Unknown directive 'forwrd'
maxprocs: Leaving GOMAXPROCS=2: CPU quota undefined
Address: 10.96.0.1
```

| Item | Observed |
|---|---|
| The replacement pod | **`0/1 CrashLoopBackOff`, restarts 2** after 25 seconds. A new pod reads the **current** file as it starts |
| The survivor | **`1/1 Running`**, still on the old config |
| Lookups | **Still work**, served by the survivor |

That is a **latent fault**: if both pods had restarted together (a node reboot, or a rollout), **DNS would have gone down**. The restart count of 2 after 25 seconds is the back-off, which grows with each failure.

## Fix it

```bash
kubectl -n kube-system patch configmap coredns --type merge --patch-file ~/coredns-orig-patch.yaml
diff <(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}') ~/Corefile.orig && echo "identical to the original"
kubectl -n kube-system delete pod $NEW
sleep 20
kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers | awk '{print $1, $2, $3, $4}'
```

```text
identical to the original
coredns-589f44dc88-grc8x 1/1 Running 0
coredns-589f44dc88-nt7pd 1/1 Running 0
```

Deleting the failing pod after the fix skips the back-off, which grows to as much as 5 minutes. A new pod mounts the corrected ConfigMap immediately, without waiting for the volume refresh that running pods go through.

---

# 8. Customising DNS

Three additions in one patch, so there is one reload to wait for:

| Change | What it does |
|---|---|
| `log` | Prints every query again, so queries can be counted |
| `rewrite name legacy.internal nginx.default.svc.cluster.local` | An **alias**: `legacy.internal` answers with whatever address the `nginx` Service currently has |
| `hosts { 192.0.2.10 fixed.internal  fallthrough }` | A **fixed** entry for a name outside the cluster (`192.0.2.10` is a documentation address that nothing owns). `fallthrough` passes other names on |

```bash
cat > ~/coredns-custom-patch.yaml <<'EOF'
data:
  Corefile: |
    .:53 {
        errors
        log
        rewrite name legacy.internal nginx.default.svc.cluster.local
        hosts {
           192.0.2.10 fixed.internal
           fallthrough
        }
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30 {
           disable success cluster.local
           disable denial cluster.local
        }
        loop
        reload
        loadbalance
    }
EOF
kubectl -n kube-system patch configmap coredns --type merge --patch-file ~/coredns-custom-patch.yaml
```

The patch differs from the original by exactly those six added lines. To know when **both** pods have reloaded, ask **each CoreDNS pod directly** by its own address:

```bash
IPS=$(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}')
t0=$(date +%s)
for i in $(seq 1 24); do
  n=0
  for ip in $IPS; do
    kubectl exec probe -- nslookup fixed.internal $ip 2>&1 | grep -q "192.0.2.10" && n=$((n+1))
  done
  echo "t+$(( $(date +%s) - t0 ))s  pods answering for fixed.internal: $n/2"
  [ "$n" -ge 2 ] && break
  sleep 10
done
```

### Observed on the real cluster

```text
coredns pod IPs: 10.244.2.16 10.244.0.13
t+1s ... t+63s   pods answering for fixed.internal: 0/2
t+73s            pods answering for fixed.internal: 2/2
```

Both pods flipped between two samples, so there was no `1/2`.

```text
Name:   fixed.internal
Address: 192.0.2.10

Address: 10.107.185.30                   <- legacy.internal
nginx ClusterIP: 10.107.185.30
wget legacy.internal: ok
Address: 10.107.185.30                   <- nginx.default.svc.cluster.local, unchanged
** server can't find nosuchname.default.svc.cluster.local: NXDOMAIN
```

| Item | Observed |
|---|---|
| `fixed.internal` | **`192.0.2.10`** |
| `legacy.internal` | **`10.107.185.30`**, which matches the `nginx` Service's address |
| `wget legacy.internal` | **`ok`** (nginx serves its default page whatever name is used) |
| Cluster names | Unchanged, and a nonexistent name still gets **NXDOMAIN**: `fallthrough` on `hosts` passes unknown names on |

The alias **follows the Service**: if it were recreated with a new ClusterIP, `legacy.internal` would follow it, while the fixed entry never changes. **Not confirmed:** whether the reply to `legacy.internal` carries the original name or the Service's. My `tail -3` cut off the line that shows it, and the alias was restored before I could look again.

## `ndots:1` against `ndots:5`

A second pod whose `dnsConfig` lowers `ndots` to 1, to compare query counts:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: probe1
spec:
  terminationGracePeriodSeconds: 1
  dnsConfig:
    options:
    - name: ndots
      value: "1"
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
```

```text
search dns.svc.cluster.local svc.cluster.local cluster.local mshome.net
nameserver 10.96.0.10
options ndots:1
```

| Lookup | Queries seen in the log |
|---|---|
| `nginx.default` from `probe` (`ndots:5`) | **4** |
| `nginx.default` from `probe1` (`ndots:1`) | **6** |
| `example.com` from `probe` and `probe1` | **Not confirmed** (see below) |

The six lines for `probe1` and `nginx.default` show the mechanism:

```text
10.244.2.17:46300  "AAAA IN nginx.default. ..."                        NXDOMAIN qr,rd,ra  0.046 s    <- asked as given first: goes UPSTREAM
10.244.2.17:46300  "A IN nginx.default. ..."                           NXDOMAIN qr,rd,ra  0.050 s
10.244.2.17:40472  "AAAA IN nginx.default.dns.svc.cluster.local. ..."  NXDOMAIN qr,aa,rd  0.00023 s
10.244.2.17:40472  "A IN nginx.default.dns.svc.cluster.local. ..."     NXDOMAIN qr,aa,rd  0.00042 s
10.244.2.17:44637  "AAAA IN nginx.default.svc.cluster.local. ..."      NOERROR  qr,aa,rd  0.00006 s    <- found
10.244.2.17:44637  "A IN nginx.default.svc.cluster.local. ..."         NOERROR  qr,aa,rd  0.00016 s
```

With `ndots:1`, `nginx.default` has one dot, so it counts as complete and is asked **as typed first**. That name isn't in the cluster zone, so CoreDNS forwarded it upstream, and it came back NXDOMAIN after **46 to 50 ms**. Only then did the search suffixes run. So **`ndots:1` made a cluster name cost 6 queries instead of 4**, and added a round trip out of the cluster. A lower `ndots` speeds up external names and slows internal ones.

The `example.com` counts (6 and 0) are wrong because of my command: with a **label selector**, `kubectl logs` shows only the **last 10 lines of each pod's log** unless you add `--tail=-1`. That cut off the oldest lines, which were the `example.com` queries. By the time I tried again, the CoreDNS pods had been replaced, and their logs were gone. The 10 + 2 breakdown in Section 5 is unaffected, since it had 12 lines, 6 per pod.

---

# 9. DNS and the pod network

DNS is the first thing that fails when the pod network breaks, even while every node reports `Ready`. During the address-change episode (the node-address guide), both CoreDNS pods sat on the **master**, while the nodes' flannel records pointed at addresses that no longer existed. The tunnel back to each worker was dead, so a request could reach CoreDNS and its reply was lost.

```text
probe-w1 (20s): ping: bad address 'kubernetes.default'
probe-w2 (20s): ping: bad address 'kubernetes.default'
```

Twenty seconds, then failure, for a pod on **each** worker, while `kubectl get nodes` said `Ready` for all three. After flannel's records were corrected:

```text
PASS  probe-w1 resolved kubernetes.default in 1s: PING kubernetes.default (10.96.0.1): 56 data bytes
PASS  probe-w2 resolved kubernetes.default in 1s: PING kubernetes.default (10.96.0.1): 56 data bytes
```

Two practical points: if DNS fails from pods, **test the pod network before touching CoreDNS** (can a pod ping a pod on another node?), and remember that a node's `Ready` status says nothing about it.

---

# 10. What I got wrong

| Claim or instruction | What the labs showed |
|---|---|
| The Corefile has **21 lines** | **23** |
| The standard Corefile has `cache 30` | It has a `cache 30 { disable success cluster.local ... }` block |
| **0** CoreDNS pods 5 s after `scale 0` | **2**, still terminating (probably `lameduck`) |
| The CoreDNS image is probably missing on worker2 | **Present**, both `v1.13.1` and `v1.14.2` |
| A `ping` of a trailing-dot name logs only **2** lines, in total | The total included the first `ping`'s own final lookup of the same name: **4** |
| About 10 queries in the log | **12**: two `ping`s |
| The error line is `Corefile:15` | **`Corefile:13`** |
| The `example.com` counts from `kubectl logs -l` | Truncated by the **default tail of 10 per pod** with a label selector (my command) |
| The checks for `ndots` ran in the master shell | They ran in the worker2 shell, where `kubectl` has no credentials: I hadn't said which shell. The `probe` pod had also been evicted by then |
| The `probe` pod would be there for the later labs | A bare pod on a node that stays `NotReady` is **evicted and not recreated** |

---

# 11. Practical tips for running these labs

- **`kubectl logs -l ...` shows only 10 lines per pod.** Add `--tail=-1` for everything, and `--since` to bound it.
- **Log lines are lost when a pod is replaced.** Count queries soon after generating them.
- **`ping` honours the search path, and BusyBox's `nslookup` seems not to.** Use `ping` to see the expansions and `nslookup` for a fully qualified name. `nslookup` also prints a failure twice, once per query type.
- **Edit the Corefile with a patch file you have verified**, keep a copy of the original, and compare with `diff` after restoring.
- **A failing ConfigMap edit gives no immediate sign.** Read the CoreDNS logs for `[ERROR]` after every Corefile change.
- **Ask each CoreDNS pod directly** (`nslookup NAME POD_IP`) to know when each has reloaded.
- **Which shell?** `kubectl` works on the master. A worker has no admin credentials.

---

# 12. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| A short name works in one namespace and not another | Short names resolve only within the pod's own namespace | Use `name.namespace` |
| Every lookup from a pod fails after 5 to 20 seconds, nodes `Ready` | The pod network is broken between the pod and CoreDNS | Test a ping across nodes before touching CoreDNS (Section 9) |
| Lookups hang with `nslookup` and fail fast with `ping` | Different tools time out differently | Trust the C library's behaviour for real applications |
| External names are slow | `ndots:5` makes the resolver try 4 search suffixes first, and one goes upstream | Use a trailing dot, or lower `ndots` for that pod (and mind the internal names) |
| A Corefile edit has no effect | The `reload` plugin hasn't picked it up (about a minute), or the edit failed | Read `kubectl -n kube-system logs -l k8s-app=kube-dns --tail=-1 \| grep -i error` |
| A CoreDNS pod is in `CrashLoopBackOff` after an edit | A typo in the Corefile, noticed only at restart | Fix the ConfigMap, then delete the failing pod |
| The CoreDNS logs are empty | The `log` plugin is off by default | Add `log` to the Corefile |
| A custom name doesn't resolve | `hosts` without `fallthrough`, or the reload hasn't happened | Check both |

---

# 13. Command cheat sheet

| Task | Command |
|---|---|
| CoreDNS pods | `kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide` |
| The Corefile | `kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'` |
| A pod's resolver settings | `kubectl exec POD -- cat /etc/resolv.conf` |
| Resolve a name (with the search path) | `kubectl exec POD -- ping -c1 -W1 NAME` |
| Resolve a fully qualified name | `kubectl exec POD -- nslookup NAME.svc.cluster.local` |
| Ask one CoreDNS pod directly | `kubectl exec POD -- nslookup NAME COREDNS_POD_IP` |
| Edit the Corefile | `kubectl -n kube-system patch configmap coredns --type merge --patch-file FILE` |
| Reload errors | `kubectl -n kube-system logs -l k8s-app=kube-dns --since=10m --tail=-1 \| grep -i error` |
| All query log lines | `kubectl -n kube-system logs -l k8s-app=kube-dns --since=1m --tail=-1` |
| Lower `ndots` for one pod | `dnsConfig: { options: [{ name: ndots, value: "1" }] }` in the pod spec |

---

# 14. Glossary

| Term | Meaning |
|---|---|
| **CoreDNS** | The cluster's DNS server, a Deployment in `kube-system` |
| **Search path** | Suffixes in `resolv.conf` added to names that are not complete |
| **`ndots`** | Names with fewer dots than this get the search suffixes first |
| **Trailing dot** | Marks a name as complete (`example.com.`), skipping the search path |
| **NXDOMAIN** | The answer for "no such name" |
| **`aa` flag** | An authoritative answer, from CoreDNS's own records. A forwarded answer lacks it |
| **Corefile** | CoreDNS's configuration, stored in the `coredns` ConfigMap |
| **`reload`** | The plugin that re-reads the Corefile without a restart |
| **`lameduck`** | The period CoreDNS keeps serving after a shutdown signal |
| **A and AAAA** | Record types for IPv4 and IPv6 addresses. Resolvers ask for both |

---

# 15. What was run, and what was not

## Run on the real cluster (the output above is from these)

- Reading CoreDNS: the Deployment, Service, EndpointSlice and Corefile, including the `cache` exception
- A pod's `resolv.conf`, and names that resolve and don't (including the namespace-scoping trap)
- The query count for a bare name against a name with a trailing dot, with the log lines
- Scaling CoreDNS to zero, DNS against the network, and recovery
- A typo in the Corefile: the reload error, the latent crash, and the fix
- A `rewrite` alias, a `hosts` entry, and `ndots:1` against `ndots:5` for a cluster name
- DNS failing from pods while nodes were `Ready` (during the address-change episode)

## Not confirmed

- **The `ndots:1` query count for `example.com`**: the logs were gone
- **Whether the reply to `legacy.internal` carries the original name**
- **Whether the fast failure of `ping` is a rejection** by kube-proxy
- **Whether `lameduck` explains the pods still listed 5 seconds after `scale 0`**
- **The reason for the `cache` exception for `cluster.local`**

## Not run

- Headless Services, SRV records, and pod A records
- `dnsPolicy` variants (`ClusterFirstWithHostNet`, `Default`, `None`)
- A stub zone with `forward` for a private domain
- NodeLocal DNSCache and the `autopath` plugin
- Changing CoreDNS's replica count or placement permanently

The explanations marked as inferences in the text are the best fit to the evidence, and not verified. Check the official Kubernetes and CoreDNS documentation for the versions you run.

## Clean up everything from this guide

```bash
# master shell
kubectl delete namespace dns
kubectl config set-context --current --namespace=default
rm -f ~/coredns-log-patch.yaml ~/coredns-orig-patch.yaml ~/coredns-typo-patch.yaml ~/coredns-custom-patch.yaml ~/Corefile.orig ~/probe.yaml ~/probe1.yaml ~/probes.yaml
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -c "log\|rewrite\|hosts\|forwrd"
kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers | awk '{print $1, $2, $3}'
```

The `grep -c` should print **0**: the Corefile is back to the original, with none of the added directives. The `dns` namespace holds only throwaway pods, and `flannel-recover.sh` re-creates its own two test pods when it needs them.
