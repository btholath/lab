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

## Lab 1: create pods with labels **(not run)**

Run inside the master shell, in the `appdesign` namespace:

```bash
kubectl run web1 --image=nginx --labels="app=web,env=prod,tier=frontend"
kubectl run web2 --image=nginx --labels="app=web,env=staging,tier=frontend"
kubectl run api1 --image=nginx --labels="app=api,env=prod,tier=backend"
kubectl get pods --show-labels
kubectl get pods -L app,env,tier
```

`--show-labels` prints every label in one column. `-L app,env,tier` prints a column per label you name, which is easier to read.

## Lab 2: select with `-l` **(not run)**

By the definitions in Section 1, each selector must match these pods:

| Selector | Matches |
|---|---|
| `kubectl get pods -l app=web` | web1, web2 |
| `kubectl get pods -l env=prod` | web1, api1 |
| `kubectl get pods -l app=web,env=prod` | web1 |
| `kubectl get pods -l 'env in (prod,staging)'` | web1, web2, api1 |
| `kubectl get pods -l 'env!=prod'` | web2 |
| `kubectl get pods -l 'tier'` | all three (the key exists) |
| `kubectl get pods -l '!canary'` | all three (none has a `canary` label) |
| `kubectl get pods -l 'app=web,tier!=backend'` | web1, web2 |

Run each one and compare the result with the table. Quote selectors with parentheses or `!`, so the shell does not interpret them.

## Lab 3: change labels on a live object **(not run)**

```bash
kubectl label pod web2 env=prod --overwrite     # change a value
kubectl label pod web2 release=blue             # add a label
kubectl label pod web2 release-                 # remove it (trailing minus)
kubectl get pods -L app,env,release
```

Without `--overwrite`, changing an existing value is refused. The trailing minus removes a label.

## Lab 4: labels on nodes **(not run)**

```bash
kubectl get nodes --show-labels
kubectl label node worker1 disk=ssd
kubectl get nodes -l disk=ssd
kubectl label node worker1 disk-
```

Expect `kubernetes.io/hostname` and `kubernetes.io/os=linux` on every node, and `node-role.kubernetes.io/control-plane` on the master.

## Lab 5: act on a selection **(not run)**

Selectors work with most `kubectl` verbs:

```bash
kubectl get all -l app=web
kubectl delete pods -l env=staging
```

Check what a selector matches with `get` before you run a `delete` on it.

## Clean up the lab pods

```bash
kubectl delete pod web1 web2 api1
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

All steps **(not run)** on this cluster.

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
kubectl get rs web-rs
kubectl get pods -l app=web -o wide
```

Expect `DESIRED 3`, `CURRENT 3`, and three pods named `web-rs-xxxxx`, spread over the workers (the master's taint keeps pods off it).

## Lab 7: self-healing

```bash
kubectl delete pod <ONE-OF-THE-WEB-RS-PODS>
kubectl get pods -l app=web
kubectl describe rs web-rs
```

Replace `<ONE-OF-THE-WEB-RS-PODS>` with a real pod name, brackets included. Expect a replacement within seconds, with a new name. The `Events` at the bottom of `describe rs` show lines like `Created pod: web-rs-...`.

## Lab 8: scale

```bash
kubectl scale rs web-rs --replicas=5
kubectl get rs web-rs
kubectl scale rs web-rs --replicas=2
kubectl get pods -l app=web
```

Scaling up creates pods, and scaling down deletes the surplus.

## Lab 9: ownership

```bash
kubectl get pod <A-WEB-RS-POD> -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
```

Expect `ReplicaSet/web-rs`.

## Lab 10: a ReplicaSet follows labels, not pod names

Change a pod's label so it no longer matches:

```bash
kubectl label pod <A-WEB-RS-POD> app=orphan --overwrite
kubectl get pods -L app
```

Expect **one more pod than before**: the ReplicaSet no longer counts the relabeled pod, so it creates a replacement, and the relabeled pod keeps running but is no longer managed. This is a common debugging trick, because it takes a suspect pod out of service and out of any Service's endpoints while keeping it alive to inspect.

Now put the label back:

```bash
kubectl label pod <THE-ORPHAN-POD> app=web --overwrite
kubectl get pods -L app
```

The ReplicaSet now sees more pods than desired and deletes the extra ones, so the count returns to `replicas`.

---

# 5. Challenges with ReplicaSets

## The main problem: changing the template does not update running pods

A ReplicaSet applies its template only to pods it **creates**. If you change the template, for example a new image, **existing pods are left as they are**. You can end up with a mix of old and new pods. There is no rolling update, no rollback, and no history.

## Lab 11: see it **(not run)**

Starting from the 2 or 3 pods of `web-rs`:

```bash
kubectl set image rs/web-rs nginx=nginx:alpine
kubectl get rs web-rs -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

The ReplicaSet's template now says `nginx:alpine`, but every existing pod should **still show `nginx`**. Now delete one pod:

```bash
kubectl delete pod <ONE-OF-THE-WEB-RS-PODS>
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

The replacement should show `nginx:alpine`, while the others stay on `nginx`. You now run **two versions at once**, and the only way to finish the update is to delete the old pods yourself, one at a time or all at once, with downtime if you delete them all.

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

All steps **(not run)** on this cluster. To make the pace visible, the lab uses a readiness probe with a delay, so each new pod takes about ten seconds to become ready. You need **two** shells: one to watch and one to change things. Open a second master shell in another PowerShell window with `multipass shell master`.

## Lab 18: the safe setting, `maxSurge: 1`, `maxUnavailable: 0`

**Shell A** (set up and update):

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

Wait for `successfully rolled out`. Then in **Shell B**, start the watch (namespace `appdesign` is set in your context, but a new shell reads the same kubeconfig, so it is the default there too):

```bash
kubectl get pods -l app=rolling -w
```

In **Shell A**, trigger the update:

```bash
kubectl set image deployment/rolling nginx=nginx:alpine
kubectl rollout status deployment/rolling
```

**What to expect in the watch:**

- At most **5 pods** exist at once (4 desired plus 1 surge).
- At least **4 are `Running` and ready** at every moment, because `maxUnavailable` is 0. A new pod must pass its readiness probe (about 10 seconds) before an old pod is removed.
- The update goes **one pod at a time**, so it is slow and gentle.

## Lab 19: the cheap setting, `maxSurge: 0`, `maxUnavailable: 2`

Change only the strategy. A strategy change does **not** start a rollout by itself:

```bash
kubectl patch deployment rolling -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":2}}}}'
kubectl get deployment rolling -o jsonpath='{.spec.strategy.rollingUpdate}{"\n"}'
```

Now start a rollout, with the watch still running in Shell B:

```bash
kubectl set image deployment/rolling nginx=nginx
kubectl rollout status deployment/rolling
```

**What to expect:**

- **Never more than 4 pods.** There is no surge.
- Two old pods are removed **first**, so only **2 pods are available** at first (4 minus `maxUnavailable` of 2), and two new pods start in the freed slots.
- The update proceeds in **two waves of two**, faster than Lab 18, but with reduced capacity during each wave.

## Lab 20: percentages

```bash
kubectl patch deployment rolling -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":"50%","maxUnavailable":"25%"}}}}'
kubectl set image deployment/rolling nginx=nginx:alpine
kubectl get pods -l app=rolling -w
```

With 4 replicas: `maxSurge` of 50% is 2 (rounded up), and `maxUnavailable` of 25% is 1 (rounded down). Expect at most **6 pods** and at least **3 available**.

## Lab 21: both zero is refused

```bash
kubectl patch deployment rolling -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":0}}}}'
```

Expect an error from the API, since the update could never progress. Nothing changes.

## Lab 22: compare with `Recreate` timing

If you ran Lab 16, compare the watch from that lab: with `Recreate` there is a moment with **no** pods at all, while the rolling settings above never had fewer than the minimum shown in the table.

## Clean up

```bash
kubectl delete deployment rolling web
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

All steps **(not run)** on this cluster, except reading the existing ones in Section 10.

## Lab 23: a node logger

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
            echo "running on $NODE_NAME at $(date)"
            sleep 30
          done
EOF
kubectl get daemonset node-logger
kubectl get pods -l app=node-logger -o wide
```

The `env` block injects the node's own name into each pod through the downward API. **Expect `DESIRED 2`**, not 3: one pod on each worker and **none on the master**, because the master's taint is not tolerated.

```bash
kubectl logs -l app=node-logger --prefix --tail=2
```

`--prefix` puts each pod's name in front of its lines. Each line should name a different worker.

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
            echo "running on $NODE_NAME at $(date)"
            sleep 30
          done
EOF
kubectl rollout status daemonset/node-logger
kubectl get daemonset node-logger
kubectl get pods -l app=node-logger -o wide
```

Expect `DESIRED 3` now, with a pod on the master as well. This is exactly how flannel and kube-proxy run on the control plane.

## Lab 25: limit it to labeled nodes

Use a label value of `enabled`. (Avoid `on`, which YAML reads as a boolean.)

```bash
kubectl label node worker1 logging=enabled
kubectl patch daemonset node-logger -p '{"spec":{"template":{"spec":{"nodeSelector":{"logging":"enabled"}}}}}'
kubectl rollout status daemonset/node-logger
kubectl get pods -l app=node-logger -o wide
```

Expect `DESIRED 1`, with the only pod on worker1. Now react to a **label change**:

```bash
kubectl label node worker2 logging=enabled
kubectl get pods -l app=node-logger -o wide
kubectl label node worker2 logging-
kubectl get pods -l app=node-logger -o wide
```

Labeling worker2 should create a pod there within seconds, and removing the label should delete it. A DaemonSet continuously reacts to node labels.

## Lab 26: rolling update

```bash
kubectl set image daemonset/node-logger logger=busybox:1.36
kubectl rollout status daemonset/node-logger
kubectl rollout history daemonset/node-logger
```

The pods are replaced one node at a time. To see the pace, run `kubectl get pods -l app=node-logger -w` in a second shell first.

## Clean up

```bash
kubectl delete daemonset node-logger
kubectl label node worker1 logging-
```

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

Finished pods are **not** deleted when the Job completes. They stay in `Completed` (or `Error`) state, so you can read their logs, until you delete the Job or its `ttlSecondsAfterFinished` expires.

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
| `concurrencyPolicy` | `Allow` | `Allow` runs overlapping Jobs, `Forbid` skips a run if the last is still going, `Replace` stops the old one and starts the new |
| `startingDeadlineSeconds` | none | How late a run may start before it is counted as missed |
| `suspend` | false | Pause the schedule without deleting it |
| `successfulJobsHistoryLimit` | 3 | Finished successful Jobs to keep (Section 16) |
| `failedJobsHistoryLimit` | 1 | Finished failed Jobs to keep (Section 16) |

Each run creates a Job named `<cronjob-name>-<number>`.

---

# 13. Implementing Jobs and CronJobs, including `activeDeadlineSeconds`

All labs **(not run)** on this cluster.

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
kubectl get pods -l job-name=batch-job -w
```

Press Ctrl+C when finished. Expect **two pods at a time**, in three waves, and `COMPLETIONS 6/6` at the end.

## `activeDeadlineSeconds`

`activeDeadlineSeconds` is a **time limit for the whole Job**, counted from when the Job starts. It covers all pods and all retries together. When the time is up, Kubernetes **terminates any running pods** and marks the Job failed with the reason `DeadlineExceeded`. It takes precedence over `backoffLimit`: a Job with retries left is still stopped when the deadline passes.

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

## Lab 30: the deadline beats the retries **(not run)**

Take Lab 29 and add `backoffLimit: 10`. The Job still fails after about 20 seconds with `DeadlineExceeded`, even though it had many retries left.

## Lab 31: a CronJob every minute

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: tick
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
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
            command: ["sh", "-c", "date; echo tick"]
EOF
kubectl get cronjob tick
kubectl get jobs -w
```

Wait about two minutes, then press Ctrl+C. Expect a new Job named `tick-<number>` **each minute**, each running one pod that completes. `kubectl get cronjob tick` shows `LAST SCHEDULE` and `ACTIVE`.

```bash
kubectl logs job/<ONE-OF-THE-TICK-JOBS>
```

Replace `<ONE-OF-THE-TICK-JOBS>` with a real Job name, brackets included.

## Lab 32: run a CronJob right now, and pause it

```bash
kubectl create job manual-run --from=cronjob/tick
kubectl get jobs
kubectl patch cronjob tick -p '{"spec":{"suspend":true}}'
kubectl get cronjob tick
```

`--from=cronjob/...` creates a Job from the CronJob's template without waiting for the schedule. After `suspend: true`, the `SUSPEND` column shows `True`, and no new Jobs appear. Resume with `"suspend":false`.

## Lab 33: concurrency policies

Make a Job that outlasts the schedule: `command: ["sh","-c","sleep 100"]` with `* * * * *` (and a long enough `activeDeadlineSeconds`). Then compare:

| `concurrencyPolicy` | Expected behavior |
|---|---|
| `Allow` | A new Job starts every minute, so several run at once |
| `Forbid` | The next run is **skipped** while the previous Job is still running |
| `Replace` | The running Job is stopped and replaced by the new one |

---

# 14. Job `backoffLimit`

## What it does

`backoffLimit` is the number of **retries** a Job allows before it gives up and is marked **failed**. The default is **6**.

When a pod fails, the Job controller creates a replacement, but with an **exponential back-off delay**: roughly 10 seconds, then 20, 40, 80 and so on, capped at six minutes. The delay prevents a broken Job from hammering the cluster.

When the limit is reached, the Job gets a `Failed` condition with the reason **`BackoffLimitExceeded`**, and no more pods are created.

## How retries are counted

| `restartPolicy` | What counts toward the limit |
|---|---|
| `Never` | **Failed pods.** Each failure creates a new pod, so you see one pod per attempt |
| `OnFailure` | **Container restarts** inside the one pod |

With `restartPolicy: Never`, a `backoffLimit` of N allows the first attempt plus up to N retries, so **up to N + 1 pods** in total. `backoffLimit: 0` means **no retries at all**: one failure fails the Job. The exact count can differ slightly with timing, so count the pods rather than assuming.

## `backoffLimit` versus `activeDeadlineSeconds`

| | `backoffLimit` | `activeDeadlineSeconds` |
|---|---|---|
| Limits | The **number of failures** | The **total time** |
| Failure reason | `BackoffLimitExceeded` | `DeadlineExceeded` |
| Good for | A job that fails fast and repeatedly | A job that might hang |

Use both for a robust Job. A pod that hangs never "fails", so `backoffLimit` alone would let it run forever. A deadline stops it.

## What to do with failed pods

Failed pods are **kept** (with `Never`), so you can read their logs:

```bash
kubectl get pods -l job-name=<JOB-NAME>
kubectl logs <A-FAILED-POD>
```

They are removed when you delete the Job or when its TTL expires.

---

# 15. Implementing `backoffLimit`

All labs **(not run)** on this cluster.

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
kubectl get pods -l job-name=backoff-job -w
```

Leave the watch running for a couple of minutes, then press Ctrl+C. **Expect:**

- A first pod, then new pods created at **growing intervals** (about 10, 20, then 40 seconds apart).
- Each pod ends in `Error`.
- After the retries are used up, **no more pods appear**. With `backoffLimit: 3`, expect around 4 pods in total.

Then check the outcome:

```bash
kubectl get pods -l job-name=backoff-job
kubectl get job backoff-job -o jsonpath='{.status.conditions[*].type}{"  "}{.status.conditions[*].reason}{"\n"}'
kubectl describe job backoff-job
kubectl logs <ONE-OF-THE-FAILED-PODS>
```

Expect a `Failed` condition with the reason **`BackoffLimitExceeded`**. Count the pods: that count is what the setting produced on your cluster. The logs show `attempt at <date>`, and the timestamps of the different pods show the back-off delays.

## Lab 35: `backoffLimit: 0`, no retries

Delete the Job and recreate it with `backoffLimit: 0`:

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
kubectl get pods -l job-name=backoff-job
```

Expect **exactly one pod**, in `Error`, and a failed Job.

## Lab 36: `restartPolicy: OnFailure`

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
kubectl get pods -l job-name=backoff-job -w
```

Expect **one pod** whose `RESTARTS` count climbs, with the container restarting in place at growing intervals. When the limit is hit, the Job fails and the pod is terminated. Compare this with Lab 34, where each attempt was a separate pod.

## Lab 37: a Job that succeeds on a retry

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
      restartPolicy: Never
      containers:
      - name: flaky
        image: busybox
        command:
        - sh
        - -c
        - |
          if [ $(( $(date +%s) % 2 )) -eq 0 ]; then
            echo "even second, succeeding"; exit 0
          else
            echo "odd second, failing"; exit 1
          fi
EOF
kubectl get pods -l job-name=flaky-job -w
```

The container succeeds or fails depending on whether the current epoch second is even or odd, so this Job usually finishes after zero to a few failed attempts. Expect `Error` pods followed by one `Completed` pod, and a Job that ends as `Complete`, not `Failed`. Retries only matter when something can succeed later.

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

These limits only trim **finished** Jobs. A Job that is still running is never removed by them.

## Lab 38: watch the history being pruned **(not run)**

Use the CronJob from Lab 31 with explicit limits:

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: tick
spec:
  schedule: "*/1 * * * *"
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: tick
            image: busybox
            command: ["sh", "-c", "date; echo tick"]
EOF
kubectl get jobs -w
```

Watch for four or five minutes, then press Ctrl+C. **Expect that at most two finished Jobs** from this CronJob are ever listed. Each time a third completes, the oldest disappears, and so do its pods:

```bash
kubectl get jobs
kubectl get pods
```

## Lab 39: the failed history **(not run)**

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
kubectl get jobs -w
```

After a few minutes, expect only **one** failed Job `tick-fail-<number>` to remain (the newest), however many runs have failed. Change `failedJobsHistoryLimit` to `3` with `kubectl patch cronjob tick-fail -p '{"spec":{"failedJobsHistoryLimit":3}}'` and expect up to three to accumulate.

## Lab 40: delete a Job by TTL **(not run)**

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
kubectl get jobs -w
```

Expect the Job to complete, and then **disappear about 30 seconds later**, with its pod. This is the tool for standalone Jobs, because the history limits only apply to Jobs created by a CronJob.

## Clean up

```bash
kubectl delete cronjob tick tick-fail --ignore-not-found
kubectl delete job ttl-job --ignore-not-found
```

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
| Changing a ReplicaSet's image does nothing | A ReplicaSet does not update existing pods | Use a Deployment |
| A Deployment rollout is stuck | A bad image, a failing readiness probe, or no capacity | `kubectl rollout status`, `kubectl describe pod`, then `kubectl rollout undo` |
| An update is too slow, or capacity drops | `maxSurge` and `maxUnavailable` do not suit the workload | Tune them (Section 8) |
| The API refuses `maxSurge: 0` with `maxUnavailable: 0` | Both zero means no progress is possible | Set at least one above zero |
| A DaemonSet has no pod on the master | The control-plane taint is not tolerated | Add the toleration (Lab 24) |
| `logging: on` in a manifest is refused by the API | YAML reads `on` as the boolean true, and label values must be strings | Quote it (`"on"`) or use another value such as `enabled` |
| A Job is rejected with `restartPolicy: Always` | Jobs allow only `Never` or `OnFailure` | Change the policy |
| A Job's pods stay after it finishes | Finished pods are kept for logs | Delete the Job, or set `ttlSecondsAfterFinished` |
| A hanging Job never fails | `backoffLimit` only counts failures | Add `activeDeadlineSeconds` |
| A CronJob never runs | A bad schedule, `suspend: true`, or a missed `startingDeadlineSeconds` | `kubectl describe cronjob X` and read the events |
| A CronJob runs at the wrong hour | The schedule is read in the controller's time zone | Set `timeZone` |
| Overlapping CronJob runs | `concurrencyPolicy: Allow` is the default | Use `Forbid` or `Replace` |
| Old Jobs pile up | No history limits, or limits set high | Set `successfulJobsHistoryLimit` and `failedJobsHistoryLimit` |
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
- Labels: a Service selecting pods with `app=nginx`, the node `ROLES` column changing after `kubectl label node`
- The two existing DaemonSets (flannel and kube-proxy) and their output

## Not run (every lab marked **(not run)**)

- ReplicaSets created directly: self-healing, scaling, relabeling, ownership and the "template change does not update pods" challenge
- Deployment `Recreate`, pause and resume, and a change-cause annotation
- Custom `maxSurge` and `maxUnavailable` values, percentages and the both-zero refusal
- A custom DaemonSet: placement, tolerations, node labels and its update
- All Jobs and CronJobs: parallelism, `activeDeadlineSeconds`, `backoffLimit` with both restart policies, concurrency policies, history limits and TTL

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
