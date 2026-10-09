# Application Design and Build: Workload Controllers

## Labels and selectors, ReplicaSets, Deployments, DaemonSets, Jobs and CronJobs

This guide is one part of the "Application design and build" topic. It explains how Kubernetes keeps your application running (labels and selectors, ReplicaSets, Deployments, DaemonSets) and how it runs work that finishes (Jobs and CronJobs). Each concept is followed by an implementation you can run.

It is built on a real three-node kubeadm cluster (1 control plane, 2 workers, Kubernetes v1.36.5). Console output from that cluster is included wherever the feature was run there. Labs the cluster has **not** run are marked **(not run)**, and their expected behavior is described in words, not shown as captured output.

**Contents**

1. Labels and selectors
2. Implementing labels and selectors
3. ReplicaSets
4. Implementing ReplicaSets
5. Challenges with ReplicaSets
6. Deployments
7. Implementing Deployments
8. `maxSurge` and `maxUnavailable`
9. Implementing `maxSurge` and `maxUnavailable`
10. DaemonSets
11. Implementing DaemonSets
12. Jobs and CronJobs
13. Implementing Jobs and CronJobs, including `activeDeadlineSeconds`
14. Job `backoffLimit`
15. Implementing `backoffLimit`
16. Job history limits
17. Choosing a controller
18. Common mistakes and troubleshooting
19. Command cheat sheet
20. Glossary
21. What was run, and what was not

---

# How to use this guide

## The big picture

```text
 Deployment ----> ReplicaSet ----> Pods        (long-running apps, rolling updates)
 ReplicaSet ----> Pods                         (rarely used directly)
 DaemonSet  ----> one Pod per node             (agents: logging, networking, monitoring)
 Job        ----> Pods that run to completion  (one-off work)
 CronJob    ----> Job ----> Pods               (work on a schedule)
```

All of them find their pods with **labels and selectors**, which is why that comes first.

## Where to run the labs

Run the labs **inside the master VM shell**, where `kubectl` works directly and heredocs (`<<'EOF'`) work:

```powershell
multipass shell master
```

The prompt becomes `ubuntu@master:~$`. If you prefer Windows PowerShell, put `multipass exec master --` in front of each `kubectl` command, but avoid the heredoc and JSON-patch commands there, because PowerShell mangles the quotes and piping YAML into `multipass exec` can hang.

## Keep the labs in their own namespace

```bash
kubectl create namespace appdesign
kubectl config set-context --current --namespace=appdesign
```

Everything you create now lands in `appdesign`, and cleaning up is one command (see the end of Section 21). The second command changes the default namespace of your kubeconfig copy, so the cleanup resets it.

## Images used

The labs use `nginx` and `busybox`, which your nodes already have. A few labs change an image to `nginx:alpine` or `busybox:1.36`, and the nodes download those on first use.

---

# 1. Labels and selectors

## Labels

A **label** is a key/value pair attached to any Kubernetes object. Labels carry no meaning for Kubernetes by themselves. They are tags that you and the controllers use to group objects.

```yaml
metadata:
  labels:
    app: web
    env: prod
    tier: frontend
```

| Rule | Detail |
|---|---|
| Key | An optional prefix (a DNS name, up to 253 characters) and a slash, then a name of up to 63 characters. The name uses letters, digits, `-`, `_` and `.`, and begins and ends with a letter or digit |
| Value | Up to 63 characters, same allowed characters, and it may be empty |
| Where | Any object: pods, nodes, Services, Deployments, namespaces |
| Prefixes | `kubernetes.io/` and `k8s.io/` are reserved for Kubernetes itself |

## Labels versus annotations

| | Labels | Annotations |
|---|---|---|
| Purpose | Identify and **select** objects | Attach **extra information** (build number, contact, tool settings) |
| Used for selection | Yes | No |
| Size | Small and strict | Can be large and free-form |

## Selectors

A **selector** is a query over labels. There are two kinds:

| Kind | Operators | Example |
|---|---|---|
| **Equality-based** | `=`, `==`, `!=` | `env=prod`, `tier!=backend` |
| **Set-based** | `in`, `notin`, key exists, key absent | `env in (prod,staging)`, `env notin (dev)`, `canary`, `!canary` |

Several conditions separated by commas mean **AND**:

```text
app=web,env=prod          ->  app is web AND env is prod
```

There is no OR between different keys. Use a set-based `in` for OR within one key.

## How the objects use selectors

| Object | Selector field | Style |
|---|---|---|
| Service | `spec.selector` (a plain map) | Equality only |
| ReplicaSet, Deployment, DaemonSet, Job | `spec.selector.matchLabels` and `matchExpressions` | Both |
| Pod scheduling | `nodeSelector` (a plain map), node affinity | Equality / expressions |
| `kubectl` | `-l` or `--selector` | Both |

`matchExpressions` use the operators `In`, `NotIn`, `Exists` and `DoesNotExist`:

```yaml
selector:
  matchLabels:
    app: web
  matchExpressions:
  - key: env
    operator: In
    values: [prod, staging]
  - key: canary
    operator: DoesNotExist
```

Both parts must match.

## Labels in your own cluster

The cluster already uses labels everywhere. Three real examples:

**1. A Service finding pods.** The nginx Service had `Selector: app=nginx`. The pods that `kubectl get pods -l app=nginx -o wide` returned were exactly the Service's four endpoints:

```text
NAME                     READY   STATUS    RESTARTS   AGE   IP           NODE
nginx-56c45fd5ff-9wkj4   1/1     Running   0          14h   10.244.2.3   worker2
nginx-56c45fd5ff-n8c6z   1/1     Running   0          14h   10.244.2.2   worker2
nginx-56c45fd5ff-nx5ff   1/1     Running   0          31s   10.244.1.4   worker1
nginx-56c45fd5ff-x9n4f   1/1     Running   0          14h   10.244.1.3   worker1

endpoints:  10.244.1.3 10.244.1.4 10.244.2.2 10.244.2.3
```

The four pod IPs and the four endpoints are the same set. The selector picks the pods, and the Service's endpoint list follows them.

**2. The label that Deployments add.** A rollout history showed the pod template with two labels. The second is added by the Deployment controller:

```text
Pod Template:
  Labels:       app=nginx
        pod-template-hash=56c45fd5ff
```

`pod-template-hash` is a hash of the pod template. It is how a Deployment keeps its **ReplicaSets** apart (see Section 6). Do not edit it.

**3. A node label changing the `ROLES` column.** Workers showed `<none>` as their role until a label was added:

```text
NAME      STATUS   ROLES    ...
worker1   Ready    <none>   ...     before
worker1   Ready    worker   ...     after:  kubectl label node worker1 node-role.kubernetes.io/worker=
```

The `ROLES` column is simply derived from labels with the `node-role.kubernetes.io/` prefix.

---

# 2. Implementing labels and selectors

Labs 1 to 5 were **run on the real cluster**, with the observed results after each lab. Run them in the `appdesign` namespace, in the master shell.

## Lab 1: create pods with labels

```bash
kubectl run web1 --image=nginx --labels="app=web,env=prod,tier=frontend"
kubectl run web2 --image=nginx --labels="app=web,env=staging,tier=frontend"
kubectl run api1 --image=nginx --labels="app=api,env=prod,tier=backend"
sleep 10
kubectl get pods --show-labels
kubectl get pods -L app,env,tier
```

`--show-labels` prints every label in one column. `-L app,env,tier` prints a column per label you name, which is easier to read.

### Observed on the real cluster

```text
NAME   READY   STATUS    RESTARTS   AGE   LABELS
api1   1/1     Running   0          10s   app=api,env=prod,tier=backend
web1   1/1     Running   0          11s   app=web,env=prod,tier=frontend
web2   1/1     Running   0          10s   app=web,env=staging,tier=frontend
NAME   READY   STATUS    RESTARTS   AGE   APP   ENV       TIER
api1   1/1     Running   0          10s   api   prod      backend
web1   1/1     Running   0          11s   web   prod      frontend
web2   1/1     Running   0          10s   web   staging   frontend
```

## Lab 2: select with `-l`

```bash
for sel in 'app=web' 'env=prod' 'app=web,env=prod' 'env in (prod,staging)' 'env!=prod' 'tier' '!canary' 'app=web,tier!=backend'; do
  echo "-l '$sel'  ->  $(kubectl get pods -l "$sel" --no-headers -o custom-columns=NAME:.metadata.name | tr '\n' ' ')"
done
```

Quote selectors that contain parentheses or `!`, so the shell does not interpret them.

### Observed on the real cluster

| Selector | Pods matched |
|---|---|
| `app=web` | web1 web2 |
| `env=prod` | api1 web1 |
| `app=web,env=prod` | web1 |
| `env in (prod,staging)` | api1 web1 web2 |
| `env!=prod` | web2 |
| `tier` | api1 web1 web2 (the key exists) |
| `!canary` | api1 web1 web2 (none has a `canary` label) |
| `app=web,tier!=backend` | web1 web2 |

All eight matched what the definitions in Section 1 predict. The names print in alphabetical order.

## Lab 3: change labels on a live object

```bash
kubectl label pod web2 env=prod                       # refused
kubectl label pod web2 env=prod --overwrite           # change a value
kubectl label pod web2 release=blue                   # add a label
kubectl get pods -L app,env,release
kubectl label pod web2 release-                       # remove it (trailing minus)
kubectl label pod web2 env=staging --overwrite
kubectl get pods -L app,env,release
```

### Observed on the real cluster

```text
error: 'env' already has a value (staging), and --overwrite is false
pod/web2 labeled
pod/web2 labeled
NAME   READY   STATUS    RESTARTS   AGE   APP   ENV    RELEASE
api1   1/1     Running   0          11s   api   prod
web1   1/1     Running   0          12s   web   prod
web2   1/1     Running   0          11s   web   prod   blue
pod/web2 unlabeled
pod/web2 labeled
```

Changing an existing value without `--overwrite` is **refused**, and the error says why. The trailing minus removes a label (`unlabeled`).

## Lab 4: labels on nodes

```bash
kubectl get nodes --show-labels
kubectl label node worker1 disk=ssd
kubectl get nodes -l disk=ssd
kubectl label node worker1 disk-
```

### Observed on the real cluster

```text
master    ... kubernetes.io/hostname=master,kubernetes.io/os=linux,node-role.kubernetes.io/control-plane=,node.kubernetes.io/exclude-from-external-load-balancers=
worker1   ... kubernetes.io/hostname=worker1,kubernetes.io/os=linux,node-role.kubernetes.io/worker=
worker2   ... kubernetes.io/hostname=worker2,kubernetes.io/os=linux,node-role.kubernetes.io/worker=

node/worker1 labeled
NAME      STATUS   ROLES    AGE     VERSION
worker1   Ready    worker   3d16h   v1.36.5
node/worker1 unlabeled
```

Every node has `kubernetes.io/hostname` and `kubernetes.io/os`. The `ROLES` column comes from the `node-role.kubernetes.io/...` labels. The master also carries `node.kubernetes.io/exclude-from-external-load-balancers`. As I understand it, that keeps it out of the pool a cloud load balancer picks from, but its effect here was not checked.

## Lab 5: act on a selection

```bash
kubectl get all -l app=web
kubectl delete pods -l env=staging
sleep 5
kubectl get pods
```

### Observed on the real cluster

```text
NAME       READY   STATUS    RESTARTS   AGE
pod/web1   1/1     Running   0          12s
pod/web2   1/1     Running   0          11s
pod "web2" deleted from appdesign namespace
NAME   READY   STATUS    RESTARTS   AGE
api1   1/1     Running   0          19s
web1   1/1     Running   0          20s
```

`delete pods -l env=staging` removed **only web2**. `get all` lists the common workload types (pods, Services, Deployments, ReplicaSets, Jobs and so on), but not everything, for example not ConfigMaps or Secrets. Check what a selector matches with `get` before you run a `delete` with it.

## Clean up the lab pods

**Do not skip this.** The ReplicaSet labs use the selector `app=web`, and a ReplicaSet adopts any pod with no owner whose labels match, so a leftover `web1` would be claimed as one of its replicas.

```bash
kubectl delete pod web1 api1 web2 --ignore-not-found
```

---

# 3. ReplicaSets

## What a ReplicaSet does

A **ReplicaSet** keeps a stated number of identical pods running. It watches the pods that match its selector, and:

- if there are **too few**, it creates new ones from its template;
- if there are **too many**, it deletes the extras.

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: web-rs
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx
```

| Field | Meaning |
|---|---|
| `replicas` | The number of pods wanted |
| `selector` | How the ReplicaSet finds **its** pods |
| `template` | The blueprint for new pods |

The `template.metadata.labels` **must match** the `selector`. Otherwise the API refuses the object, because the ReplicaSet could never count the pods it creates.

## Ownership

A pod created by a ReplicaSet records its owner in `metadata.ownerReferences`. Deleting the ReplicaSet deletes its pods too. The pod name is the ReplicaSet's name plus a random suffix.

## The ReplicaSets in your cluster

You never created a ReplicaSet by hand. The **Deployment** created them. After a rollout in the real cluster:

```text
NAME               DESIRED   CURRENT   READY   AGE
nginx-56c45fd5ff   0         0         0       14h
nginx-79f698694b   4         4         4       48s
```

| Column | Meaning |
|---|---|
| `DESIRED` | `spec.replicas` |
| `CURRENT` | Pods that exist and belong to it |
| `READY` | Pods that are ready to serve |

The old ReplicaSet is kept at **zero** so that you can roll back (Section 6).

## Why you rarely use one directly

A ReplicaSet only keeps a count. It cannot do rolling updates or rollbacks. A **Deployment** wraps it and adds those (Section 6). Use a ReplicaSet directly only to learn how it works, or in the rare case where you need its behavior and nothing more.

---

# 4. Implementing ReplicaSets

Labs 6 to 10 were **run on the real cluster**, with the observed results after each lab. Lab 11, the challenge, is in Section 5. Run them in the master shell, in the `appdesign` namespace, with no pods left over from Section 2.

## Lab 6: create a ReplicaSet

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: web-rs
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx
EOF
sleep 8
kubectl get rs web-rs
kubectl get pods -l app=web -o wide
```

### Observed on the real cluster

```text
NAME     DESIRED   CURRENT   READY   AGE
web-rs   3         3         3       8s
NAME           READY   STATUS    RESTARTS   AGE   IP             NODE
web-rs-9r699   1/1     Running   0          9s    10.244.2.200   worker2
web-rs-nlwtd   1/1     Running   0          9s    10.244.2.201   worker2
web-rs-x8glj   1/1     Running   0          9s    10.244.1.58    worker1
```

Three pods named `web-rs-xxxxx`, spread over the two workers (two and one), and none on the master, whose taint keeps ordinary pods off it. The spreading is best effort.

## Lab 7: self-healing

```bash
P=$(kubectl get pods -l app=web -o name | head -1)
echo "deleting $P"
kubectl delete $P
sleep 5
kubectl get pods -l app=web
kubectl describe rs web-rs | tail -8
```

`$(... | head -1)` picks the first pod for you, so there is nothing to fill in.

### Observed on the real cluster

```text
deleting pod/web-rs-9r699
pod "web-rs-9r699" deleted from appdesign namespace
NAME           READY   STATUS    RESTARTS   AGE
web-rs-nlwtd   1/1     Running   0          15s
web-rs-x8glj   1/1     Running   0          15s
web-rs-zx2rb   1/1     Running   0          6s
Events:
  Normal  SuccessfulCreate  15s   replicaset-controller  Created pod: web-rs-9r699
  Normal  SuccessfulCreate  15s   replicaset-controller  Created pod: web-rs-x8glj
  Normal  SuccessfulCreate  15s   replicaset-controller  Created pod: web-rs-nlwtd
  Normal  SuccessfulCreate  6s    replicaset-controller  Created pod: web-rs-zx2rb
```

The deleted pod was gone within seconds, with no `Terminating` line (nginx stops quickly), and the ReplicaSet created a replacement with a **new name** at once. The four `SuccessfulCreate` events are the original three plus the replacement.

## Lab 8: scale

```bash
kubectl scale rs web-rs --replicas=5
sleep 6
kubectl get rs web-rs
kubectl get pods -l app=web
kubectl scale rs web-rs --replicas=2
sleep 8
kubectl get pods -l app=web
```

### Observed on the real cluster

```text
(after scaling to 5)
web-rs   5   5   5   21s
web-rs-2spll   1/1   Running   0   6s
web-rs-nlwtd   1/1   Running   0   21s
web-rs-qqjv2   1/1   Running   0   6s
web-rs-x8glj   1/1   Running   0   21s
web-rs-zx2rb   1/1   Running   0   12s

(after scaling to 2)
web-rs-nlwtd   1/1   Running   0   29s
web-rs-x8glj   1/1   Running   0   29s
```

Scaling down removed the three **newest** pods (`zx2rb`, `2spll`, `qqjv2`) and kept the two oldest. That agrees with the documented preference for deleting newer pods first, but it is one run.

## Lab 9: ownership

```bash
P=$(kubectl get pods -l app=web -o name | head -1)
kubectl get $P -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
```

### Observed on the real cluster

```text
ReplicaSet/web-rs
```

## Lab 10: a ReplicaSet follows labels, not pod names

Relabel a pod so it no longer matches, then put the label back:

```bash
kubectl scale rs web-rs --replicas=3
sleep 5
P=$(kubectl get pods -l app=web -o name | head -1)
echo "relabeling $P"
kubectl label $P app=orphan --overwrite
sleep 6
kubectl get pods -L app
kubectl get rs web-rs
echo "owner of the relabeled pod: [$(kubectl get $P -o jsonpath='{.metadata.ownerReferences[*].name}')]"
O=$(kubectl get pods -l app=orphan -o name)
kubectl label $O app=web --overwrite
sleep 8
kubectl get pods -L app
kubectl get rs web-rs
echo "owner now: [$(kubectl get $O -o jsonpath='{.metadata.ownerReferences[*].name}' 2>&1)]"
```

### Observed on the real cluster

```text
relabeling pod/web-rs-8vph7
NAME           READY   STATUS    RESTARTS   AGE   APP
web-rs-8vph7   1/1     Running   0          11s   orphan
web-rs-nlwtd   1/1     Running   0          66s   web
web-rs-wjwhf   1/1     Running   0          6s    web
web-rs-x8glj   1/1     Running   0          66s   web
web-rs   3   3   3   66s
owner of the relabeled pod: []

(after relabeling it back to web)
web-rs-8vph7   1/1   Running   0   20s   web
web-rs-nlwtd   1/1   Running   0   75s   web
web-rs-x8glj   1/1   Running   0   75s   web
web-rs   3   3   3   75s
owner now: [web-rs]
```

| Step | What happened |
|---|---|
| After `app=orphan` | **Four pods**: the relabeled one and three matching ones, including a brand-new `wjwhf`. The ReplicaSet reports `CURRENT 3`. The orphan's **owner is empty**: the ReplicaSet released it |
| After relabeling it back | **Three pods** again. The ReplicaSet saw four matching pods and deleted **`wjwhf`, the newest**, not the pod that came back. The returned pod's owner is `web-rs` again: it was **re-adopted** |

Two things to take away. A ReplicaSet owns pods **by their labels**, so a label change takes a pod out of service and out of any Service's endpoints while keeping it alive, which is a useful debugging trick. And the same label match means a stray pod with the right labels is claimed by the ReplicaSet, which is why the cleanup in Section 2 matters.

---

# 5. Challenges with ReplicaSets

## The main problem: changing the template does not update running pods

A ReplicaSet applies its template only to pods it **creates**. If you change the template, for example a new image, **existing pods are left as they are**. You can end up with a mix of old and new pods. There is no rolling update, no rollback, and no history.

## Lab 11: see it

Starting from the three pods of `web-rs`:

```bash
kubectl set image rs/web-rs nginx=nginx:alpine
sleep 5
kubectl get rs web-rs -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
P=$(kubectl get pods -l app=web -o name | head -1)
kubectl delete $P
sleep 12
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

### Observed on the real cluster

```text
replicaset.apps/web-rs image updated
nginx:alpine
NAME           IMAGE
web-rs-8vph7   nginx
web-rs-nlwtd   nginx
web-rs-x8glj   nginx
pod "web-rs-8vph7" deleted from appdesign namespace
NAME           IMAGE
web-rs-7cqh7   nginx:alpine
web-rs-nlwtd   nginx
web-rs-x8glj   nginx
```

| Step | Result |
|---|---|
| The ReplicaSet's template | `nginx:alpine` |
| The three existing pods | **All still `nginx`.** The ReplicaSet did not touch them |
| After deleting one | The replacement `7cqh7` is `nginx:alpine`, while the other two stay on `nginx` |

You now run **two versions at once**, and the only way to finish the update is to delete the old pods yourself, one at a time or all at once, with downtime if you delete them all.

## All the limitations

| Challenge | Consequence |
|---|---|
| Template changes do not touch existing pods | Mixed versions, and a manual finish |
| No rolling update strategy | You control the pace and the downtime yourself |
| No rollback and no revision history | Going back means editing the template and deleting pods again |
| No pause and resume | You cannot stage a change |
| A ReplicaSet can **adopt** a pod it did not create | Any pod **with no owner** whose labels match the selector is claimed, so overlapping selectors cause surprises |
| Selector overlap between two controllers | Two ReplicaSets can fight over the same pods |

## The solution

A **Deployment** manages ReplicaSets for you: a new ReplicaSet per template change, scaled up as the old one is scaled down, with history. That is Section 6.

## Clean up

```bash
kubectl delete rs web-rs
```

---

# 6. Deployments

## What a Deployment adds

A **Deployment** owns ReplicaSets, and each ReplicaSet owns pods:

```text
Deployment nginx
   |-- ReplicaSet nginx-56c45fd5ff   (old template, scaled to 0, kept for rollback)
   `-- ReplicaSet nginx-79f698694b   (current template, 4 pods)
```

Every change to the **pod template** creates a new ReplicaSet. The Deployment then moves replicas from the old one to the new one at a controlled pace. This gives you:

| Feature | How |
|---|---|
| Rolling updates | The new ReplicaSet is scaled up while the old one is scaled down |
| Rollback | The old ReplicaSet is still there, so `kubectl rollout undo` scales it back up |
| History | Each template is a numbered revision |
| Pause and resume | Stage several edits, then roll them out together |
| Scaling | `kubectl scale`, with the change passed to the current ReplicaSet |

## What counts as a template change

Only `spec.template` changes cause a rollout. Changing `replicas` or the `strategy` does not. In your real cluster, `kubectl rollout restart` caused a rollout by adding one annotation to the template, `kubectl.kubernetes.io/restartedAt`. That single change was enough for a new hash and a new ReplicaSet:

```text
deployment.apps/nginx with revision #3
Pod Template:
  Labels:       app=nginx
        pod-template-hash=56c45fd5ff
  Containers:
   nginx:
    Image:      nginx
```

```text
deployment.apps/nginx with revision #2
Pod Template:
  Labels:       app=nginx
        pod-template-hash=79f698694b
  Annotations:  kubectl.kubernetes.io/restartedAt: 2026-10-06T07:49:29-07:00
  Containers:
   nginx:
    Image:      nginx
```

## Important fields

| Field | Default | Meaning |
|---|---|---|
| `replicas` | 1 | How many pods |
| `selector` | none (required) | How the Deployment finds its pods. **Immutable** after creation |
| `strategy.type` | `RollingUpdate` | `RollingUpdate`, or `Recreate` (delete all, then create all, with downtime) |
| `strategy.rollingUpdate.maxSurge` | 25% | Extra pods allowed during an update (Section 8) |
| `strategy.rollingUpdate.maxUnavailable` | 25% | Pods allowed to be unavailable during an update (Section 8) |
| `revisionHistoryLimit` | 10 | How many old ReplicaSets to keep for rollback |
| `minReadySeconds` | 0 | How long a new pod must stay ready before it counts as available |
| `progressDeadlineSeconds` | 600 | How long a rollout may make no progress before it is reported as failed |

## A real rollout and rollback

The real cluster's history after a restart and an undo (note the revision numbers):

```text
Before the undo:           After the undo:
REVISION  CHANGE-CAUSE     REVISION  CHANGE-CAUSE
1         <none>           2         <none>
2         <none>           3         <none>
```

A rollback does not go back in time. Kubernetes re-labels the **old template as the newest revision**, so revision 1 reappeared as revision 3, and the old entry disappeared. Revision numbers only ever go up.

Mid-rollback, both ReplicaSets existed at once, one growing and one shrinking:

```text
NAME               DESIRED   CURRENT   READY   AGE
nginx-56c45fd5ff   2         2         0       14h
nginx-79f698694b   3         3         3       2m9s
```

---

# 7. Implementing Deployments

## Lab 12: create and inspect a Deployment **(not run as written; the same kind of objects were run before)**

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 4
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx
EOF
kubectl get deployment web
kubectl get rs -l app=web
kubectl get pods -l app=web -o wide
```

Expect `READY 4/4`, one ReplicaSet named `web-<hash>`, and four pods named `web-<hash>-<suffix>`. The imperative form of the same thing is `kubectl create deployment web --image=nginx --replicas=4`.

## Lab 13: update the image and watch the rollout

```bash
kubectl set image deployment/web nginx=nginx:alpine
kubectl rollout status deployment/web
kubectl get rs -l app=web
kubectl rollout history deployment/web
```

Expect two ReplicaSets: the new one with 4 pods, and the old one at 0. The history lists two revisions. To make the history readable, record a reason right after a change:

```bash
kubectl annotate deployment/web kubernetes.io/change-cause="switch to nginx:alpine" --overwrite
kubectl rollout history deployment/web
```

## Lab 14: roll back

```bash
kubectl rollout undo deployment/web
kubectl rollout status deployment/web
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

Expect the images back to `nginx`. To go to a specific revision, use `kubectl rollout undo deployment/web --to-revision=1`, and inspect a revision first with `kubectl rollout history deployment/web --revision=1`.

## Lab 15: pause, stage several changes, resume

```bash
kubectl rollout pause deployment/web
kubectl set image deployment/web nginx=nginx:alpine
kubectl set resources deployment/web -c nginx --requests=cpu=50m,memory=32Mi
kubectl rollout resume deployment/web
kubectl rollout status deployment/web
```

While paused, no rollout starts. On `resume`, both changes roll out together, as one revision.

## Lab 16: the `Recreate` strategy

```bash
kubectl patch deployment web -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
kubectl set image deployment/web nginx=nginx
kubectl get pods -l app=web -w
```

Press Ctrl+C to stop watching. Expect **all old pods to terminate before any new one starts**, so for a moment the application has no pods. `Recreate` is for applications that cannot run two versions at the same time. The `rollingUpdate: null` part clears the rolling settings, because `Recreate` cannot have them. Set it back:

```bash
kubectl patch deployment web -p '{"spec":{"strategy":{"type":"RollingUpdate"}}}'
```

## Lab 17: restart without changing anything

```bash
kubectl rollout restart deployment/web
```

This is the command used on the real cluster to recreate pods and rebalance them across nodes.

---

# 8. `maxSurge` and `maxUnavailable`

These two fields set the **pace and safety** of a rolling update.

| Field | Meaning |
|---|---|
| `maxSurge` | How many pods **above** `replicas` may exist during the update |
| `maxUnavailable` | How many pods may be **missing** (not available) during the update |

Each is a number (`2`) or a percentage of `replicas` (`25%`).

## Rounding of percentages

| Field | Rule |
|---|---|
| `maxSurge` as a percentage | rounds **up** |
| `maxUnavailable` as a percentage | rounds **down** |

With the default 25% and `replicas: 4`, both work out to exactly 1. With `replicas: 10`, the default gives `maxSurge` = ceil(2.5) = **3**, and `maxUnavailable` = floor(2.5) = **2**.

## What the numbers mean for pod counts

With `replicas = R`:

- The **most** pods that may exist at once: `R + maxSurge`
- The **fewest** pods that must stay available: `R - maxUnavailable`

| `replicas` | `maxSurge` | `maxUnavailable` | Max pods at once | Min available |
|---|---|---|---|---|
| 4 | 1 (default 25%) | 1 (default 25%) | 5 | 3 |
| 4 | 1 | 0 | 5 | 4 |
| 4 | 0 | 1 | 4 | 3 |
| 4 | 0 | 2 | 4 | 2 |
| 4 | 100% | 0 | 8 | 4 |
| 10 | 3 (default 25%) | 2 (default 25%) | 13 | 8 |

**They cannot both be zero**, because then the update could never make progress. The API refuses it.

## What it looked like on the real cluster

The defaults, with 4 replicas, allow 5 pods and require at least 3 available. A real rollout showed exactly that: **3 old pods still serving, and 2 new pods starting**, so five existed at once:

```text
NAME                     READY   STATUS              RESTARTS   AGE
nginx-56c45fd5ff-9wkj4   1/1     Running             0          14h
nginx-56c45fd5ff-f9tgz   1/1     Running             0          78s
nginx-56c45fd5ff-n8c6z   1/1     Running             0          14h
nginx-79f698694b-6rjsx   0/1     ContainerCreating   0          2s
nginx-79f698694b-csvm9   0/1     ContainerCreating   0          1s
```

| What you see | Why |
|---|---|
| 3 old pods `Running` | `maxUnavailable` of 1 allowed one old pod to go, and the other three keep serving, which is the minimum of 3 |
| 2 new pods `ContainerCreating` | One was allowed by the surge and one by the freed slot, giving 5 pods in total |
| The Service kept answering | Only ready pods are endpoints, so traffic stayed on the three old pods |

The messages from `kubectl rollout status` reflect the same counts: `2 out of 4 new replicas have been updated`, then `3 out of 4`, then `1 old replicas are pending termination`.

## The trade-offs

| Setting | Effect | Use when |
|---|---|---|
| `maxSurge: 1`, `maxUnavailable: 0` | Capacity never drops. Needs room for one extra pod | You cannot lose any capacity (the safest) |
| `maxSurge: 0`, `maxUnavailable: 1` | No extra pods, but capacity dips by one | The cluster is nearly full |
| `maxSurge: 100%`, `maxUnavailable: 0` | The whole new set is created before the old one goes. Fast, and needs double the room | You have spare capacity and want the quickest update |
| `maxSurge: 0`, `maxUnavailable: 100%` | Every old pod goes at once. It behaves like `Recreate` | Rarely a good idea |

A new pod only counts as available after its **readiness probe** passes (and `minReadySeconds` has elapsed). Without a probe, a pod counts as ready the moment its container starts, which can send traffic to an app that is not up yet. This is one of the strongest reasons to define readiness probes.

---

# 9. Implementing `maxSurge` and `maxUnavailable`

Labs 18 to 21 were **run on the real cluster**, and the observed results are shown after each lab. Lab 22 was not run. To make the pace visible, the labs use a readiness probe with a delay, so each new pod takes about ten seconds to become available.

You need **two** shells: one to change things (**Shell A**) and one to watch (**Shell B**). Open a second master shell with `multipass shell master` in another PowerShell window. A new shell reads the same kubeconfig file, so it uses the `appdesign` namespace too.

## The counter

Counting pod lines is unreliable, because terminating pods still appear in `kubectl get pods`. A better measure is the Deployment's own numbers, printed every two seconds:

```bash
while true; do
  echo "$(date +%T)  $(kubectl get deployment rolling -o jsonpath='{.status.replicas} total, {.status.availableReplicas} available')"
  sleep 2
done
```

`total` is the number of pods the Deployment owns, and `available` is the number ready to serve. In a steady state it prints `4 total, 4 available`. Press Ctrl+C to stop it.

> **Habit to build:** after every `kubectl set image`, look for the line `deployment.apps/NAME image updated`. If it is missing, the image was already that value, the pod template did not change, and **no rollout starts** (see Lab 20).

## Lab 18: the safe setting, `maxSurge: 1`, `maxUnavailable: 0`

Optionally pre-pull the second image on both workers, so the timings are not mixed with a download. Run these in PowerShell, one at a time:

```powershell
multipass exec worker1 -- sudo timeout 300 ctr -n k8s.io images pull docker.io/library/nginx:alpine
multipass exec worker2 -- sudo timeout 300 ctr -n k8s.io images pull docker.io/library/nginx:alpine
```

**Shell A:**

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rolling
spec:
  replicas: 4
  selector:
    matchLabels:
      app: rolling
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: rolling
    spec:
      containers:
      - name: nginx
        image: nginx
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
EOF
kubectl rollout status deployment/rolling
```

When the Deployment is first created there is no old pod, so all four start together, and `rollout status` climbs from `0 of 4` to `3 of 4 updated replicas are available`. `maxSurge` and `maxUnavailable` only govern **updates**.

Start the counter in **Shell B**, wait for a few steady lines, then in **Shell A**:

```bash
kubectl set image deployment/rolling nginx=nginx:alpine
kubectl rollout status deployment/rolling
```

### Observed on the real cluster

| Number | Predicted | Observed |
|---|---|---|
| Highest `total` | 5 | **5**, and never 6 |
| Lowest `available` | 4 | **4** on every line (about 35 samples). It never dipped |
| Duration | 40 to 60 s | **about 51 s** (10:45:21 to 10:46:10) |

The counter held `4 total, 4 available`, then `5 total, 4 available` for the whole update, then `4 total, 4 available` again. `rollout status` stepped through `1 out of 4`, `2 out of 4`, `3 out of 4` and then `1 old replicas are pending termination`.

Four waves of about 12 seconds each add up to the 51 seconds: a new pod starts, waits out its 10-second readiness probe, becomes available, and only then is an old pod removed. That waiting is the price of `maxUnavailable: 0`. The counter never showed `5 available`, probably because the handoff between waves is shorter than the two-second sampling interval (an inference).

Afterwards, `kubectl get rs -l app=rolling` showed the old ReplicaSet at **0** and the new one at **4**, and all four pods ran `nginx:alpine`.

## Lab 19: the cheap setting, `maxSurge: 0`, `maxUnavailable: 2`

Change only the strategy. A strategy change does **not** start a rollout:

```bash
kubectl patch deployment rolling -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":2}}}}'
kubectl get deployment rolling -o jsonpath='{.spec.strategy.rollingUpdate}{"\n"}'
```

Start the counter in Shell B. In Shell A, change the image back, then check the ReplicaSets:

```bash
kubectl set image deployment/rolling nginx=nginx
kubectl rollout status deployment/rolling
kubectl get rs -l app=rolling
kubectl rollout history deployment/rolling
```

### Observed on the real cluster

| Number | Predicted | Observed |
|---|---|---|
| Highest `total` | 4 | **4**. No extra pods were ever created |
| Lowest `available` | 2 | **2**, from 10:57:41 to 10:58:04 |
| Duration | about half of Lab 18 | **about 29 s** (10:57:41 to 10:58:10), 57% of Lab 18's time |

The counter held `4 total, 4 available` until 10:57:41, then dropped straight to **`4 total, 2 available`**: two old pods were removed at once. It stayed at 2 for about 23 seconds, then showed 3, then 4. I had predicted "two waves of two", but `rollout status` showed the new ReplicaSet going from 0 to 2 and then to 3, so the pods did not arrive in two clean pairs. The numbers that matter held: a maximum of 4, a minimum of 2, and a faster update.

Two further results:

- `patched (no change)` means the strategy already had those values.
- Setting the image back to `nginx` made the pod template identical to the original, so the Deployment **reused the old ReplicaSet** (`rolling-85bc46c95d`, now 4 of 4) and scaled the other to 0. No third ReplicaSet appeared. The history showed revisions **2 and 3**, so the old template was re-labeled as the newest revision, just like the rollback on the nginx Deployment.

**Comparing the two settings:**

| | Lab 18 | Lab 19 |
|---|---|---|
| Settings | `maxSurge: 1`, `maxUnavailable: 0` | `maxSurge: 0`, `maxUnavailable: 2` |
| Max pods | 5 | 4 |
| Min available | 4 | 2 |
| Time | 51 s | 29 s |
| Costs | One pod's worth of spare room, and time | Half the capacity for about 25 s |

## Lab 20: percentages, and a bad rollout

With 4 replicas, `maxSurge: 50%` rounds **up** to 2, and `maxUnavailable: 25%` rounds **down** to 1, so the prediction is a maximum of **6 pods** and a minimum of **3 available**.

```bash
kubectl patch deployment rolling -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":"50%","maxUnavailable":"25%"}}}}'
kubectl get deployment rolling -o jsonpath='{.spec.strategy.rollingUpdate}{"\n"}'
kubectl set image deployment/rolling nginx=nginx:alpine
kubectl rollout status deployment/rolling
```

### Observed on the real cluster: an accidental stall

Two things went differently from the plan, and both are instructive.

**1. A no-op update.** A first `kubectl set image deployment/rolling nginx=nginx` printed **no** `image updated` line, and `rollout status` reported success at once. The image was already `nginx`, so the template did not change and nothing rolled out. The counter showed `4 total, 4 available` throughout.

**2. A typo that stalled the rollout.** The next command was `kubectl set image deployment/rolling nginx=nginx-alpine`, with a **hyphen** where the colon belongs. `nginx-alpine` is not an image, so the new pods could never start. The rollout stalled, and the state was:

```text
NAME                 DESIRED   CURRENT   READY   AGE
rolling-57f748f7b4   3         3         0       10m      <- new, bad image: none ready
rolling-85bc46c95d   3         3         3       37m      <- old: still serving

NAME      READY   UP-TO-DATE   AVAILABLE   AGE
rolling   3/4     3            3           38m

NAME                       IMAGE
rolling-57f748f7b4-7n9xn   nginx-alpine
rolling-57f748f7b4-kwmls   nginx-alpine
rolling-57f748f7b4-sk8zx   nginx-alpine
rolling-85bc46c95d-2xpf5   nginx
rolling-85bc46c95d-mx6bk   nginx
rolling-85bc46c95d-rkft2   nginx
```

| What you see | What it shows |
|---|---|
| **3 old + 3 new = 6 pods** | The maximum: 4 plus a surge of 2 (50% of 4) |
| **3 available** | The minimum: 4 minus 1 (25% of 4, rounded down) |
| New pods `READY 0` | Their image could not be used. (Their `STATUS` column was not captured. `ErrImagePull` or `ImagePullBackOff` is the almost certain cause) |
| `rollout status` stuck on `3 out of 4 new replicas have been updated` | The update could not make progress, and could not make things worse |

This is the safety of a rolling update on a bad image. The rollout went as far as the limits allowed and then stopped, with three healthy old pods still serving. The fix is `kubectl rollout undo deployment/rolling`, or setting a correct image.

**3. The progress deadline.** After the correct `nginx:alpine` was set, `kubectl rollout status` immediately printed:

```text
error: deployment "rolling" exceeded its progress deadline
```

By then the stalled rollout was more than 10 minutes old, and a Deployment gives up on a rollout that makes no progress for `progressDeadlineSeconds` (default **600**). It looks like `rollout status` reported that earlier timeout right after the corrected update, which is my best explanation, not something verified. The Deployment was deleted before it could be seen whether the corrected rollout then succeeded. The lesson: this error does not prove the newest change failed, so check `kubectl get rs` and `kubectl get pods`.

A clean percentage run (a correct image from a healthy start) was **not** captured. Expect up to 6 total and at least 3 available.

## Lab 21: both zero is refused

```bash
kubectl patch deployment rolling -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":0}}}}'
kubectl get deployment rolling -o jsonpath='{.spec.strategy.rollingUpdate}{"\n"}'
```

### Observed on the real cluster

```text
The Deployment "rolling" is invalid: spec.strategy.rollingUpdate.maxUnavailable: Invalid value: 0: may not be 0 when `maxSurge` is 0
{"maxSurge":"50%","maxUnavailable":"25%"}
```

The API refuses the change, and the previous values are untouched.

## Lab 22: compare with `Recreate` timing **(not run)**

If you ran Lab 16, compare its watch: with `Recreate` there is a moment with **no** pods at all, while the settings above never went below the minimums shown.

## Clean up

```bash
kubectl delete deployment rolling
```

---

# 10. DaemonSets

## What a DaemonSet does

A **DaemonSet** runs **one pod on every node** (or on every node that matches a selector). When a node joins the cluster, it gets a pod automatically. When a node leaves, its pod is cleaned up.

Typical uses are node-level agents: log collectors, monitoring exporters, storage drivers, and **networking**. Your cluster already runs two DaemonSets.

## The DaemonSets in your cluster (real output)

```text
NAMESPACE      NAME              DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kube-flannel   kube-flannel-ds   3         3         3       3            3           <none>                   40h
kube-system    kube-proxy        3         3         3       3            3           kubernetes.io/os=linux   42h
```

| Column | Meaning |
|---|---|
| `DESIRED` | The number of nodes the DaemonSet wants a pod on. Here 3, one per node |
| `CURRENT` / `READY` | Pods that exist and are ready |
| `UP-TO-DATE` | Pods running the latest template |
| `NODE SELECTOR` | Which nodes it targets. `kube-proxy` selects Linux nodes, and flannel has no restriction |

Both run on the **master too**, even though the master carries the `node-role.kubernetes.io/control-plane:NoSchedule` taint. They can, because their pod templates **tolerate** that taint. A DaemonSet that does not tolerate it will **skip the master** (Section 11).

## Where DaemonSet pods go

| Mechanism | Effect |
|---|---|
| No selector | Every node, subject to taints |
| `nodeSelector` / node affinity in the template | Only matching nodes |
| Tolerations in the template | Allow nodes with matching taints, such as the control plane |
| Automatic tolerations | Kubernetes adds tolerations for conditions such as `not-ready`, `unreachable`, and memory or disk pressure, so a node-level agent keeps running when a node is unhealthy |

## Updates

| `updateStrategy` | Behavior |
|---|---|
| `RollingUpdate` (default) | Pods are replaced node by node, with `maxUnavailable` (default 1) controlling the pace. A `maxSurge` (default 0) is also available in recent versions |
| `OnDelete` | A pod is replaced only when you delete it. For agents you want to update by hand |

## DaemonSet versus Deployment

| | Deployment | DaemonSet |
|---|---|---|
| Number of pods | You choose `replicas` | One per matching node |
| Placement | The scheduler decides | One per node, by definition |
| Scales with | Your setting | The number of nodes |

---

# 11. Implementing DaemonSets

Labs 23 to 26 were **run on the real cluster**, with the observed results after each lab. They build on each other: do not delete the DaemonSet between them.

## Lab 23: a node logger, with no toleration

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-logger
spec:
  selector:
    matchLabels:
      app: node-logger
  template:
    metadata:
      labels:
        app: node-logger
    spec:
      containers:
      - name: logger
        image: busybox
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        command:
        - sh
        - -c
        - |
          while true; do
            echo "running on $NODE_NAME at $(date -u +%T)"
            sleep 30
          done
EOF
sleep 20
kubectl get daemonset node-logger
kubectl get pods -l app=node-logger -o wide
kubectl logs -l app=node-logger --prefix --tail=2
```

The `env` block gives each pod the name of its own node, through the downward API.

### Observed on the real cluster

```text
NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
node-logger   2         2         2       2            2           <none>          20s
NAME                READY   STATUS    RESTARTS   AGE   IP             NODE      ...
node-logger-k9xq6   1/1     Running   0          20s   10.244.2.193   worker2
node-logger-s9h99   1/1     Running   0          20s   10.244.1.52    worker1
[pod/node-logger-s9h99/logger] running on worker1 at 14:44:10
[pod/node-logger-k9xq6/logger] running on worker2 at 07:16:09
```

| Prediction | Observed |
|---|---|
| `DESIRED 2`, not 3 | **2** |
| One pod on each worker, **none on the master**, whose taint is not tolerated | `k9xq6` on worker2 and `s9h99` on worker1. Nothing on the master |
| Each log line names a different worker | `running on worker1` and `running on worker2` |

**A surprise in the logs:** the two lines were printed in the same command, at most 30 seconds apart, yet their clocks differ by 7 hours 28 minutes (`14:44:10` against `07:16:09`). The nodes' clocks disagreed at that moment. See Section 15, "A later episode".

## How flannel and kube-proxy get onto the master

They run on the master, so their templates must tolerate its taint:

```bash
kubectl -n kube-flannel get daemonset kube-flannel-ds -o jsonpath='{.spec.template.spec.tolerations}{"\n"}'
kubectl -n kube-system get daemonset kube-proxy -o jsonpath='{.spec.template.spec.tolerations}{"\n"}'
```

```text
[{"effect":"NoSchedule","operator":"Exists"}]
[{"operator":"Exists"}]
```

flannel tolerates **any** `NoSchedule` taint, which includes the master's. kube-proxy has a bare `operator: Exists` with no key and no effect, so it tolerates **every** taint of any effect. That is the usual pattern for node-level agents, and it is why kube-proxy kept running through the `NoExecute` experiments.

## Lab 24: add a toleration so it also runs on the master

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-logger
spec:
  selector:
    matchLabels:
      app: node-logger
  template:
    metadata:
      labels:
        app: node-logger
    spec:
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: logger
        image: busybox
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        command:
        - sh
        - -c
        - |
          while true; do
            echo "running on $NODE_NAME at $(date -u +%T)"
            sleep 30
          done
EOF
kubectl rollout status daemonset/node-logger
kubectl get daemonset node-logger
kubectl get pods -l app=node-logger -o wide
```

### Observed on the real cluster

```text
Waiting for daemon set "node-logger" rollout to finish: 1 out of 3 new pods have been updated...
Waiting for daemon set "node-logger" rollout to finish: 2 out of 3 new pods have been updated...
Waiting for daemon set "node-logger" rollout to finish: 2 of 3 updated pods are available...
daemon set "node-logger" successfully rolled out
NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
node-logger   3         3         3       3            3           <none>          7h30m
NAME                READY   STATUS    RESTARTS   AGE     IP             NODE
node-logger-pl5cx   1/1     Running   0          7h28m   10.244.1.53    worker1
node-logger-wsm2b   1/1     Running   0          7h28m   10.244.2.194   worker2
node-logger-xnfjg   1/1     Running   0          7h29m   10.244.0.9     master
```

| Prediction | Observed |
|---|---|
| `DESIRED 3`, with a pod on the master | **3**, with `xnfjg` on the master |
| The workers' pods are **replaced** (the template changed) | Yes: the names changed (`k9xq6`, `s9h99` became `wsm2b`, `pl5cx`) |
| A rolling update through the nodes | `rollout status` stepped through `1`, `2` and `3 of 3` and ended with `successfully rolled out` |

**The ages are impossible:** `7h30m`, for objects created a minute or two earlier. The master's clock was behind when the objects were created, and then jumped forward about 7.5 hours, so the stored creation times are wrong. Objects created after the clocks were corrected have normal ages. See Section 15.

## Lab 25: limit the DaemonSet with a node label

Use the label value `enabled`, not `on`: YAML reads a bare `on` as a boolean.

```bash
kubectl label node worker1 logging=enabled
kubectl patch daemonset node-logger -p '{"spec":{"template":{"spec":{"nodeSelector":{"logging":"enabled"}}}}}'
kubectl rollout status daemonset/node-logger
kubectl get daemonset node-logger
kubectl get pods -l app=node-logger -o wide
```

Then react to label changes:

```bash
kubectl label node worker2 logging=enabled
sleep 10
kubectl get daemonset node-logger
kubectl get pods -l app=node-logger -o wide
kubectl label node worker2 logging-
sleep 10
kubectl get daemonset node-logger
kubectl get pods -l app=node-logger -o wide
```

### Observed on the real cluster

```text
(after the patch)
node-logger   1   1   1   1   1   logging=enabled   9h
node-logger-h8gxv   1/1   Running   0   2s   10.244.1.54   worker1

(after labeling worker2, 10 s later)
node-logger   2   2   2   2   2   logging=enabled   9h
node-logger-h8gxv   1/1   Running   0   62s   10.244.1.54    worker1
node-logger-nqzf2   1/1   Running   0   10s   10.244.2.195   worker2

(after removing worker2's label, 10 s later)
node-logger   1   1   1   1   1   logging=enabled   9h
node-logger-h8gxv   1/1   Running       0   72s   10.244.1.54    worker1
node-logger-nqzf2   1/1   Terminating   0   20s   10.244.2.195   worker2
```

| Step | Predicted | Observed |
|---|---|---|
| After the patch | `DESIRED 1`, the only pod on worker1 | **`DESIRED 1`**, one pod on worker1. The `NODE SELECTOR` column now reads `logging=enabled`. The pods on the master and worker2 were deleted |
| After labeling worker2 | `DESIRED 2`, a new pod on worker2 within seconds, worker1's not restarted | `DESIRED 2`. `nqzf2` appeared on worker2, **10 seconds old**, and worker1's `h8gxv` kept its name and age |
| After removing worker2's label | `DESIRED 1`, worker2's pod deleted | `DESIRED 1`, and `nqzf2` was `Terminating` |

A DaemonSet reacts to node labels within seconds. The pod's own shell has no signal handler, so a pod like `nqzf2` can stay in `Terminating` for up to 30 seconds (as in Lab 29). That specific lingering was not confirmed for this pod.

## Lab 26: a rolling image update

First remove the node selector, so the DaemonSet covers all three nodes again:

```bash
kubectl patch daemonset node-logger --type json -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
kubectl rollout status daemonset/node-logger
kubectl get daemonset node-logger
kubectl get pods -l app=node-logger -o wide
```

Expect `DESIRED 3` with pods on all three nodes. Then change the image and watch the pace:

```bash
kubectl set image daemonset/node-logger logger=busybox:1.36
for i in $(seq 1 50); do
  echo "$(date -u +%T)  $(kubectl get pods -l app=node-logger --no-headers -o custom-columns=NODE:.spec.nodeName,PHASE:.status.phase,IMAGE:.spec.containers[0].image | awk '{printf "%s:%s:%s  ", $1, $2, $3}')"
  sleep 3
done
kubectl rollout status daemonset/node-logger
kubectl rollout history daemonset/node-logger
```

Keep the laptop awake during the loop (about two and a half minutes).

### Observed on the real cluster

```text
16:28:30  worker1:Running:busybox  master:Running:busybox  worker2:Running:busybox
[... unchanged for 30 seconds ...]
16:29:01  worker1:Running:busybox  master:Running:busybox  worker2:Pending:busybox:1.36
16:29:07  worker1:Running:busybox  master:Running:busybox  worker2:Running:busybox:1.36
[... unchanged for 30 seconds ...]
16:29:38  master:Pending:busybox:1.36  worker1:Running:busybox  worker2:Running:busybox:1.36
16:29:41  master:Running:busybox:1.36  worker1:Running:busybox  worker2:Running:busybox:1.36
[... unchanged for 30 seconds ...]
16:30:12  master:Running:busybox:1.36  worker2:Running:busybox:1.36  worker1:Pending:busybox:1.36
16:30:18  master:Running:busybox:1.36  worker2:Running:busybox:1.36  worker1:Running:busybox:1.36
daemon set "node-logger" successfully rolled out

REVISION  CHANGE-CAUSE
1         <none>
3         <none>
4         <none>
5         <none>
```

| Prediction | Observed |
|---|---|
| **One node at a time** | Yes. Only one node changed image at any moment, and the lines mix `busybox` and `busybox:1.36` |
| About 30 to 35 s per node | **About 31 s** between one node becoming ready and the next replacement, plus about 6 s for a new pod to start. All three nodes took about **1 minute 50 seconds** (16:28:28 to 16:30:18) |
| Two revisions in the history | **Wrong: four** (1, 3, 4, 5) |

How to read the plateaus:

- The loop prints `status.phase`, and a pod that is shutting down still has the phase `Running`. So each 30-second plateau is most likely the **old pod terminating**. The default update strategy deletes one old pod, waits until it is gone, and only then creates the replacement. The 30 seconds match the default grace period, since this pod's shell ignores the termination signal (the same cause as Lab 29). This is consistent with the evidence, but a `kubectl get pods` listing, which shows `Terminating`, would show it directly.
- **The order of the nodes** was worker2, then the master, then worker1. That is what happened here, and I would not generalize it.
- **Revision 2 is missing from the history.** The template sequence was: (1) the original, (2) with a toleration, (3) with a toleration and `nodeSelector`, then removing the selector gave a template **identical to revision 2**. The DaemonSet appears to have reused that revision and renumbered it as 4, and the image change became 5. As with Deployments, revision numbers only go up, and an old number disappears when its template is reused. This is an inference, since the DaemonSet was deleted before it could be checked.

To see how much the signal handling matters, repeat Lab 26 with the `trap` command from Lab 29b in the template. Each node should then take only a few seconds, for a total of about 20 seconds. That was not run.

## Clean up

```bash
kubectl delete daemonset node-logger
kubectl label node worker1 logging-
kubectl get nodes --show-labels | grep logging
```

The last command should print nothing.

---

# 12. Jobs and CronJobs

## Jobs: work that finishes

A Deployment keeps pods running forever. A **Job** runs pods **until the work is done**, then stops. A Job creates one or more pods, retries failed ones, and counts successful completions.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: hello-job
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: hello
        image: busybox
        command: ["sh", "-c", "echo hello; sleep 5; echo done"]
```

| Field | Default | Meaning |
|---|---|---|
| `template` | required | The pod. `restartPolicy` **must be `Never` or `OnFailure`** (not `Always`) |
| `completions` | 1 | How many successful pods the Job needs |
| `parallelism` | 1 | How many pods may run at the same time |
| `backoffLimit` | 6 | How many retries before the Job is marked failed (Section 14) |
| `activeDeadlineSeconds` | none | A time limit for the whole Job (Section 13) |
| `ttlSecondsAfterFinished` | none | Delete the Job (and its pods) this long after it finishes |

## Pods and restart policy

| `restartPolicy` | A failing container |
|---|---|
| `Never` | The pod is marked `Failed`, and the Job creates a **new pod** for the retry. You keep each failed pod for inspection |
| `OnFailure` | The container is restarted **inside the same pod**. The pod stays, with a growing `RESTARTS` count |

Pods of a Job that **completes** are not deleted, and neither are failed pods created under `restartPolicy: Never`. (When a Job fails, pods that are still running are deleted, as Labs 29 and 36 showed.) They stay in `Completed` (or `Error`) state, so you can read their logs, until you delete the Job or its `ttlSecondsAfterFinished` expires.

## Patterns

| Pattern | Settings |
|---|---|
| One pod, run once | The defaults |
| N tasks, one at a time | `completions: N`, `parallelism: 1` |
| N tasks, a few at a time | `completions: N`, `parallelism: P` |

## CronJobs: Jobs on a schedule

A **CronJob** creates a Job on a repeating schedule, like the Unix `cron`.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: tick
spec:
  schedule: "*/1 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: tick
            image: busybox
            command: ["sh", "-c", "date; echo tick"]
```

The `jobTemplate` is a full Job spec, so every Job field applies, including `backoffLimit` and `activeDeadlineSeconds`.

### The schedule

Five fields: **minute, hour, day of month, month, day of week**.

```text
┌───────── minute (0-59)
│ ┌─────── hour (0-23)
│ │ ┌───── day of month (1-31)
│ │ │ ┌─── month (1-12)
│ │ │ │ ┌─ day of week (0-6, Sunday is 0)
* * * * *
```

| Schedule | Meaning |
|---|---|
| `*/1 * * * *` or `* * * * *` | Every minute (the finest granularity) |
| `*/5 * * * *` | Every five minutes |
| `0 2 * * *` | Every day at 02:00 |
| `30 8 * * 1-5` | 08:30 on weekdays |
| `@hourly`, `@daily` | Shortcuts |

Set `timeZone` (for example `timeZone: "America/Los_Angeles"`) so the schedule does not depend on the controller's own clock, which is commonly UTC.

### CronJob fields

| Field | Default | Meaning |
|---|---|---|
| `schedule` | required | The cron expression |
| `timeZone` | the controller's zone | The zone the schedule is read in |
| `concurrencyPolicy` | `Allow` | `Allow` runs overlapping Jobs. `Forbid` never overlaps: a run that falls during an active Job is **postponed** until it ends, then one catch-up run starts. `Replace` deletes the running Job and starts the new one (Lab 33) |
| `startingDeadlineSeconds` | none | How late a run may start before it is counted as missed |
| `suspend` | false | Pause the schedule without deleting it |
| `successfulJobsHistoryLimit` | 3 | Finished successful Jobs to keep (Section 16) |
| `failedJobsHistoryLimit` | 1 | Finished failed Jobs to keep (Section 16) |

Each run creates a Job named `<cronjob-name>-<number>`.

---

# 13. Implementing Jobs and CronJobs, including `activeDeadlineSeconds`

All the labs in this section (27 to 33, including 29b) were **run on the real cluster**, with their results shown after each lab.

## Lab 27: a simple Job

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: hello-job
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: hello
        image: busybox
        command: ["sh", "-c", "echo hello from $(hostname); sleep 5; echo done"]
EOF
kubectl get job hello-job
kubectl wait --for=condition=complete job/hello-job --timeout=90s
kubectl get pods -l job-name=hello-job
kubectl logs job/hello-job
```

Expect the Job to reach `COMPLETIONS 1/1`, its pod to show **`Completed`**, and the logs to show `hello from <pod-name>` and `done`. The pod is still there afterwards. The label `job-name=hello-job` is added to a Job's pods automatically (check with `kubectl get pods --show-labels`).

### Observed on the real cluster

```text
job.batch/hello-job created
job.batch/hello-job condition met
NAME        STATUS     COMPLETIONS   DURATION   AGE
hello-job   Complete   1/1           9s         9s
NAME              READY   STATUS      RESTARTS   AGE
hello-job-n6z79   0/1     Completed   0          9s
hello from hello-job-n6z79
done
```

| Output | Meaning |
|---|---|
| `STATUS Complete`, `COMPLETIONS 1/1` | The Job did what it was created for, and stopped |
| `DURATION 9s` | The 5-second `sleep`, plus about 4 seconds to start the container (the extra time is an inference) |
| Pod `hello-job-n6z79`, `READY 0/1`, `Completed` | The container finished, so `0/1` is normal. The pod stays so you can read its logs |
| `hello from hello-job-n6z79` | `$(hostname)` inside a pod is the pod's name |

## Lab 28: several completions, in parallel

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: batch-job
spec:
  completions: 6
  parallelism: 2
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: busybox
        command: ["sh", "-c", "echo working on $(hostname); sleep 10"]
EOF
for i in $(seq 1 14); do
  echo "$(date -u +%T)  $(kubectl get pods -l job-name=batch-job --no-headers 2>/dev/null | awk '{c[$3]++} END {for (s in c) printf "%s=%d ", s, c[s]}')  job=$(kubectl get job batch-job --no-headers | awk '{print $2, $3}')"
  sleep 4
done
```

### Observed on the real cluster

```text
04:50:27  ContainerCreating=2   job=Running 0/6
04:50:31  Running=2   job=Running 0/6
04:50:39  Running=2   job=Running 0/6
04:50:43  ContainerCreating=1 Completed=2   job=Running 1/6
04:50:47  Running=2 Completed=2   job=Running 2/6
04:50:55  Running=1 Completed=3   job=Running 2/6
04:50:59  Running=2 Completed=4   job=Running 4/6
04:51:08  Running=2 Completed=4   job=Running 4/6
04:51:12  Completed=6   job=Complete 6/6
```

| Prediction | Observed |
|---|---|
| Never more than 2 pods active at once | Never above 2: every sample has `Running` plus `ContainerCreating` at 2 or fewer |
| Three waves of two | A **sliding window**, not strict pairs. A replacement pod starts as soon as one finishes |
| `6/6` and six `Completed` pods | `job=Complete 6/6`, `Completed=6` |
| About 40 seconds | About **45 seconds** (04:50:27 to 04:51:12) |

At 04:50:43, two pods had completed but the next was still being created, so only one was active for a moment. At 04:50:55, `Running=1 Completed=3` shows one pod of the second pair had already finished.

**The Job's own counter lags the pod states** by up to a few seconds. At 04:50:43 two pods are `Completed` but the Job says `1/6`, and at 04:50:55 three are done but it says `2/6`. Trust the pod states for timing and the Job's counter for the final result.

## `activeDeadlineSeconds`

`activeDeadlineSeconds` is a **time limit for the whole Job**, counted from when the Job starts. It covers all pods and all retries together. When the time is up, Kubernetes **terminates any running pods** and marks the Job failed with the reason `DeadlineExceeded`. The final `Failed` condition appears only once the pods have actually stopped, so a pod that is slow to stop delays it (see the observed run in Lab 29). It takes precedence over `backoffLimit`: a Job with retries left is still stopped when the deadline passes.

Do not confuse it with the pod-level field of the same name, which limits one pod's lifetime. The Job-level one lives under the Job's own `spec`.

## Lab 29: a Job that exceeds its deadline

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: deadline-job
spec:
  activeDeadlineSeconds: 20
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: sleeper
        image: busybox
        command: ["sh", "-c", "echo start; sleep 300"]
EOF
kubectl get pods -l job-name=deadline-job -w
```

Press Ctrl+C after the pod has gone. **Expect the pod to be terminated after about 20 seconds**, though the command would have run for 300. Then:

```bash
kubectl get job deadline-job -o jsonpath='{.status.conditions[*].type}{"  "}{.status.conditions[*].reason}{"\n"}'
kubectl describe job deadline-job
```

Expect a `Failed` condition with the reason **`DeadlineExceeded`**, and an event saying the Job was active longer than its deadline. In recent versions you may also see a `FailureTarget` condition listed before `Failed`.

### Observed on the real cluster

A timeline printed every three seconds, with the pod's name and status:

```text
14:32:22  deadline-job-p28ts ContainerCreating
14:32:25  deadline-job-p28ts Running
[... Running until 14:32:40 ...]
14:32:43  deadline-job-p28ts Terminating
[... Terminating until 14:33:11 ...]
14:33:14  No found
```

(`No found` is the awk fragment of kubectl's own message `No resources found`, so it means the pod was gone.)

| Time | Status | What happened |
|---|---|---|
| 14:32:22 | `ContainerCreating` | The Job started |
| 14:32:25 to 14:32:40 | `Running` | About 18 seconds of running |
| 14:32:43 | `Terminating` | The deadline fired, **20 seconds** after the Job began |
| 14:32:43 to 14:33:11 | `Terminating` | **About 30 seconds** stuck in Terminating |
| 14:33:14 on | gone | The pod was removed |

The Job's conditions and events:

```text
FailureTarget Failed  DeadlineExceeded DeadlineExceeded

Events:
  Type     Reason            Age   From            Message
  Normal   SuccessfulCreate  85s   job-controller  Created pod: deadline-job-p28ts
  Normal   SuccessfulDelete  65s   job-controller  Deleted pod: deadline-job-p28ts
  Warning  DeadlineExceeded  34s   job-controller  Job was active longer than specified deadline
```

| Observation | Explanation |
|---|---|
| `SuccessfulDelete` is **20 seconds** after `SuccessfulCreate` (85 s and 65 s ago) | The Job controller deleted the pod exactly at the deadline |
| The pod then took **about 30 seconds** to disappear | That is Kubernetes' default grace period. A shell running as a container's main process ignores the termination signal, so Kubernetes waits the full 30 seconds and then kills it. The exact 30 seconds fits this explanation, though the cause was not confirmed |
| `DeadlineExceeded` appeared about **51 seconds** after the pod was created | That is when the pod finally disappeared, so the `Failed` condition seems to have been set only after the pod was gone |
| Two conditions, `FailureTarget` then `Failed`, both `DeadlineExceeded` | `FailureTarget` marks the moment the Job decided to fail, and `Failed` is the final state. Recent versions use both. Compare their `lastTransitionTime` values to see the gap: `kubectl get job NAME -o jsonpath='{range .status.conditions[*]}{.type}{"  "}{.lastTransitionTime}{"\n"}{end}'` |

So the deadline is enforced on time (20 s), but **a Job takes as long as its slowest pod takes to stop**.

## Lab 29b: end the pod quickly

In Lab 29 the pod sat in `Terminating` for about 30 seconds after the deadline. This lab tests the explanation: the same Job, but the shell **handles the termination signal**, so the container exits at once.

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: deadline-fast
spec:
  activeDeadlineSeconds: 20
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: sleeper
        image: busybox
        command: ["sh", "-c", "trap 'exit 0' TERM; echo start; sleep 300 & wait"]
EOF
for i in $(seq 1 24); do echo "$(date -u +%T)  $(kubectl get pods -l job-name=deadline-fast --no-headers 2>&1 | awk '{print $1, $3}')"; sleep 3; done
kubectl get job deadline-fast -o jsonpath='{range .status.conditions[*]}{.type}{"  "}{.lastTransitionTime}{"\n"}{end}'
kubectl describe job deadline-fast | tail -6
```

An alternative is to leave the command alone and add `terminationGracePeriodSeconds: 2` under the pod's `spec`, next to `restartPolicy` (not run).

### Observed on the real cluster

```text
05:40:59  deadline-fast-6w2q2 ContainerCreating
05:41:02  deadline-fast-6w2q2 ContainerCreating
05:41:05  deadline-fast-6w2q2 Running
[... Running until 05:41:17 ...]
05:41:20  No found

FailureTarget  2026-10-09T05:41:19Z
Failed  2026-10-09T05:41:20Z

Events:
  Normal   SuccessfulCreate  64s   job-controller  Created pod: deadline-fast-6w2q2
  Normal   SuccessfulDelete  44s   job-controller  Deleted pod: deadline-fast-6w2q2
  Warning  DeadlineExceeded  43s   job-controller  Job was active longer than specified deadline
```

| | Lab 29 (no signal handler) | Lab 29b (`trap 'exit 0' TERM`) |
|---|---|---|
| The Job decides to fail (`FailureTarget`) | at 20 s | at 20 s |
| Pod in `Terminating` | **about 30 s** | **never seen** in a 3-second sample, so under 3 s |
| `FailureTarget` to `Failed` | **31 s** | **1 s** |
| `DeadlineExceeded` event, counted from pod creation | about 51 s | **21 s** |

With a signal handler, the Job went from started to finally failed in about 21 seconds, against about 51 without one. The pod's slowness to stop was the whole difference, and the Job's `Failed` state does wait for it.

Two details:

- The pod was `Running` for only about 14 seconds. The deadline counts from the **Job's** start, and about 6 seconds went on `ContainerCreating`.
- The pod exited with status 0 when asked to stop, yet the Job still ended `Failed`. A tidy exit during termination does not rescue a Job whose deadline had passed.

The usual explanation, consistent with this result but not verified by inspecting signals, is that a container's main process ignores the termination signal unless it installs a handler. Kubernetes then waits out the grace period (30 seconds by default) and kills it. This also slows drains and rolling updates for applications that do not handle the signal. Handle it, or lower `terminationGracePeriodSeconds`.

## Lab 30: the deadline beats the retries

A Job that fails every time, with plenty of retries left but a short deadline:

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: deadline-retries
spec:
  backoffLimit: 10
  activeDeadlineSeconds: 25
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: fail
        image: busybox
        command: ["sh", "-c", "echo attempt at $(date); exit 1"]
EOF
kubectl wait --for=condition=failed job/deadline-retries --timeout=90s
kubectl get pods -l job-name=deadline-retries --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CREATED:.metadata.creationTimestamp
kubectl get job deadline-retries -o jsonpath='{.status.failed}{" failed, conditions: "}{.status.conditions[*].type}{"  "}{.status.conditions[*].reason}{"\n"}'
kubectl describe job deadline-retries | tail -12
```

### Observed on the real cluster

```text
NAME                     STATUS   CREATED
deadline-retries-42qrc   Failed   2026-10-09T04:51:40Z
deadline-retries-dvfs8   Failed   2026-10-09T04:51:45Z
deadline-retries-ckchp   Failed   2026-10-09T04:51:49Z
deadline-retries-pbmlb   Failed   2026-10-09T04:51:53Z
deadline-retries-5wnn4   Failed   2026-10-09T04:51:59Z
6 failed, conditions: FailureTarget Failed  DeadlineExceeded DeadlineExceeded

Events:
  Normal   SuccessfulCreate  14m   job-controller  Created pod: deadline-retries-42qrc
  [... four more SuccessfulCreate ...]
  Normal   SuccessfulCreate  14m   job-controller  Created pod: deadline-retries-rw6v2
  Normal   SuccessfulDelete  14m   job-controller  Deleted pod: deadline-retries-rw6v2
  Warning  DeadlineExceeded  14m   job-controller  Job was active longer than specified deadline
```

| Result | Meaning |
|---|---|
| Final reason **`DeadlineExceeded`**, with only about 6 of 10 retries used | **The deadline ended a Job that still had retries left.** This is what the lab shows |
| `6 failed`, but five pods listed | A sixth pod, `rw6v2`, was created and then **deleted** when the deadline fired, so it is in the events but not in the pod list |
| Pods created 4 to 6 seconds apart | **Not normal back-off.** See Section 15, "When retry delays disappear": a node's clock was wrong |

In a cluster whose clocks agree, I would expect about two pods here (the first, and one retry about 11 seconds later), since the next retry would only come about 23 seconds after that. That expectation was not observed.

## Lab 31: a CronJob every minute

As run, this lab also set the history limits that Section 16 explains.

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: tick
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 30
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: tick
            image: busybox
            command: ["sh", "-c", "date -u; echo tick"]
EOF
kubectl get cronjob tick
for i in $(seq 1 22); do
  echo "$(date -u +%T)  $(kubectl get jobs --no-headers 2>&1 | awk '{printf "%s(%s) ", $1, $2}')"
  sleep 15
done
```

Keep the laptop awake while the loop runs (about five and a half minutes). Right after the apply there is no Job: a CronJob creates its first one at the **next minute boundary**. Afterwards:

```bash
kubectl get cronjob tick
kubectl get jobs
kubectl get pods
kubectl logs job/$(kubectl get jobs --no-headers -o custom-columns=NAME:.metadata.name | tail -1)
kubectl get cronjob tick -o jsonpath='{.status.lastScheduleTime}{"\n"}'
```

### Observed on the real cluster

```text
NAME   SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
tick   */1 * * * *   <none>     False     0        40s             49s
NAME            STATUS     COMPLETIONS   DURATION   AGE
tick-29858354   Complete   1/1           5s         40s
NAME                  READY   STATUS      RESTARTS   AGE
tick-29858354-rwnvk   0/1     Completed   0          40s
Thu Oct  8 23:14:02 UTC 2026
tick
2026-10-08T23:14:00Z
```

The timeline (every 15 seconds):

```text
23:13:55  No(resources)
23:14:10  tick-29858354(Complete)
23:15:10  tick-29858354(Complete) tick-29858355(Complete)
23:16:11  tick-29858355(Complete) tick-29858356(Complete)
23:17:11  tick-29858356(Complete) tick-29858357(Complete)
23:18:11  tick-29858357(Complete) tick-29858358(Complete)
```

| Prediction | Observed |
|---|---|
| The first Job appears at a minute boundary | `lastScheduleTime` **23:14:00Z**, about 9 seconds after the CronJob was created |
| Names rise by 1 every minute | `…354`, `…355`, `…356`, `…357`, `…358` |
| 1 Job, then 2, then it stays at 2 | Exactly that: 1 at 23:14, 2 at 23:15, and 2 from then on |
| Two pods, both `Completed` | Yes, and the pods of pruned Jobs were gone |
| One line of UTC time plus `tick` | `Thu Oct 8 23:14:02 UTC 2026` and `tick`, two seconds after the schedule |

**The number in a Job's name is the scheduled time in minutes since 1970.** `29858354 × 60` seconds is exactly 2026-10-08 23:14:00 UTC, and the other numbers match their minutes the same way. So a CronJob's Job name carries its own timestamp.

`DURATION 5s` for a command that takes milliseconds is mostly pod start-up time.

## Lab 32: run a CronJob now, pause it, and resume it

```bash
kubectl create job manual-run --from=cronjob/tick
kubectl get jobs
kubectl patch cronjob tick -p '{"spec":{"suspend":true}}'
kubectl get cronjob tick
```

Wait about two and a half minutes (`sleep 150`), then look again with `kubectl get jobs` and `kubectl get cronjob tick`. `--from=cronjob/...` creates a Job from the CronJob's template without waiting for the schedule.

### Observed on the real cluster

```text
job.batch/manual-run created
NAME            STATUS     COMPLETIONS   DURATION   AGE
manual-run      Running    0/1           0s         0s
tick-29858358   Complete   1/1           5s         2m3s
tick-29858359   Complete   1/1           4s         63s
tick-29858360   Running    0/1           3s         3s
cronjob.batch/tick patched
NAME   SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
tick   */1 * * * *   <none>     True      1        3s              6m12s

(150 seconds later)
NAME            STATUS     COMPLETIONS   DURATION   AGE
manual-run      Complete   1/1           9s         3m14s
tick-29858360   Complete   1/1           5s         3m17s
NAME   SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
tick   */1 * * * *   <none>     True      0        3m17s           9m26s
```

| Observation | Meaning |
|---|---|
| `manual-run` started at once, with a plain name | The template ran immediately |
| `SUSPEND True`, and `ACTIVE 1` straight away | Suspending does **not** stop a Job that has already started. `tick-29858360` finished by itself |
| No new `tick-…` Jobs after 150 seconds | While suspended, no runs are created, though several minute boundaries passed |
| `manual-run` stayed, but `tick-29858358` and `…359` were **pruned** | The manual Job **counted toward the CronJob's history limit of 2**. Running Jobs are not counted, only finished ones |
| `manual-run` was **deleted with the CronJob** (shown when the CronJob was deleted next) | The Job created with `--from=cronjob/…` is owned by the CronJob. That ownership explains both rows above. The owner reference itself was not inspected |

`ACTIVE` showed 1 while two Jobs (`tick-29858360` and `manual-run`) were running. Whether a manually created Job is counted there, or the count was a moment late, is unknown.

### Resuming: one run, not one per missed minute

This was run on the failing CronJob from Lab 39, whose history limit was 3 at the time. It was suspended for 150 seconds, and then resumed:

```text
(suspended; Jobs listed:)  tick-fail-29858586  tick-fail-29858587  tick-fail-29858588
(150 s later, unchanged:)  tick-fail-29858586  tick-fail-29858587  tick-fail-29858588
03:11:24                   <- time of the resume
(15 s after the resume:)   tick-fail-29858587  tick-fail-29858588  tick-fail-29858591
NAME        SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
tick-fail   */1 * * * *   <none>     False     0        40s             3h35m
```

| Prediction | Observed |
|---|---|
| While suspended, the list doesn't change | Unchanged |
| After the resume, **exactly one** new Job for the latest minute | One new Job, `…591`, which is 03:11:00 UTC. Nothing for `…589` (03:09) or `…590` (03:10) |
| The normal schedule continues | `LAST SCHEDULE 40s`, so recent again |

The skipped minutes are simply lost, which is the right behavior for most scheduled jobs.

## Lab 33: concurrency policies

A CronJob fires every minute, but each Job runs for about 100 seconds, so the runs overlap. The three policies handle that differently.

```bash
cat > /tmp/conc.yaml <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: conc-NAME
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: POLICY
  successfulJobsHistoryLimit: 5
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      activeDeadlineSeconds: 150
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: long
            image: busybox
            command: ["sh", "-c", "trap 'exit 0' TERM; echo start $(date -u +%T); sleep 100 & wait"]
EOF
run_policy() {
  p=$1
  l=$(echo $p | tr 'A-Z' 'a-z')
  sed "s/POLICY/$p/g; s/NAME/$l/g" /tmp/conc.yaml | kubectl apply -f -
  for i in $(seq 1 18); do
    echo "$(date -u +%T)  $(kubectl get jobs --no-headers 2>&1 | awk '{printf "%s(%s) ", $1, $2}') active=$(kubectl get cronjob conc-$l -o jsonpath='{.status.active[*].name}' | wc -w)"
    sleep 15
  done
  kubectl describe cronjob conc-$l | tail -10
  kubectl delete cronjob conc-$l
}
run_policy Allow
run_policy Forbid
run_policy Replace
```

Each policy takes 4.5 minutes, so keep the laptop awake and do not interrupt the loop. The function replaces `POLICY` and `NAME` in the template, using a lowercase name because CronJob names cannot contain capitals.

### Observed on the real cluster: Allow

```text
05:45:08  conc-allow-29858745(Running)  active=1
05:46:08  conc-allow-29858745(Running) conc-allow-29858746(Running)  active=2
05:46:53  conc-allow-29858745(Complete) conc-allow-29858746(Running)  active=1
05:47:08  conc-allow-29858745(Complete) conc-allow-29858746(Running) conc-allow-29858747(Running)  active=2
05:47:54  conc-allow-29858745(Complete) conc-allow-29858746(Complete) conc-allow-29858747(Running)  active=1
05:48:09  [... 747 and 748 Running ...]  active=2
```

A new Job started **every minute**, whether or not the previous one had finished, and `active` alternated between 2 and 1. Each Job lasted about 100 to 110 seconds against a 60-second schedule, so the overlap never went away.

### Observed on the real cluster: Forbid

```text
06:58:09  conc-forbid-29858818(Running)  active=1
06:59:40  conc-forbid-29858818(Running)  active=1
06:59:55  conc-forbid-29858818(Complete) conc-forbid-29858819(Running)  active=1
07:01:26  conc-forbid-29858818(Complete) conc-forbid-29858819(Running)  active=1
07:01:41  conc-forbid-29858818(Complete) conc-forbid-29858819(Complete) conc-forbid-29858821(Running)  active=1

Events:
  Normal  SuccessfulCreate  3m56s                cronjob-controller  Created job conc-forbid-29858818
  Normal  SawCompletedJob   2m11s                cronjob-controller  Saw completed job: conc-forbid-29858818, condition: Complete
  Normal  SuccessfulCreate  2m11s                cronjob-controller  Created job conc-forbid-29858819
  Normal  JobAlreadyActive  27s (x7 over 2m56s)  cronjob-controller  Not starting job because prior execution is running and concurrency policy is Forbid
  Normal  SawCompletedJob   27s                  cronjob-controller  Saw completed job: conc-forbid-29858819, condition: Complete
  Normal  SuccessfulCreate  27s                  cronjob-controller  Created job conc-forbid-29858821
```

| Observation | Meaning |
|---|---|
| `active` never exceeded 1 | No overlap, as `Forbid` promises |
| `…819` (the **06:59** run) started at about 06:59:46, right after `…818` finished, **46 seconds late** | `Forbid` did **not** discard the missed run. It postponed it until the previous Job ended |
| `…821` (the **07:01** run) started right after `…819` finished. **`…820` never ran** | Two boundaries (07:00 and 07:01) were missed during `…819`, and only **one** catch-up Job ran, for the latest one |
| `JobAlreadyActive (x7 over 2m56s)` | The controller re-checked seven times and found the prior Job still running each time |
| `SawCompletedJob` and `SuccessfulCreate` at the same instant | A new run starts the moment the previous Job completes |

I had predicted that a run falling during an active Job would simply be **skipped**, with a new Job only every two minutes. That was wrong. The effective rate was about one Job per Job duration (about 105 seconds), and the gap in the Job numbers appeared only where several boundaries had been missed at once (`…819` to `…821`). This matches the resume result in Lab 32, where a suspended CronJob created **one** Job for the latest minute: missed runs seem to collapse into a single catch-up run for the latest scheduled time. Whether a very late run is dropped depends on `startingDeadlineSeconds`, which was not tested.

### Observed on the real cluster: Replace

```text
07:02:11  conc-replace-29858822(Running)  active=1
07:03:12  conc-replace-29858823(Running)  active=1
07:04:12  conc-replace-29858824(Running)  active=1
07:05:13  conc-replace-29858825(Running)  active=1
07:06:13  conc-replace-29858826(Running)  active=1

Events:
  Normal  SuccessfulCreate  4m28s  cronjob-controller  Created job conc-replace-29858822
  Normal  SuccessfulDelete  3m28s  cronjob-controller  Deleted job conc-replace-29858822
  Normal  SuccessfulCreate  3m28s  cronjob-controller  Created job conc-replace-29858823
  Normal  SuccessfulDelete  2m28s  cronjob-controller  Deleted job conc-replace-29858823
```

| Observation | Meaning |
|---|---|
| One Job name per line, a new one every minute | One Job at a time. `active=1` throughout |
| **No `Complete` anywhere** | No Job lived long enough |
| `SuccessfulDelete` exactly 60 seconds after each `SuccessfulCreate`, and the next Job created at the same instant | The controller deleted the running Job and started the new one together, every minute |

A Job that needs 100 seconds, under `Replace` with a one-minute schedule, **never finishes**.

### The three policies compared

| Policy | Runs overlapping | A run missed during an active Job | Does a Job complete? |
|---|---|---|---|
| `Allow` (default) | Yes, `active=2` | Not applicable: it starts anyway | Yes, each after about 105 s |
| `Forbid` | **Never** | **Postponed** until the Job ends, then one catch-up run for the latest time | Yes |
| `Replace` | Never | The running Job is **deleted** and replaced | **No**, here, since each is replaced at 60 s |

---

# 14. Job `backoffLimit`

## What it does

`backoffLimit` is the number of **retries** a Job allows before it gives up and is marked **failed**. The default is **6**.

When a pod fails, the Job controller creates a replacement, but with an **exponential back-off delay**: roughly 10 seconds, then 20, 40, 80 and so on, capped at six minutes. On the real cluster the gaps between pod creations were **11, 23 and 43 seconds** (Lab 34). This needs the node clocks to agree with the master's: with a node's clock behind, the delays vanished (Section 15). The delay prevents a broken Job from hammering the cluster.

When the limit is reached, the Job gets a `Failed` condition with the reason **`BackoffLimitExceeded`**, and no more pods are created.

## How retries are counted

| `restartPolicy` | What counts toward the limit |
|---|---|
| `Never` | **Failed pods.** Each failure creates a new pod, so you see one pod per attempt |
| `OnFailure` | **Container restarts** inside the one pod |

With `restartPolicy: Never`, a `backoffLimit` of N allows the first attempt plus N retries, so **N + 1 pods** in total. On the real cluster, `backoffLimit: 3` produced exactly **4 pods** (Lab 34). `backoffLimit: 0` means **no retries at all**: one failure fails the Job, and Lab 35 produced exactly one pod.

## `backoffLimit` versus `activeDeadlineSeconds`

| | `backoffLimit` | `activeDeadlineSeconds` |
|---|---|---|
| Limits | The **number of failures** | The **total time** |
| Failure reason | `BackoffLimitExceeded` | `DeadlineExceeded` |
| Good for | A job that fails fast and repeatedly | A job that might hang |

Use both for a robust Job. A pod that hangs never "fails", so `backoffLimit` alone would let it run forever. A deadline stops it.

## What to do with failed pods

Failed pods are **kept** (with `Never`), so you can read their logs. With `OnFailure` the opposite happened on the real cluster: when the Job reached its limit, the controller **deleted the pod** (Lab 36), and its logs went with it.

```bash
kubectl get pods -l job-name=<JOB-NAME>
kubectl logs <A-FAILED-POD>
```

They are removed when you delete the Job or when its TTL expires.

---

# 15. Implementing `backoffLimit`

Labs 34 to 37 were **run on the real cluster**, and the observed results are shown after each lab.

**Tips for these labs:**

- `kubectl wait` prints nothing while it waits, which looks like a hang. It prints `condition met` when the Job reaches the state you asked for.
- Keep the laptop awake while a timing loop runs. In one run, the shell paused for about 18 minutes (its timestamps jumped from `21:39:26` to `21:57:46`), and the Job itself had done nothing during that time.
- Compare **creation timestamps** to measure retry timing. They do not depend on when you happen to look.

## Lab 34: a Job that always fails, with `backoffLimit: 3`

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: backoff-job
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: fail
        image: busybox
        command: ["sh", "-c", "echo attempt at $(date); exit 1"]
EOF
kubectl wait --for=condition=failed job/backoff-job --timeout=240s
```

Then read the outcome:

```bash
kubectl get pods -l job-name=backoff-job --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CREATED:.metadata.creationTimestamp
kubectl get job backoff-job -o jsonpath='{.status.failed}{" failed pods, conditions: "}{.status.conditions[*].type}{"  "}{.status.conditions[*].reason}{"\n"}'
kubectl get pods -l job-name=backoff-job --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\n"}{end}' | while read t; do s=$(date -u -d "$t" +%s); [ -n "$prev" ] && echo "gap: $((s-prev))s"; prev=$s; done
kubectl logs <ONE-OF-THE-FAILED-PODS>
```

The last command prints the seconds between consecutive pod creations. Replace `<ONE-OF-THE-FAILED-PODS>` with a real pod name, brackets included.

### Observed on the real cluster

```text
NAME                STATUS   CREATED
backoff-job-zcfd5   Failed   2026-10-08T21:38:14Z
backoff-job-gz4vk   Failed   2026-10-08T21:38:25Z
backoff-job-nm7rg   Failed   2026-10-08T21:38:48Z
backoff-job-djrxr   Failed   2026-10-08T21:39:31Z
4 failed pods, conditions: FailureTarget Failed  BackoffLimitExceeded BackoffLimitExceeded
gap: 11s
gap: 23s
gap: 43s

attempt at Thu Oct 8 21:38:15 UTC 2026
```

| Prediction | Observed |
|---|---|
| 4 pods (the first attempt plus 3 retries) | **4 pods**, and `failed=4` |
| Gaps of about 10, 20 and 40 seconds | **11, 23 and 43 seconds** |
| Final state `Failed`, reason `BackoffLimitExceeded` | `FailureTarget Failed`, both with `BackoffLimitExceeded` |
| About a minute and a half | **About 78 seconds** from the first pod to the last |

The gaps roughly double (11, then 23, then 43), which is the exponential back-off. Each is a second or three above 10, 20 and 40, since the pod's own run time adds a little. A fourth retry would have waited about 80 seconds, up to a cap of six minutes.

While the retries were running, a snapshot taken at about a minute showed `failed=3` and an **empty** conditions list. The Job is not failed until the limit is used up.

The log shows one line, `attempt at ...`, and its time is one second after the pod's creation, so the container started almost at once (the image was cached).

## Lab 35: `backoffLimit: 0`, no retries

```bash
kubectl delete job backoff-job
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: backoff-job
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: fail
        image: busybox
        command: ["sh", "-c", "echo attempt at $(date); exit 1"]
EOF
kubectl wait --for=condition=failed job/backoff-job --timeout=90s
kubectl get pods -l job-name=backoff-job
kubectl get job backoff-job -o jsonpath='{.status.failed}{" failed, conditions: "}{.status.conditions[*].type}{"  "}{.status.conditions[*].reason}{"\n"}'
```

### Observed on the real cluster

```text
job.batch/backoff-job condition met
NAME                READY   STATUS   RESTARTS   AGE
backoff-job-rjwws   0/1     Error    0          6s
1 failed, conditions: FailureTarget Failed  BackoffLimitExceeded BackoffLimitExceeded
```

| Item | Predicted | Observed |
|---|---|---|
| Pods | Exactly one, in `Error` | **One pod**, `Error`, `RESTARTS 0` |
| `failed` | 1 | **1** |
| Conditions | `Failed`, `BackoffLimitExceeded` | `FailureTarget Failed`, both `BackoffLimitExceeded` |
| Time | A few seconds | The pod was **5 to 6 seconds** old (the run was done twice, with the same result) |

Compare this with Lab 34 (four pods, 78 seconds). The only difference was the limit, and `backoffLimit: 0` means no retry, so there is no back-off wait.

## Lab 36: `restartPolicy: OnFailure`

The same failing container, but Kubernetes now restarts it **inside the same pod**.

```bash
kubectl delete job backoff-job
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: backoff-job
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: fail
        image: busybox
        command: ["sh", "-c", "echo attempt at $(date); exit 1"]
EOF
for i in $(seq 1 60); do
  echo "$(date -u +%T)  $(kubectl get pods -l job-name=backoff-job --no-headers 2>&1 | awk '{print $1, $3, "restarts="$4}')  job=$(kubectl get job backoff-job -o jsonpath='{.status.conditions[*].type}' 2>&1)"
  if kubectl get job backoff-job -o jsonpath='{.status.conditions[*].type}' | grep -q Failed; then break; fi
  sleep 5
done
kubectl get pods -l job-name=backoff-job
kubectl get job backoff-job -o jsonpath='{.status.failed}{" failed, conditions: "}{.status.conditions[*].type}{"  "}{.status.conditions[*].reason}{"\n"}'
kubectl describe job backoff-job | tail -8
```

The loop stops itself when the Job has failed. `No found restarts=in` in its output is the awk fragment of kubectl's message `No resources found in ...`, so it means the pod is gone.

### Observed on the real cluster

```text
22:12:08  backoff-job-gxjbc ContainerCreating restarts=0  job=
22:12:13  backoff-job-gxjbc CrashLoopBackOff restarts=1  job=
22:12:18  backoff-job-gxjbc CrashLoopBackOff restarts=1  job=
22:12:23  backoff-job-gxjbc CrashLoopBackOff restarts=1  job=
22:12:29  backoff-job-gxjbc Error restarts=2  job=
[... Error and CrashLoopBackOff until 22:12:49 ...]
22:12:54  No found restarts=in  job=FailureTarget Failed

No resources found in appdesign namespace.
1 failed, conditions: FailureTarget Failed  BackoffLimitExceeded BackoffLimitExceeded

Events:
  Normal   SuccessfulCreate      85s   job-controller  Created pod: backoff-job-gxjbc
  Normal   SuccessfulDelete      43s   job-controller  Deleted pod: backoff-job-gxjbc
  Warning  BackoffLimitExceeded  42s   job-controller  Job has reached the specified backoff limit
```

| Observation | Meaning |
|---|---|
| **One pod** (`gxjbc`) for the whole run | With `OnFailure`, the container is restarted **inside the same pod**. Lab 34 created four pods |
| `STATUS` alternates between `Error` and `CrashLoopBackOff` | `Error` is the moment the container has just exited. `CrashLoopBackOff` is the kubelet waiting before the next restart. That wait is the kubelet's own back-off, separate from the Job controller's back-off in Lab 34 |
| `restarts=1`, then `restarts=2` within about 21 seconds | The restart count climbs within the one pod |
| The pod was **deleted** when the Job gave up | The events show `SuccessfulDelete` 42 seconds after `SuccessfulCreate`, together with `BackoffLimitExceeded` |
| `failed` is 1 | One pod was counted as failed in the end |

So the Job gave up after about **42 seconds**, against 78 for the same limit in Lab 34. The samples reach only `restarts=2`. I believe a third restart happened between the last sample and the deletion, since the Job's limit of 3 was reached, but the loop did not catch it, so I can't show it.

In an earlier, interrupted run of the same lab, the `RESTARTS` column once showed `1 (<invalid> ago)`, a display glitch whose cause was not determined.

### The two restart policies compared

| | `restartPolicy: Never` (Lab 34) | `restartPolicy: OnFailure` (Lab 36) |
|---|---|---|
| Pods created | 4, one per attempt | **1**, restarted in place |
| Time until the Job gave up | 78 s | **about 42 s** |
| After the Job fails | All 4 failed pods **remain**, so you can read their logs | The pod is **deleted**, so its logs are gone |
| Retry delays | The Job controller's back-off (11, 23, 43 s) | The kubelet's restart back-off |

For debugging, `Never` keeps the evidence, and `OnFailure` throws it away when the Job fails.

## Lab 37: a Job that fails twice and then succeeds

Retries only matter when something can succeed later. This version is deterministic. It keeps an attempt counter in an `emptyDir` volume, which survives **container restarts inside a pod**, and it fails the first two attempts:

```bash
kubectl delete job backoff-job
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: flaky-job
spec:
  backoffLimit: 5
  template:
    spec:
      restartPolicy: OnFailure
      volumes:
      - name: state
        emptyDir: {}
      containers:
      - name: flaky
        image: busybox
        volumeMounts:
        - name: state
          mountPath: /data
        command:
        - sh
        - -c
        - |
          n=$(cat /data/count 2>/dev/null || echo 0)
          n=$((n+1))
          echo $n > /data/count
          echo "attempt $n"
          if [ $n -lt 3 ]; then
            echo "failing"
            exit 1
          fi
          echo "success"
EOF
for i in $(seq 1 40); do
  echo "$(date -u +%T)  $(kubectl get pods -l job-name=flaky-job --no-headers 2>&1 | awk '{print $1, $3, "restarts="$4}')  job=$(kubectl get job flaky-job -o jsonpath='{.status.conditions[*].type}')"
  if kubectl get job flaky-job -o jsonpath='{.status.conditions[*].type}' | grep -q Complete; then break; fi
  sleep 3
done
kubectl get pods -l job-name=flaky-job
kubectl get job flaky-job
kubectl logs job/flaky-job
kubectl logs $(kubectl get pods -l job-name=flaky-job -o name) --previous
```

### Observed on the real cluster

```text
22:54:14  No found restarts=in  job=
22:54:17  flaky-job-g4tdt Error restarts=0  job=
22:54:20  flaky-job-g4tdt CrashLoopBackOff restarts=1  job=
22:54:23  flaky-job-g4tdt CrashLoopBackOff restarts=1  job=
22:54:26  flaky-job-g4tdt CrashLoopBackOff restarts=1  job=
22:54:29  flaky-job-g4tdt Completed restarts=2  job=
22:54:33  flaky-job-g4tdt Completed restarts=2  job=SuccessCriteriaMet Complete

NAME              READY   STATUS      RESTARTS      AGE
flaky-job-g4tdt   0/1     Completed   2 (21s ago)   23s
NAME        STATUS     COMPLETIONS   DURATION   AGE
flaky-job   Complete   1/1           17s        24s
attempt 3
success
unable to retrieve container logs for containerd://2af550264a08...
```

| Prediction | Observed |
|---|---|
| One pod throughout, `RESTARTS` reaching 2 | **One pod**, `restarts=2` |
| The Job becomes `Complete`, the pod `Completed` and kept | `Complete`, `1/1`, pod `Completed` and still present |
| About 30 seconds | **17 seconds** (`DURATION`), faster than predicted because the first restarts were quick |
| `kubectl logs job/flaky-job` shows `attempt 3` and `success` | Exactly that. It shows the **last** container run only |
| `--previous` shows `attempt 2` and `failing` | **Failed:** `unable to retrieve container logs` |

What the run shows:

- **`attempt 3`** proves the counter file survived the container restarts: the `emptyDir` lives as long as the **pod**. It would **not** survive a pod replacement. With `restartPolicy: Never`, every retry is a new pod with a fresh volume, so every attempt would be "attempt 1" and this Job would never succeed. That variant was not run.
- **`SuccessCriteriaMet` then `Complete`.** On success the Job shows two conditions, just as failure showed `FailureTarget` then `Failed`. `SuccessCriteriaMet` is the earlier marker, and `Complete` is the final state.
- **`--previous` failed**, so the earlier container instance was no longer available to the runtime. The kubelet cleans up old exited containers and keeps very few per pod, which would explain it, but this was not confirmed. **Do not count on `--previous` once a Job has finished.** Capture logs while the Job runs, or use `restartPolicy: Never`, which keeps a pod per attempt.

## When retry delays disappear: clock skew between nodes

In Lab 30 the retries fired every 4 to 6 seconds, not with the doubling delays of Lab 34. Three further runs on the same day did the same, each with short gaps:

| Run | Settings | Pods | Gaps |
|---|---|---|---|
| Experiment 1 | `backoffLimit: 10`, no deadline | 11 | 4, 4, 4, 4, 4, 5, 7, 4, 4, 5 s |
| Experiment 2 | `backoffLimit: 3`, deadline 120 s | 4 | 5, 4, 4 s |
| Control | Lab 34's spec, unchanged | 4 | 5, 4, 4 s |

So the Job's settings were not the cause (the control run used exactly Lab 34's spec). A clock check found the cause: **worker2's clock was 43 minutes behind** the others, as measured from Windows:

```text
master:  VM clock minus Windows clock = -0.5 s
worker1: VM clock minus Windows clock = -0.7 s
worker2: VM clock minus Windows clock = -2,580.1 s
```

All three nodes reported `NTPSynchronized = yes`, so that flag does **not** prove the time is right. A later `timedatectl timesync-status` showed `Poll interval: 8min 32s (min: 32s; max 34min 8s)`, so the time service checks only every 8 to 34 minutes. Why the clock fell behind is unknown. One guess is that the laptop's sleep paused the VMs and stopped their clocks.

### The controlled test

By the time of the tests below, worker2's clock had corrected itself. The same Job was pinned to each node, then to worker2 with its clock deliberately set 10 minutes back:

```bash
# on the master: a template, and a function that runs it on one node
cat > /tmp/clock-job.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: clock-NODE
spec:
  backoffLimit: 3
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: NODE
      restartPolicy: Never
      containers:
      - name: fail
        image: busybox
        command: ["sh", "-c", "echo attempt at $(date -u +%T); exit 1"]
EOF
run_test() {
  n=$1
  sed "s/NODE/$n/g" /tmp/clock-job.yaml | kubectl apply -f -
  kubectl wait --for=condition=failed job/clock-$n --timeout=200s
  kubectl get pods -l job-name=clock-$n --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,CREATED:.metadata.creationTimestamp
  kubectl get pods -l job-name=clock-$n --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\n"}{end}' | while read t; do s=$(date -u -d "$t" +%s); [ -n "$prev" ] && echo "gap: $((s-prev))s"; prev=$s; done
  echo "first pod's own log:"
  kubectl logs $(kubectl get pods -l job-name=clock-$n --sort-by=.metadata.creationTimestamp -o name | head -1)
  echo "master clock now: $(date -u +%T)"
  kubectl delete job clock-$n
}
run_test worker2
run_test worker1
```

To set a node's clock back (and to **restore it right afterwards**), run these inside that node's shell. This was a deliberate experiment, and must not be left in place:

```bash
sudo timedatectl set-ntp false
sudo date -s "10 minutes ago"
# ... run the test from the master ...
sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd
```

### Observed on the real cluster

| Run | The node's clock | Gaps |
|---|---|---|
| `clock-worker2` | Correct: the container logged `05:24:21` for a pod created at `05:24:17` | 14, 21, 41 s |
| `clock-worker1` | Correct: logged `05:25:38` for a pod created at `05:25:37` | 11, 22, 41 s |
| `clock-worker2`, clock **10 minutes back** | The container logged `05:20:25` for a pod created at `05:30:24` | **4, 4, 5 s** |

The last two rows are the same node, the same Job and the same cluster, with one change: the clock. With the clock correct, the retries doubled. With the clock 10 minutes behind, the delays disappeared, and the whole Job failed in 13 seconds instead of about 80.

The likeliest mechanism, which was **not verified**, is that the Job controller works out each retry delay from the time the previous pod finished, as stamped by the node's clock, and compares it with the master's clock. A node that is 10 minutes behind makes every finish time look 10 minutes old, so each delay has "already passed". The earlier short-gap runs match this, but I never recorded which nodes they ran on, apart from the control run (worker2).

### What to take away

- **Compare actual clocks, not the NTP flag.** A node can say `NTPSynchronized = yes` while minutes off.
- **Clock skew shows up in odd places**: retry delays that vanish here, and other time-based behavior (certificate validity, lease timing, log ordering) on a node with a badly wrong clock.
- **After a laptop sleeps**, check the VM clocks. In PowerShell, this prints each VM's offset from Windows (anything within about a second is noise):

```powershell
foreach ($vm in "master","worker1","worker2") {
  $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $r = multipass exec $vm -- date -u +%s.%N
  $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  "{0}: VM clock minus Windows clock = {1:N1} s" -f $vm, ([double]$r - ($t0+$t1)/2000.0)
}
```

- To correct a node, `sudo systemctl restart systemd-timesyncd` inside it, then compare again.

### A later episode: all three VMs behind real time

Hours later, after the laptop had been idle, the clocks misbehaved again, in a different way. Two clues appeared during the DaemonSet labs (Section 11): the pods' own logs disagreed, and a DaemonSet created a minute earlier showed an age of `7h30m`.

```text
[pod/node-logger-s9h99/logger] running on worker1 at 14:44:10
[pod/node-logger-k9xq6/logger] running on worker2 at 07:16:09
node-logger   3   3   3   3   3   <none>   7h30m
```

A later check against Windows found something different:

```text
Windows UTC: 16:17:35
master:  VM clock minus Windows clock = -4,666.8 s
worker1: VM clock minus Windows clock = -4,667.0 s
worker2: VM clock minus Windows clock = -4,667.0 s
```

All three VMs were about **78 minutes behind** Windows, and within 0.2 seconds of each other. Which clock was wrong? Independent sources settled it:

| Source | Reading | Meaning |
|---|---|---|
| `w32tm /stripchart /computer:time.windows.com` | Windows is off by about 1.7 s | Windows is right |
| `curl.exe -sI https://www.google.com`, the `Date` header, from Windows | `16:19:44` GMT | Real time |
| The same header, fetched from the master | `16:19:45` GMT | Real time (it is Google's own clock, so the VM's clock does not matter) |

So Windows was right, and the VMs were behind. All three being behind by the same amount fits the laptop's sleep pausing them together, though that was not verified.

Four minutes later the picture had changed again:

```text
master:  VM clock minus Windows clock = -1.3 s      (corrected on its own)
worker1: VM clock minus Windows clock = -4,667.0 s  (still 78 minutes behind)
worker2: VM clock minus Windows clock = -1.3 s      (corrected on its own)
```

Each VM corrected itself at its **own next poll**, so for a while they disagreed. Restarting the time service on worker1 fixed it within the 40-second wait:

```powershell
multipass exec worker1 -- sudo systemctl restart systemd-timesyncd
Start-Sleep -Seconds 40
```

Afterwards all three read about −1.3 s, which is just the round trip of the measurement.

### The status output that misled

worker1's `timedatectl timesync-status` showed `Offset: +1.796ms` and `Poll interval: 17min 4s` while its clock was 78 minutes wrong. As I understand it, the offset is the one measured at the **last poll**, which can be many minutes old. If the VM was paused after that poll, the status looks healthy while the clock is far off. That also explains `NTPSynchronized = yes` on a node whose clock was 43 minutes slow.

**To check a VM's clock, compare it with Windows (or another trusted clock), and do not trust the status.**

### What to do after the laptop sleeps

This restarts the time service on all three VMs and shows the result:

```powershell
foreach ($vm in "master","worker1","worker2") { multipass exec $vm -- sudo systemctl restart systemd-timesyncd }
Start-Sleep -Seconds 40
foreach ($vm in "master","worker1","worker2") {
  $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $r = multipass exec $vm -- date -u +%s.%N
  $t1 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  "{0}: VM clock minus Windows clock = {1:N1} s" -f $vm, ([double]$r - ($t0+$t1)/2000.0)
}
```

Two ideas to make this automatic, **neither tried**:

- Lower `PollIntervalMaxSec` (for example to 256) in `/etc/systemd/timesyncd.conf`, so a stale clock is corrected within minutes.
- The VMs expose the host's clock as `/dev/ptp_hyperv`, which a daemon such as chrony can follow, and which I expect would correct the time on resume.

### What it affects

- **Retry delays** vanish when a node is behind the master (see above).
- **Stored timestamps** are wrong for objects created while the master's clock was off, so ages look impossible. Newer objects are fine.
- A uniform offset, with all nodes agreeing, is probably harmless to Kubernetes. That exact case was not tested.

## Clean up

```bash
kubectl delete job hello-job batch-job deadline-job backoff-job flaky-job manual-run --ignore-not-found
```

---

# 16. Job history limits

## The problem

A CronJob creates a Job on every run. Without limits, finished Jobs (and their pods) would pile up forever, filling the cluster with objects.

## The two fields

| Field | Default | Keeps |
|---|---|---|
| `successfulJobsHistoryLimit` | **3** | The most recent finished **successful** Jobs |
| `failedJobsHistoryLimit` | **1** | The most recent finished **failed** Jobs |

Older Jobs beyond the limit are **deleted automatically**, together with their pods. Setting a limit to `0` deletes finished Jobs of that kind immediately, which leaves nothing to read logs from.

A good habit is a small success history (so you can see recent runs) and a larger failure history (so you can investigate problems):

```yaml
spec:
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 5
```

## Related fields

| Field | Applies to | Purpose |
|---|---|---|
| `successfulJobsHistoryLimit`, `failedJobsHistoryLimit` | CronJob | How many finished Jobs the CronJob keeps |
| `ttlSecondsAfterFinished` | Any Job (also usable inside a CronJob's `jobTemplate`) | Delete one Job a set time after it finishes |
| `revisionHistoryLimit` | Deployment | How many old ReplicaSets are kept for rollback. The same idea, for a different object |

These limits only trim **finished** Jobs. A Job that is still running is never removed by them. A Job created by hand with `kubectl create job --from=cronjob/NAME` is owned by the CronJob, so it **counts toward the limits** too (Lab 32).

## Lab 38: watch the history being pruned

This lab was run together with Lab 31, which used `successfulJobsHistoryLimit: 2` and `failedJobsHistoryLimit: 1`. If you ran Lab 31, you have already done it. Otherwise, apply the CronJob from Lab 31 and watch:

```bash
for i in $(seq 1 22); do
  echo "$(date -u +%T)  $(kubectl get jobs --no-headers 2>&1 | awk '{printf "%s(%s) ", $1, $2}')"
  sleep 15
done
kubectl get jobs
kubectl get pods
```

### Observed on the real cluster

```text
23:14:10  tick-29858354(Complete)
23:15:10  tick-29858354(Complete) tick-29858355(Complete)
23:16:11  tick-29858355(Complete) tick-29858356(Complete)       <- 354 pruned
23:17:11  tick-29858356(Complete) tick-29858357(Complete)       <- 355 pruned
23:18:11  tick-29858357(Complete) tick-29858358(Complete)       <- 356 pruned
```

| Prediction | Observed |
|---|---|
| At most two finished Jobs are ever listed | **Two**, in every sample. Each time a third completed, the oldest disappeared |
| The pods of pruned Jobs go too | Only two pods existed at the end |

If there was ever a moment with three, it was shorter than the 15-second sampling interval.

## Lab 39: the failed history, and changing the limit

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: tick-fail
spec:
  schedule: "*/1 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: fail
            image: busybox
            command: ["sh", "-c", "echo failing; exit 1"]
EOF
for i in $(seq 1 22); do
  echo "$(date -u +%T)  $(kubectl get jobs --no-headers 2>&1 | awk '{printf "%s(%s) ", $1, $2}')"
  sleep 15
done
```

While the loop is running, raise the limit from a second shell:

```bash
kubectl patch cronjob tick-fail -p '{"spec":{"failedJobsHistoryLimit":3}}'
```

### Observed on the real cluster

The patch ran at about 23:37:23, partway through the loop, so the timeline holds both settings:

| Time (UTC) | Failed Jobs listed | Limit at the time |
|---|---|---|
| 23:36:11 | `…376` | 1 |
| 23:37:12 | `…377` only | 1: `…376` was **pruned** when `…377` appeared |
| 23:38:12 | `…377`, `…378` | 3, after the patch: the history **grows** |
| 23:39:12 | `…377`, `…378`, `…379` | 3 |
| 23:40:13 | `…378`, `…379`, `…380` | 3: `…377` pruned, the history is **capped** at three |
| 23:41:13 | `…379`, `…380`, `…381` | 3 |

| Prediction | Observed |
|---|---|
| A new Job each minute, failing within seconds | Yes. Each is `Failed`, `0/1` completions |
| Exactly **one** failed Job kept at limit 1 | Yes |
| The CronJob keeps scheduling after failures | Yes. `ACTIVE 0`, and `LAST SCHEDULE` stayed recent |
| Up to **3** after raising the limit | Yes: 2 at 23:38, 3 at 23:39, and stable at 3 |

A failed Job's `DURATION` equals its `AGE` and keeps growing (`2m43s`, `103s`, `43s`), whereas successful Jobs showed a fixed 4 or 5 seconds. My guess is that a failed Job has no completion time to stop the clock, which was not verified.

### The limit over hours

The same CronJob was left running for **3 hours 35 minutes**. Its Job numbers rose from `…376` to `…588` (the scheduled minutes), meaning it kept creating a failing Job every minute throughout. Yet at any sample, only **three** Jobs existed. That is more than 200 failed Jobs created, and a history limit of 3 kept the cluster from filling with them. Left running with no limit at all, they would have piled up.

Also, resuming from a suspension created one Job (see Lab 32), and the cap of 3 held.

## Lab 40: delete a Job by TTL

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: ttl-job
spec:
  ttlSecondsAfterFinished: 30
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: hello
        image: busybox
        command: ["sh", "-c", "echo bye"]
EOF
for i in $(seq 1 14); do echo "$(date -u +%T)  $(kubectl get job ttl-job --no-headers 2>&1 | awk '{print $1, $2}')  pods=$(kubectl get pods -l job-name=ttl-job --no-headers 2>&1 | awk '{print $3}')"; sleep 5; done
```

### Observed on the real cluster

```text
03:20:32  ttl-job Running  pods=ContainerCreating
03:20:37  ttl-job Running  pods=Completed
03:20:43  ttl-job Complete  pods=Completed
[... Complete until 03:21:08 ...]
03:21:13  Error from  pods=found
```

| Prediction | Observed |
|---|---|
| The Job finishes within about 8 seconds | `Complete` by 03:20:43, with the pod `Completed` at 03:20:37 |
| It stays for **30 seconds** after finishing | Still present at 03:21:08, about 30 seconds after it finished |
| It disappears **with its pod**, about 40 to 45 seconds after creation | Gone at 03:21:13, about **42 seconds** after creation. The pods column emptied at the same moment |

`Error from  pods=found` is awk's fragment of kubectl's two messages: `Error from server (NotFound)` for the Job, and `No resources found` for the pods. Both were gone.

This is the tool for standalone Jobs, since the history limits above apply only to Jobs created by a CronJob.

## Clean up

```bash
kubectl delete cronjob tick tick-fail --ignore-not-found
kubectl delete job ttl-job --ignore-not-found
```

Deleting a CronJob also deletes its Jobs, including a manual one created with `--from=cronjob/...`, and their pods.

---

# 17. Choosing a controller

| You need to... | Use |
|---|---|
| Run a stateless app with N copies, with rolling updates and rollback | **Deployment** |
| Understand how replica counting works | A **ReplicaSet** (learning), but use a Deployment in practice |
| Run one pod on every node (an agent) | **DaemonSet** |
| Run a task once, and retry if it fails | **Job** |
| Run a task on a schedule | **CronJob** |
| Run a database or anything needing stable identity and storage | A **StatefulSet** (not covered here) |
| Run a single pod, only for a quick test | A bare **Pod** (`kubectl run`), which nothing restarts if the node fails |

## What each controller restarts

| Controller | If a pod dies | If a node dies |
|---|---|---|
| Bare Pod | Nothing recreates it (apart from the container restart policy) | The pod is lost |
| ReplicaSet / Deployment | A replacement pod is created | Replacements are created on other nodes |
| DaemonSet | A replacement on the same node | The pod goes with the node |
| Job | Retried up to `backoffLimit` | Retried on another node |

---

# 18. Common mistakes and troubleshooting

| Mistake or symptom | Cause | Fix |
|---|---|---|
| The API refuses a ReplicaSet or Deployment | `template.metadata.labels` do not match `selector` | Make the template's labels include everything in the selector |
| A Deployment's `selector` cannot be changed | The selector is immutable | Delete and recreate the Deployment |
| A Service has no endpoints | Its selector matches no ready pods | Compare `kubectl get svc X -o yaml` with `kubectl get pods --show-labels` |
| A stray pod is claimed by a ReplicaSet | Its labels match the selector | Use more specific labels, or relabel the pod |
| `kubectl label` fails with `'env' already has a value (staging), and --overwrite is false` | Changing an existing label value needs `--overwrite` | Add `--overwrite` |
| Relabeling a ReplicaSet's pod makes the ReplicaSet create a new pod | The ReplicaSet counts pods by label, so the relabeled pod no longer counts | Expected. It is a useful way to take a pod out of service while keeping it for inspection |
| Changing a ReplicaSet's image does nothing | A ReplicaSet does not update existing pods | Use a Deployment |
| A Deployment rollout is stuck | A bad image, a failing readiness probe, or no capacity | `kubectl rollout status`, `kubectl describe pod`, then `kubectl rollout undo` |
| An update is too slow, or capacity drops | `maxSurge` and `maxUnavailable` do not suit the workload | Tune them (Section 8) |
| `set image` printed no `image updated` line, and nothing rolled out | The image was already that value, so the pod template did not change | Check the current image with `kubectl get deployment X -o jsonpath='{.spec.template.spec.containers[0].image}'` |
| A rollout stalls at `N out of 4 new replicas have been updated` and the new pods never become ready | A bad image name (for example `nginx-alpine` instead of `nginx:alpine`), or a failing readiness probe | `kubectl get pods`, `kubectl describe pod`, then fix the image or `kubectl rollout undo`. The old pods keep serving meanwhile |
| `error: deployment "X" exceeded its progress deadline` | No progress for `progressDeadlineSeconds` (default 600 s). It can still be reported just after you fix the cause | Check `kubectl get rs` and the pods to see where the rollout really stands |
| The API refuses `maxSurge: 0` with `maxUnavailable: 0` | Both zero means no progress is possible | Set at least one above zero |
| A DaemonSet has no pod on the master | The control-plane taint is not tolerated | Add the toleration (Lab 24) |
| `logging: on` in a manifest is refused by the API | YAML reads `on` as the boolean true, and label values must be strings | Quote it (`"on"`) or use another value such as `enabled` |
| A Job is rejected with `restartPolicy: Always` | Jobs allow only `Never` or `OnFailure` | Change the policy |
| A Job's pods stay after it finishes | Finished pods are kept for logs | Delete the Job, or set `ttlSecondsAfterFinished` |
| A hanging Job never fails | `backoffLimit` only counts failures | Add `activeDeadlineSeconds` |
| `kubectl logs --previous` says `unable to retrieve container logs` | The earlier container instance was no longer available to the runtime (seen after a finished Job, cause not confirmed) | Capture logs while the Job runs, or use `restartPolicy: Never`, which keeps a pod per attempt |
| A failing Job's retries fire every few seconds, with no growing delay | A node's clock is behind the master's, so pod finish times look old (seen with a node 10 and 43 minutes slow) | Compare the clocks (Section 15), then restart `systemd-timesyncd` on the node |
| `NTPSynchronized` says `yes`, but the time is wrong | The flag reports that the last poll worked, not that the clock is right now | Compare `date -u` on each node with a trusted clock |
| `timedatectl timesync-status` shows a tiny `Offset`, but the clock is wrong | The offset is from the last poll, which can be many minutes old (the poll interval reached 34 minutes) | Compare the VM with Windows or another trusted clock, then restart `systemd-timesyncd` |
| An object created a minute ago shows an age of hours | The master's clock was behind when it was created, then stepped forward | Check the clocks (Section 15). Objects created afterwards are fine |
| A DaemonSet update takes about 30 seconds per node | The old pod's main process ignores the termination signal, so Kubernetes waits out the grace period | Handle the signal in the container, or lower `terminationGracePeriodSeconds` |
| A failed Job's pod has disappeared, along with its logs | With `OnFailure`, the Job deletes its pod when it gives up | Use `restartPolicy: Never` when you need to debug failures |
| A Job using a counter file in `emptyDir` never succeeds with `Never` | Each retry is a new pod with a fresh volume | Use `OnFailure`, or keep state outside the pod |
| A Job past its `activeDeadlineSeconds` still shows a `Terminating` pod for about 30 seconds | The container ignores the termination signal (for example a shell as the main process), so Kubernetes waits out the default grace period | Handle the signal with `trap`, or lower `terminationGracePeriodSeconds` (Lab 29b) |
| A CronJob never runs | A bad schedule, `suspend: true`, or a missed `startingDeadlineSeconds` | `kubectl describe cronjob X` and read the events |
| A CronJob runs at the wrong hour | The schedule is read in the controller's time zone | Set `timeZone` |
| Overlapping CronJob runs | `concurrencyPolicy: Allow` is the default | Use `Forbid` or `Replace` |
| With `Forbid`, a Job starts late, right after the previous one ended | `Forbid` postpones a missed run instead of dropping it, and starts only one catch-up run for the latest missed time | Set `startingDeadlineSeconds` if late runs are unwanted (not tested here) |
| With `Replace`, no Job ever completes | Each new run deletes the running Job after one schedule period | Use `Forbid` or `Allow`, or make the Job shorter than the period |
| Old Jobs pile up | No history limits, or limits set high | Set `successfulJobsHistoryLimit` and `failedJobsHistoryLimit` |
| A suspended CronJob still has a running Job | Suspending stops **new** runs only. A Job that has already started finishes | Delete the Job if you need it stopped |
| A resumed CronJob did not run the minutes it missed | By design: it creates **one** Job for the latest scheduled minute | Run `kubectl create job NAME --from=cronjob/CRON` if you need an extra run |
| A manual `--from=cronjob/...` Job disappeared | It is owned by the CronJob, so it counts toward the history limit and is deleted with the CronJob | Copy the Job's YAML into its own Job if it must outlive the CronJob |
| `connection refused` to `127.0.0.1` from Windows | Plain `kubectl` in PowerShell talks to a different cluster | Use `multipass exec master -- kubectl ...`, or work inside the master shell |

---

# 19. Command cheat sheet

## Labels and selectors

| Task | Command |
|---|---|
| Show labels | `kubectl get pods --show-labels` |
| Show labels as columns | `kubectl get pods -L app,env` |
| Select by label | `kubectl get pods -l app=web` |
| Several conditions | `kubectl get pods -l app=web,env=prod` |
| Set-based | `kubectl get pods -l 'env in (prod,staging)'` |
| Add or change | `kubectl label pod NAME key=value --overwrite` |
| Remove | `kubectl label pod NAME key-` |
| Label a node | `kubectl label node NAME key=value` |

## ReplicaSets and Deployments

| Task | Command |
|---|---|
| Create a Deployment | `kubectl create deployment NAME --image=IMAGE --replicas=N` |
| Scale | `kubectl scale deployment NAME --replicas=N` |
| Change the image | `kubectl set image deployment/NAME CONTAINER=IMAGE` |
| Watch a rollout | `kubectl rollout status deployment/NAME` |
| History | `kubectl rollout history deployment/NAME` |
| Roll back | `kubectl rollout undo deployment/NAME` |
| Pause and resume | `kubectl rollout pause deployment/NAME`, `kubectl rollout resume deployment/NAME` |
| Restart pods | `kubectl rollout restart deployment/NAME` |
| List ReplicaSets | `kubectl get rs` |

## DaemonSets, Jobs and CronJobs

| Task | Command |
|---|---|
| List DaemonSets | `kubectl get ds -A` |
| Watch a DaemonSet update | `kubectl rollout status daemonset/NAME` |
| List Jobs | `kubectl get jobs` |
| Pods of a Job | `kubectl get pods -l job-name=NAME` |
| Job logs | `kubectl logs job/NAME` |
| Wait for a Job | `kubectl wait --for=condition=complete job/NAME --timeout=90s` |
| Why a Job failed | `kubectl describe job NAME` |
| List CronJobs | `kubectl get cronjob` |
| Run a CronJob now | `kubectl create job NAME --from=cronjob/CRON` |
| Pause a CronJob | `kubectl patch cronjob NAME -p '{"spec":{"suspend":true}}'` |

---

# 20. Glossary

| Term | Meaning |
|---|---|
| **Label** | A key/value tag on an object |
| **Selector** | A query over labels |
| **ReplicaSet** | Keeps a set number of identical pods running |
| **Deployment** | Manages ReplicaSets, adding rolling updates, rollback and history |
| **`pod-template-hash`** | The label a Deployment adds to tell its ReplicaSets apart |
| **Revision** | One numbered version of a Deployment's pod template |
| **`maxSurge`** | How many pods above `replicas` an update may create |
| **`maxUnavailable`** | How many pods an update may take out of service at once |
| **Readiness probe** | A check that decides whether a pod receives traffic |
| **DaemonSet** | Runs one pod per matching node |
| **Toleration** | Lets a pod run on a node with a matching taint |
| **Job** | Runs pods until the work completes |
| **CronJob** | Creates Jobs on a schedule |
| **`backoffLimit`** | How many retries a Job allows |
| **`activeDeadlineSeconds`** | A time limit for a Job (or a single pod, at pod level) |
| **`ttlSecondsAfterFinished`** | Deletes a finished Job after a delay |
| **History limit** | How many finished Jobs a CronJob keeps |

---

# 21. What was run, and what was not

## Run on the real cluster (the console output above is from these)

- A Deployment of four nginx pods: its ReplicaSets, its `pod-template-hash` label, rollouts with `rollout restart`, the rollout history and a rollback (revision numbers 1 and 2, then 2 and 3)
- The default rolling-update pace with 4 replicas: five pods at once mid-rollout, and the `rollout status` messages
- **Labs 18 to 21** (`maxSurge` and `maxUnavailable`): `maxSurge: 1`, `maxUnavailable: 0` (never below 4 available, 5 total, 51 s), `maxSurge: 0`, `maxUnavailable: 2` (never above 4 total, down to 2 available, 29 s), the percentage settings (a stalled rollout that reached exactly 6 pods with 3 available), and the refusal of both zero
- **Labs 27 and 29** (Jobs): a Job that completes (`9s`, one `Completed` pod), and a Job that exceeded `activeDeadlineSeconds` (pod terminated at 20 s, `DeadlineExceeded`, about 30 s of `Terminating`)
- **Labs 31, 32, 38, 39 and 40** (CronJobs): a CronJob every minute with Jobs named by the scheduled minute (`tick-29858354` is 23:14 UTC), history capped at 2, a manual run that counted toward the limit, suspend and resume (one Job on resume, none for skipped minutes), a failing CronJob capped at 1 and then 3 (and held at 3 over more than 3 hours), and a Job deleted 30 seconds after finishing by its TTL
- **Labs 28 and 30** (parallelism and the deadline against retries), and the **clock experiments**: two pods at a time in a sliding window (45 s for six completions), a deadline that ended a Job with retries left, and retry delays that disappeared on a node whose clock was behind (4, 4, 5 s) and returned once it was correct (11 to 21 s, doubling)
- **Labs 29b and 33**: a pod that handles the termination signal let a deadline Job fail in about 21 s instead of 51 s, and the three concurrency policies (`Allow` overlapped, `Forbid` postponed the missed run and then ran one catch-up Job, `Replace` deleted each Job after 60 s so none completed)
- **Labs 23 to 26** (DaemonSets): no toleration (2 pods, none on the master), flannel and kube-proxy tolerations, a toleration added (3 pods, the workers' pods replaced), a node label controlling placement (1, 2, then 1 pod, reacting within seconds), and a rolling image update (one node at a time, about 31 s per node, 4 revisions in the history)
- **Labs 1 to 11** (labels and ReplicaSets): labeled pods and eight selectors, the refusal to change a label without `--overwrite`, node labels, a ReplicaSet that healed itself, scaled down by removing the newest pods, released and re-adopted a pod by its labels, and left two image versions running after a template change
- **Labs 34 to 37** (`backoffLimit`): `backoffLimit: 3` with `Never` (4 pods, gaps of 11, 23 and 43 s, 78 s in total), `backoffLimit: 0` (one pod, about 5 s), `OnFailure` (one pod restarted in place, pod deleted at the end, about 42 s), and a Job that succeeded on its third attempt (17 s, `SuccessCriteriaMet` then `Complete`)
- Labels: a Service selecting pods with `app=nginx`, the node `ROLES` column changing after `kubectl label node`
- The two existing DaemonSets (flannel and kube-proxy) and their output

## Not run (every lab marked **(not run)**)

- Deployment `Recreate`, pause and resume, and a change-cause annotation
- A clean percentage rollout (the run in Section 9 stalled on a bad image name) and Lab 22

For those, the expected behavior in this guide is what the Kubernetes documentation describes, and **not** a captured result from this cluster. Counts such as the number of failed pods for a given `backoffLimit` can vary slightly with timing, so trust what you observe. Check the official Kubernetes documentation for the version you run.

## Clean up everything from this guide

```bash
kubectl delete namespace appdesign
kubectl config set-context --current --namespace=default
kubectl label node worker1 logging- 2>/dev/null
kubectl label node worker2 logging- 2>/dev/null
kubectl label node worker1 disk- 2>/dev/null
```

The first command deletes every object created in the labs. The second puts your kubeconfig back on the `default` namespace. The remaining ones remove the node labels the labs added, and print nothing if they were never added.
