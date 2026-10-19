# multipass: a 3-node kubeadm Kubernetes lab

A hands-on lab that builds a Kubernetes cluster with `kubeadm` on three
[Multipass](https://multipass.run) Ubuntu VMs (1 control plane + 2 workers) on a
single Windows laptop, then practices core Kubernetes skills on it.

The full step-by-step guide is in [`docs/`](docs/).

## Layout

| Path | Purpose |
|---|---|
| `docs/kubernetes-kubeadm-cluster-guide.md` | Beginner guide (Markdown) |
| `docs/kubernetes-kubeadm-cluster-guide.docx` | Same guide as a Word document |
| `docs/kubeadm-upgrade-walkthrough.md` | A real v1.35.9 to v1.36.5 upgrade, with console output and explanations |
| `docs/kubernetes-services-guide.md` | Services: ClusterIP, NodePort, LoadBalancer, with real console output |
| `docs/app-design-workload-controllers.md` | Labels and selectors, ReplicaSets, Deployments, DaemonSets, Jobs and CronJobs, with labs |
| `docs/scheduling-guide.md` | Requests, limits, QoS, node affinity and topology spread, with real output |
| `docs/probes-guide.md` | Readiness, liveness and startup probes, with real output |
| `docs/hpa-guide.md` | metrics-server, the HPA's rules, scaling up and down, and `behavior`, with real output |
| `docs/rbac-guide.md` | Roles, bindings, a certificate-based user, groups, anonymous access and escalation, with real output |
| `docs/configmaps-secrets-guide.md` | ConfigMaps and Secrets: updates, failures, base64, etcd plaintext, and who can read them, with real output |
| `docs/broken-kubelet-guide.md` | Four ways to break a kubelet, how each looks from the control plane, and how to find the cause, with real output |
| `docs/dns-guide.md` | CoreDNS, the search path and `ndots`, DNS down against the network down, a Corefile typo, and custom names, with real output |
| `docs/node-address-change-guide.md` | When the VMs' addresses change: the symptoms, stale flannel records, a permanent route, and the `netplan apply` trap, with real output |
| `docs/ingress-traefik-guide.md` | Ingress with Traefik: what the 7 objects do and how a request flows. Written before the first run, so outputs are expected, not observed. Includes `docs/images/traefik-step2-flow.gif` |
| `docs/ingress-errors-lab.md` | The 404/503/502 lab: what each status means, the first run's results (a Service with no ready Pods gets a 404, not a 503, by default), the documented reason, and what is still open |
| `scripts/create-vms.ps1` | Create the three VMs (Windows PowerShell) |
| `scripts/common.sh` | Steps 1-3: prepare node, install containerd, kubeadm, kubelet, kubectl |
| `scripts/setup-common.ps1` | Copy and run `common.sh` on all VMs |
| `scripts/pin-ip.sh` | Runs inside a VM: adds a fixed second IP with netplan and keeps DHCP (`--undo` removes it) |
| `scripts/pin-ip.ps1` | Copies `pin-ip.sh` into a VM and runs it |
| `scripts/host-alias.ps1` | Run as Administrator after a Windows reboot if the Hyper-V Default Switch changed subnet |
| `scripts/apply-manifest.ps1` | Copy a YAML file into the master and `kubectl apply` it |
| `scripts/check-clocks.ps1` | Compare each VM's clock with Windows (`-Fix` restarts the time service first) |
| `scripts/flannel-recover.sh` | After the nodes' addresses change: repair stale flannel records and verify pods, DNS and metrics (run on the master) |
| `scripts/route-to-master.sh` | Give a worker a permanent direct route to the master's fixed address, so a subnet change cannot cut it off. Does not run `netplan apply` (run on each worker) |
| `scripts/ingress-lab.sh` | Set up, check (`status`), remove (`down`) or restart from clean (`reset`) the Ingress lab: Traefik, two test apps and an Ingress. Idempotent. Run on the master |
| `scripts/ingress-errors-lab.sh` | Makes Traefik answer 404, 503 and 502 on purpose in its own namespace (`errors-lab`), records the status and Traefik's access-log fields for each, and times scale-downs and scale-ups. `flag` turns Traefik's `allowEmptyServices` on, re-probes and turns it off again. `down` removes it. Needs the Ingress lab up |
| `scripts/git-hooks/pre-commit` | Blocks commits that add private keys, kubeconfig credentials, AWS keys, join tokens or GitHub tokens |
| `scripts/install-hooks.sh` | One-time installer for the git hook |
| `manifests/` | Example Deployment, Service and scheduling-test pods |

## Quick start (Windows PowerShell)

```powershell
cd scripts
.\create-vms.ps1          # 1. create master, worker1, worker2
multipass list            #    note the master's IP
.\setup-common.ps1        # 2. install everything on all three (slow on a slow link)
```

Then follow the guide, Sections 7 to 10, to run `kubeadm init` on the master,
install flannel, and join the workers. Practice with the manifests:

```powershell
.\apply-manifest.ps1 ..\manifests\deployment.yaml
.\apply-manifest.ps1 ..\manifests\service-nodeport.yaml
multipass exec master -- kubectl get pods -o wide
```

## Secret scanning (git hook)

Enable the pre-commit hook once per clone, from anywhere inside the repository:

```bash
bash multipass/scripts/install-hooks.sh
```

It scans only the lines a commit adds, skips binary files, and prints the file and
line number of a finding but never the secret itself. Certificates and certificate
requests (public data) are allowed. To keep a harmless false positive, add
`secret-scan: allow` to that line, or bypass once with `git commit --no-verify`.
If a real secret was ever used, rotate it as well as removing it.

## Notes

- In PowerShell always run `multipass exec master -- kubectl ...`. Plain `kubectl`
  talks to a different cluster.
- The master's IP must not change, or `kubectl` fails with `no route to host`. Add a fixed second
  address to the master with `scripts/pin-ip.ps1` (guide Section 21). Do **not** replace DHCP with a
  static address: Multipass then cannot find the VM. A Windows reboot can still change the Hyper-V
  Default Switch subnet; Section 21.5 covers it.
- **Never commit** kubeconfig files, `admin.conf`, join tokens or keys. `.gitignore`
  blocks the common names, but check `git status` before committing.
- Shut down with `multipass stop --all`; remove everything with
  `multipass delete --all` then `multipass purge`.
