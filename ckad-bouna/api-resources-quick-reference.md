# kubectl api-resources — CKAD Quick Reference

**Purpose:** `kubectl api-resources` lists every resource type the API
server knows about, along with its **short name** — the abbreviation that
saves real time in a timed exam (`po` instead of `pods`, `deploy` instead
of `deployments`, `netpol` instead of `networkpolicies`). This file
organizes the output from this cluster by **API group**, with the
CKAD-relevant resources called out separately from the Calico/cluster
internals that won't appear on the exam.

**Source:** real `kubectl api-resources` output from this WSL2 kubeadm
cluster (Kubernetes v1.35.0, Calico v3.31).

**Live lookup, any time:** rather than memorizing this file verbatim, the
exam environment always has this command available:
```bash
kubectl api-resources
kubectl api-resources --namespaced=true    # only namespaced kinds
kubectl api-resources -o wide              # adds verbs each resource supports
```

---

## Core `v1` API (no group prefix) — the most exam-relevant group

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| `cm` | configmaps | ConfigMap | ✅ |
| `ep` | endpoints | Endpoints | ✅ |
| `ev` | events | Event | ✅ |
| `limits` | limitranges | LimitRange | ✅ |
| `ns` | namespaces | Namespace | ❌ |
| `no` | nodes | Node | ❌ |
| `pvc` | persistentvolumeclaims | PersistentVolumeClaim | ✅ |
| `pv` | persistentvolumes | PersistentVolume | ❌ |
| `po` | pods | Pod | ✅ |
| `rc` | replicationcontrollers | ReplicationController | ✅ |
| `quota` | resourcequotas | ResourceQuota | ✅ |
| — | secrets | Secret | ✅ |
| `sa` | serviceaccounts | ServiceAccount | ✅ |
| `svc` | services | Service | ✅ |
| — | bindings | Binding | ✅ |
| — | componentstatuses (`cs`) | ComponentStatus | ❌ |
| — | podtemplates | PodTemplate | ✅ |

**Memorize these six first** — they cover the large majority of CKAD tasks:
`po`, `svc`, `cm`, `sa`, `pvc`, `ns`.

---

## `apps/v1` — Workloads

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| `deploy` | deployments | Deployment | ✅ |
| `rs` | replicasets | ReplicaSet | ✅ |
| `sts` | statefulsets | StatefulSet | ✅ |
| `ds` | daemonsets | DaemonSet | ✅ |
| — | controllerrevisions | ControllerRevision | ✅ |

This is Lab 5's whole object chain in one table: `deploy` → `rs` → `po`
(the last from the core group above).

---

## `batch/v1` — Run-to-completion Workloads

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| `cj` | cronjobs | CronJob | ✅ |
| — | jobs | Job | ✅ |

Not covered yet in this series — worth a dedicated lab, since CKAD tests
Jobs/CronJobs directly and nothing here has touched them.

---

## `networking.k8s.io/v1` — Networking

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| `ing` | ingresses | Ingress | ✅ |
| `netpol` | networkpolicies | NetworkPolicy | ✅ |
| — | ingressclasses | IngressClass | ❌ |
| `ip` | ipaddresses | IPAddress | ❌ |
| — | servicecidrs | ServiceCIDR | ❌ |

**Note the naming collision:** `networkpolicies` exists in **three**
different API groups on this cluster — `networking.k8s.io/v1` (the
standard Kubernetes one, used throughout Lab 6), `crd.projectcalico.org/v1`
(Calico's own CRD version, short name unlisted), and `projectcalico.org/v3`
(short names `cnp`, `caliconetworkpolicy`). Plain `kubectl get netpol`
always means the standard `networking.k8s.io` one — the Calico-native
versions need the full `caliconetworkpolicies.projectcalico.org` name or
`cnp` to disambiguate. This matters if you ever see `NetworkPolicy` show up
twice in `kubectl api-resources` and aren't sure which one a command is
touching.

`ing` (Ingress) is the one major CKAD/exam topic not yet built hands-on in
this series — see the mind map's remaining dashed branch.

---

## `storage.k8s.io/v1` — Storage

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| `sc` | storageclasses | StorageClass | ❌ |
| — | csidrivers | CSIDriver | ❌ |
| — | csinodes | CSINode | ❌ |
| — | csistoragecapacities | CSIStorageCapacity | ✅ |
| — | volumeattachments | VolumeAttachment | ❌ |
| `vac` | volumeattributesclasses | VolumeAttributesClass | ❌ |

`sc` is the exact resource Lab 10 found **empty** (`kubectl get
storageclass` → `No resources found`), which is why that lab used static
PV provisioning by hand instead of dynamic provisioning.

---

## `rbac.authorization.k8s.io/v1` — RBAC (not yet covered hands-on)

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| — | roles | Role | ✅ |
| — | rolebindings | RoleBinding | ✅ |
| — | clusterroles | ClusterRole | ❌ |
| — | clusterrolebindings | ClusterRoleBinding | ❌ |

Four objects, two pairs: `Role`/`RoleBinding` are namespace-scoped,
`ClusterRole`/`ClusterRoleBinding` are cluster-wide. This is a named gap in
the series index — core CKAD/KCSA material worth doing as a dedicated lab.

---

## `policy/v1` — Disruption Control

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| `pdb` | poddisruptionbudgets | PodDisruptionBudget | ✅ |

Seen for real in Lab 11 — the Bitnami nginx chart's
`maxUnavailable: 1` PDB.

---

## `autoscaling/v2` — Scaling

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| `hpa` | horizontalpodautoscalers | HorizontalPodAutoscaler | ✅ |

Referenced (disabled) in the Helm chart scaffold's `values.yaml`
(`autoscaling.enabled: false`) but never exercised — another named gap.

---

## `scheduling.k8s.io/v1`

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| `pc` | priorityclasses | PriorityClass | ❌ |

---

## `node.k8s.io/v1`

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| — | runtimeclasses | RuntimeClass | ❌ |

This is the object type behind the gVisor discussion earlier in this
series — `kubectl get runtimeclass` returning empty is what prompted that
whole explanation of what a RuntimeClass is for.

---

## `discovery.k8s.io/v1`

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| — | endpointslices | EndpointSlice | ✅ |

The modern replacement for the core `v1` `endpoints`/`ep` resource — used
throughout Labs 7 and 10 (`kubectl get endpointslices -l
kubernetes.io/service-name=...`) specifically because plain `endpoints` is
deprecated as of Kubernetes 1.33+.

---

## `apiextensions.k8s.io/v1` and `apiregistration.k8s.io/v1`

| Short name | Full name | Kind | Namespaced |
|---|---|---|---|
| `crd`, `crds` | customresourcedefinitions | CustomResourceDefinition | ❌ |
| — | apiservices | APIService | ❌ |

`crd` is how Calico (and every other operator-based tool) adds new
resource types to the cluster in the first place — the entire
`crd.projectcalico.org/v1` and `projectcalico.org/v3` groups below exist
*because* Tigera's operator registered CRDs for them.

---

## Calico / Tigera-Specific (cluster internals, not exam material)

These exist on **this cluster specifically** because of the Calico CNI
install from the Setup Guide — they will not appear in a standard CKAD
exam environment, which typically uses a simpler CNI (often Cilium or
Flannel) or an exam-provided cluster with different internals.

| Group | Notable kinds |
|---|---|
| `crd.projectcalico.org/v1` | `BGPConfiguration`, `FelixConfiguration`, `IPPool`, `NetworkPolicy` (Calico CRD form), `Tier` |
| `projectcalico.org/v3` | Same resources again, under short names `bgpconfig`, `felixconfig`, `cnp`, `gnp` (GlobalNetworkPolicy), `hep` (HostEndpoint) |
| `operator.tigera.io/v1` | `Installation`, `APIServer`, `Goldmane`, `Whisker` — the objects behind `kubectl get pods -n calico-system` and `-n tigera-operator` throughout this series |

Worth recognizing by sight (so you don't mistake them for something you
need to know for the exam), not worth memorizing short names for.

---

## Not Yet Covered in This Series — Grouped by What They're For

| Resource | Group | Status |
|---|---|---|
| `Job`, `CronJob` | `batch/v1` | Not touched — worth a dedicated lab |
| `Ingress`, `IngressClass` | `networking.k8s.io/v1` | Placeholder on the mind map; the next major networking topic |
| `Role`, `RoleBinding`, `ClusterRole`, `ClusterRoleBinding` | `rbac.authorization.k8s.io/v1` | Named gap — core CKAD/KCSA material |
| `HorizontalPodAutoscaler` | `autoscaling/v2` | Present in the Helm scaffold, disabled, never exercised |
| `StorageClass` | `storage.k8s.io/v1` | Empty on this cluster (Lab 10) — dynamic provisioning not set up |
| `LimitRange`, `ResourceQuota` | core `v1` | Not touched — relevant to CKAD's resource-management objectives |

---

## Fast Lookup Habits Worth Building for a Timed Exam

```bash
# Full resource list with short names, right when you need it
kubectl api-resources

# Only namespaced kinds (most of what you'll create)
kubectl api-resources --namespaced=true

# Find which API group a kind belongs to, when unsure
kubectl api-resources | grep -i <kind>

# See exactly which verbs (get/list/create/delete/...) a resource supports
kubectl api-resources -o wide

# Explain any field of any resource without leaving the terminal
kubectl explain pod.spec.containers.volumeMounts
kubectl explain deployment.spec.strategy
```

`kubectl explain` in particular is worth using constantly during CKAD
practice — it's the exam-legal way to look up exact field names and types
without needing external documentation, and it works for every resource in
this table.
