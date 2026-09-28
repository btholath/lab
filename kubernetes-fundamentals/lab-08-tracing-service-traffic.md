# Lab 8: Tracing a Service Through kube-proxy — Why LoadBalancer Says `<pending>`

**Goal:** build a Service for a real app (Mealie), turn it into a
LoadBalancer, find out **why its external address stays `<pending>`**, prove
it still works, and then follow a request through the actual iptables rules
that kube-proxy wrote on your node.

**Time:** about 60 minutes.

**How each step is explained.** Every step answers four questions:

| Question | Meaning |
|---|---|
| **What** | The command and what it does |
| **Why** | The reason you run it |
| **How** | How to read the output |
| **When** | When you would do this in real life |

**Where the outputs come from.** Almost everything below is **real output
from this WSL2 kubeadm cluster**. The few blocks marked **Expected output**
are standard behavior that I have not seen on this cluster, so confirm them
on yours.

**Builds on:** Lab 5 (Deployments), Lab 6 (Calico policy), Lab 7 (Services).

---

## Before you start

You need the Mealie Deployment from Lab 5 running in the `mealie` namespace.
Every command below uses `-n mealie` where it matters, so it works regardless
of your saved default namespace.

```bash
kubectl get pods -n mealie
```

**Output from the real session:**
```
NAME                      READY   STATUS    RESTARTS   AGE
mealie-6754cc7b44-dpb2q   1/1     Running   0          17h
```

If you have no Mealie pod, go back to Lab 5, Step 13.

---

## Vocabulary you will meet

| Term | Plain meaning |
|---|---|
| **kube-proxy** | A program on every node that writes the rules that make Service addresses work |
| **iptables `nat` table** | The part of the Linux firewall that rewrites addresses. kube-proxy writes its rules here |
| **Chain** | A named list of firewall rules. A rule can jump to another chain, like calling a function |
| **DNAT** | Rewriting a packet's **destination** (a Service address becomes a pod address) |
| **Masquerade (SNAT)** | Rewriting a packet's **source**, so replies come back through the node that rewrote it |
| **Mark** | A tag stuck on a packet by one rule and read by a later rule |
| **conntrack** | The kernel's memory of open connections. It lets later packets skip the rules |
| **NodePort** | A port (30000-32767) opened on every node for a Service |

---

# Part A: Build the Service

## Step 1: Point `kubectl` at the `mealie` namespace

**What:**
```bash
kubectl config set-context --current --namespace=mealie
kubectl get pods
```

**Output from the real session:**
```
Context "kubernetes-admin@kubernetes" modified.
NAME                      READY   STATUS    RESTARTS   AGE
mealie-6754cc7b44-dpb2q   1/1     Running   0          17h
```

**Why:** it saves typing `-n mealie` on every command. This edits your
kubeconfig **permanently**, so it stays in effect in every new terminal.

**How:** the second command has no `-n`, and it shows the Mealie pod, which
proves the default changed.

**When:** when you will work in one namespace for a while. **Remember to
switch back** (`--namespace=default`) when you finish. The saved namespace is
what put the `frontend` pods in the wrong place in Lab 7.

---

## Step 2: Expose it as a ClusterIP Service

**What:**
```bash
kubectl expose deployment mealie --port 9000
kubectl get svc
```

**Output from the real session:**
```
service/mealie exposed

NAME     TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
mealie   ClusterIP   10.98.174.14   <none>        9000/TCP   59s
```

**Why:** the Mealie pod's IP changes whenever the pod is replaced. The
Service gives it one stable address and name.

**How:**
- `TYPE ClusterIP` is the default, so it is reachable only inside the cluster.
- `EXTERNAL-IP <none>` is correct for that type (Lab 7, Step 10).
- Unlike the `frontend` mistake in Lab 7, **this one is correct without
  `--target-port`.** `expose` copies `--port` into `targetPort`, and Mealie
  really does listen on 9000, so both numbers are right.

**When:** whenever other things in the cluster need to reach a Deployment.

---

## Step 3: Reach it from your own machine with `port-forward`

**What:**
```bash
kubectl port-forward services/mealie 9000
```

**Output from the real session:**
```
Forwarding from 127.0.0.1:9000 -> 9000
Forwarding from [::1]:9000 -> 9000
Handling connection for 9000
Handling connection for 9000
...
```

Then open `http://localhost:9000` in a browser. Leave this command running
in its own terminal.

**Why:** a ClusterIP is not reachable from outside the cluster. `port-forward`
builds a temporary tunnel from a port on your machine to the app, so you can
look at it in a browser.

**How:**
- The two `Forwarding from` lines confirm the tunnel is open, on IPv4 and IPv6.
- Each `Handling connection for 9000` line is one connection. A browser opens
  several per page, which is why you see many.

**When:** for quick checks and debugging. It is **not** a way to keep an app
available, for two reasons:

- It goes through the API server as a tunnel, so it needs your `kubectl`
  running.
- When you forward to a **Service**, `kubectl` picks **one backing pod** when
  the command starts and tunnels to it. It does not spread connections across
  pods, and if that pod is replaced, the tunnel drops. Re-run the command to
  pick up the new pod. (To see this, run the forward, then
  `kubectl delete pod -n mealie -l app=mealie`. **Expected output:** the
  forward stops with an error, and re-running it works.)

Traffic from `port-forward` also does not travel over the pod's network
connection from another pod, so pod-to-pod NetworkPolicy rules from Lab 6
usually do not see it.

Stop it with `Ctrl+C` before continuing.

---

## Step 4: Save the live Service as YAML

**What:**
```bash
kubectl get svc mealie -o yaml > service.yaml
cat service.yaml
```

**Output from the real session:**
```yaml
apiVersion: v1
kind: Service
metadata:
  creationTimestamp: "2026-09-28T17:27:25Z"
  labels:
    app: mealie
  name: mealie
  namespace: mealie
  resourceVersion: "229652"
  uid: d6c7327e-c99c-4d6b-8e39-0c15490f18ed
spec:
  clusterIP: 10.98.174.14
  clusterIPs:
  - 10.98.174.14
  internalTrafficPolicy: Cluster
  ipFamilies:
  - IPv4
  ipFamilyPolicy: SingleStack
  ports:
  - port: 9000
    protocol: TCP
    targetPort: 9000
  selector:
    app: mealie
  sessionAffinity: None
  type: ClusterIP
status:
  loadBalancer: {}
```

**Why:** a file you can edit, keep in Git, and re-apply is better than typing
flags. Lab 7, Step 5 explains every field.

**How:** decide which fields **you** own and which the API server owns:

| Keep (yours) | Delete (the server fills them in) |
|---|---|
| `apiVersion`, `kind` | `creationTimestamp`, `resourceVersion`, `uid` |
| `metadata.name`, `namespace`, `labels` | `clusterIP`, `clusterIPs` |
| `spec.ports`, `spec.selector`, `spec.type` | `internalTrafficPolicy`, `ipFamilies`, `ipFamilyPolicy`, `sessionAffinity` |
| | `status` |

Deleting `clusterIP` means the next Service gets a **new** address. That is
what you will see in Step 5.

**When:** whenever you turn a hand-made resource into something repeatable.
(`kubectl-neat` from Lab 3 automates the server-field part.)

---

## Step 5: Recreate it as a LoadBalancer

**What:** edit `service.yaml` down to the fields you own and change the type:

```yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    app: mealie
  name: mealie
  namespace: mealie
spec:
  ports:
  - port: 9000
    protocol: TCP
    targetPort: 9000
  selector:
    app: mealie
  type: LoadBalancer
```

Then replace the old Service:

```bash
kubectl delete svc mealie
kubectl apply -f service.yaml
kubectl get svc
```

**Output from the real session:**
```
service "mealie" deleted
service/mealie created

NAME     TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
mealie   LoadBalancer   10.96.241.203   <pending>     9000:30315/TCP   17s
```

**Why:** to see what the LoadBalancer type does on a cluster with no cloud
provider.

**How:** compare with Step 2:

| | ClusterIP | Node port | EXTERNAL-IP |
|---|---|---|---|
| Step 2 (ClusterIP Service) | `10.98.174.14` | none | `<none>` |
| Step 5 (LoadBalancer Service) | `10.96.241.203` | `30315` | `<pending>` |

Three things to learn from that table:

1. **The ClusterIP changed.** The stable address belongs to the **Service
   object**. Delete the object and the next one gets a fresh IP. Clients
   should use the DNS name, which stays the same.
2. **A node port appeared** (`30315`) even though the YAML did not ask for
   one. The types stack: LoadBalancer includes NodePort, and the API server
   picks a free port in 30000-32767.
3. **`EXTERNAL-IP` is `<pending>`**, and that is the puzzle for Part B.

**When:** you would use `LoadBalancer` for a public entry point on a cloud, or
on bare metal with something like MetalLB (Lab 7, Step 12). Delete-and-recreate
is fine for a lab. In production, prefer `kubectl apply` with the changed file
so the Service is updated in place.

---

# Part B: Find out why it is `<pending>`

## Step 6: Ask the Service what is happening

**What:**
```bash
kubectl describe svc mealie -n mealie | grep -A3 Events
kubectl get svc mealie -n mealie -o jsonpath='{.status.loadBalancer}{"\n"}'
```

**Output from the real session:**
```
Events:                   <none>
{}
```

**Why:** `<pending>` is a status, and you want the evidence behind it, not a
guess.

**How:**
- **`Events: <none>`:** no controller has reacted to the request. On a cloud
  cluster this section would show load balancer events such as
  `EnsuringLoadBalancer` and `EnsuredLoadBalancer`.
- **`{}`:** `status.loadBalancer` is empty. That field is where a provider
  writes the load balancer's address, and `kubectl` shows it as `EXTERNAL-IP`.
  Empty field, `<pending>` column.

The story in three lines:

1. You ask for a LoadBalancer, and the API server stores the request.
2. On AKS, EKS or GKE, the **cloud controller manager** sees it, creates a
   real load balancer, and writes its address into `status`.
3. This kubeadm cluster has no cloud controller, so **nothing ever performs
   step 2**.

**When:** any time an `EXTERNAL-IP` sits at `<pending>`. Check the events
first.

---

## Step 7: Prove the Service still works

**What:** test the two doors that do exist, the ClusterIP and the node port:

```bash
kubectl run curl -n mealie --image=curlimages/curl --restart=Never -- sleep 300
kubectl wait -n mealie --for=condition=Ready pod/curl --timeout=60s
kubectl exec -n mealie curl -- curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://mealie.mealie.svc.cluster.local:9000
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30315
kubectl delete pod curl -n mealie
```

**Output from the real session:**
```
pod/curl created
pod/curl condition met
200
200
pod "curl" deleted
```

**Why:** to show that `<pending>` describes only the missing external load
balancer. The Service itself is healthy.

**How:**
- The first `200` came from a pod **inside** the cluster, through the
  Service's ClusterIP, using its full DNS name (the full name is the reliable
  one with this minimal curl image, as noted in Lab 7).
- The second `200` came from **WSL**, through the node port `30315` on
  `localhost`.

| Path | Address | Result |
|---|---|---|
| Inside the cluster | `mealie.mealie.svc.cluster.local:9000` | `200` |
| The node | `localhost:30315` | `200` |
| The load balancer | `<EXTERNAL-IP>:9000` | does not exist |

**When:** whenever you suspect a Service, test each path separately. It
tells you *which layer* is broken.

---

# Part C: Trace the request through kube-proxy

You now know the Service works. This part shows **how**, by reading the real
firewall rules on the node. Use `sudo`, and remember from Lab 6 that this node
uses the legacy iptables backend, which plain `iptables` reads.

## Step 8: Find the node-port rules

**What:**
```bash
sudo iptables -t nat -L KUBE-NODEPORTS -n | grep 30315
```

**Output from the real session:**
```
KUBE-EXT-JKNPVJ4BLSQY4T26  6  --  0.0.0.0/0  127.0.0.0/8  /* mealie/mealie */ tcp dpt:30315 nfacct-name localhost_nps_accepted_pkts
KUBE-EXT-JKNPVJ4BLSQY4T26  6  --  0.0.0.0/0  0.0.0.0/0    /* mealie/mealie */ tcp dpt:30315
```

**Why:** to see exactly which rules make port `30315` answer on the node.

**How:** read the columns as *target, protocol, source, destination, notes*.
Protocol `6` is TCP (with `-n`, iptables prints protocol numbers). Both rules
send TCP port 30315 to the **same next chain**, `KUBE-EXT-JKNPVJ4BLSQY4T26`.
They differ only in the destination they match:

| Rule | Matches | Your test |
|---|---|---|
| First | Destination in `127.0.0.0/8` (localhost). It also feeds a named kernel counter, `localhost_nps_accepted_pkts` | `curl localhost:30315` |
| Second | Any destination address | `curl 192.168.155.98:30315`, or any other local IP |

The first rule explains why `localhost` worked. It matches two lines from
this cluster's real kube-proxy log:

```
nodePortAddresses is unset; NodePort connections will be accepted on all local IPs.
Setting route_localnet=1 to allow node-ports on localhost; ...
```

**Where does `KUBE-NODEPORTS` get called?** The last rule of the main
`KUBE-SERVICES` chain (seen in Lab 7, Step 8) sends any packet addressed to a
local address on to `KUBE-NODEPORTS`. Packets addressed to anywhere else never
reach it.

**When:** when a NodePort or LoadBalancer Service does not answer on a node.
If the rule is missing, kube-proxy has not programmed the Service.

---

## Step 9: Follow the jump into `KUBE-EXT`

**What:**
```bash
sudo iptables -t nat -L KUBE-EXT-JKNPVJ4BLSQY4T26 -n
```

**Output from the real session:**
```
Chain KUBE-EXT-JKNPVJ4BLSQY4T26 (2 references)
target                      prot opt source      destination
KUBE-MARK-MASQ              0    --  0.0.0.0/0   0.0.0.0/0   /* masquerade traffic for mealie/mealie external destinations */
KUBE-SVC-JKNPVJ4BLSQY4T26   0    --  0.0.0.0/0   0.0.0.0/0
```

**Why:** to see what extra work traffic coming in through the node port gets
compared to traffic using the ClusterIP.

**How:**
- **`(2 references)`:** two rules call this chain, and those are the two rules
  from Step 8.
- **`KUBE-MARK-MASQ`:** this does not rewrite anything yet. It **stamps a
  mark** on the packet. A rule in kube-proxy's `KUBE-POSTROUTING` chain later
  sees the mark and rewrites the packet's **source** address (masquerade), so
  the pod's reply returns through this node.
- **`KUBE-SVC-JKNPVJ4BLSQY4T26`:** the chain that picks a pod. Note that this
  is the **same chain name** the ClusterIP rule uses (Step 10).

Why masquerade at all? The Service is configured with
`externalTrafficPolicy: Cluster` (Lab 7, Step 12), which allows any node to
forward to a pod on any node. Rewriting the source keeps the return path
symmetric, and the price is that **the pod sees the node's address instead of
the real client's**.

**When:** when a pod's logs show the wrong client IP, or when replies to
external clients vanish. The masquerade step is the first thing to check.

---

## Step 10: See what is missing in `KUBE-SERVICES`

**What:**
```bash
sudo iptables -t nat -L KUBE-SERVICES -n | grep mealie
```

**Output from the real session:**
```
KUBE-SVC-JKNPVJ4BLSQY4T26  6  --  0.0.0.0/0  10.96.241.203  /* mealie/mealie cluster IP */ tcp dpt:9000
```

**Why:** `KUBE-SERVICES` is where every Service address is matched, so it shows
which addresses kube-proxy knows about.

**How:** there is exactly **one** rule for `mealie`, matching the ClusterIP
`10.96.241.203` on port 9000. It jumps to the same `KUBE-SVC-JKNPVJ4BLSQY4T26`
chain as the node-port path.

**There is no rule for any external address.** That absence is `<pending>`
seen at the packet level. Here is my expectation of what would happen on a
cluster with a working load balancer: its address would appear in this chain
as a second rule for the same Service. Here, that rule was never written
because no address was ever assigned.

**When:** to check whether a Service address is actually handled. If the
ClusterIP rule is missing, kube-proxy is not running or not watching.

---

## Step 11: Watch the counters move

**What:** the `-v` flag adds packet and byte counters. Read them, send three
requests, and read them again:

```bash
sudo iptables -t nat -L KUBE-NODEPORTS -n -v | grep 30315
for i in 1 2 3; do curl -s -o /dev/null http://localhost:30315; done
sudo iptables -t nat -L KUBE-NODEPORTS -n -v | grep 30315
```

**Output from the real session** (columns trimmed to *packets, bytes, target,
destination*):

```
Before:
    1    60  KUBE-EXT-JKNPVJ4BLSQY4T26  ...  127.0.0.0/8  ... tcp dpt:30315 nfacct-name localhost_nps_accepted_pkts
    0     0  KUBE-EXT-JKNPVJ4BLSQY4T26  ...  0.0.0.0/0    ... tcp dpt:30315

After 3 curls:
    4   240  KUBE-EXT-JKNPVJ4BLSQY4T26  ...  127.0.0.0/8  ... tcp dpt:30315 nfacct-name localhost_nps_accepted_pkts
    0     0  KUBE-EXT-JKNPVJ4BLSQY4T26  ...  0.0.0.0/0    ... tcp dpt:30315
```

**Why:** counters turn the rules from a picture into evidence. You can watch
your own request use a specific rule.

**How:**

| | Before | After 3 curls |
|---|---|---|
| Localhost rule (`127.0.0.0/8`) | 1 packet, 60 bytes | 4 packets, 240 bytes |
| Any-address rule | 0 | 0 |

- **It went up by exactly 3, and 180 bytes.** Each `curl` opened one
  connection, and each connection counted one 60-byte packet.
- **Only the first packet of a connection is counted.** The `nat` table sees
  just the packet that opens a connection. The kernel's **conntrack** then
  remembers the decision, and the rest of that connection's packets skip
  these rules. A 60-byte connection-opening TCP packet is typical.
- **The starting `1`** was the localhost test from Step 7.
- **The second rule stayed at 0** because `localhost` matched the first rule,
  which ends by jumping away, so a packet never reaches the second.

**When:** to answer "is my traffic even reaching this rule?" If a counter
never moves while you test, the packet is not arriving here, and you should
look earlier (routing, another firewall, the wrong address).

---

## Step 12 (optional): Finish the trace

These three checks complete the chain. The outputs are **expected**, not
seen on this cluster:

**a) Make the second counter move by using the node's own IP:**

```bash
curl -s -o /dev/null http://192.168.155.98:30315
sudo iptables -t nat -L KUBE-NODEPORTS -n -v | grep 30315
```

**Expected output:** the second rule now shows `1` packet, and the
`127.0.0.0/8` rule stays at `4`.

**b) Follow the chain down to the pod:**

```bash
sudo iptables -t nat -L KUBE-SVC-JKNPVJ4BLSQY4T26 -n
sudo iptables -t nat -L KUBE-SEP-<name from above> -n
kubectl get pod -n mealie -o wide
```

**Expected output:** Mealie has one pod, so `KUBE-SVC` holds a single jump to
one `KUBE-SEP-...` chain, and that chain holds a **DNAT** to the pod's
address, `192.168.78.114:9000` if the pod is unchanged. Match it against the
IP in the pod list.

**c) See where the masquerade mark is used:**

```bash
sudo iptables -t nat -L KUBE-POSTROUTING -n
```

**Expected output:** a `MASQUERADE` rule that matches on the mark. That is the
second half of `KUBE-MARK-MASQ` from Step 9.

---

## The full picture, with your real chain names

```
ClusterIP path
  KUBE-SERVICES ─────────────────────────────────► KUBE-SVC-JKNPVJ4BLSQY4T26 ─► KUBE-SEP-... ─► DNAT to pod:9000

NodePort path
  KUBE-SERVICES ─► KUBE-NODEPORTS ─► KUBE-EXT-JKNPVJ4BLSQY4T26 ─► (MARK-MASQ) ─► KUBE-SVC-JKNPVJ4BLSQY4T26 ─► KUBE-SEP-... ─► DNAT to pod:9000
```

Both paths end at the **same `KUBE-SVC` chain**. The node port is an extra
door into the same room, and the `KUBE-EXT` chain is the extra step for
traffic that arrived from outside the Service's own address. After the DNAT,
the packet follows the route to the pod's veth and then meets Calico's rules
(Lab 6). **Three tools, one packet.**

---

## Command cheat table: what, why, how, when

| Command | What it does | Why you run it | How to read it | When to use it |
|---|---|---|---|---|
| `kubectl config set-context --current --namespace=X` | Saves a default namespace in kubeconfig | Save typing `-n` | Later commands act on `X` | Long work in one namespace, then **switch back** |
| `kubectl expose deployment X --port P` | Creates a Service | Give pods a stable address | `TYPE` defaults to ClusterIP | Anything needs to reach a Deployment |
| `kubectl port-forward svc/X P` | Tunnels a local port to one backing pod | Look at an app from your machine | `Forwarding from ...` means it is up | Quick debugging only |
| `kubectl get svc X -o yaml` | Dumps the live Service | Make a reusable file | Delete server-owned fields | Turning a hand-made object into YAML |
| `kubectl describe svc X` | Shows Service details and events | Find out why something is pending | `Events: <none>` means no controller acted | Any `<pending>` or missing endpoint |
| `kubectl get svc X -o jsonpath='{.status.loadBalancer}'` | Prints one field | Check whether an address exists | `{}` means none assigned | Confirming a pending LoadBalancer |
| `kubectl run curl ... -- sleep N` and `kubectl exec curl -- curl ...` | Tests from inside the cluster | Test the ClusterIP path | HTTP code, or curl exit code | Testing a Service |
| `sudo iptables -t nat -L KUBE-NODEPORTS -n` | Lists node-port rules | See which ports kube-proxy opened | Rule per node port, with a `KUBE-EXT` target | A node port does not answer |
| `sudo iptables -t nat -L KUBE-EXT-<id> -n` | Shows the outside-traffic step | See masquerade and the next hop | `KUBE-MARK-MASQ` then `KUBE-SVC-...` | Wrong client IP or lost replies |
| `sudo iptables -t nat -L KUBE-SERVICES -n \| grep X` | Lists a Service's address rules | Check the address is programmed | One rule per Service address | Service address unreachable |
| `sudo iptables -t nat -L <chain> -n -v` | Adds packet and byte counters | Prove traffic reaches a rule | Counters rising with your test | Unsure where a packet stops |

---

## A debugging order for any Service that does not answer

Work from the pods outward, and stop at the first thing that fails:

1. **Endpoints exist?** `kubectl get endpointslices -l kubernetes.io/service-name=X`. If empty: the selector and pod labels disagree, or the pods are not Ready, or they are in another namespace.
2. **Right `targetPort`?** `kubectl get svc X -o jsonpath='{.spec.ports[0]}'`. Connection refused (curl exit 7) usually means a wrong port.
3. **Does DNS resolve?** Use the full name `X.<namespace>.svc.cluster.local` from a test pod.
4. **Does the ClusterIP path work from a pod?** If yes, the Service is healthy.
5. **Does the node port work on the node?** `curl localhost:<nodePort>`. If not, look at `KUBE-NODEPORTS` (Step 8).
6. **Is a NetworkPolicy dropping it?** A timeout (curl exit 28) points here (Lab 6).
7. **Is `EXTERNAL-IP` pending?** Expected on this cluster. Use the ClusterIP or node port.

---

## Common Mix-ups

| Common belief | What is actually true |
|---|---|
| "`<pending>` means the Service is broken" | It means nobody answered the load balancer request. The ClusterIP and node port still work (Step 7) |
| "The Service's IP never changes" | It is stable **while the Service object exists**. Delete and recreate it and you get a new one (Step 5) |
| "`port-forward` to a Service load-balances and survives restarts" | It tunnels to **one** pod chosen at start. If that pod is replaced, re-run it (Step 3) |
| "A LoadBalancer Service has no node port" | It gets one. The types stack (Step 5) |
| "Every packet passes through these iptables rules" | Only the **first packet** of a connection does. conntrack handles the rest (Step 11) |
| "`localhost` should not reach a node port" | On this cluster it does, because of `route_localnet` (Step 8) |
| "Masquerading is harmless" | It hides the client's real IP from the pod (Step 9) |

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `EXTERNAL-IP <pending>` for minutes | No load balancer provider (this cluster) | Step 6 confirms it. Use the node port, or add MetalLB |
| `curl localhost:<nodePort>` refused | The Service's `targetPort` is wrong, or no ready pods | Debugging order, steps 1 and 2 |
| No rule for the node port in `KUBE-NODEPORTS` | kube-proxy not programming it | `kubectl get pods -n kube-system -l k8s-app=kube-proxy`, then its logs |
| `iptables -L` shows no `KUBE-*` chains | Wrong table or backend | Add `-t nat`, and use the legacy backend (Lab 6) |
| Counters never move while you test | The packet is not reaching this rule | Check the address you are using and the routes |
| New pods stuck in `ContainerCreating` | Stale Calico token after long uptime | Lab 4, cycle `calico-node` |
| `port-forward` dropped | The pod it chose was replaced | Re-run it |

---

## Clean up

```bash
kubectl delete svc mealie -n mealie
kubectl config set-context --current --namespace=default
kubectl get pods -n mealie
```

The Mealie pod stays. Only the Service is removed. Recreate a plain ClusterIP
Service with Step 2 whenever you want one back.

---

## Key Takeaways

1. **`<pending>` is a status, not a fault.** Nothing on this cluster answers load balancer requests, so `status.loadBalancer` stays empty. `Events: <none>` and `{}` prove it.
2. **The Service still works through its other doors:** the ClusterIP and the node port. The types stack.
3. **The stable address belongs to the Service object.** Recreate the object and the ClusterIP and node port change.
4. **kube-proxy is the engine.** It writes iptables rules in the `nat` table, and those rules are the entire mechanism.
5. **Two doors, one room.** ClusterIP and NodePort traffic both end in the same `KUBE-SVC` chain, which picks a pod.
6. **The node-port path adds a masquerade mark.** That keeps replies flowing back through the node, and it hides the real client IP from the pod.
7. **The absence of an external-address rule in `KUBE-SERVICES` is `<pending>` at the packet level.**
8. **Counters give you proof.** Three requests moved the localhost rule from 1 packet to 4, because only a connection's first packet is counted.
9. **`kubectl port-forward` tunnels to one pod.** It is for debugging, not for keeping an app reachable.
10. **Debug from the pods outward:** endpoints, `targetPort`, DNS, the ClusterIP, the node port, then policy.

---

## Command Reference

```bash
# Build the Service
kubectl expose deployment mealie --port 9000 -n mealie
kubectl get svc -n mealie
kubectl port-forward services/mealie 9000 -n mealie
kubectl get svc mealie -n mealie -o yaml > service.yaml

# Diagnose a pending LoadBalancer
kubectl describe svc mealie -n mealie | grep -A3 Events
kubectl get svc mealie -n mealie -o jsonpath='{.status.loadBalancer}{"\n"}'

# Test each door
kubectl run curl -n mealie --image=curlimages/curl --restart=Never -- sleep 300
kubectl exec -n mealie curl -- curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://mealie.mealie.svc.cluster.local:9000
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:<nodePort>

# Trace the rules
sudo iptables -t nat -L KUBE-NODEPORTS -n | grep <nodePort>
sudo iptables -t nat -L KUBE-EXT-<id> -n
sudo iptables -t nat -L KUBE-SERVICES -n | grep mealie
sudo iptables -t nat -L KUBE-NODEPORTS -n -v | grep <nodePort>
sudo iptables -t nat -L KUBE-SVC-<id> -n
sudo iptables -t nat -L KUBE-SEP-<id> -n
sudo iptables -t nat -L KUBE-POSTROUTING -n

# Tidy up
kubectl delete svc mealie -n mealie
kubectl config set-context --current --namespace=default
```
