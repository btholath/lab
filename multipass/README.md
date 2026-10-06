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
| `scripts/create-vms.ps1` | Create the three VMs (Windows PowerShell) |
| `scripts/common.sh` | Steps 1-3: prepare node, install containerd, kubeadm, kubelet, kubectl |
| `scripts/setup-common.ps1` | Copy and run `common.sh` on all VMs |
| `scripts/pin-ip.sh` | Runs inside a VM: adds a fixed second IP with netplan and keeps DHCP (`--undo` removes it) |
| `scripts/pin-ip.ps1` | Copies `pin-ip.sh` into a VM and runs it |
| `scripts/host-alias.ps1` | Run as Administrator after a Windows reboot if the Hyper-V Default Switch changed subnet |
| `scripts/apply-manifest.ps1` | Copy a YAML file into the master and `kubectl apply` it |
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
