# ExternalIP in Kubernetes — Nodes and Services, Explained in Detail

**Why this doc exists:** across this whole series, `<none>` and `<pending>`
kept showing up in the `EXTERNAL-IP` column — on `kubectl get nodes -o
wide`, on `kubectl get svc`, on both the kubeadm cluster and a local Kind
cluster. This is one concept with two slightly different faces (Node
ExternalIP vs. Service EXTERNAL-IP), and both come down to the same root
cause: **nothing provisioned one, because nothing is watching for the
request.**

**Clusters referenced below:**
- A kubeadm cluster (`b`, single node, Kubernetes v1.35.6, Calico CNI, WSL2)
- A local Kind cluster (`btlabs-k8s`, three nodes, Kubernetes v1.32.0, Docker-backed)

---

## Part 1: ExternalIP on a Node

### What the field is

Every Node object has an `Addresses` list, and each entry has a `type`:

| Type | Always present? | Populated by |
|---|---|---|
| `Hostname` | Yes | kubelet, from the node's own hostname |
| `InternalIP` | Yes | kubelet, the address the node is reachable at *within* the cluster's network |
| `ExternalIP` | **No — optional** | A **cloud provider integration**, specifically the **cloud controller manager** |

`InternalIP` and `Hostname` are set unconditionally by kubelet when a node
registers. `ExternalIP` is different: it only gets populated when something
*else* — a controller with knowledge of the node's real-world network
position — writes it in.

### What actually showed up on each cluster

**Kind worker node** (`btlabs-k8s-worker2`):
```
Addresses:
  InternalIP:  172.18.0.5
  Hostname:    btlabs-k8s-worker2
```
`172.18.0.5` is a **Docker bridge network address**. Confirmed by:
```
ProviderID: kind://docker/btlabs-k8s/btlabs-k8s-worker2
```
A Kind "node" is, underneath, just a Docker container. Its `InternalIP` is
whatever address Docker's own bridge network assigned it — there is no
real, separate physical or virtual machine behind it with its own public
address.

**kubeadm node** (`b`):
```bash
kubectl get nodes -o wide
```
```
NAME   INTERNAL-IP      EXTERNAL-IP
b      192.168.155.98   <none>
```
`192.168.155.98` is this WSL2 VM's own network address (the same one
used as the `kubeadm init --apiserver-advertise-address` throughout the
Setup Guide). `EXTERNAL-IP` is `<none>` for the exact same structural
reason as the Kind node: **nothing is running that would populate it.**

### Why no cloud controller manager exists on either cluster

The **cloud controller manager (CCM)** is the component that bridges
Kubernetes to a specific cloud provider's APIs. On AKS/EKS/GKE, the CCM:
- Watches each `Node` object
- Asks the cloud provider "what is this instance's public/external IP?"
- Writes that address into the Node's `status.addresses` as `ExternalIP`

Neither a plain kubeadm cluster nor a local Kind cluster runs a CCM, because
neither is backed by an actual cloud provider's compute API — there's
nothing to *ask*. A WSL2 VM and a Docker container both have no public IP
address of their own to report in the first place, even if something were
asking.

**This is structurally the same gap** that caused `LoadBalancer` Services
to show `EXTERNAL-IP <pending>` throughout Labs 7, 8, and 11 — a
`Service`'s `EXTERNAL-IP` and a `Node`'s `ExternalIP` are populated by
*related* mechanisms (cloud-provider integration), just acting on different
object kinds.

### Checking it yourself

```bash
kubectl get nodes -o wide
kubectl describe node <node-name> | grep -A3 Addresses:
```

**Expected on any self-managed cluster** (kubeadm, Kind, k3s without
additional setup, Minikube): `ExternalIP` absent from the `Addresses:`
block entirely, or shown as `<none>` in the `-o wide` table.

**Where you *would* see it populated:** any managed Kubernetes offering
(EKS, GKE, AKS) — run the same `describe node` command there and expect to
see a real `ExternalIP` entry matching the cloud instance's public or
NAT-mapped address.

---

## Part 2: EXTERNAL-IP on a Service — the related-but-different case

This is the one already covered in depth in Lab 7 and Lab 8, summarized
here for direct comparison against the Node case above.

### The three Service types and their EXTERNAL-IP behavior

| Type | EXTERNAL-IP column shows |
|---|---|
| `ClusterIP` | `<none>` — correct and permanent; this type is never meant to have one |
| `NodePort` | `<none>` — also correct; reachability is via `<node-ip>:<nodePort>` instead |
| `LoadBalancer` | A real IP, **if** something fulfills the request — otherwise `<pending>` forever |

### What actually fulfills a LoadBalancer request

Same cast of characters as Part 1, applied to Services instead of Nodes:

- **On a real cloud cluster**: the cloud controller manager sees a
  `type: LoadBalancer` Service, calls the cloud's load-balancer API (an
  Azure LB, an AWS NLB/ELB, a Google Cloud LB), and writes the resulting
  address into `status.loadBalancer.ingress[0].ip` — which `kubectl`
  displays as `EXTERNAL-IP`.
- **On this kubeadm cluster**: confirmed directly in Lab 8 —
  `kubectl describe svc mealie` showed `Events: <none>` and
  `status.loadBalancer: {}`. No controller ever reacted to the request at
  all.
- **On Docker Desktop's Kubernetes**: genuinely different — Docker Desktop
  runs its own `cloud-provider-kind` container (confirmed directly via
  `docker ps -a` showing `docker/desktop-cloud-provider-kind:v0.6.0`),
  which *does* implement this mechanism for Kind-based clusters. A
  `LoadBalancer` Service there would likely get a real, usable address
  instead of sitting `<pending>`.
- **On a plain Kind cluster** (not Docker Desktop's), with no
  `cloud-provider-kind` running: same `<pending>` outcome as kubeadm,
  unless that tool is installed separately.

### Quick cross-reference of every `<pending>`/`<none>` moment in this series

| Where | Object | Field | Why |
|---|---|---|---|
| Lab 7, Step 10 | `frontend` Service (ClusterIP) | `EXTERNAL-IP: <none>` | Correct by design — not meant to have one |
| Lab 7, Step 12 | `mealie` Service (LoadBalancer) | `EXTERNAL-IP: <pending>` | No cloud controller manager on this cluster |
| Lab 8 | Same `mealie` Service | `status.loadBalancer: {}`, `Events: <none>` | Direct proof nothing ever tried to fulfill it |
| Lab 10 | PVC `mealie-data` | `STATUS: Pending` | Same *shape* of problem, different subsystem — no StorageClass/provisioner, not a networking issue at all, but worth recognizing as the same pattern: **a request with nothing watching to fulfill it** |
| This doc | `b` node (kubeadm) | `EXTERNAL-IP: <none>` | No cloud controller manager to query a real-world address |
| This doc | `btlabs-k8s-worker2` (Kind) | `EXTERNAL-IP: <none>` | Same — a Docker container has no "external" address to report |

**The pattern worth internalizing:** Kubernetes is full of objects that
represent a *request* or a *placeholder for something an external system
should fill in* — a Service's external address, a Node's external address,
a PVC's bound volume. On a fully self-managed cluster with no cloud
integration and no storage provisioner, **all of these stay empty**, and
that's not breakage — it's Kubernetes correctly reporting "I'm still
waiting for something to answer this."

---

## Part 3: How to Actually Get a Populated ExternalIP, If You Need One

### For a Node

Manually adding an `ExternalIP` to a Node is possible but rarely done by
hand in practice — it's meant to be managed by a CCM. If you genuinely
needed to set one manually (e.g., for a bare-metal cluster where you know
the real public IP), it's done via `kubectl patch`:

```bash
kubectl patch node <node-name> --subresource=status --type=merge \
  -p '{"status":{"addresses":[{"type":"ExternalIP","address":"<your-ip>"}]}}'
```

⚠️ This is a manual override, not a real integration — if the node is ever
re-registered (e.g., `kubeadm reset` + rejoin), this patched value is lost
and must be reapplied. Not recommended outside of very specific bare-metal
setups with their own external IP management.

### For a Service

The realistic options, in increasing order of effort:

1. **Use what already works** — a `ClusterIP`'s address plus
   `kubectl port-forward`, or a `NodePort`'s `<node-ip>:<nodePort>` — both
   fully functional without any additional setup, as used throughout
   Labs 7, 8, and 11.
2. **MetalLB** — the standard answer for bare-metal/self-managed clusters
   (mentioned as a next step in Lab 7, Step 12). It watches for
   `LoadBalancer` Services and assigns addresses from a pool you configure,
   advertised via ARP/BGP on your local network.
3. **`cloud-provider-kind`** — if working specifically with Kind clusters,
   this tool (the same one Docker Desktop bundles) can be run standalone
   to provide the same LoadBalancer-fulfillment behavior without needing
   Docker Desktop at all.
4. **A real managed cluster** (EKS/GKE/AKS) — the CCM is already running;
   `type: LoadBalancer` just works, and Node `ExternalIP` is populated
   automatically too.

---

## Key Takeaways

1. **`ExternalIP` (Node) and `EXTERNAL-IP` (Service) are both optional fields, populated only by a cloud controller manager (or equivalent) — never by Kubernetes core itself.**
2. **Neither a kubeadm cluster nor a plain Kind cluster runs a CCM**, because neither is backed by a real cloud provider API that could answer "what's this node/service's external address?"
3. **A Kind node's `InternalIP` is a Docker bridge network address** — there's no separate "external" identity for a Docker container to report.
4. **Docker Desktop's Kubernetes is the one local option in this series that *does* solve the Service side** of this, via its bundled `cloud-provider-kind` container — worth remembering as a contrast point.
5. **This is the same underlying pattern as Lab 10's `Pending` PVC** — a Kubernetes object representing a request that nothing is currently set up to fulfill. Recognizing this pattern (request object + missing fulfiller = stuck in a waiting state, not broken) generalizes across Services, Nodes, and PersistentVolumeClaims alike.
6. **None of this blocks real work.** Every exercise in this series reached its target successfully through ClusterIP + port-forward or NodePort — `<none>`/`<pending>` are informational, not failures.

---

## Command Reference

```bash
# Check a Node's addresses
kubectl get nodes -o wide
kubectl describe node <node-name> | grep -A3 Addresses:

# Check a Service's external address status
kubectl get svc <name> -n <namespace>
kubectl describe svc <name> -n <namespace> | grep -A3 Events
kubectl get svc <name> -n <namespace> -o jsonpath='{.status.loadBalancer}{"\n"}'

# Confirm no cloud-controller-manager is running (expected on kubeadm/Kind)
kubectl get pods -A | grep -i cloud-controller

# Manual (non-persistent) Node ExternalIP override — rarely needed
kubectl patch node <node-name> --subresource=status --type=merge \
  -p '{"status":{"addresses":[{"type":"ExternalIP","address":"<ip>"}]}}'
```
