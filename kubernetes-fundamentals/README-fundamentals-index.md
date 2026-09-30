# Kubernetes Fundamentals — Series Index

This is the map of everything covered in this lab series, in the order it
was built: a real kubeadm cluster on WSL2, taken from bare metal through
Pods, Deployments, Services, storage, and Helm — with every real failure
encountered along the way kept in, not edited out, because diagnosing them
was as much the point as the happy path.

**How to use this index:** read top to bottom if you're going through the
series for the first time. If you already know roughly what you're looking
for, the table below gets you there directly.

---

## Reading Order

| # | Document | Covers |
|---|---|---|
| 0 | **Setup Guide** (`kubernetes-wsl2-beginner-guide.md`) | Pre-flight checks, `install_k8s_stack.sh`, `bootstrap_cluster.sh`, first verification |
| — | `install_k8s_stack.sh`, `bootstrap_cluster.sh` | The idempotent scripts themselves — safe to re-run any time |
| — | `production-practices-cni-token-incident.md` | Why large orgs rarely hit the stale-token bug — node rotation, monitoring, chaos engineering |
| 2 | **Lab 2** — Imperative to Declarative | `--dry-run=client`, `kubectl apply`'s `created`/`unchanged`/`configured`, what's mutable on a running Pod |
| 3 | **Lab 3** — kubectl-neat & krew | Installing `krew`, cleaning a live object's YAML down to a reusable manifest, what Kubernetes auto-injects |
| 4 | **Lab 4** — The Stale CNI Token Incident | Diagnosing `Unauthorized` errors from Calico, why `calico-node`'s token snapshot goes stale, the automated fix added to `bootstrap_cluster.sh` |
| 5 | **Lab 5** — Deployments | Self-healing, scaling, rolling updates (the real surge/unavailable math), rollback, a full Mealie version upgrade |
| 6 | **Lab 6** — Calico Network Policy | Reading Felix's actual iptables chains, default-allow vs. a selected pod's deny-by-default tier, ipsets behind label selectors |
| 7 | **Lab 7** — Services | ClusterIP/NodePort/LoadBalancer, the `targetPort` trap, EndpointSlices, why `<pending>` is normal here |
| 8 | **Lab 8** — Tracing Service Traffic | The actual `KUBE-SERVICES → KUBE-SVC → KUBE-SEP` DNAT chain, `KUBE-EXT` masquerade, packet counters as proof |
| 9 | **Lab 9** — Pod Volumes | `emptyDir`, the pod-container-list immutability rule, a working two-container sidecar sharing a volume |
| 10 | **Lab 10** — PersistentVolumes & Claims | Why PVCs stay `Pending` with no StorageClass, static PV provisioning, proving data survives pod *and* whole-Deployment deletion |
| — | **k9s Guide** (`k9s-guide.md`) | A terminal UI alternative to typing individual `kubectl` commands |
| 11 | **Lab 11** — Helm | Installing Helm, a full install/upgrade/rollback cycle on a public chart, reading generated manifests, scaffolding a chart from the mealie YAML |
| — | **CLI Command Reference** (`cli-command-reference.md`) | Every command from cluster bootstrap through Services, in logical order, plus full cleanup/rebuild |
| — | **Networking Mind Map** (`k8s-networking-mindmap.jpeg`) | Visual: Pods, Network Policies, and Services branches, each with real cluster data |
| — | **Plain-Language Explainer** (`kubernetes-explained-for-everyone.md`) | The harbor metaphor — for anyone non-technical asking "what is this thing you've been doing" |

---

## What This Cluster Actually Is

- **kubeadm**, not a managed service or a local dev tool (Kind/k3s/Docker
  Desktop) — every piece was installed and wired up manually, which is
  precisely why the failure modes below were visible at all.
- **Kubernetes v1.35.6**, **Calico v3.31** as CNI, **containerd** as the
  runtime, running on **WSL2** on a single Windows machine.
- **Single node** doing double duty as control plane and worker — meaningful
  limitations noted throughout (no real multi-node routing, `hostPath`
  volumes only make sense here because there's nowhere else for a pod to be
  rescheduled to).

---

## The Recurring Bug Worth Knowing By Sight

**The stale Calico CNI token** appeared **three separate times** across
this series (Lab 4, and twice more in later sessions) — always the same
signature:

```
plugin type="calico" failed (add): error getting ClusterInformation: connection is unauthorized: Unauthorized
```
or, on the delete path:
```
plugin type="calico" failed (delete): error getting ClusterInformation: connection is unauthorized: Unauthorized
```

**Root cause:** `calico-node`'s `install-cni` init container writes a
one-time service-account token snapshot to
`/etc/cni/net.d/calico-kubeconfig` when the pod starts. Unlike a token
mounted *inside* a running pod (which kubelet auto-rotates hourly), this
on-disk snapshot never refreshes — so it silently goes stale the longer
`calico-node` runs without restarting.

**Fix, every time:**
```bash
kubectl delete pod -n calico-system -l k8s-app=calico-node
```

This is baked into `bootstrap_cluster.sh` as an automatic self-heal check
now — but it only runs when that script executes, not continuously. If
you hit this a fourth time, that's the signal to actually set up periodic
detection (a cron job, or just re-running the bootstrap script as a
session-start habit) rather than diagnosing it by hand again.

---

## Concepts That Showed Up Repeatedly, Across Different Labs

These aren't separate topics — they're the same handful of ideas,
recognized again and again in new contexts:

- **Declarative vs. imperative** (Lab 2) → every `kubectl apply` since, →
  Helm's whole reason for existing (Lab 11)
- **Pod template hash → new ReplicaSet** (Lab 5) → recognized again the
  moment `volumes` changed in Lab 10, and again when Helm's `--set
  replicaCount` did *not* trigger it (because replica count isn't part of
  the template)
- **Owned vs. independent objects** — a Pod is owned by a ReplicaSet, owned
  by a Deployment; but a PVC and a Service are **not** owned by the
  Deployment using them (proven directly in Lab 10, Step 7)
- **`emptyDir`'s shared-but-ephemeral nature** (Lab 9) → generalized with
  `subPath` in a real chart (Lab 11) → contrasted directly with a PVC's
  durability (Lab 10)
- **iptables as the actual mechanism**, not an abstraction — Calico's
  policy chains (Lab 6) and kube-proxy's Service chains (Lab 8) are both
  real, readable rules on the node, not magic
- **`describe`'s Events section as the first diagnostic step**, every
  single time something didn't work, from Lab 2 onward

---

## What's Deliberately Not Covered Yet

The networking mind map still has open branches, and this series has a few
other gaps worth naming explicitly rather than leaving implicit:

| Topic | Why it's next |
|---|---|
| **Ingress** | Every Service so far has been reached directly (ClusterIP, NodePort, or `port-forward`). Ingress is the standard way to route HTTP(S) traffic to multiple Services behind one entry point, and it's the last major dashed branch on the mind map. |
| **StorageClasses / dynamic provisioning** | Lab 10 deliberately used static provisioning (a hand-written PV) because this cluster has no provisioner. Installing something like `local-path-provisioner` would let future PVCs bind automatically. |
| **RBAC (Roles, RoleBindings, ServiceAccounts)** | Referenced conceptually (k9s guide, the Bitnami chart's dedicated ServiceAccount) but never actually configured. This is core KCSA material. |
| **Pod Security Standards / admission control** | The root-user findings from early exec exploration, and the Bitnami chart's hardened `securityContext`, both point here directly. |
| **Horizontal Pod Autoscaling** | Mentioned in the chart scaffold's `values.yaml` (`autoscaling.enabled: false`) but never exercised. |
| **StatefulSets** | Mealie's PVC gave one pod durable storage; a StatefulSet is the pattern for **multiple** pods each needing their own durable, identity-linked storage. |
| **Completing the mealie Helm chart** | Lab 11 ends with a scaffolded, values-customized chart that was never actually `helm install`-ed — a clean, ready-to-run next step. |

---

## Repository Structure (suggested)

```
kubernetes-fundamentals/
├── README-fundamentals-index.md          ← this file
├── readme-what-is-kubernetes.md
├── kubernetes-intro-notes.md
├── kubernetes-explained-for-everyone.md
├── kubernetes-harbor-animation.html
├── k8s-networking-mindmap.jpeg
├── k9s-guide.md
├── cli-command-reference.md
├── lab-02-imperative-to-declarative.md
├── lab-03-kubectl-neat-krew.md
├── lab-04-stale-cni-token-incident.md
├── production-practices-cni-token-incident.md
├── lab-05-deployments.md
├── lab-06-calico-network-policy.md
├── lab-07-services.md
├── lab-08-tracing-service-traffic.md
├── lab-09-pod-volumes.md
├── lab-10-persistent-volumes.md
├── lab-11-helm.md
├── setup/
│   ├── install_k8s_stack.sh
│   ├── bootstrap_cluster.sh
│   └── readme.md
├── deployments/
│   ├── deploy.yaml, frontend.yaml, nginx.yaml, ...
├── mealie/
│   ├── deployment.yaml, service.yaml, storage.yaml, mealie-pv.yaml
└── helm/
    ├── mealie-chart/
    └── my-nginx-manifest.yaml
```

---

## Closing Note

Every lab in this series came from a real command run against a real
cluster, including every error message. That's a deliberate choice: the
CNI token incident, the `targetPort` mismatch, the duplicated YAML key in
a sidecar pod, the PVC stuck `Pending` — none of these were planted for
teaching purposes, and all of them are exactly the kind of thing that
happens on a genuinely self-managed cluster, which is precisely why they
were worth documenting in full rather than smoothing over.
