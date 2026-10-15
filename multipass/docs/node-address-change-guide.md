# When the VMs' Addresses Change: A Cluster That Looks Healthy and Isn't

## A subnet change on a Multipass and Hyper-V cluster: the symptoms in the order they appeared, the evidence, two fixes, three scripts, and a command that made things worse

The cluster in these guides runs on Multipass VMs behind Hyper-V's Default Switch. After the host machine had been away for a day, the nodes' network addresses had changed, and a cluster that had been healthy turned into one where the nodes were `NotReady`, then `Ready` with a dead pod network, then healthy again. This guide records what was seen, in order, what was done, and what turned out to be wrong, with the console output copied from the run. Explanations marked as inferences are best guesses, not results.

**Contents**

1. The setup, and why addresses change
2. The first sign
3. The evidence
4. The clock red herring
5. First fix: a direct route to the master
6. Second problem: flannel's stale records
7. The three scripts
8. `netplan apply` and a dead pod network
9. Making the route permanent, and proving it
10. What a restart changes
11. A triage procedure
12. What I got wrong
13. Practical tips
14. Troubleshooting
15. Command cheat sheet
16. Glossary
17. What was run, and what was not

---

# 1. The setup, and why addresses change

| Fact | Detail |
|---|---|
| The VMs | One master and two workers, created by Multipass on Hyper-V |
| Their addresses | **DHCP** from the Default Switch. Multipass finds a VM through the switch's DNS record, `<name>.mshome.net`, so a VM that stops using DHCP becomes unreachable for Multipass (this is the reasoning in the header of `pin-ip.sh`) |
| The master's fixed address | **`172.25.246.7/20`**, added as a **secondary** address by a netplan drop-in (`60-fixed-ip.yaml`), next to its DHCP address |
| Who uses the fixed address | Every kubelet (`server: https://172.25.246.7:6443`), kube-proxy, etcd (listening on it), and the API server's certificate, which names **only** `172.25.246.7`, `10.96.0.1` and the usual DNS names |

The design assumed that the Default Switch keeps its subnet. It doesn't. The host's own address on the switch, which appears in the `Last login ... from` lines of each VM's login banner, was seen as:

| Where | Host address on the switch |
|---|---|
| Master login, Oct 10 | `172.25.240.1` |
| Master login, Oct 14 | `172.17.224.1` |
| Worker2 login, Oct 15 | `172.28.32.1` |

So the switch changed subnet **at least twice** in five days. The cause is my inference: I did not watch the host restart, and it fits the machine having been asleep and restarted. The workers' addresses changed with it:

| VM | First seen | Then | Then |
|---|---|---|---|
| master (DHCP address) | not recorded | `172.28.39.97` | |
| worker1 | `172.25.253.184` | `172.28.32.153` | `172.28.37.254` (after a reboot) |
| worker2 | `172.25.252.5` | `172.28.32.131` | `172.28.39.201` (after a reboot) |

The master kept answering on `172.25.246.7`, because that address is configured on the master itself, and nothing on the switch needs to agree with it. That is why `kubectl` on the master never stopped working, and why the problem was easy to miss from there.

---

# 2. The first sign

Nothing announced the change. The first sign was an error from a command that had nothing to do with addresses, a log request for a CoreDNS pod that happened to run on worker2:

```text
Error from server: Get "https://172.25.252.5:10250/containerLogs/kube-system/coredns-589f44dc88-grc8x/coredns?sinceSeconds=3600": dial tcp 172.25.252.5:10250: connect: no route to host
```

The last words matter. Compare with the kubelet guide, where a **stopped** kubelet gave `connection refused`:

| Error | What it means |
|---|---|
| `connect: connection refused` | The host **answered**, and nothing listened on port 10250 |
| **`connect: no route to host`** | The host **didn't answer at all**: it is down, or no longer at that address |

The master was asking for worker2 at `172.25.252.5`, the address recorded in worker2's node object. That address no longer belonged to anything.

---

# 3. The evidence

All read-only. In PowerShell, on the host:

```powershell
multipass list
```

```text
master    Running   172.28.39.97
worker1   Running   172.28.32.153
worker2   Running   172.28.32.131
```

All three addresses were new. On worker2:

```bash
ip -4 -brief addr show
ip route
ping -c2 -W2 172.25.246.7
date -u
timedatectl timesync-status
systemctl is-active kubelet containerd
```

```text
eth0   UP   172.28.32.131/20 metric 100
default via 172.28.32.1 dev eth0 proto dhcp src 172.28.32.131 metric 100
172.28.32.0/20 dev eth0 proto kernel scope link src 172.28.32.131 metric 100

2 packets transmitted, 0 received, 100% packet loss, time 1033ms
Thu Oct 15 16:27:33 UTC 2026
       Server: 185.125.190.56 (ntp.ubuntu.com)
        Offset: +17.987ms
 Packet count: 6
active
active
```

On the master:

```bash
ip -4 -brief addr show eth0
ip route
kubectl get nodes -o wide
sudo ss -tlnp | grep -E ':6443 |:2379 |:2380 '
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName
```

```text
eth0   UP   172.25.246.7/20 172.28.39.97/20 metric 100
default via 172.28.32.1 dev eth0 proto dhcp src 172.28.39.97 metric 100
172.25.240.0/20 dev eth0 proto kernel scope link src 172.25.246.7
172.28.32.0/20 dev eth0 proto kernel scope link src 172.28.39.97 metric 100

master    Ready      control-plane   v1.36.5   172.25.246.7
worker1   NotReady   worker          v1.36.5   172.25.253.184
worker2   NotReady   worker          v1.36.5   172.25.252.5

*:6443 users:(("kube-apiserver",...))
172.25.246.7:2379  172.25.246.7:2380  127.0.0.1:2379   (etcd)

X509v3 Subject Alternative Name:
    DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, DNS:master, IP Address:10.96.0.1, IP Address:172.25.246.7
```

And, on worker2, the kubelet's side:

```bash
sudo grep -E "^\s+server:" /etc/kubernetes/kubelet.conf
sudo journalctl -u kubelet --since "15 minutes ago" --no-pager | grep -E "dial tcp|no route|i/o timeout" | tail -3 | cut -c1-220
ip route get 172.25.246.7
```

```text
    server: https://172.25.246.7:6443
... "Unable to register node with API server" err="Post \"https://172.25.246.7:6443/api/v1/nodes\": dial tcp 172.25.246.7:644...
172.25.246.7 via 172.28.32.1 dev eth0 src 172.28.32.131 uid 1000
```

| Observation | What it means |
|---|---|
| The master holds **both** addresses, and a stale `172.25.240.0/20` route | The fixed address still works on the master itself |
| The workers are `NotReady`, with their **old** `InternalIP`s | They stopped reporting, so the node objects still hold the old addresses |
| The API server listens on `*:6443` | It answers on any of the master's addresses |
| The certificate names only `172.25.246.7` | A connection to the master's **new** address would fail the certificate check. The fixed address is the only name the certificate knows |
| worker2's `kubelet.conf` says `172.25.246.7:6443` | The kubelet is configured for the fixed address |
| `ip route get 172.25.246.7` goes **via the gateway** | worker2 sends traffic for the fixed address to a gateway that doesn't know it |
| worker2's services are `active`, its clock is correct | The node itself is fine. It is cut off from the API server |

The chain, partly inferred, since I never watched it happen:

```text
the switch changes subnet
  -> the workers get new addresses, and have no route to 172.25.246.7 except via the gateway
  -> the kubelets can't reach the API server, so the nodes go NotReady
  -> the master can't reach the workers either: it uses their old node addresses
```

---

# 4. The clock red herring

Because the clocks had caused trouble earlier, `check-clocks.ps1 -Fix` was run first. Its output was strange:

```text
Windows UTC: 22:25:07

VM      OffsetSeconds RoundTripMs Status
master         -132.1      264746 OFF
worker1      -31607.9    63217297 OFF
worker2      -36753.7        6535 OFF
```

A `multipass exec ... date` call takes about a second. A round trip of **264,746 ms** (4.4 minutes) and **63,217,297 ms** (17.6 hours) is impossible, and the **Windows clock itself** had stepped during the run. That ruins the offset, which is computed from the middle of each window.

I first read the one normal-looking row (worker2, 6.5 s) as "worker2's clock is about 10 hours behind", and guessed it couldn't reach a time server. Worker2's own output says otherwise:

| Item | Observed |
|---|---|
| `date -u` | `Thu Oct 15 16:27:33 UTC 2026`: **correct** |
| `timesync-status` | Server `ntp.ubuntu.com`, **offset +17.987 ms**, 6 packets: **reaching a time server** |

**That claim was wrong, and I withdrew it.** The login banner also read 09:30 PDT, which is 16:30 UTC, so worker2's clock was right, and it was the Windows reading that was off. The script's offsets can't be trusted when the round trips are huge. Check the `RoundTripMs` column first: a value over a few seconds means the measurement is broken, not the VM.

---

# 5. First fix: a direct route to the master

The workers and the master share the same switch. A worker can reach `172.25.246.7` **directly**, by asking the local network who holds that address, and the master answers, even though the address isn't in the worker's own subnet. All it needs is a route saying so:

```bash
sudo ip route add 172.25.246.7/32 dev eth0
ip route get 172.25.246.7
ping -c2 -W2 172.25.246.7
curl -sk --max-time 5 -o /dev/null -w "API server healthz: HTTP %{http_code}\n" https://172.25.246.7:6443/healthz
```

```text
172.25.246.7 dev eth0 src 172.28.32.131 uid 1000
PING 172.25.246.7 (172.25.246.7) 56(84) bytes of data.
64 bytes from 172.25.246.7: icmp_seq=1 ttl=64 time=0.375 ms
64 bytes from 172.25.246.7: icmp_seq=2 ttl=64 time=0.173 ms
API server healthz: HTTP 200
```

| Why this fix | Why |
|---|---|
| No certificate work | The certificate names `172.25.246.7`, and the worker keeps using exactly that name |
| No kubelet, etcd or kubeconfig changes | They all already point at the fixed address |
| It survives the next renumbering | Whatever subnet the switch picks, the master and workers share it, and the fixed address stays on the master |

After the route, the node recovered (the paste doesn't record how long it took), and the control plane saw its **new** address:

```text
NAME      STATUS   ROLES           AGE   VERSION   INTERNAL-IP
master    Ready    control-plane   9d    v1.36.5   172.25.246.7
worker1   Ready    worker          9d    v1.36.5   172.28.32.153
worker2   Ready    worker          9d    v1.36.5   172.28.32.131
```

Worker1 needed the same route. Two alternatives were not tried: **renumbering the control plane** (new certificate, new API server and etcd addresses, new kubeconfigs, kubelet changes on every node), which would break again at the next renumbering, and **rebuilding the cluster** with the repo's scripts.

---

# 6. Second problem: flannel's stale records

With every node `Ready`, the cluster was still not healthy. The pod network is provided by **flannel**, which records each node's **public address** in a node annotation, and every other node builds its VXLAN tunnel to that address. Flannel reads the address **once, at startup**, and the VMs had kept running while their addresses changed underneath it.

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,FLANNEL-IP:.metadata.annotations.flannel\\.alpha\\.coreos\\.com/public-ip
bridge fdb show dev flannel.1
```

```text
NAME      FLANNEL-IP
master    172.25.246.7
worker1   172.25.253.184
worker2   172.25.252.5

26:b6:c3:69:44:49 dst 172.25.253.184 self permanent
da:03:79:5e:db:b5 dst 172.25.252.5 self permanent
```

Both workers' tunnels pointed at addresses nobody answered on. The consequences, all observed:

```bash
ping -c2 -W2 10.244.2.18 | tail -2          # a pod on worker2, from the master
ping -c2 -W2 10.244.1.0 | tail -2           # worker1's flannel interface
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes 2>&1 | head -3
```

```text
2 packets transmitted, 0 received, 100% packet loss, time 1000ms
2 packets transmitted, 0 received, 100% packet loss, time 1031ms
v1beta1.metrics.k8s.io   kube-system/metrics-server   False (FailedDiscoveryCheck)   4d19h
error: Metrics API not available
```

And from test pods pinned to each worker:

```text
probe-w1 (20s): ping: bad address 'kubernetes.default'
probe-w2 (20s): ping: bad address 'kubernetes.default'
```

| Symptom | Cause |
|---|---|
| Pings from the master to pods on a worker: 100% loss | The tunnel went to the old address |
| The metrics APIService `FailedDiscoveryCheck`, `kubectl top` failing | The API server (on the master) couldn't reach the metrics-server pod on worker2 |
| DNS failing after 20 s from pods on **both** workers | Both CoreDNS pods were on the master, and the replies couldn't come back |
| **Every node `Ready`, every pod `Running`** | The kubelet's health check never tests the pod network |

The pod listing also told the story of the outage. The four `nginx` pods were **26 hours old**, all on worker2: they replaced the ones from worker1, which had been evicted. Both CoreDNS pods were on the master. The earlier test pod `probe` was **gone**: a bare pod on a node that stays `NotReady` past its toleration is evicted, and nothing recreates it.

## The fix: restart flannel

```bash
kubectl -n kube-flannel rollout restart daemonset/kube-flannel-ds
kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=180s
kubectl get nodes -o custom-columns=NAME:.metadata.name,FLANNEL-IP:.metadata.annotations.flannel\\.alpha\\.coreos\\.com/public-ip
bridge fdb show dev flannel.1
```

```text
master    172.25.246.7
worker1   172.28.32.153         <- updated
worker2   172.25.252.5          <- still the old address

26:b6:c3:69:44:49 dst 172.28.32.153 self permanent
da:03:79:5e:db:b5 dst 172.25.252.5 self permanent
```

Worker1's record updated and worker2's didn't. Two explanations were open: a race (the last pod restarted hadn't finished writing its annotation when it was read), or a wrong address. It was a **race**: when the recovery script ran a few minutes later, worker2's record already read `172.28.32.131`, and nothing needed repairing. The rollout reports success as soon as the pods start, not when they have written their records.

The master's record stayed at `172.25.246.7`, the first address on its interface. That works for the workers, because of the direct route.

---

# 7. The three scripts

The repeated commands became three scripts in the repo.

## `check-clocks.ps1` (Windows PowerShell)

Measures each VM's clock offset from Windows, and with `-Fix` first restarts `systemd-timesyncd` on each. It marks a VM `OFF` above 2 seconds. Its first real use found worker1 **213.7 seconds behind** after a laptop sleep, and `-Fix` corrected it within the 40-second wait. In this episode it printed impossible round trips (Section 4), which is the one thing it can't see through: **read `RoundTripMs` before the offset.**

Windows blocks unsigned scripts from a `\\wsl.localhost\...` path. Run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` in each new window, or start it in a fresh process with `powershell -ExecutionPolicy Bypass -File C:\Users\bijut\check-clocks.ps1`.

## `flannel-recover.sh` (on the master)

Checks, repairs and verifies in five stages:

| Stage | What it does |
|---|---|
| 1 | Lists the nodes and flags any that are not `Ready`, with the route command for that worker |
| 2 | Compares the address flannel recorded for each node with the node's own address, and **restarts the flannel pod of every node that is stale**, then waits for the new record |
| 3 | Checks the pod network: master to each worker, worker to worker, worker to master. The targets are found automatically |
| 4 | Checks DNS from a test pod on each worker |
| 5 | Checks the metrics API and `kubectl top nodes` |

`--check` changes nothing. It exits 0 if everything passes, 1 if anything fails, and 2 if `kubectl` can't reach the API server. It was tested against a fake `kubectl` in six scenarios (a stale record repaired, `--check` leaving it alone, a healthy cluster, a `NotReady` worker, an unreachable API server, broken network paths), then on the real cluster:

```text
== Result
  14 passed, 0 failed
  The cluster network is healthy.
```

Run from PowerShell without opening a shell:

```powershell
multipass transfer C:\Users\bijut\flannel-recover.sh master:/home/ubuntu/
multipass exec master -- bash /home/ubuntu/flannel-recover.sh
```

On its first real run nothing was stale, so the **repair branch has not run on the real cluster**. The script also **can't repair** a node whose records match but whose pod network is dead (Section 8).

## `route-to-master.sh` (on each worker)

Gives a worker a permanent direct route to the master's fixed address, through a netplan drop-in (`61-master-route.yaml`). It reads the address from the worker's `kubelet.conf`, takes the interface id from the existing cloud-init file (and refuses to guess if there isn't one), validates the file with `netplan generate`, removes it if netplan rejects it, and adds the live route with `ip route replace`. **It does not run `netplan apply`** unless asked with `--apply`. That is the lesson of the next section, and the first version of this script did run it. It was tested against a fake filesystem and stand-in commands, and **it was never run on the real workers**: their drop-ins were written by hand with `printf`, and are identical to what the script produces (114 bytes, mode 600).

---

# 8. `netplan apply` and a dead pod network

To make worker2's route permanent, I gave this command, which removes the manual route and applies netplan:

```powershell
multipass exec worker2 -- sudo sh -c "ip route del 172.25.246.7/32 dev eth0; netplan apply; sleep 3; ip route get 172.25.246.7 | head -1; ip route show | grep 172.25"
```

It printed **nothing at all**, not even the route lines, which should always print something. The session probably broke while the network was being re-applied, though I can't confirm that. Then:

```text
== 3. Pod network
  PASS  master -> worker1 (10.244.1.0)
  FAIL  master -> worker2 (10.244.2.0)
  FAIL  pod on worker1 -> worker2 (10.244.2.0)
  FAIL  pod on worker2 -> worker1 (10.244.1.0)
  PASS  pod on worker1 -> master (10.244.0.0)
  FAIL  pod on worker2 -> master (10.244.0.0)
== 4. DNS
  PASS  probe-w1 resolved kubernetes.default in 1s
  FAIL  probe-w2 could not resolve kubernetes.default (20s): ping: bad address 'kubernetes.default'
== 5. Metrics API
  FAIL  the metrics APIService is not Available (status: False)
  7 passed, 7 failed
```

| Observation | Meaning |
|---|---|
| worker2 was `Ready`, flannel's records **matched** the node addresses | This was **not** a stale address |
| **Every** failing path involves worker2, and every passing one involves only the master and worker1 | Worker2's own pod network was dead |
| After `multipass restart worker2` | **`14 passed, 0 failed`** |

My explanation, an **inference**: `netplan apply` re-applies the whole network configuration, and on a Kubernetes node that can disturb the virtual interfaces that flannel and the CNI created. I never looked at worker2's interfaces between the apply and the restart. What I have is the symptom, the timing, and the cure. The first version of `route-to-master.sh` ended with `netplan apply`, so it would have caused the same. It was rewritten: the permanent route is a file that takes effect at the next boot, and the running system gets the same route from `ip route replace`, which changes nothing for a route that's already there.

For the same reason, worker1 was treated differently: the drop-in was written and checked with `netplan generate`, **not applied**, and the VM was restarted.

---

# 9. Making the route permanent, and proving it

The drop-in (identical for both workers, 114 bytes, mode 600):

```yaml
network:
  version: 2
  ethernets:
    default:
      routes:
        - to: 172.25.246.7/32
          scope: link
```

`default` is the interface id in each worker's own cloud-init file. It must match, so netplan merges the new file into the existing definition. A different id would define a second entry for the same interface.

The proof is a reboot. After `multipass restart worker2`:

```text
-rw------- 1 root root 148 Oct  5 14:09 50-cloud-init.yaml
-rw------- 1 root root 114 Oct 15 13:22 61-master-route.yaml
172.25.246.7 dev eth0 proto static scope link
172.25.246.7 dev eth0 src 172.28.39.201 uid 1000
6.8.0-147-generic
up 6 minutes
```

And after `multipass restart worker1`:

```text
-rw------- 1 root root 114 Oct 15 13:48 61-master-route.yaml
172.25.246.7 dev eth0 proto static scope link
172.25.246.7 dev eth0 src 172.28.37.254 uid 0
6.8.0-147-generic
up 14 minutes
```

| Observation | Meaning |
|---|---|
| **`proto static`** | The route was installed by netplan at boot. A manual `ip route add` is `proto boot`, and would not survive a reboot |
| `ip route get` has **no `via`** | It goes direct |
| Both nodes `Ready` again, with no manual step | The permanent route works |
| `flannel-recover.sh` afterwards | **`14 passed, 0 failed`** for both |

---

# 10. What a restart changes

The restarts showed several things that weren't part of the plan:

| Observation | Detail |
|---|---|
| **A restart takes a new DHCP lease** | worker2 `172.28.32.131` became `172.28.39.201`, and worker1 `172.28.32.153` became `172.28.37.254`: new addresses within the same subnet, with no subnet change involved |
| **Flannel corrects itself on a rebooted node** | Its pod starts fresh and records the current address. The stale-record problem is mostly about nodes that **keep running** |
| **The kernel updated** | `6.8.0-142-generic` became `6.8.0-147-generic`: the restart booted an update that had been waiting (the login banner says `*** System restart required ***`) |
| **`Timeout connecting to workerN.mshome.net`** | In the first minute or two after a restart, Multipass can't find the VM: the new lease's name hasn't appeared yet. `multipass list` shows `N/A` for the address meanwhile. This is not a cluster fault |
| **Bare pods are lost** | A pod with no controller on a node that goes down for longer than its toleration is evicted and not recreated |

---

# 11. A triage procedure

Everything here comes from the episode. Other causes were not tested.

1. **`kubectl get nodes -o wide`**: is a node `NotReady`? Does its `INTERNAL-IP` look old?
2. **`multipass list`** (on the host): do its addresses differ from the node objects?
3. **On the worker**: `ip -4 -brief addr show`, and `ip route get <the master's fixed address>`. A `via <gateway>` means it has no direct route.
4. **The kubelet's journal**: `journalctl -u kubelet --since "15 minutes ago" | grep "dial tcp"`. The same address in every error is the clue.
5. **Add the route**, check with `ip route get`, `ping` and `curl .../healthz`, and watch the node return to `Ready`.
6. **Check flannel**: compare each node's annotation with its address, or run `flannel-recover.sh --check`.
7. **Restart flannel** on a stale node (or run the script without `--check`).
8. **Verify** the pod network, DNS from a pod on each worker, and the metrics API.
9. **Make the route permanent**: a drop-in, validated with `netplan generate`, **not** applied on a running node.
10. **A node whose records match but whose pod network is dead** needs its VM restarted. The script can find it, and cannot repair it.

---

# 12. What I got wrong

| Claim or instruction | What happened |
|---|---|
| "worker2's clock is about 10 hours behind, and it can't reach a time server" | **Wrong**: its clock was right, and it was syncing. The Windows clock had stepped, which made the script's offsets meaningless |
| The checks for the pod network ran **in the master shell** | I didn't say which shell, and they ran on worker2, where `kubectl` has no credentials. The test pod they used had also been evicted |
| Worker1 would stay `NotReady` until its own route was added | It was already `Ready`: the route had been added without being pasted |
| `netplan apply` to make the route permanent | It was followed by **7 failures**: a dead pod network on worker2. The step was mine |
| I predicted `14 passed` afterwards | **7 passed, 7 failed** |
| `cat` of a mode-600 file without `sudo` | `Permission denied`, on two nodes |
| worker2's flannel record would be a wrong address | It was a **race**: the record corrected itself |
| The recovery script's repair branch is proven | It is not: nothing was ever stale when it ran |

---

# 13. Practical tips

- **Read `RoundTripMs` before the clock offset** in `check-clocks.ps1`.
- **Compare `multipass list` with `kubectl get nodes -o wide`** first. Different addresses are the signature of this fault.
- **`no route to host` and `connection refused` are different diagnoses**: one is a missing host, the other a stopped service.
- **Don't run `netplan apply` on a running Kubernetes node.** Write the file, validate it with `netplan generate`, add the live route with `ip route replace`, and let the next boot apply it.
- **Check a netplan file's interface id against the cloud-init file's**, so it merges and doesn't duplicate.
- **A node's `Ready` status says nothing about the pod network.** Test it: ping across nodes, and resolve a name from a pod on each worker.
- **After a flannel restart, wait before reading the annotation.** The rollout reports success before the record is written.
- **A restart can change a VM's address and name resolution for a minute or two.** Wait, and use `multipass list`.
- **Keep `kubectl` on the master.** A worker's `kubectl` falls back to `localhost:8080`.

---

# 14. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Workers `NotReady`, services `active` on the node, `no route to host` from the master | The VMs' addresses changed, and the workers lost their route to the master's fixed address | Add `172.25.246.7/32 dev eth0` on each worker, then make it permanent |
| Nodes `Ready`, pods can't reach other nodes, DNS fails | Flannel's records are stale | `flannel-recover.sh`, or restart flannel |
| `kubectl top` fails, the metrics APIService `FailedDiscoveryCheck` | The API server can't reach the metrics-server pod across the tunnel | Fix the pod network first |
| Records match, but one node's pod paths all fail | That node's pod network is dead (seen after `netplan apply`) | Restart that VM |
| `Timeout connecting to workerN.mshome.net` | A freshly restarted VM, whose DHCP name isn't registered yet | Wait a minute or two, check `multipass list` |
| A new netplan file seems to have no effect | `netplan apply` was not run, which is intended on a node | The file applies at the next boot, and `ip route replace` covers the running system |
| A route reads `proto boot` after a reboot | It was added by hand, and netplan didn't install the permanent one | Check that the file exists with `sudo cat`, and `netplan generate` for errors |
| `check-clocks.ps1` shows a round trip of minutes or hours | The host clock stepped during the run | Discard that run and measure again |

---

# 15. Command cheat sheet

| Task | Command |
|---|---|
| Nodes and their recorded addresses | `kubectl get nodes -o wide` |
| The VMs' addresses (host) | `multipass list` |
| How a worker reaches the master | `ip route get 172.25.246.7` |
| Add the direct route (temporary) | `sudo ip route add 172.25.246.7/32 dev eth0` |
| Flannel's recorded address | `kubectl get nodes -o custom-columns=NAME:.metadata.name,FLANNEL-IP:.metadata.annotations.flannel\\.alpha\\.coreos\\.com/public-ip` |
| Flannel's tunnel table | `bridge fdb show dev flannel.1` |
| Restart flannel | `kubectl -n kube-flannel rollout restart daemonset/kube-flannel-ds` |
| Check, repair and verify | `bash flannel-recover.sh` (or `--check`) |
| The permanent route's file | `sudo cat /etc/netplan/61-master-route.yaml` |
| Validate a netplan file | `sudo netplan generate` |
| Is a route netplan's own? | `ip route show \| grep 172.25` and look for `proto static` |

---

# 16. Glossary

| Term | Meaning |
|---|---|
| **Default Switch** | Hyper-V's built-in virtual network, which hands the VMs DHCP addresses and can change its subnet |
| **Fixed address** | The master's secondary address, `172.25.246.7`, which the cluster is configured around |
| **Direct (link) route** | A route with no gateway: "this address is on my local network, ask for it" |
| **Flannel** | The pod network. It records each node's address in an annotation and builds VXLAN tunnels to it |
| **VXLAN tunnel** | The overlay that carries pod traffic between nodes |
| **netplan** | Ubuntu's network configuration. A drop-in file adds to the cloud-init configuration |
| **`proto static`** | A route installed from configuration, as opposed to `proto boot`, installed by hand |
| **Stale record** | An address stored at startup that no longer belongs to the node |
| **Bare pod** | A pod with no controller, which nothing recreates if it is evicted |

---

# 17. What was run, and what was not

## Run on the real cluster (the output above is from these)

- The diagnosis: `multipass list`, the nodes' and the master's addresses and routes, the kubelet's errors, the certificate's names
- The direct route on both workers, by hand, and its effect on the nodes
- Flannel's stale records, the 100% packet loss, the failing metrics API and DNS, and the restart
- `flannel-recover.sh`: a passing run, a failing run (7 failures), and a run after a reboot
- `netplan apply` on a worker, and the dead pod network that followed
- The permanent drop-in on both workers, proven by a reboot each

## Not run

- **A master restart.** The master holds the fixed address, and was the one node never rebooted. Whether it comes back cleanly after a restart is untested
- **The repair branch of `flannel-recover.sh` on a real stale record**: the one real case had corrected itself
- **What `netplan apply` did to the interfaces**: I never looked between the apply and the restart
- **The cause of the subnet change.** A host restart fits, and I didn't observe one
- **Pinning flannel's address** (its `--iface` option or an address-overwrite annotation) instead of restarting it
- **Renumbering the control plane** (a new certificate and kubeconfigs), or a DHCP reservation, or a static address
- **`route-to-master.sh` on the real workers**: tested only against stand-ins
- **A cluster with more than one control-plane node**

The explanations marked as inferences in the text (the subnet change, the cause of the dead pod network after `netplan apply`) are the best fit to the evidence, and not verified.

## Clean up

```powershell
# PowerShell: nothing to undo. The routes are permanent drop-ins, and they stay.
```

```bash
# master shell: only the test pods, which flannel-recover.sh re-creates when it needs them
kubectl delete namespace dns
kubectl config set-context --current --namespace=default
kubectl get nodes
```

Keep the two files `/etc/netplan/61-master-route.yaml` on the workers, and the scripts in the repo. Everything else was temporary.
