# k9s — A Terminal UI for Kubernetes

**What it is, in one line:** a terminal tool that runs on your own machine
(same category as `kubectl` itself) and gives you a live, navigable,
color-coded view of a cluster, instead of typing individual
`kubectl get`/`describe`/`logs` commands one at a time.

**What it is not:** it does **not** get installed *into* the cluster.
Nothing runs as a pod. k9s reads your existing `~/.kube/config` — the same
file `kubectl` already uses — and talks directly to the API server as a
client, exactly like `kubectl` does.

---

## Why bother, given `kubectl` already works

Across this whole lab series, a lot of debugging looked like this:

```bash
kubectl get pods -w              # terminal 1
kubectl describe pod <name>      # terminal 2
kubectl logs -f <name>           # terminal 3
```

k9s replaces that three-terminal juggling with one live screen: pod status
updates in real time, and pressing a single key on a highlighted resource
does what you'd otherwise type a full command for. It's the same
information, the same underlying API calls — just navigated instead of
typed.

---

## Install (WSL2 Ubuntu)

The `.deb` package from the official GitHub releases is the cleanest fit —
no third-party repo, no GPG key to import, and it matches the pattern
you've already used for local `.deb` installs elsewhere in this series:

```bash
curl -Lo k9s.deb https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb
sudo apt install ./k9s.deb
rm k9s.deb
k9s version
```

**Expected output:** a version banner confirming the binary installed.

---

## Run it

```bash
k9s
```

That's the entire "setup." It opens using whatever context and namespace
your kubeconfig currently points at — if your saved default is still
`mealie` from earlier labs, k9s opens scoped there. Change namespace or
context from inside the tool at any time (see below).

---

## Exiting

| Key | Does |
|---|---|
| `:q` + Enter | Quit k9s entirely |
| `Ctrl+C` | Also quits immediately, from anywhere |
| `Esc` | Goes back **one level** — out of a describe view, a filtered list, etc. **Not** quit |

If you're ever unsure which screen you're on, press `Esc` a few times to
get back to the main resource list, then `:q` to exit cleanly.

⚠️ **`Ctrl+D`** (while a resource is selected) is **not** an exit shortcut —
it **deletes the selected resource**. Worth being deliberate about which
Ctrl-key you reach for.

---

## Core Navigation

| Key / Command | Does | `kubectl` equivalent |
|---|---|---|
| `:pods`, `:svc`, `:deploy`, `:pvc`, `:ns`, `:pv`, `:netpol`, etc. | Jump to that resource type | `kubectl get <type>` |
| `/` | Filter/search the current list | `kubectl get <type> \| grep ...` |
| `d` | Describe the selected resource | `kubectl describe` |
| `l` | Tail logs (live) | `kubectl logs -f` |
| `s` | Shell into a pod | `kubectl exec -it ... -- sh` |
| `y` | View the resource as raw YAML | `kubectl get ... -o yaml` |
| `Ctrl+D` | **Delete** the selected resource | `kubectl delete` |
| `:xray <type>` | Visualize ownership as a tree (e.g. Deployment → ReplicaSet → Pods) | Several `kubectl get`/`describe` calls, manually cross-referenced |
| `0` | Switch view to all namespaces | `kubectl get <type> -A` |
| `?` | Full help / key list | — |
| `Esc` | Back one level | — |
| `:q` | Quit | — |

Resource aliases work the same short names `kubectl` uses (`:po`, `:svc`,
`:deploy`, `:ns`), so anything already muscle-memorized from this series
carries over directly.

---

## A First Exercise on This Cluster

Using the actual mealie work from Labs 5–10:

```bash
k9s
```
1. Type `:pods` and press Enter.
2. Type `/mealie` to filter down to the mealie pod.
3. Select it, press `l` to tail its logs live — the same
   `mealie.log` content that was manually `grep`-ed in Lab 10 to prove
   data persistence, now streaming in a scrollable pane instead.
4. Press `Esc`, then try `:xray deploy` and select `mealie` — this draws
   the Deployment → ReplicaSet → Pod hierarchy as a tree, the same
   relationship that took three separate `kubectl get` calls to trace by
   hand back in Lab 5.

---

## A Note for KCSA / RBAC Context

k9s has no permissions of its own — it can only do whatever the
credentials in the kubeconfig it's reading are allowed to do. Pointing
k9s at a kubeconfig tied to a limited ServiceAccount (rather than your
full `kubernetes-admin` context) is a good way to **see RBAC restrictions
in action**: resource types you lack permission for simply won't list, and
actions like `Ctrl+D` (delete) will fail with a clear permissions error if
the bound Role/ClusterRole doesn't allow it. This is worth revisiting once
RBAC is covered as its own topic.

---

## Quick Reference

```bash
# Install
curl -Lo k9s.deb https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb
sudo apt install ./k9s.deb
rm k9s.deb

# Run
k9s

# Inside k9s
:pods            # jump to pods
:svc             # jump to services
:deploy          # jump to deployments
:pvc             # jump to persistent volume claims
:ns              # jump to / switch namespaces
:xray deploy     # visualize ownership tree
/<text>          # filter current list
d                # describe selected
l                # tail logs
s                # shell into pod
y                # view as YAML
0                # toggle all-namespaces view
?                # help
Esc              # back one level
:q               # quit
```
