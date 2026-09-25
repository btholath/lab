# Lab 3: Exporting a Clean Pod Manifest with `kubectl-neat`

**Goal:** take a pod that's already running in the cluster (created imperatively
or otherwise) and export its definition as a *clean, reusable* YAML file —
not the noisy, server-populated dump that `kubectl get -o yaml` produces by
default. Along the way, you'll install `krew`, the standard plugin manager
for `kubectl`, which unlocks a whole ecosystem of useful tools beyond just
this one.

**Why this matters:** once a Pod exists in the cluster, its live object
contains a lot of information the *API server* added — status fields,
internal IDs, scheduling metadata — that you never wrote yourself and don't
want in a manifest you plan to reuse or commit to Git. Stripping that out by
hand is tedious and error-prone; `kubectl-neat` automates it.

---

## Step 1: Check your starting pods

```bash
kubectl get pods
```

**Expected output:**
```
NAME         READY   STATUS    RESTARTS   AGE
httpd        1/1     Running   0          33m
nginx-yaml   1/1     Running   0          84m
```

**Why:** confirms you have a running pod (`httpd`) to work with before doing
anything else — always good practice to verify current state before running
a new command.

---

## Step 2: Try exporting the live pod through `kubectl-neat`

```bash
kubectl get pod httpd -o yaml | kubectl neat
```

**Expected output (on a machine without the plugin yet):**
```
error: unknown command "neat" for "kubectl"
```
*(or a similar "not found" message, depending on your kubectl version)*

**Why this fails:** `kubectl neat` is not a built-in `kubectl` subcommand —
it's a **plugin**. Plugins have to be installed separately before `kubectl`
knows about them; there's nothing wrong with your cluster or your pod here,
`kubectl` genuinely just doesn't have this command yet.

---

## Step 3: Try installing it the "obvious" way — and see why it doesn't work

```bash
apt install kubectl-neat
```

**Expected output:**
```
E: Could not open lock file /var/lib/dpkg/lock-frontend - open (13: Permission denied)
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), are you root?
```

**Why:** `apt install` (without `sudo`) always fails this way — installing
system packages requires root privileges, and `apt` is telling you exactly
that.

Add `sudo` and try again:

```bash
sudo apt install kubectl-neat
```

**Expected output:**
```
E: Unable to locate package kubectl-neat
```

**Why this *also* fails, differently this time:** now you have the right
permissions, but `kubectl-neat` simply **isn't a Debian/Ubuntu apt
package at all**. It's distributed as a `kubectl` **plugin**, not a normal
Linux program — apt has no idea it exists, and never will, no matter how
many times you run `apt update`.

**The lesson here:** not every command-line tool is installed the same way.
`kubectl` plugins live in their own separate ecosystem, managed by a tool
called **krew** — similar in spirit to how Python has `pip`, or Node has
`npm`, separate from your OS's own package manager.

---

## Step 4: Install `krew` (the plugin manager for `kubectl`)

```bash
(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew
)
```

**What this script actually does, line by line:**
- `cd "$(mktemp -d)"` — creates and moves into a brand-new temporary directory, so downloaded files don't clutter your working folder
- `OS=...` / `ARCH=...` — detects your operating system (`linux`) and CPU architecture (`amd64`) automatically, so the correct krew binary gets downloaded for *your* machine specifically
- `curl -fsSLO ...` — downloads the matching krew release archive
- `tar zxvf ...` — extracts it
- `./krew-linux_amd64 install krew` — runs the extracted binary once, telling it to install *itself* properly (krew bootstraps its own installation this way)

**Expected output (abbreviated):**
```
Adding "default" plugin index from https://github.com/kubernetes-sigs/krew-index.git.
Updated the local copy of plugin index.
Installing plugin: krew
Installed plugin: krew
...
krew is now installed! To start using kubectl plugins, you need to add
krew's installation directory to your PATH:
    export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
```

**Why the `$PATH` step matters:** your shell only looks for commands in
directories listed in the `$PATH` environment variable. krew installs itself
into `~/.krew/bin`, which isn't in your `$PATH` by default — without adding
it, your shell would never find the `kubectl-krew` command (or any plugin
krew installs later), even though the files genuinely exist on disk.

---

## Step 5: Add krew to your PATH permanently

```bash
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

**Why two commands:**
- `echo ... >> ~/.bashrc` — appends that line to your shell's startup
  file, so this PATH addition happens automatically every time you open a
  new terminal from now on
- `source ~/.bashrc` — re-runs that startup file *immediately*, in your
  *current* terminal session, so you don't have to close and reopen your
  terminal just to use krew right now

---

## Step 6: Install the `neat` plugin using krew

```bash
kubectl krew install neat
```

**Expected output:**
```
Updated the local copy of plugin index.
Installing plugin: neat
Installed plugin: neat

Use this plugin:
     kubectl neat
Documentation:
     https://github.com/itaysk/kubectl-neat

WARNING: You installed plugin "neat" from the krew-index plugin repository.
   These plugins are not audited for security by the Krew maintainers.
   Run them at your own risk.
```

**Why the warning appears:** krew's plugin index is community-maintained,
similar to how npm or PyPI packages aren't individually vetted by npm/PyPI
themselves. This is a routine, expected warning for *every* community plugin
you install via krew — not a sign that anything went wrong. `kubectl-neat`
specifically is a well-known, widely used plugin in the Kubernetes community.

---

## Step 7: Verify the plugin installed correctly

```bash
kubectl neat --help
```

**Expected output:**
```
Usage:
  kubectl-neat [flags]
  kubectl-neat [command]

Examples:
kubectl get pod mypod -o yaml | kubectl neat
kubectl get pod mypod -oyaml | kubectl neat -o json
kubectl neat -f - <./my-pod.json
kubectl neat -f ./my-pod.json
kubectl neat -f ./my-pod.json --output yaml

Available Commands:
  completion  Generate the autocompletion script for the specified shell
  get
  help        Help about any command
  version     Print kubectl-neat version

Flags:
  -f, --file string     file path to neat, or - to read from stdin (default "-")
  -h, --help            help for kubectl-neat
  -o, --output string   output format: yaml or json (default "yaml")
```

Seeing a proper help menu (instead of an "unknown command" error) confirms
the plugin is installed and `kubectl` can find it.

---

## Step 8: Export a clean manifest from the live `httpd` pod

```bash
kubectl get pod httpd -o yaml | kubectl neat > httpd-clean.yaml
```

**What's happening here (a Unix pipe):**
1. `kubectl get pod httpd -o yaml` — fetches the full, live object from the
   API server, exactly as Kubernetes currently has it stored — including
   every server-generated field
2. `| kubectl neat` — pipes that output *into* `kubectl-neat`, which strips
   out the noisy, auto-generated fields (`status`, `resourceVersion`, `uid`,
   `creationTimestamp`, `managedFields`, and similar) and leaves only the
   fields that represent your actual *intent* — the parts you'd want if you
   were writing this manifest from scratch
3. `> httpd-clean.yaml` — redirects that cleaned-up result into a new file
   instead of printing it to your screen

**Expected result:** no console output (redirected straight to the file).
Confirm it worked:
```bash
cat httpd-clean.yaml
```
You should see a much shorter, cleaner manifest than a raw
`kubectl get pod httpd -o yaml` would produce — close in spirit to what
`kubectl run httpd --image=httpd --dry-run=client -o yaml` would have given
you *before* the pod ever existed, but reflecting whatever the pod's *actual*
current state is (including anything that changed since creation).

---

## Step 9: Inspect the "clean" file — it's cleaner, but not fully portable yet

```bash
cat httpd-clean.yaml
```

**Actual output from this lab:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    cni.projectcalico.org/containerID: 4da1ab88a8267d4bac601453c00cf29730c0a058a8b7b62f1a9b2730c3dfcb5c
    cni.projectcalico.org/podIP: 192.168.78.77/32
    cni.projectcalico.org/podIPs: 192.168.78.77/32
  labels:
    run: httpd
  name: httpd
  namespace: default
spec:
  containers:
  - image: httpd
    name: httpd
    volumeMounts:
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      name: kube-api-access-5k629
      readOnly: true
  preemptionPolicy: PreemptLowerPriority
  priority: 0
  serviceAccountName: default
  tolerations:
  - effect: NoExecute
    key: node.kubernetes.io/not-ready
    operator: Exists
    tolerationSeconds: 300
  - effect: NoExecute
    key: node.kubernetes.io/unreachable
    operator: Exists
    tolerationSeconds: 300
  volumes:
  - name: kube-api-access-5k629
    projected:
      sources:
      - serviceAccountToken:
          expirationSeconds: 3607
          path: token
      - configMap:
          items:
          - key: ca.crt
            path: ca.crt
          name: kube-root-ca.crt
      - downwardAPI:
          items:
          - fieldRef:
              fieldPath: metadata.namespace
            path: namespace
```

`kubectl-neat` stripped the *big* server-generated noise (`status`,
`resourceVersion`, `uid`, `managedFields`, `creationTimestamp`) — but several
fields here are still tied to **this one specific pod instance**, not
generically reusable:

| Field | Why it's a problem for reuse |
|---|---|
| `metadata.annotations` (all 3 Calico ones) | Tied to *this pod's* actual network attachment — `containerID` and `podIP` are meaningless, and will be wrong/stale, the moment this file is used to create a **different** pod |
| `spec.volumes[].projected.sources[].serviceAccountToken` volume name (`kube-api-access-5k629`) | That random suffix is auto-generated fresh every time *any* pod is created. Hardcoding it ties this manifest to one past pod instance rather than being a generic template |
| `spec.containers[].volumeMounts[]` referencing `kube-api-access-5k629` | Same issue — it references the volume above by its instance-specific name |
| `spec.preemptionPolicy`, `spec.priority` | Cluster-assigned defaults, not something a hand-written manifest needs to declare |

**Why `kubectl-neat` leaves these in:** its job is narrowly scoped to
stripping fields that are *always* purely server-managed bookkeeping
(status, resourceVersion, etc.). It doesn't try to guess which *spec* fields
were auto-injected by your specific cluster's admission controllers versus
fields you genuinely intended to set — that distinction requires knowing
your own cluster's defaults, which is a judgment call worth understanding
rather than fully automating away.

---

## Step 10: Prove it — diff against a true from-scratch manifest

The clearest way to see *exactly* what Kubernetes auto-injects at creation
time is to compare your cleaned file against a manifest that never touched
a running cluster at all:

```bash
diff <(kubectl run httpd --image=httpd --dry-run=client -o yaml) httpd-clean.yaml
```

**What you're comparing:**
- **Left side** (`kubectl run ... --dry-run=client`) — pure client-side
  generation. Nothing has been sent to the API server; this is *only* what
  you declared.
- **Right side** (`httpd-clean.yaml`) — a real object that existed in the
  cluster, then had server bookkeeping stripped by `kubectl-neat`.

Everything the `diff` shows as only present on the right side —
`serviceAccountName`, the `kube-api-access` volume/mount, `tolerations`,
`preemptionPolicy`, `priority`, and the Calico annotations — is something
**Kubernetes added automatically**, via admission controllers and default
scheduling behavior, regardless of whether you asked for it. None of it
needs to be hand-written in a manifest you intend to reuse.

---

## Step 11: Write the actual minimal, reusable manifest

Based on the `diff`, the genuinely portable version of this pod definition
is just:

```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    run: httpd
  name: httpd
  namespace: default
spec:
  containers:
  - image: httpd
    name: httpd
```

This is functionally equivalent to the original `--dry-run=client` output —
which makes sense: that was always the *intent-only* version. Save this as
`httpd-template.yaml`:

```bash
vim httpd-template.yaml
```

Now that you have a truly clean, minimal manifest, you can safely:
- Commit it to your Git repo as a real, reusable definition
- Change its `name` and re-`apply` it to create a second, similar pod
- Use it as a starting template for a Deployment later

---

## Summary — Why Each Tool Exists

| Tool | Purpose |
|---|---|
| **`apt`** | Installs *system-level* Linux packages (OS tools, libraries) |
| **`krew`** | Installs *kubectl plugins* — a separate ecosystem, not related to your OS's package manager |
| **`kubectl-neat`** | Strips the big server-generated bookkeeping fields (`status`, `resourceVersion`, `uid`, `managedFields`) from `kubectl get -o yaml` output |
| **Manual review + `diff`** | Catches the remaining instance-specific fields `kubectl-neat` doesn't know to remove (annotations, generated volume names, scheduling defaults) |

**The core lesson of this lab:** a live Kubernetes object (`kubectl get -o
yaml`) and a manifest you'd write by hand are related but not identical — the
live object accumulates state from **three different sources**:

1. **What you declared** (the image, the name, your labels)
2. **What the API server stamps on every object** (`uid`, `resourceVersion`,
   `status`, timestamps) — this is what `kubectl-neat` removes for you
3. **What admission controllers and scheduling defaults inject** (service
   account tokens, tolerations, priority, and in this case Calico's CNI
   annotations) — this layer requires your own judgment to identify, which
   is exactly what the `diff` in Step 10 made visible

Going from "what's running" back to "a clean, reusable definition of what
*should* run" means peeling back all three layers, not just the first one
`kubectl-neat` automates.

---

## Command Reference for This Lab

```bash
# See current pods
kubectl get pods

# Install krew (one-time, per machine)
(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew
)

# Add krew to PATH (one-time, per machine)
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Install the neat plugin (one-time)
kubectl krew install neat

# Get a partially-cleaned manifest from a live object
kubectl get pod <pod-name> -o yaml | kubectl neat > <pod-name>-clean.yaml

# See exactly what Kubernetes auto-injected, by comparing against
# a pure client-side (never-existed-in-cluster) manifest
diff <(kubectl run <pod-name> --image=<image> --dry-run=client -o yaml) <pod-name>-clean.yaml

# Hand-write the final, truly minimal, reusable manifest based on that diff
vim <pod-name>-template.yaml
```
