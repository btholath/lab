# Lab 11: Helm — Packaging Kubernetes YAML Into Reusable Charts

**Goal:** understand what Helm actually is, install it, work with a real
public chart end to end (install → upgrade → inspect → rollback), read the
raw YAML a chart generates, and start converting the hand-written mealie
manifests (Labs 5, 7, 10) into a real, parameterized chart of your own.

**Time:** about 60 minutes.

**Where the outputs come from:** everything in Parts 1–3 is real output
from this WSL2 kubeadm cluster. Part 4 (the mealie chart) captures the
scaffold and the edits made to it; actually installing the finished chart
is left as the natural next step rather than fabricated here.

**Builds on:** Lab 4 (stale CNI token — recurs a third time in this lab),
Lab 5 (Deployments/rollouts), Lab 6 (NetworkPolicy), Lab 7 (Services),
Lab 9 (volumes), Lab 10 (PVCs).

---

## The Big Idea

Every exercise in this series so far has meant hand-writing separate YAML
files — `deployment.yaml`, `service.yaml`, `storage.yaml` for mealie alone
— and keeping them in sync by hand. Helm's purpose is to package that into
**one reusable, versioned, parameterized unit**.

| Term | What it means |
|---|---|
| **Chart** | A packaged bundle of Kubernetes YAML *templates* — placeholders filled in at install time, not static files |
| **Values** | A YAML file of parameters that fill in a chart's templates — image tag, replica count, storage size, etc. |
| **Release** | One **installed instance** of a chart in your cluster, given a name |
| **Repository** | A place charts are published from, like an apt repo but for Helm charts |

The relationship: **Chart + Values → Release**. Change the values, run one
command, and Helm regenerates and re-applies *every* object the chart
defines — the same `kubectl apply`-style reconciliation from Lab 2, just
operating on a whole bundle of objects at once instead of one file.

---

## Part 1: Install Helm and a Public Chart

### Step 1: Install Helm

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh
rm get_helm.sh
helm version
```

**Output from the real session:**
```
Helm v3.22.0 is available. Changing from version v3.21.3.
Downloading https://get.helm.sh/helm-v3.22.0-linux-amd64.tar.gz
Verifying checksum... Done.
helm installed into /usr/local/bin/helm
version.BuildInfo{Version:"v3.22.0", ...}
```

The official install script checks for and installs the **latest**
version automatically — it went from v3.21.3 to v3.22.0 in the same run.

### Step 2: Add a chart repository and search it

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo bitnami/nginx
```

**Output from the real session:**
```
"bitnami" has been added to your repositories
Update Complete. ⎈Happy Helming!⎈

NAME                                    CHART VERSION   APP VERSION
bitnami/nginx                           25.2.1          1.31.6
bitnami/nginx-ingress-controller        12.0.7          1.13.1
bitnami/nginx-intel                     2.1.15          0.4.9
```

**Why a repo add step exists at all:** same concept as `apt-get update`
against an apt source, or `helm repo add`'s closest analog from earlier in
this series — the `krew` plugin index from Lab 3. Nothing is installed yet;
this just makes the repo's chart index searchable locally.

### Step 3: Install a real chart

```bash
kubectl create namespace helm-demo
helm install my-nginx bitnami/nginx -n helm-demo
```

**Output from the real session (trimmed):**
```
NAME: my-nginx
STATUS: deployed
REVISION: 1

NOTES:
CHART NAME: nginx
CHART VERSION: 25.2.1
APP VERSION: 1.31.6

⚠ WARNING: Since August 28th, 2025, only a limited subset of images/charts
    are available for free. Subscribe to Bitnami Secure Images...

NGINX can be accessed through the following DNS name from within your cluster:
    my-nginx.helm-demo.svc.cluster.local (port 80)

WARNING: Rolling tag detected (bitnami/nginx:latest), please note that it
is strongly recommended to avoid using rolling tags in a production environment.
```

**Three things worth noting immediately:**

- **`NOTES:`** isn't generic Helm output — it's rendered from a
  `NOTES.txt` template *inside the chart itself*, customized by whoever
  published it. Different charts show completely different notes.
- **The Bitnami subscription warning** reflects a real change (August
  2025) restricting free access to most Bitnami images. Some charts may
  hit `ImagePullBackOff` because of this — always check
  `kubectl get pods` after an install rather than trusting the install
  command's exit alone.
- **`:latest` tags** — this chart pulls `bitnami/nginx:latest`,
  `bitnami/git:latest`, `bitnami/nginx-exporter:latest`. Worth remembering:
  the opposite of the pinned versions (`httpd:alpine3.19`,
  `mealie:v3.28.0`) used deliberately throughout this series. A `:latest`
  tag means re-running the same install command weeks apart can silently
  pull a different image.

### Step 4: Confirm it's actually healthy

```bash
kubectl get pods -n helm-demo
helm list -n helm-demo
```

**Output from the real session:**
```
NAME                        READY   STATUS    RESTARTS   AGE
my-nginx-67dd668677-xx28c   1/1     Running   0          97s

NAME       NAMESPACE   REVISION   STATUS     CHART           APP VERSION
my-nginx   helm-demo   1          deployed   nginx-25.2.1    1.31.6
```

`helm list` is the Helm-level equivalent of `kubectl get deployments` —
except it reports on the whole **release** (every object kind the chart
created), not just one object type.

---

## Part 2: Reading What a Chart Actually Generated

The real value of a chart isn't magic — it's templating. This section
shows the actual YAML Helm sent to the API server.

### Step 5: Dump the rendered manifest

```bash
helm get manifest my-nginx -n helm-demo > my-nginx-manifest.yaml
grep "^kind:" my-nginx-manifest.yaml
```

**Output from the real session:**
```
kind: NetworkPolicy
kind: PodDisruptionBudget
kind: ServiceAccount
kind: Secret
kind: Service
kind: Deployment
```

**One `helm install` command created six object kinds.** Compare this
against mealie, where you hand-wrote `deployment.yaml`, `service.yaml`,
and `storage.yaml` separately across three different labs.

### Step 6: Objects that connect directly to earlier labs

**`NetworkPolicy`** — direct continuation of Lab 6:
```yaml
policyTypes:
  - Ingress
  - Egress
egress:
  - {}
ingress:
  - ports:
      - port: 8080
      - port: 8443
```
`egress: [{}]` is an empty rule allowing **everything** outbound. `ingress`
restricts by **port only**, no `from:` selector — same shape as the real
`allow-apiserver`/`whisker`/`goldmane` policies read directly out of
iptables back in Lab 6.

**`PodDisruptionBudget`** — new in this lab:
```yaml
spec:
  maxUnavailable: 1
```
Not related to rolling updates (that's `Deployment.spec.strategy`, Lab 5)
— this governs **voluntary disruptions** like node drains or cluster
maintenance. With `replicas: 1`, `maxUnavailable: 1` is the only value
that could ever be satisfied.

**Shared `emptyDir` sliced with `subPath`** — the exact Lab 9 sidecar
pattern, generalized:
```yaml
volumeMounts:
  - name: empty-dir
    mountPath: /opt/bitnami/nginx/conf
    subPath: app-conf-dir
  - name: empty-dir
    mountPath: /opt/bitnami/nginx/logs
    subPath: app-logs-dir
```
One `emptyDir` volume, carved into separate subdirectories per mount via
`subPath` — the precise field name for the "same volume, different paths"
mechanism Lab 9 demonstrated with two separate containers.

**Real Pod Security hardening** — worth contrasting directly with earlier
labs:
```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 1001
  seccompProfile:
    type: RuntimeDefault
automountServiceAccountToken: false
```
Recall the earlier exec exploration where **both** `nginx` and `httpd`
came back `uid=0(root)` on `whoami`. This chart does the opposite,
correctly: explicit non-root user, all capabilities dropped, read-only
root filesystem (which is *why* the `subPath` dance above exists — nginx
needs exactly a few writable paths, carved out deliberately rather than
leaving the whole filesystem writable). `automountServiceAccountToken:
false` also means this pod does **not** get the
`kube-api-access-...` projected volume that's appeared in every pod
you've created throughout this series — since this pod has no reason to
call the Kubernetes API, the chart disables that mount entirely.

---

## Part 3: Upgrade, Inspect, and Roll Back a Release

### Step 7: Override a value without touching any template

```bash
helm upgrade my-nginx bitnami/nginx -n helm-demo --set replicaCount=2
kubectl get pods -n helm-demo
helm list -n helm-demo
helm get values my-nginx -n helm-demo
```

**Output from the real session:**
```
Release "my-nginx" has been upgraded. Happy Helming!
REVISION: 2

NAME                        READY   STATUS     RESTARTS   AGE
my-nginx-67dd668677-g6szw   0/1     Init:0/1   0          1s
my-nginx-67dd668677-xx28c   1/1     Running    0          76m

NAME       REVISION   STATUS     CHART          APP VERSION
my-nginx   2          deployed   nginx-25.2.1   1.31.6

USER-SUPPLIED VALUES:
replicaCount: 2
```

`--set replicaCount=2` changed **exactly** one parameter — `helm get
values` proves nothing else was touched — and Helm regenerated the whole
release accordingly. Note the pod-template hash (`67dd668677`) stayed
identical to revision 1: scaling doesn't change the pod template, same
rule established in Lab 5.

### Step 8: A real recurrence — the stale CNI token, a third time

The second pod stuck at `Init:0/1` for several minutes:

```bash
kubectl describe pod my-nginx-67dd668677-g6szw -n helm-demo
```

**Output from the real session (Events):**
```
Warning  FailedCreatePodSandBox  ...  plugin type="calico" failed (add):
error getting ClusterInformation: connection is unauthorized: Unauthorized
```

The exact Lab 4 signature, recurring for the third time across this
series — `calico-node` had again been running long enough for its
one-time CNI token snapshot to go stale. Fix, same as every time before:

```bash
kubectl delete pod -n calico-system -l k8s-app=calico-node
kubectl get pods -n calico-system -w
```

**Output from the real session, once resolved:**
```
NAME                        READY   STATUS    RESTARTS   AGE
my-nginx-67dd668677-g6szw   1/1     Running   0          4m6s
my-nginx-67dd668677-xx28c   1/1     Running   0          80m
```

Kubelet's own retry loop cleared the stuck pod automatically, no manual
pod deletion needed — the same self-healing behavior confirmed every
previous time this happened.

**Worth noting:** the automated self-heal check added to
`bootstrap_cluster.sh` after Lab 4 only runs when that script executes.
It doesn't run continuously, so it didn't catch this occurrence
automatically. Given three recurrences now, a periodic check (a cron job
running the same detection logic every 30 minutes, or simply re-running
`bootstrap_cluster.sh` as a session-start habit) is worth genuinely
adopting rather than continuing to diagnose this by hand each time.

### Step 9: Roll back an entire release

```bash
helm history my-nginx -n helm-demo
```

**Output from the real session:**
```
REVISION   UPDATED                    STATUS       CHART          DESCRIPTION
1          Wed Sep 30 09:54:10 2026   superseded   nginx-25.2.1   Install complete
2          Wed Sep 30 11:10:38 2026   deployed     nginx-25.2.1   Upgrade complete
```

```bash
helm rollback my-nginx 1 -n helm-demo
kubectl get pods -n helm-demo
helm get values my-nginx -n helm-demo
```

**Output from the real session:**
```
Rollback was a success! Happy Helming!

NAME                        READY   STATUS        RESTARTS   AGE
my-nginx-67dd668677-g6szw   1/1     Terminating   0          4m6s
my-nginx-67dd668677-xx28c   1/1     Running       0          80m

USER-SUPPLIED VALUES:
null
```

```bash
helm history my-nginx -n helm-demo
```

**Expected output** (the mechanism this reveals):
```
REVISION   STATUS       DESCRIPTION
1          superseded   Install complete
2          superseded   Upgrade complete
3          deployed     Rollback to 1
```

**This is the key difference from `kubectl rollout undo` (Lab 5):**
`helm rollback` doesn't erase history — it creates a **new** revision
(3) whose *content* matches revision 1. The full install → upgrade →
rollback sequence remains addressable. And critically, this rollback
was atomic across **every object in the release** — Deployment, Service,
NetworkPolicy, PodDisruptionBudget — not just one Deployment the way
`kubectl rollout undo` is scoped.

---

## Part 4: Building a Chart From the Mealie Manifests

### Step 10: Scaffold a new chart

```bash
helm create mealie-chart
find mealie-chart -type f
```

**Output from the real session:**
```
mealie-chart/Chart.yaml
mealie-chart/templates/ingress.yaml
mealie-chart/templates/NOTES.txt
mealie-chart/templates/serviceaccount.yaml
mealie-chart/templates/deployment.yaml
mealie-chart/templates/httproute.yaml
mealie-chart/templates/tests/test-connection.yaml
mealie-chart/templates/_helpers.tpl
mealie-chart/templates/hpa.yaml
mealie-chart/templates/service.yaml
mealie-chart/values.yaml
mealie-chart/.helmignore
```

`helm create` generates a **working, generic nginx chart** as a starting
scaffold — every chart author starts here and strips/extends it.

### Step 11: Read the templating syntax

The generated `templates/deployment.yaml` contains Go template syntax,
processed *before* the YAML reaches Kubernetes:

| Syntax | Means |
|---|---|
| `{{ .Values.replicaCount }}` | Insert a value from `values.yaml` |
| `{{ .Chart.Name }}`, `{{ .Chart.AppVersion }}` | Insert metadata from `Chart.yaml` |
| `{{ include "mealie-chart.fullname" . }}` | Call a reusable named template defined in `_helpers.tpl` |
| `{{- with .Values.X }} ... {{- end }}` | Only render this block if `.Values.X` is set — an empty/unset field produces **no key at all** in the output |

This directly explains an oddity noticed in the `my-nginx` manifest
earlier — blank keys like `envFrom:` with nothing under them. Those come
from a `{{- with }}` block whose underlying value was empty: the
hardcoded key text still printed, but the block's contents rendered as
nothing.

### Step 12: Preview the unmodified scaffold

```bash
helm template mealie-chart
```

This is Helm's equivalent of `kubectl apply --dry-run=client` — full
rendered YAML, no cluster contact, using the scaffold's generic nginx
defaults since nothing's been customized yet.

### Step 13: Point the chart at mealie

Edit `mealie-chart/values.yaml`:

```yaml
replicaCount: 1

image:
  repository: ghcr.io/mealie-recipes/mealie
  pullPolicy: IfNotPresent
  tag: "v3.28.0"

service:
  type: ClusterIP
  port: 9000

volumes:
  - name: mealie-data
    persistentVolumeClaim:
      claimName: mealie-data

volumeMounts:
  - name: mealie-data
    mountPath: /app/data
```

**The important realization:** `templates/deployment.yaml` needed **zero
changes**. It already reads `.Values.image.repository`,
`.Values.image.tag`, `.Values.service.port`, `.Values.volumes`, and
`.Values.volumeMounts` generically — the scaffold's `volumes`/
`volumeMounts` sections are direct passthroughs
(`{{- with .Values.volumes }}...{{- toYaml . }}`), so mealie's existing
PVC from Lab 10 slots in by just populating those two fields. This is the
actual point of a chart: the template is reusable *because* it never
hardcodes `nginx`, `80`, or any specific volume anywhere — only
`values.yaml` does.

```bash
helm template mealie-chart
```

**Expected result:** the rendered Deployment now shows
`image: "ghcr.io/mealie-recipes/mealie:v3.28.0"`, `containerPort: 9000`,
and a `volumes`/`volumeMounts` block referencing `mealie-data` — produced
entirely from editing one file, with the template untouched.

### Step 14 (next session): Install and compare

Natural continuation, not yet run:

```bash
kubectl create namespace mealie-helm
helm install mealie mealie-chart -n mealie-helm
kubectl get pods -n mealie-helm
helm get manifest mealie -n mealie-helm | diff - <(cat deployment.yaml service.yaml)
```

Worth checking: does the chart-generated Service correctly reference port
9000? Does the pod mount `mealie-data` and skip Mealie's first-run setup,
proving the same PVC binds correctly through a chart-managed Deployment
(same test as Lab 10, Step 6/7, run through Helm this time)? And — since
this chart's `templates/deployment.yaml` has no `securityContext` set by
default in `values.yaml` — would be worth adding the same non-root
hardening seen in the Bitnami chart (Part 2) as a further exercise.

---

## Key Takeaways

1. **A chart is a template; values fill in the blanks.** The same chart produces different results depending on what `values.yaml` (or `--set`) supplies.
2. **One `helm install` can create many object kinds at once** — Deployment, Service, NetworkPolicy, PodDisruptionBudget, ServiceAccount, Secret — all versioned together as one release.
3. **`helm upgrade --set key=value` changes exactly what you name.** Nothing else in the release is touched, and `helm get values` proves it.
4. **`helm rollback` is atomic across the whole release**, and it creates a *new* revision rather than erasing history — a meaningfully different (and more complete) safety net than `kubectl rollout undo`, which only ever tracks one Deployment.
5. **The stale CNI token (Lab 4) isn't a one-time fluke** — it recurred a third time here, purely because `calico-node` had been running long enough again. Worth automating detection rather than continuing to diagnose it manually.
6. **`helm create` scaffolds a real, working chart** — study it rather than starting from a blank file; most of what a custom chart needs is already there as a generic pattern (image, replicas, service, probes, volumes) waiting to be pointed at your actual application.
7. **Good charts parameterize everything, including security.** The Bitnami chart's non-root `securityContext`, dropped capabilities, and disabled token automount are all things worth deliberately adding to a hand-rolled chart, not just accepting scaffold defaults.

---

## Command Reference

```bash
# Install Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh && ./get_helm.sh

# Repositories
helm repo add <name> <url>
helm repo update
helm search repo <name>/<chart>

# Install / inspect / upgrade / rollback a release
helm install <release> <chart> -n <namespace>
helm list -n <namespace>
helm get manifest <release> -n <namespace>
helm get values <release> -n <namespace>
helm upgrade <release> <chart> -n <namespace> --set <key>=<value>
helm history <release> -n <namespace>
helm rollback <release> <revision> -n <namespace>
helm uninstall <release> -n <namespace>

# Build your own chart
helm create <chart-name>
helm template <chart-name>              # render without installing
helm install <release> <chart-name> -n <namespace>
helm lint <chart-name>                  # check for template/style problems
```
