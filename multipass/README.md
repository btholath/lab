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
| `scripts/apply-manifest.ps1` | Copy a YAML file into the master and `kubectl apply` it |
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

## Notes

- In PowerShell always run `multipass exec master -- kubectl ...`. Plain `kubectl`
  talks to a different cluster.
- The master's IP must not change. Check `multipass list` after every restart.
- **Never commit** kubeconfig files, `admin.conf`, join tokens or keys. `.gitignore`
  blocks the common names, but check `git status` before committing.
- Shut down with `multipass stop --all`; remove everything with
  `multipass delete --all` then `multipass purge`.
