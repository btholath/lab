# Lab 6: How Calico Enforces Network Policy

**Goal:** understand what actually happens on a node when you create a
Kubernetes `NetworkPolicy`. You will read the real firewall rules Calico has
already written on your cluster, then run a small experiment that adds a
policy and watches those rules change.

**Time:** about 45 minutes.

**How this lab is organized**

- **Part 1** only *reads* your cluster. The outputs there are from the real
  session (trimmed for readability). Nothing changes.
- **Part 2** is an experiment. It runs in its own scratch namespace,
  `netlab`, so `mealie` and everything else stays untouched. Outputs in
  Part 2 are labeled **Expected output**, because they describe standard
  behavior that you should confirm on your own cluster.

This lab builds on Lab 4 (what `calico-node` is) and on the networking mind
map (`k8s-networking-mindmap.jpeg`, Network policies branch).

**Before you start:**

```bash
kubectl get nodes
kubectl config view --minify | grep namespace:
```

The node should be `Ready`. If the second command prints `namespace: mealie`,
that is your saved default from Lab 5. Every command in Part 2 passes `-n`
explicitly, so it does not matter, but keep it in mind.

---

## The Big Idea

A `NetworkPolicy` is just an **object stored in the Kubernetes API**. Nothing
in core Kubernetes reads it and blocks a single packet. Something else has
to turn the object into real firewall rules:

> **The CNI plugin's policy engine enforces it.** On your cluster that is
> **Felix**, the agent inside the `calico-node` pod.

Two consequences follow, and both matter for real clusters and for KCSA:

1. **The API accepts a NetworkPolicy even if the network can't enforce it.**
   With a CNI that has no policy support, the object is stored and silently
   does nothing. It looks protected and isn't.
2. **The rules live on each node, not in the API.** To see what is really
   enforced, look at the node's iptables, which is what Part 1 does.

Using the harbor picture from the explainer doc: the policy is a rule posted
in the harbor office ("only trucks from company X may deliver to dock 5"),
and Felix is the gate guard at each crate's door who reads the posted rules
and checks every arriving and departing package.

---

# Part 1: Read the rules already on your cluster

## Step 1: Where Felix plugs in

Pod traffic is routed through the node (you saw the per-pod `/32` routes in
the CNI lab), so it passes through the kernel's **FORWARD** hook. Calico
attaches its own chains there:

```
iptables INPUT / FORWARD / OUTPUT
        │
        ▼
cali-INPUT / cali-FORWARD / cali-OUTPUT      ← Calico's entry points
        │
cali-FORWARD
   ├─ cali-from-wl-dispatch  ──►  cali-fw-<veth>   checks for the pod SENDING
   └─ cali-to-wl-dispatch    ──►  cali-tw-<veth>   checks for the pod RECEIVING
```

Confirm the entry points exist:

```bash
sudo iptables -L -n | grep -E "^Chain cali-(INPUT|FORWARD|OUTPUT)"
```

**Output from the real session** (the same names appear in your full dump):
```
Chain cali-FORWARD (1 references)
Chain cali-INPUT (1 references)
Chain cali-OUTPUT (1 references)
```

> **Tip:** if that command prints nothing, you are looking at the wrong
> iptables backend. Your node uses the *legacy* backend (the
> `update-alternatives` output earlier in this series showed
> `iptables-legacy`), and Calico's chains are there. Plain `iptables -L`
> reads it.

The dispatch chains pick the right per-pod chain from the pod's **veth
name**. Your 10 pods with a veth each have 10 `cali-fw-` chains and 10
`cali-tw-` chains. Pods on the host network (etcd, kube-proxy, calico-node
and so on) have no veth, so they have no chains.

## Step 2: Decode the chain names

The names look cryptic, but they follow a small vocabulary:

| Name piece | Meaning |
|---|---|
| `wl` | workload, meaning a pod |
| `cali-fw-<veth>` | **f**rom **w**orkload: traffic *leaving* that pod (its egress) |
| `cali-tw-<veth>` | **t**o **w**orkload: traffic *arriving* at that pod (its ingress) |
| `cali-pi-<hash>` | **p**olicy **i**nbound: the ingress rules of one policy |
| `cali-po-<hash>` | **p**olicy **o**utbound: the egress rules of one policy |
| `cali-pri-<name>` | **pr**ofile **i**nbound (a fallback rule set) |
| `cali-pro-<name>` | **pr**ofile **o**utbound |
| `kns.<namespace>` | the namespace's profile |
| `ksa.<namespace>.<serviceaccount>` | the service account's profile |
| `knp.default.<name>` | a **K**ubernetes **N**etwork**P**olicy, translated into Calico's `default` tier |

The `<hash>` in a policy chain name is a shortened form of the policy's
name, because iptables limits chain-name length.

## Step 3: A pod with NO policy (mealie)

First find mealie's veth from its IP:

```bash
POD_IP=$(kubectl get pod -n mealie -l app=mealie -o jsonpath='{.items[0].status.podIP}')
ip route | grep "$POD_IP"
```

**Output from the real session:**
```
192.168.78.114 dev calif28f6243a23 scope link
```

Now read the chain for traffic *arriving* at mealie:

```bash
sudo iptables -L cali-tw-calif28f6243a23 -n
```

**Output from the real session** (comments trimmed):
```
Chain cali-tw-calif28f6243a23 (1 references)
ACCEPT     ctstate RELATED,ESTABLISHED
DROP       ctstate INVALID
MARK       MARK and 0xfffcffff
cali-pri-kns.mealie
RETURN     /* Return if profile accepted */ mark match 0x10000/0x10000
cali-pri-ksa.mealie.default
RETURN     /* Return if profile accepted */ mark match 0x10000/0x10000
NFLOG      nflog-prefix DRI nflog-group 1 nflog-size 80
DROP       /* Drop if no profiles matched */
```

Read it top to bottom, the way the kernel does:

1. **`ACCEPT ... RELATED,ESTABLISHED`**: replies to connections that already
   exist are always allowed. Calico is *stateful*.
2. **`DROP ... INVALID`**: malformed or out-of-state packets are dropped.
3. **`MARK and 0xfffcffff`**: clear Calico's decision flags so this packet
   starts undecided.
4. **`cali-pri-kns.mealie`**: jump to the namespace profile, which decides.
5. **`RETURN if ... mark match 0x10000`**: if the packet has been marked
   *accepted*, stop and let it through.
6. Otherwise try the service account profile, then log (`NFLOG`) and
   **`DROP`** if nothing accepted it.

So who accepts mealie's traffic? Look at the namespace profile:

```bash
sudo iptables -L cali-pri-kns.mealie -n
```

**Output from the real session:**
```
Chain cali-pri-kns.mealie (1 references)
MARK       /* Profile kns.mealie ingress */ MARK or 0x10000
NFLOG      mark match 0x10000/0x10000 nflog-prefix "ARI0|kns.mealie"
```

**This is the whole reason your cluster is "allow-all".** The namespace
profile has one rule: set the *accepted* flag (`MARK or 0x10000`). Every
packet gets that flag, so step 5 returns it to the caller. The four
namespace profiles (`kns.default`, `kns.kube-system`, `kns.mealie`,
`kns.calico-system`) all work this way. Nothing here is a bug. It is
Kubernetes' documented default: **a pod that no policy selects accepts all
traffic.**

## Step 4: A pod WITH a policy (calico-apiserver)

The `calico-apiserver` pods are selected by a real NetworkPolicy,
`allow-apiserver`, which you inspected in the setup guide. Their chain looks
different:

```bash
sudo iptables -L cali-tw-cali5c14023033c -n
```

**Output from the real session** (comments trimmed):
```
Chain cali-tw-cali5c14023033c (1 references)
ACCEPT     ctstate RELATED,ESTABLISHED
DROP       ctstate INVALID
MARK       MARK and 0xfffcffff
MARK       /* Start of tier default */ MARK and 0xfffdffff
cali-pi-_RPHPUh868v26JJg7645     mark match 0x0/0x20000
RETURN     /* Return if policy accepted */ mark match 0x10000/0x10000
NFLOG      mark match 0x0/0x20000 nflog-prefix "DPI|default"
DROP       /* End of tier default. Drop if no policies passed packet */ mark match 0x0/0x20000
cali-pri-kns.calico-system
...
```

The new part is the block between `Start of tier default` and `End of tier
default`. That block exists **only for pods some policy selects.** Read it
as:

1. Run the policy chain `cali-pi-_RPHPUh...`.
2. If the policy accepted the packet, `RETURN` (allowed).
3. If not, log it and **`DROP`** at `End of tier default`.

Notice the drop happens *before* the namespace profile is ever consulted.
That is how one selecting policy flips a pod from "allow everything" to
"allow only what is listed."

(There is a second flag, `0x20000`, that Calico uses for policies that hand a
decision on to a later tier. Kubernetes NetworkPolicy never does that, so you
can ignore it here.)

Now read the policy's own chain:

```bash
sudo iptables -L cali-pi-_RPHPUh868v26JJg7645 -n
```

**Output from the real session:**
```
Chain cali-pi-_RPHPUh868v26JJg7645 (2 references)
MARK   6   /* Policy calico-system/knp.default.allow-apiserver ingress */ multiport dports 5443 MARK or 0x10000
NFLOG      mark match 0x10000/0x10000 nflog-prefix "API0|calico-system/knp.default.allow-apiserver"
```

This one rule is the whole policy: **TCP to port 5443 gets the accepted
flag.** (With `-n`, iptables prints protocol *numbers*, and `6` is TCP.)
Anything else reaches `End of tier default` unflagged and is dropped.
`(2 references)` means two other chains call this one, one for each of your
two `calico-apiserver` pods.

## Step 5: The policies on your cluster, side by side

Three policies exist in `calico-system`. Here is what each does, read from
the dump:

| Policy | Pods it selects | Effect in iptables |
|---|---|---|
| `allow-apiserver` | `calico-apiserver` (two pods) | Ingress: TCP 5443 only |
| `goldmane` | `goldmane` | Ingress: TCP 7443 only |
| `whisker` | `whisker` | Ingress: nothing allowed. Egress: TCP 7443 to one address set, port 53 (DNS) to another |

The `whisker` ingress chain is the most instructive one:

```
Chain cali-pi-_YYnSgB46MA1TYU44kJq (1 references)
           /* Policy calico-system/knp.default.whisker ingress */
```

A single rule with **no action at all** (only a comment). Nothing in it can
set the accepted flag, so nothing gets in, and every packet falls through to
`End of tier default` and is dropped. That is what an **empty ingress list**
looks like on the wire. Its egress chain, by contrast, sets the accepted flag
only for the two allowed destinations.

Also note the `match-set cali40s:...` pieces in the egress rules. Those are
**ipsets**, which Part 2 explains.

## Step 6: See the same policies the way Calico stores them

Your cluster runs the Calico API server, so Calico's own resources are
visible to `kubectl`:

```bash
kubectl get networkpolicies.projectcalico.org -n calico-system
```

**Expected output** (the column headings may differ; the names are what
matter, and they follow the `knp.default.<name>` pattern from Step 2):
```
NAME                          CREATED AT
knp.default.allow-apiserver   ...
knp.default.goldmane          ...
knp.default.whisker           ...
```

Each Kubernetes policy has a translated twin. Felix watches those and
rewrites the chains you just read whenever one changes.

---

# Part 2: Watch a policy change the rules

## Step 7: Build a scratch namespace

```bash
kubectl create namespace netlab
kubectl create deployment web --image=nginx -n netlab
kubectl expose deployment web --port=80 -n netlab
kubectl run client-a -n netlab --image=curlimages/curl --labels=role=trusted --restart=Never -- sleep 3600
kubectl run client-b -n netlab --image=curlimages/curl --labels=role=other   --restart=Never -- sleep 3600
kubectl wait -n netlab --for=condition=Ready pod --all --timeout=90s
```

**Expected output:**
```
namespace/netlab created
deployment.apps/web created
service/web exposed
pod/client-a created
pod/client-b created
pod/web-xxxxxxxxxx-xxxxx condition met
pod/client-a condition met
pod/client-b condition met
```

You now have one web server and two clients that differ only by a label:
`client-a` is `role=trusted`, `client-b` is `role=other`.

> If the pods stay in `ContainerCreating` for many minutes, that is the
> stale-token problem from Lab 4. Check `kubectl describe pod` first.

## Step 8: Baseline. Everyone can reach the web server

```bash
for c in client-a client-b; do
  echo -n "$c: "
  kubectl exec -n netlab $c -- curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://web.netlab.svc.cluster.local
done
```

**Expected output:**
```
client-a: 200
client-b: 200
```

(The full `web.netlab.svc.cluster.local` name is used on purpose. Short names
can fail with this minimal curl image, as noted in the setup guide.)

The Service address gets translated to the web pod's IP by kube-proxy
first, and Calico's rules are then checked against the pod IP.

## Step 9: Look at the web pod's chain before any policy

Set two shell variables you will reuse:

```bash
WEB_IP=$(kubectl get pod -n netlab -l app=web -o jsonpath='{.items[0].status.podIP}')
VETH=$(ip route | awk -v ip="$WEB_IP" '$1==ip {print $3}')
echo "$WEB_IP  $VETH"
```

**Expected output** (yours will differ):
```
192.168.78.120  cali1a2b3c4d5e6
```

Count the "tier" lines in its ingress chain:

```bash
sudo iptables -L cali-tw-$VETH -n | grep -ci tier
```

**Expected output:**
```
0
```

Zero, just like mealie in Step 3: no policy selects this pod, so there is no
tier section.

## Step 10: Apply a default-deny policy

This is the most common security starting point: select every pod in the
namespace and allow nothing in.

```bash
kubectl apply -n netlab -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
  - Ingress
EOF
```

**Expected output:**
```
networkpolicy.networking.k8s.io/default-deny-ingress created
```

- `podSelector: {}` selects **every pod in this namespace**
- `policyTypes: [Ingress]` controls incoming traffic
- There is no `ingress:` list, so **nothing is allowed in**

Wait two or three seconds for Felix to react, then repeat the test from
Step 8:

```bash
for c in client-a client-b; do
  echo -n "$c: "
  kubectl exec -n netlab $c -- curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://web.netlab.svc.cluster.local
done
```

**Expected output:**
```
client-a: 000
command terminated with exit code 28
client-b: 000
command terminated with exit code 28
```

`000` means no HTTP response arrived, and exit code 28 is curl's *timeout*.

**Timeout, not "connection refused", is the signature of a NetworkPolicy
drop.** Calico uses `DROP`, which discards packets silently, so the sender
just waits. A quick "connection refused" (curl exit code 7) would instead
mean the packet *reached* the pod and nothing was listening.

Now confirm the rule change on the node:

```bash
sudo iptables -L cali-tw-$VETH -n | grep -i tier
```

**Expected output:**
```
MARK  /* Start of tier default */ MARK and 0xfffdffff
DROP  /* End of tier default. Drop if no policies passed packet */ mark match 0x0/0x20000
```

Compare with Step 9: the tier section now exists, exactly as it did for
`calico-apiserver` in Step 4. Find the policy's chain and look inside it:

```bash
POLCHAIN=$(sudo iptables -L cali-tw-$VETH -n | awk '/cali-pi-/ {print $1; exit}')
sudo iptables -L "$POLCHAIN" -n
```

**Expected output** (the same shape as `whisker`'s empty ingress in Step 5):
```
Chain cali-pi-_xxxxxxxxxxxxxxxxxxxx (1 references)
           /* Policy netlab/knp.default.default-deny-ingress ingress */
```

A rule with no action, so nothing sets the accepted flag. That is what
"deny all ingress" looks like as iptables.

## Step 11: Add an allow rule for trusted clients only

```bash
kubectl apply -n netlab -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-trusted-to-web
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: trusted
    ports:
    - protocol: TCP
      port: 80
EOF
```

**Expected output:**
```
networkpolicy.networking.k8s.io/allow-trusted-to-web created
```

Reading it: *select the pods labeled `app=web`; allow ingress only from pods
labeled `role=trusted`, only on TCP port 80.* Test both clients again:

```bash
for c in client-a client-b; do
  echo -n "$c: "
  kubectl exec -n netlab $c -- curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://web.netlab.svc.cluster.local
done
```

**Expected output:**
```
client-a: 200
client-b: 000
command terminated with exit code 28
```

Same web server, same port, and the only difference is a label. Now look at
how the selector was translated:

```bash
sudo iptables -L cali-tw-$VETH -n | grep cali-pi-
```

The web pod's chain now calls **two** policy chains. Open the new one, the
one that is not the empty deny chain:

```bash
sudo iptables -L <the-other-cali-pi-chain> -n
```

**Expected output:**
```
Chain cali-pi-_yyyyyyyyyyyyyyyyyyyy (1 references)
MARK  6  /* Policy netlab/knp.default.allow-trusted-to-web ingress */ match-set cali40s:AAAA... src multiport dports 80 MARK or 0x10000
```

The important piece is **`match-set cali40s:...  src`**. The selector
`role=trusted` did not become a list of IPs written into the rule. It became
a reference to an **ipset**, a kernel-maintained collection of addresses.

## Step 12: Watch the ipset update on its own

List the ipsets Felix keeps (install the viewer first if needed, because
Calico itself does not require it):

```bash
sudo apt install -y ipset
sudo ipset list | grep -A8 "^Name: cali40s"
```

**Expected output:** several sets, and one whose `Members:` contains
`client-a`'s pod IP and nobody else. Find `client-a`'s IP with
`kubectl get pod client-a -n netlab -o wide` to match it.

Why sets? Pods come and go constantly, and their IPs change. If every
selector were baked into iptables rules, every pod start or stop would force
Felix to rewrite chains. With an ipset, **the rule never changes.** Felix
just adds and removes addresses from the set as matching pods appear and
disappear.

Prove it. Give `client-b` the trusted label, without touching either policy:

```bash
kubectl label pod client-b -n netlab role=trusted --overwrite
sleep 3
kubectl exec -n netlab client-b -- curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://web.netlab.svc.cluster.local
```

**Expected output:**
```
pod/client-b labeled
200
```

`client-b` is now allowed. The `ipset list` output will show a second member
in that set. Put it back:

```bash
kubectl label pod client-b -n netlab role=other --overwrite
```

After a few seconds `client-b` is blocked again. This is the practical
meaning of "policy follows labels, not IPs."

## Step 13: Direction and state — what a deny does NOT block

Both policies above only control **ingress**. Check that the blocked client
can still talk *out*, and that the answers can come back:

```bash
kubectl exec -n netlab client-b -- curl -sk -m 5 -o /dev/null -w "%{http_code}\n" https://kubernetes.default.svc.cluster.local/healthz
```

**Expected output:**
```
200
```

(This is the same `/healthz` check you ran from a pod in the setup guide.
Any HTTP answer at all proves the request went out and the reply came
back.)

This is worth pausing on. `default-deny-ingress` selects `client-b` too, so
*ingress* to `client-b` is denied. Yet the API server's reply is a packet
arriving *at* `client-b`. It got through because of the first rule in every
chain from Steps 3 and 4:

```
ACCEPT  ctstate RELATED,ESTABLISHED
```

Replies to connections the pod itself started are always allowed. A
NetworkPolicy blocks *new connections in the denied direction*, not answers
to connections you opened.

## Step 14: Things a NetworkPolicy does not see (try them)

Two behaviors are commonly reported and worth confirming yourself:

```bash
kubectl port-forward -n netlab deploy/web 8081:80
```

In another terminal:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081
```

**Expected output:** `200`, even while the default-deny policy is active.
`kubectl port-forward` reaches the pod through the container runtime, not
over the pod's veth from another pod, so the pod-to-pod rules do not see it.
Stop the port-forward with `Ctrl+C`.

Also remember that **pods on the host network have no veth** (etcd,
kube-proxy, calico-node and the rest), so pod-level policy does not
apply to them the way it does to normal pods.

## Step 15: Clean up

```bash
kubectl delete namespace netlab
```

**Expected output:**
```
namespace "netlab" deleted
```

Deleting the namespace removes the pods and both policies. After a few
seconds Felix removes the web pod's chains too, which you can confirm:

```bash
sudo iptables -L -n | grep -c "cali-tw-$VETH"
```

**Expected output:**
```
0
```

The rules on the node exist only as long as the pod and policy exist,
because Felix keeps them synchronized in both directions.

---

## What Felix is doing, in one picture

```
kubectl apply  NetworkPolicy
        │
        ▼
 Kubernetes API  ──►  Calico translates to  knp.default.<name>
        │
        ▼   (Felix watches for changes)
 Felix in calico-node, on each node:
   1. builds cali-pi-* / cali-po-*  chains from the rules
   2. builds cali40s:* ipsets from the selectors (pod labels → IPs)
   3. adds "Start / End of tier default" to each selected pod's
      cali-tw-* and cali-fw-* chains
   4. keeps ipset members current as pods start, stop, or change labels
```

---

## Troubleshooting

| Symptom | Likely cause | What to check |
|---|---|---|
| Policy created but traffic still flows | The CNI does not enforce policy, or the policy selects the wrong pods | `kubectl get pod -n <ns> --show-labels` against your `podSelector`. On a CNI without policy support, no fix applies. The object is silently ignored |
| Policy applied in the wrong namespace | `NetworkPolicy` is **namespaced**. It only protects pods in its own namespace | Add `-n <ns>` and `kubectl get netpol -A` |
| Everything, including DNS, breaks after adding an **egress** policy | Egress was restricted, so the pod can no longer reach CoreDNS | Allow egress to port 53 (TCP and UDP). `whisker`'s real policy does exactly this, so use it as the model |
| `curl` hangs then prints `000` | Packets are being dropped | This is the normal signature of a policy drop. A fast refusal means the pod was reached instead |
| `sudo iptables -L -n \| grep cali` prints nothing | Wrong backend | Use `iptables-legacy`, or check `update-alternatives --display iptables` |
| `ipset: command not found` | The viewer is not installed | `sudo apt install -y ipset`. Calico does not need it to work, only for you to look |
| New pods stuck in `ContainerCreating` while doing this lab | Stale CNI token (`Unauthorized`) | Lab 4: cycle `calico-node` |

---

## Key Takeaways

1. **A NetworkPolicy is only an API object.** The CNI (Felix, for Calico) turns it into real rules on every node. A CNI that can't enforce policy stores it and ignores it.
2. **No policy means allow-all.** Mealie's namespace profile marks every packet as accepted.
3. **One selecting policy flips the pod to an allow-list.** The pod's chain gains a tier section that ends in `DROP`, and only what some policy allows gets the accepted flag.
4. **The accepted flag (`0x10000`) is the whole decision.** Rules set it, and later rules test it.
5. **`cali-tw-` guards traffic to a pod, `cali-fw-` guards traffic from it.** `pi`/`po` chains are a policy's ingress and egress rules.
6. **Selectors become ipsets.** Rules stay fixed while Felix adds and removes addresses as labels and pods change.
7. **Policies drop, they don't reject.** Blocked traffic shows up as a timeout, and a fast "connection refused" means the pod was reached.
8. **Replies are always allowed.** A denied direction blocks new connections, not answers to connections the pod opened.
9. **Start from default-deny and add allows.** It is the standard hardening pattern, and it is only a few lines of YAML.

---

## Command Reference

```bash
# Find a pod's veth
ip route | grep <pod-ip>

# Read Calico's chains
sudo iptables -L -n | grep cali
sudo iptables -L cali-tw-<veth> -n          # traffic TO the pod
sudo iptables -L cali-fw-<veth> -n          # traffic FROM the pod
sudo iptables -L cali-tw-<veth> -n -v       # with packet counters
sudo iptables -L cali-pi-<hash> -n          # one policy's ingress rules

# See the ipsets behind selectors
sudo apt install -y ipset
sudo ipset list | grep -A8 "^Name: cali40s"

# Policies
kubectl get networkpolicy -A
kubectl describe networkpolicy <name> -n <ns>
kubectl get networkpolicies.projectcalico.org -A

# Labels drive selectors
kubectl get pod -n <ns> --show-labels
kubectl label pod <pod> -n <ns> <key>=<value> --overwrite

# Default-deny ingress for a namespace
kubectl apply -n <ns> -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
  - Ingress
EOF
```
