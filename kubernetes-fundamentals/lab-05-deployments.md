# Lab 5: Deployments — Running Apps That Fix and Update Themselves

**Goal:** understand what a Deployment is, why you almost never run a bare
Pod in real life, and how a Deployment gives you self-healing, scaling, and
zero-downtime updates. Every command here was run on the WSL2 kubeadm
cluster built in the earlier labs; where an output came from that real
session it is shown as-is, and where it is the standard behavior you should
expect, it is labeled **Expected output**.

**Time:** about 45 minutes.

**Before you start**, confirm the cluster is healthy:

```bash
kubectl get nodes
```

**Expected output:**
```
NAME   STATUS   ROLES           AGE    VERSION
b      Ready    control-plane   5d3h   v1.35.6
```

If the node is not `Ready`, go back to the setup guide first. If you have
changed your default namespace in an earlier lab, reset it so this lab's
commands behave as written:

```bash
kubectl config set-context --current --namespace=default
```

---

## The Big Idea (in plain English)

In Lab 2 you created a **Pod** by hand. A Pod is one running copy of your
app. It works, but a bare Pod has a serious weakness:

> **If a bare Pod dies, or the machine under it fails, nothing brings it back.**

A **Deployment** fixes that. You stop saying "run this pod" and start
saying:

> "I want **3 copies** of this app running, **always**."

Kubernetes then works continuously to make that statement true. This is the
*declarative* idea from the introduction notes, and Deployments are where it
becomes real.

Using the harbor picture from the explainer doc:

| Harbor word | Kubernetes object | Job |
|---|---|---|
| The standing order ("keep 3 crates of this cargo on the ship, and swap the cargo type carefully when I change it") | **Deployment** | Holds your desired state and manages updates |
| The foreman who counts crates and replaces missing ones | **ReplicaSet** | Keeps exactly N pods alive |
| The crates | **Pods** | The running copies of your app |

You only ever talk to the Deployment. It creates and manages the other two
layers for you.

---

## Step 1: See the problem — a bare Pod does not come back

```bash
kubectl run lonely --image=nginx
kubectl get pods
```

**Expected output:**
```
pod/lonely created

NAME     READY   STATUS    RESTARTS   AGE
lonely   1/1     Running   0          8s
```

Now delete it, as if it had crashed or its machine had failed:

```bash
kubectl delete pod lonely
kubectl get pods
```

**Expected output:**
```
pod "lonely" deleted

No resources found in default namespace.
```

**What this shows:** the pod is simply gone. Nothing was watching it,
nothing recreated it. That is fine for an experiment and unacceptable for a
real application. Keep this in mind for Step 5, where the same deletion
turns out very differently.

---

## Step 2: Create your first Deployment

```bash
kubectl create deployment test --image=httpd --replicas=3
```

**Output:**
```
deployment.apps/test created
```

Check the pods a few seconds later:

```bash
kubectl get pods
```

**Output from the real session** (a few seconds after creation):
```
NAME                    READY   STATUS              RESTARTS   AGE
test-77c4c4df6c-4r9qw   0/1     ContainerCreating   0          39s
test-77c4c4df6c-q2gfg   0/1     ContainerCreating   0          39s
test-77c4c4df6c-qlbb6   0/1     ContainerCreating   0          39s
```

**Reading the command:**
- `create deployment test` — make a Deployment named `test`
- `--image=httpd` — each pod runs the Apache `httpd` image
- `--replicas=3` — keep 3 pods running

`ContainerCreating` is normal for the first few seconds while the image is
pulled and the network is attached. Within a minute all three should show
`1/1 Running`. If they stay stuck for many minutes, jump to the
Troubleshooting section at the end.

---

## Step 3: Meet the three layers

A single command created **three** kinds of object. Look at each one:

```bash
kubectl get deployments
kubectl get replicasets
kubectl get pods
```

**Output from the real session** (10-replica version of this lab):
```
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
test   10/10   10           10          2m9s

NAME              DESIRED   CURRENT   READY   AGE
test-77c4c4df6c   10        10        10      4m23s
```

The chain of ownership looks like this:

```
Deployment  test
   └── ReplicaSet  test-77c4c4df6c
          ├── Pod  test-77c4c4df6c-4r9qw
          ├── Pod  test-77c4c4df6c-q2gfg
          └── Pod  test-77c4c4df6c-qlbb6
```

**Decoding the names:**

| Piece | Example | Meaning |
|---|---|---|
| Deployment name | `test` | What you typed |
| Middle hash | `77c4c4df6c` | A fingerprint of the **pod template** (image, labels, and so on). This is the ReplicaSet's name suffix. Change the template and the hash changes |
| Last suffix | `4r9qw` | Random, unique per pod |

The middle hash is the most useful clue in this lab. It is how you will
recognize, in Step 9, that a rolling update created a new ReplicaSet.

**Column meanings for `get deployments`:**
- `READY` — pods ready out of pods desired (`10/10`)
- `UP-TO-DATE` — pods running the latest version of the template
- `AVAILABLE` — pods actually able to serve traffic

---

## Step 4: Read the Deployment's full status

```bash
kubectl describe deployment test
```

**Output from the real session** (3-replica version):
```
Name:                   test
Namespace:              default
Labels:                 app=test
Annotations:            deployment.kubernetes.io/revision: 1
Selector:               app=test
Replicas:               3 desired | 3 updated | 3 total | 3 available | 0 unavailable
StrategyType:           RollingUpdate
MinReadySeconds:        0
RollingUpdateStrategy:  25% max unavailable, 25% max surge
Pod Template:
  Labels:  app=test
  Containers:
   httpd:
    Image:         httpd
...
Conditions:
  Type           Status  Reason
  Available      True    MinimumReplicasAvailable
  Progressing    True    NewReplicaSetAvailable
OldReplicaSets:  <none>
NewReplicaSet:   test-77c4c4df6c (3/3 replicas created)
```

**The lines worth understanding:**

- **`Replicas: 3 desired | 3 updated | 3 total | 3 available | 0 unavailable`**
  — the whole health story on one line. When `desired` equals `available`
  and `unavailable` is `0`, the Deployment has reached its target.
- **`Selector: app=test`** — the label the Deployment uses to find *its own*
  pods. This idea comes back in Step 7.
- **`StrategyType: RollingUpdate`** — how updates happen (Steps 9 to 11).
- **`revision: 1`** — this is the first version of the Deployment.
- **`Conditions`** — `Available=True` means enough pods are serving.
  `Progressing=True` with reason `NewReplicaSetAvailable` means the latest
  rollout finished successfully.

---

## Step 5: Self-healing — delete a pod and watch it come back

This is the moment Deployments earn their keep. Start a live view in one
terminal:

```bash
kubectl get pods --watch
```

In a second terminal, delete one pod (use a real name from your list):

```bash
kubectl delete pod test-77c4c4df6c-4r9qw
```

**Expected output in the watch terminal:**
```
NAME                    READY   STATUS        RESTARTS   AGE
test-77c4c4df6c-4r9qw   1/1     Terminating   0          6m
test-77c4c4df6c-q2gfg   1/1     Running       0          6m
test-77c4c4df6c-qlbb6   1/1     Running       0          6m
test-77c4c4df6c-x8v2m   0/1     Pending       0          0s
test-77c4c4df6c-x8v2m   0/1     ContainerCreating   0    0s
test-77c4c4df6c-x8v2m   1/1     Running       0          3s
```

Press `Ctrl+C` to stop watching.

**What happened, step by step:**
1. You deleted a pod, so the number of pods dropped to 2.
2. The **ReplicaSet** noticed: "I was told to keep 3, and I count 2."
3. It immediately created a replacement pod, with a new random suffix
   (`x8v2m`) but the same ReplicaSet hash.
4. The count returned to 3, with no action from you.

Compare this with Step 1, where the bare Pod stayed deleted. Same action,
completely different result, and the only difference is that a controller
was watching.

---

## Step 6: Scale up and down

Changing the number of copies is one command:

```bash
kubectl scale deployment test --replicas=5
kubectl get pods
```

**Expected output:**
```
deployment.apps/test scaled

NAME                    READY   STATUS    RESTARTS   AGE
test-77c4c4df6c-...     1/1     Running   0          10m    (three existing)
test-77c4c4df6c-...     1/1     Running   0          4s     (two new)
```

Scale back down:

```bash
kubectl scale deployment test --replicas=2
```

Kubernetes picks pods to terminate until only 2 remain. You never chose
which ones, and that is the point: individual pods are disposable, and the
count is what matters. This is a small version of the "100 replicas" story
from the introduction notes.

---

## Step 7: Generate the Deployment as YAML

Typing flags is fine for experiments. Real work uses **files** that you can
review, keep in Git, and re-apply. Let Kubernetes write the first draft
without creating anything (`--dry-run=client`, the same trick as Lab 2):

```bash
kubectl create deployment test --image=httpd --replicas=10 --dry-run=client -o yaml > deploy.yaml
cat deploy.yaml
```

**Output from the real session:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: test
  name: test
spec:
  replicas: 10
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - image: httpd
        name: httpd
```

(The real generator also prints a few empty fields such as
`creationTimestamp: null`, `strategy: {}`, `resources: {}` and
`status: {}`. They are harmless, and were trimmed from the file above to
keep it readable.)

**Reading the file, top to bottom:**

| Field | Meaning |
|---|---|
| `apiVersion: apps/v1` | Deployments live in the `apps` API group. (A Pod is plain `v1`.) |
| `kind: Deployment` | The type of object |
| `metadata.name` | The Deployment's name |
| `spec.replicas` | How many pods you want |
| `spec.selector.matchLabels` | How the Deployment finds the pods it owns |
| `spec.template` | The blueprint for each pod, which is a Pod spec nested inside |
| `template.metadata.labels` | The labels stamped onto every pod it creates |
| `containers[].image` / `name` | What to run |

### The one rule that trips beginners

> **`selector.matchLabels` must match `template.metadata.labels`.**

The Deployment creates pods with the template's labels, then finds its pods
using the selector. If the two disagree, the Deployment would create pods it
cannot recognize as its own. Kubernetes rejects a mismatch when you apply
the file, which is the safe outcome. Here both say `app: test`, so it is
consistent.

---

## Step 8: Apply it declaratively

First remove the imperative Deployment so the file becomes the single source
of truth:

```bash
kubectl delete deployment test
kubectl apply -f deploy.yaml
```

**Output from the real session:**
```
deployment.apps "test" deleted
deployment.apps/test created
```

Re-run the apply without changing anything:

```bash
kubectl apply -f deploy.yaml
```

**Expected output:**
```
deployment.apps/test unchanged
```

**The three possible answers from `apply`:**

| Result | Meaning |
|---|---|
| `created` | It did not exist; now it does |
| `unchanged` | It exists and already matches your file |
| `configured` | It exists but differed; Kubernetes patched it to match |

`configured` is what you will see in the next steps. It describes the
Deployment *object*. Whether pods actually change is a separate question,
and Step 11 shows why.

---

## Step 9: Your first rolling update

Change the image in `deploy.yaml`:

```bash
vim deploy.yaml
```

Change this line:

```yaml
      - image: httpd
```

to:

```yaml
      - image: httpd:alpine3.18
```

Make sure the indentation stays exactly aligned with the other lines. Then
apply it:

```bash
kubectl apply -f deploy.yaml
```

**Output:**
```
deployment.apps/test configured
```

Check the pods:

```bash
kubectl get pods
```

**Output from the real session** (a few seconds after the apply):
```
NAME                    READY   STATUS    RESTARTS   AGE
test-6f56c677d6-4zx6m   1/1     Running   0          16s
test-6f56c677d6-5x8kt   1/1     Running   0          12s
test-6f56c677d6-8q5dt   1/1     Running   0          22s
...
```

**Look at the middle hash.** Before the change the pods were
`test-77c4c4df6c-...`. Now they are `test-6f56c677d6-...`. Changing the
image changed the pod template, which changed its fingerprint, so the
Deployment created a **brand new ReplicaSet**.

Confirm it:

```bash
kubectl get replicasets
```

**Expected output:**
```
NAME              DESIRED   CURRENT   READY   AGE
test-77c4c4df6c   0         0         0       12m    ← old version, scaled to 0
test-6f56c677d6   10        10        10      1m     ← new version
```

The old ReplicaSet is not deleted. It is kept at zero pods so you can roll
back instantly (Step 12).

> **Why you might not see the gradual swap.** A small, cached image can
> finish the whole rollout in under a second, faster than a one-second
> `watch` can catch. The mechanism still ran. To see it in slow motion, use
> a bigger or uncached image tag, and run
> `kubectl get replicasets --watch` in another terminal while you apply.

---

## Step 10: How a rolling update stays safe (the math)

A rolling update replaces pods gradually instead of all at once. Two
settings control the pace. You saw them in Step 4:

```
RollingUpdateStrategy:  25% max unavailable, 25% max surge
```

- **`maxSurge`** — how many *extra* pods may exist above the desired count
  during the update.
- **`maxUnavailable`** — how many pods may be *missing* from the desired
  count during the update.

With percentages, Kubernetes rounds **surge up** and **unavailable down**.
That rule explains a number from the real session. The 10-replica
ReplicaSet carried this annotation:

```
deployment.kubernetes.io/desired-replicas: 10
deployment.kubernetes.io/max-replicas: 13
```

The math: 25% of 10 is 2.5, which rounds up to a surge of **3**. So the
ceiling is 10 + 3 = **13** pods. And 25% of 10 rounded down is an
unavailable allowance of **2**, so at least **8** stay available.

| Replicas | maxSurge (25%, up) | maxUnavailable (25%, down) | Most pods at once | Fewest available |
|---|---|---|---|---|
| 1 | 1 | 0 | 2 | 1 |
| 3 | 1 | 0 | 4 | 3 |
| 10 | 3 | 2 | 13 | 8 |

Notice the `replicas: 1` and `replicas: 3` rows. Because `maxUnavailable`
rounds down to **0**, Kubernetes must start a new pod and wait until it is
Ready *before* removing an old one. That is the zero-downtime guarantee, and
it is not magic, only careful over-provisioning during the switch.

You can see it in the events of a real rollout. Here is the real session's
Mealie update (1 replica), captured at two moments:

```
16:40:18   old: Running       new: ContainerCreating   ← surge pod pulling the image
16:40:54   old: Terminating   new: Running 1/1         ← new passed readiness, old released
```

The old pod was only terminated after the new one reported `1/1`.

---

## Step 11: Tune the strategy — and one YAML trap

You can replace the percentages with exact numbers. Add a `strategy` block
under `spec` in `deploy.yaml`:

```yaml
spec:
  replicas: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: test
```

(The position under `spec` does not matter to Kubernetes, only the
indentation does. In the real session the block sat at the bottom of `spec`
and worked.)

### The trap: a missing space after the colon

In the real session, the first attempt was written like this:

```yaml
      maxUnavailable:1
      maxSurge:1
```

That is **invalid YAML**. YAML needs a space after the colon to read
`key: value`. Without it, `maxUnavailable:1` is treated as one long piece of
text rather than a key with a value, and `kubectl apply` rejects the file.
The fix is a single space:

```yaml
      maxUnavailable: 1
      maxSurge: 1
```

If `kubectl apply` ever complains about parsing, check spacing and
indentation first. Those two cause most beginner YAML errors.

### Applying a strategy-only change does not restart anything

```bash
kubectl apply -f deploy.yaml
```

**Output from the real session:**
```
deployment.apps/test configured
```

Yet the pod names did **not** change. The pods kept their old hash and their
old ages. Why?

> A Deployment only rolls out new pods when the **pod template**
> (`spec.template`) changes. The `strategy` block describes how *future*
> updates behave. It is not part of the pod template, so changing it updates
> the Deployment object without touching a single pod.

Verify that the setting did take effect:

```bash
kubectl describe deployment test | grep RollingUpdateStrategy
```

**Expected output:**
```
RollingUpdateStrategy:  1 max unavailable, 1 max surge
```

With 10 replicas this means at most 11 pods at once and at least 9
available, moving one pod at a time.

**Rule of thumb:** template changes (image, environment variables, labels
inside the template, resources) trigger a rollout. Changes outside the
template (replica count, strategy) do not.

---

## Step 12: Watch, inspect, and undo a rollout

Trigger a real rollout by changing the image again:

```bash
kubectl set image deployment/test httpd=httpd:2.4-alpine
```

**Expected output:**
```
deployment.apps/test image updated
```

(`httpd` before the `=` is the **container name** from the YAML, not the
image. Get it wrong and Kubernetes will say the container was not found.)

Follow it live:

```bash
kubectl rollout status deployment/test
```

**Expected output:**
```
Waiting for deployment "test" rollout to finish: 3 out of 10 new replicas have been updated...
Waiting for deployment "test" rollout to finish: 7 out of 10 new replicas have been updated...
Waiting for deployment "test" rollout to finish: 1 old replicas are pending termination...
deployment "test" successfully rolled out
```

Record why you made the change, so history is readable later:

```bash
kubectl annotate deployment/test kubernetes.io/change-cause="switch to httpd 2.4-alpine"
kubectl rollout history deployment/test
```

**Expected output:**
```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
3         switch to httpd 2.4-alpine
```

Now undo it:

```bash
kubectl rollout undo deployment/test
```

**Expected output:**
```
deployment.apps/test rolled back
```

Kubernetes scales the previous ReplicaSet back up and the newer one back
down, using the same safe one-at-a-time rules. This is why old ReplicaSets
are kept at zero replicas: rollback is instant because nothing has to be
rebuilt.

### What if the new version is broken?

Try an image tag that does not exist:

```bash
kubectl set image deployment/test httpd=httpd:does-not-exist
kubectl get pods
```

**Expected output:**
```
NAME                    READY   STATUS             RESTARTS   AGE
test-...-old            1/1     Running            0          5m    (old pods stay up)
test-...-old            1/1     Running            0          5m
test-...-new            0/1     ErrImagePull       0          10s   (new pod cannot start)
```

The rollout **stalls**, but your app keeps serving because the surge rules
never removed the working pods until replacements were Ready. That is the
safest property of Deployments: **a bad update does not take down the
working version.** Recover with:

```bash
kubectl rollout undo deployment/test
```

---

## Step 13: A real application — Mealie in its own namespace

Now use everything on a real app: **Mealie**, a recipe manager that listens
on port 9000. This also practices **namespaces**, which are separate
"drawers" for organizing resources on one cluster.

Create the namespace and make it your default:

```bash
kubectl create namespace mealie
kubectl config set-context --current --namespace=mealie
```

**Output:**
```
namespace/mealie created
Context "kubernetes-admin@kubernetes" modified.
```

> **Heads-up:** the second command changes your kubeconfig permanently. From
> now on, commands without `-n` act on `mealie`, not `default`. That is why
> the generated YAML below contained `namespace: mealie` without you typing
> it. If a later command seems to "lose" your other pods, check the current
> namespace with `kubectl config view --minify | grep namespace:`.

Generate and edit the Deployment:

```bash
kubectl create deployment mealie --image=nginx --dry-run=client -o yaml > deployment.yaml
vim deployment.yaml
```

Set the real image and add the port. The final file from the real session:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: mealie
  name: mealie
  namespace: mealie
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mealie
  template:
    metadata:
      labels:
        app: mealie
    spec:
      containers:
      - image: ghcr.io/mealie-recipes/mealie:v1.2.0
        name: mealie
        ports:
        - containerPort: 9000
```

`containerPort: 9000` is documentation that tells readers and tools which
port the app uses. The generator never guesses it, so you add it by hand
after reading the app's docs.

```bash
kubectl apply -f deployment.yaml
kubectl get pods
```

**Output from the real session:**
```
deployment.apps/mealie created

NAME                      READY   STATUS    RESTARTS   AGE
mealie-58d548ff48-hrdzf   1/1     Running   0          53s
```

The first pull of this image took about 13 seconds for 143 MB, so a real
application takes longer than `nginx` or `httpd` did.

### Reach it in a browser

Give the Deployment a stable address with a **Service**, then forward a
local port to it:

```bash
kubectl expose deployment mealie --port=9000 --target-port=9000
kubectl port-forward svc/mealie 9000:9000
```

Open `http://localhost:9000` in your Windows browser. In the real session
this loaded Mealie's home page, and `wget http://localhost:9000` from a
second terminal returned `200 OK`.

**Why forward to the Service and not the pod?** In the real session the
first attempt forwarded to a specific pod name. That works until the pod is
replaced. Any rollout or crash gives the replacement a new random name and
breaks the forward. A Service always points at whichever pods currently
match, so it survives replacement.

### Upgrade it live

Change the image line in `deployment.yaml` to
`ghcr.io/mealie-recipes/mealie:v3.28.0` and apply it while watching:

```bash
kubectl apply -f deployment.yaml
kubectl get pods --watch
```

The real session captured this:

```
NAME                      READY   STATUS              RESTARTS   AGE
mealie-58d548ff48-hrdzf   1/1     Running             0          20m
mealie-6754cc7b44-dpb2q   0/1     ContainerCreating   0          30s

NAME                      READY   STATUS        RESTARTS   AGE
mealie-58d548ff48-hrdzf   1/1     Terminating   0          21m
mealie-6754cc7b44-dpb2q   1/1     Running       0          66s

NAME                      READY   STATUS    RESTARTS   AGE
mealie-6754cc7b44-dpb2q   1/1     Running   0          78s
```

This is the Step 10 math on a real app: with one replica, one surge pod
appears, the old pod stays until the new one is Ready, and only then is the
old one removed. The hash changed from `58d548ff48` to `6754cc7b44`, so a
new ReplicaSet took over.

### The catch: your data does not survive this

This Deployment has **no persistent storage**. Anything you add to Mealie
lives only in the container's own writable layer, which is thrown away when
the pod is replaced, including during a rollout like the one above. After
the upgrade, Mealie started fresh. Keeping data across restarts needs a
`PersistentVolumeClaim`, which is the natural next lab.

Also note that jumping from v1.2.0 to v3.28.0 skips many versions. With
real data, apps like this often need stepped upgrades and database
migrations, so read the release notes before a big jump.

---

## Step 14: Clean up

Deleting the Deployment removes its ReplicaSets and pods automatically,
because they are owned by it:

```bash
kubectl delete deployment mealie
kubectl delete service mealie
kubectl delete namespace mealie
kubectl config set-context --current --namespace=default
kubectl delete deployment test
kubectl get pods
```

**Expected output:**
```
No resources found in default namespace.
```

Deleting a namespace deletes everything inside it, which makes namespaces a
convenient way to wipe a whole experiment. Resetting the default namespace
at the end saves you from confusion in the next lab.

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Pods stuck in `ContainerCreating` for many minutes | Image is still pulling, **or** the Calico CNI token has gone stale on a long-running node | Run `kubectl describe pod <name>` and read the Events. If you see `plugin type="calico" failed (add) ... Unauthorized`, follow **Lab 4** (cycle `calico-node`) |
| Pods stuck in `Terminating` for many minutes | Same stale-token issue, on the delete path | `describe pod` shows `FailedKillPod ... failed (delete) ... Unauthorized`. Same fix as Lab 4 |
| `ErrImagePull` / `ImagePullBackOff` | Wrong image name or tag, or no network to the registry | `kubectl describe pod`, check the image string, fix it, and re-apply. Use `kubectl rollout undo` if it was an update |
| `kubectl apply` fails with a parse error | YAML spacing or indentation (often a missing space after a colon) | Compare against the examples above character by character |
| `apply` says `configured` but no pods restarted | You changed something outside `spec.template` (for example `strategy` or `replicas`) | Expected. Only template changes trigger a rollout |
| `kubectl get pods` shows nothing but you know pods exist | You are looking at a different namespace | `kubectl get pods -A`, or check with `kubectl config view --minify \| grep namespace:` |
| `set image` says the container was not found | You used the image name instead of the **container** name | Use the `name:` from the YAML (`httpd=httpd:2.4-alpine`) |
| Port-forward stopped working after an update | It was tied to a specific pod that got replaced | Forward to the Service: `kubectl port-forward svc/<name> ...` |

---

## Key Takeaways

1. **A bare Pod has no one watching it.** A Deployment adds a controller that keeps the right number of pods alive.
2. **Three layers, one command:** Deployment → ReplicaSet → Pods. You manage the Deployment; the rest follows.
3. **The middle hash in a pod's name is a fingerprint of its template.** A new hash means a new ReplicaSet, which means a rollout happened.
4. **Only template changes roll out.** Editing `replicas` or `strategy` updates the Deployment without restarting pods.
5. **Rolling updates are careful over-provisioning.** `maxSurge` rounds up and `maxUnavailable` rounds down, so a single replica always gets a new pod before losing the old one.
6. **Bad updates stall safely,** and `kubectl rollout undo` brings the previous version back in seconds.
7. **Forward to Services, not pods,** because pod names change and Services do not.
8. **Data needs volumes.** Without a PersistentVolumeClaim, a rollout or restart throws your data away.

---

## Command Reference

```bash
# Create
kubectl create deployment <name> --image=<image> --replicas=<n>
kubectl create deployment <name> --image=<image> --replicas=<n> --dry-run=client -o yaml > deploy.yaml
kubectl apply -f deploy.yaml

# Inspect
kubectl get deployments
kubectl get replicasets
kubectl get pods --watch
kubectl describe deployment <name>

# Change
kubectl scale deployment <name> --replicas=<n>
kubectl set image deployment/<name> <container>=<image>:<tag>

# Roll out, review, and undo
kubectl rollout status deployment/<name>
kubectl rollout history deployment/<name>
kubectl annotate deployment/<name> kubernetes.io/change-cause="<why>"
kubectl rollout undo deployment/<name>

# Reach a running app
kubectl expose deployment <name> --port=<port> --target-port=<port>
kubectl port-forward svc/<name> <local-port>:<port>

# Namespaces
kubectl create namespace <name>
kubectl config set-context --current --namespace=<name>
kubectl config view --minify | grep namespace:

# Clean up
kubectl delete deployment <name>
```
