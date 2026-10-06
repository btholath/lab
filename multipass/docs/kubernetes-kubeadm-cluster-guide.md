# Build Your Own Kubernetes Cluster with kubeadm

## A beginner's hands-on guide: 1 control plane + 2 workers on one Windows laptop

This guide walks you from "I have a laptop with WSL/Ubuntu" to a working three-node Kubernetes cluster that you built yourself with `kubeadm`, then shows you how to run pods on it and practice real Kubernetes skills. Every command is explained, and the common problems we hit along the way are included with their fixes.

> **How this guide was tested:** the steps were run on a real Windows laptop with Multipass, and the outputs shown come from that run. The exceptions are steps marked "optional" or "not run in the worked example" (including Section 16), which are extra practice that was not verified.

> **Who this is for:** beginners preparing for hands-on Kubernetes practice (for example CKA/CKAD). You do not need prior kubeadm experience. You should be comfortable typing commands into a terminal.

## Contents

1. What you will build, and key concepts
2. Check what you already have on WSL
3. Why you need virtual machines
4. Install Multipass on Windows
5. Create the three virtual machines
6. Prepare all three machines (containerd, kubeadm, kubelet, kubectl)
7. Initialize the control plane (master)
8. Install the pod network (flannel)
9. Join the worker nodes
10. Verify the cluster
11. Run pods and test the cluster
12. Services and endpoints
13. Self-healing, drain and rolling updates
14. Scheduling: selectors, taints and tolerations
15. Node failure behavior
16. Use kubectl from WSL (optional)
17. Daily operations: stop, start, clean up
18. Troubleshooting
19. Security notes
20. Command cheat sheet
21. What to practice next

# 1. What you will build, and key concepts

## The target layout

You will create three virtual machines (VMs) on your laptop and turn them into one cluster:

| Machine | Role | What it does |
|---|---|---|
| master | Control plane | Runs the API server, scheduler, controller manager and etcd (the cluster's brain and database) |
| worker1 | Worker node | Runs your application pods |
| worker2 | Worker node | Runs your application pods |

## The six kubeadm steps

Setting up a cluster with kubeadm always follows the same six steps. Steps 1-3 run on every machine, step 4 only on the master, step 5 once from the master, and step 6 on each worker.

| Step | What happens | Where it runs |
|---|---|---|
| 1 | Prepare the machine (disable swap, kernel settings) | All three |
| 2 | Install containerd (the container runtime) | All three |
| 3 | Install kubeadm, kubelet and kubectl | All three |
| 4 | Initialize the control plane (`kubeadm init`) | Master only |
| 5 | Install a pod network (flannel) | Master only |
| 6 | Join the nodes (`kubeadm join`) | Each worker |

## Key concepts in plain language

| Term | Meaning |
|---|---|
| Cluster | A group of machines working together to run containers |
| Control plane (master) | The machine that makes decisions: where pods run, what to restart |
| Worker node | A machine that actually runs your pods |
| Pod | The smallest unit in Kubernetes: one or more containers running together |
| Deployment | A recipe that keeps a chosen number of identical pods running |
| kubectl | The command-line tool you use to talk to a cluster |
| kubeadm | A tool that bootstraps a cluster: it creates the control plane and joins nodes |
| kubelet | The agent on every node that starts and watches pods |
| containerd | The container runtime that actually runs containers |
| CNI / pod network | A plugin that lets pods on different nodes talk to each other. We use flannel |
| Taint | A "keep out" mark on a node. The master has one so normal pods do not run there |
| Context | A saved kubectl connection (cluster + user). You can have several |

# 2. Check what you already have on WSL

Before building anything, it helps to know what is already on your machine. Open your WSL Ubuntu terminal and run these checks. This is also a good way to learn how to inspect any cluster.

## 2.1 Is kubectl installed?

**Run in: WSL Ubuntu**

```bash
which kubectl
kubectl version --client
```

If `which` prints nothing, kubectl is not installed in WSL.

## 2.2 Is there a cluster you can reach?

```bash
kubectl cluster-info
kubectl config get-contexts
kubectl config current-context
```

- `cluster-info` prints the API server address if a cluster is reachable.
- `get-contexts` lists every cluster kubectl knows about. The `*` marks the active one.
- "connection refused" means a cluster is configured but not running.

## 2.3 List the nodes

```bash
kubectl get nodes -o wide
```

The `ROLES` column tells you what each node is. `control-plane` is the master. `<none>` is normal for a worker, because plain worker nodes are not labeled.

## 2.4 Identify the kind of cluster

On WSL a cluster is usually one of these. Check each:

| Type | How to check |
|---|---|
| Docker Desktop Kubernetes | Node is named `docker-desktop` |
| kind (Kubernetes in Docker) | `which kind`, `kind get clusters`, `docker ps` shows `kindest/node` containers |
| minikube | `which minikube`, `minikube status` |
| k3s / k3d | `which k3s k3d`, `k3d cluster list` |
| kubeadm on the host | `which kubeadm`, `systemctl status kubelet`, `ps aux` shows `kube-apiserver` |

## 2.5 What this author found (a worked example)

On the example machine, the checks showed **two separate clusters** at the same time:

| Cluster | Context | Nodes |
|---|---|---|
| kind | `kind-btlabs-k8s` | 1 control plane + 2 workers, running as Docker containers |
| kubeadm on the WSL host | `kubernetes-admin@kubernetes` | 1 node (`b`) acting as both control plane and worker |

How the kubeadm cluster was recognized as single-node: `kubectl --context kubernetes-admin@kubernetes get nodes` showed one node, and `describe node` showed `Taints: <none>`. Normally a control-plane node has the taint `node-role.kubernetes.io/control-plane:NoSchedule`, which keeps ordinary pods away. With no taint, that one node runs everything.

Useful commands to inspect a cluster that is not your current context:

```bash
kubectl --context kubernetes-admin@kubernetes get nodes -o wide
kubectl --context kubernetes-admin@kubernetes describe node b | grep -i taints
```

Two other things worth knowing from that output:

- **Version skew:** kubectl is only supported within one minor version of the API server. kubectl v1.35 against a v1.32 kind cluster works for basics but is outside the supported range.
- **Resource use:** running several clusters at once on WSL uses a lot of memory. Stop what you are not using.

> **Tip:** to switch clusters, use `kubectl config use-context <name>`. Always run `kubectl config current-context` before doing anything destructive, so you do not change the wrong cluster.

# 3. Why you need virtual machines

kubeadm expects each node to be its own machine with its own hostname, network address and kernel settings. All WSL distros on one laptop share a single Linux kernel and one network identity, so you cannot run three independent kubeadm nodes inside WSL. That is why a WSL kubeadm install is single-node.

The practical fix is to create **three small VMs on your laptop**. The easiest tool for this is **Multipass**, which launches Ubuntu VMs with one command.

> **Shortcut for pure exam practice:** a kind cluster already gives you 1 control plane and 2 workers, and kind uses kubeadm internally. For CKAD-style practice (pods, deployments, services) kind is often enough. Build the kubeadm VM cluster in this guide when you specifically want to learn installation, `kubeadm join`, upgrades and etcd backup, which matter more for CKA.

## Check your laptop first

| Resource | Recommended |
|---|---|
| RAM | 16 GB comfortable. 8 GB is tight; lower the workers to 1.5-2 GB each |
| CPU | 4+ cores (each VM gets 2) |
| Disk | About 60 GB free (three 20 GB virtual disks) |
| Windows | Pro/Enterprise/Education uses Hyper-V. Home needs VirtualBox |

Three VMs at 2 GB each need about 6 GB of RAM on top of Windows. If you also have old clusters running in WSL, stop them first:

**Run in: WSL Ubuntu**

```bash
kind delete cluster --name btlabs-k8s
sudo systemctl stop kubelet
```

You can also cap how much memory WSL takes. Create `C:\Users\<you>\.wslconfig` with:

```
[wsl2]
memory=4GB
```

Then run `wsl --shutdown` in PowerShell and reopen Ubuntu.

# 4. Install Multipass on Windows

Multipass is installed on the **Windows side**, not inside WSL, and used from **Windows PowerShell**.

**Run in: Windows PowerShell**

```powershell
winget install Canonical.Multipass
```

## 4.1 Fix: "multipass is not recognized"

After installing, you may see this error:

```
multipass : The term 'multipass' is not recognized as the name of a cmdlet...
```

This happens because the installer adds Multipass to the PATH after your PowerShell window started, and open windows do not pick up PATH changes. Fix it in this order:

1. **Close PowerShell completely and open a new window.** Try `multipass version`.
2. If it still fails, confirm it is installed:

```powershell
Test-Path "C:\Program Files\Multipass\bin\multipass.exe"
```

3. If that prints `True`, run it by full path to prove it works:

```powershell
& "C:\Program Files\Multipass\bin\multipass.exe" version
```

4. For the current window only, create a shortcut:

```powershell
Set-Alias multipass "C:\Program Files\Multipass\bin\multipass.exe"
```

5. To make it permanent, add it to your PATH, then reopen PowerShell:

```powershell
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Program Files\Multipass\bin", "User")
```

When it works, `multipass version` prints two lines: the client and `multipassd` (the background service). Both must show a version.

## 4.2 Check the virtual machine backend

Find your Windows edition:

```powershell
(Get-ComputerInfo).WindowsProductName
```

- **Pro / Enterprise / Education:** Multipass uses Hyper-V. If launching fails, enable Hyper-V from an **Administrator** PowerShell and reboot:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```

- **Home:** Hyper-V is unavailable. Install VirtualBox and switch Multipass to it:

```powershell
winget install Oracle.VirtualBox
multipass set local.driver=virtualbox
```

# 5. Create the three virtual machines

**Run in: Windows PowerShell**

```powershell
multipass launch 24.04 --name master  --cpus 2 --memory 2G --disk 20G
multipass launch 24.04 --name worker1 --cpus 2 --memory 2G --disk 20G
multipass launch 24.04 --name worker2 --cpus 2 --memory 2G --disk 20G
multipass list
```

What the options mean: `24.04` is the Ubuntu version, `--cpus 2` gives two CPU cores, `--memory 2G` gives 2 GB of RAM (the minimum kubeadm accepts for a control plane), `--disk 20G` sets the disk size.

The first launch downloads the Ubuntu image, so it takes a few minutes. `multipass list` then shows each VM's IP address. Example output (your IPs will be different):

```
Name        State     IPv4              Image
master      Running   172.25.246.7      Ubuntu 24.04 LTS
worker1     Running   172.25.249.246    Ubuntu 24.04 LTS
worker2     Running   172.25.244.139    Ubuntu 24.04 LTS
```

> **Write down your master's IP address.** Everywhere this guide says `<MASTER_IP>`, use that value. In the worked example it was `172.25.246.7`.

Useful Multipass commands:

| Command | Purpose |
|---|---|
| `multipass shell master` | Open a terminal inside the master VM (type `exit` to leave) |
| `multipass exec master -- <command>` | Run one command inside a VM without opening a shell |
| `multipass transfer file vm:/path` | Copy a file from Windows into a VM |
| `multipass stop --all` / `multipass start --all` | Shut down / resume all VMs |
| `multipass list` | Show VM states and IPs |

## 5.1 Which window am I typing in?

Most beginner mistakes come from running a command in the wrong place. There are three places:

| Prompt you see | Where you are | What to run here |
|---|---|---|
| `PS C:\Users\you>` | Windows PowerShell | `multipass ...` commands, and `multipass exec master -- kubectl ...` |
| `you@name:~$` (a long hostname) | WSL Ubuntu | Your older WSL clusters and tools |
| `ubuntu@master:~$` | Inside the master VM (after `multipass shell master`) | Plain `kubectl ...` with no prefix |

> **Warning:** do not type plain `kubectl` in Windows PowerShell for this cluster. Windows has its own kubectl pointed at a different, stopped cluster, and you get a long `connectex: No connection could be made` error. In PowerShell always write `multipass exec master -- kubectl ...`. Every command in Sections 8 to 15 already includes this prefix.

# 6. Prepare all three machines

This covers steps 1-3 of the diagram. To avoid typing them three times, put everything in one script and run it on every VM.

## 6.1 Create the script

**Run in: Windows PowerShell.** Paste this whole block. It creates a file called `common.sh` in your current folder.

```powershell
@'
#!/bin/bash
set -e

# Step 1: prepare the machine
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# Step 2: install containerd
sudo apt-get update
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Step 3: install kubeadm, kubelet, kubectl
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
echo "DONE: common setup finished"
'@ | Out-File -Encoding ascii common.sh
```

## 6.2 What each part does

| Part | Why it is needed |
|---|---|
| `swapoff -a` and the `fstab` edit | The kubelet refuses to run while swap is on. The edit keeps it off after reboot |
| `overlay` and `br_netfilter` modules | Kernel features that container storage and pod networking need |
| `sysctl` settings | Let the kernel pass bridged traffic through iptables and forward packets between pods |
| `SystemdCgroup = true` | Makes containerd and the kubelet use the same cgroup driver. Forgetting this causes flaky control-plane pods later |
| `apt-mark hold` | Stops accidental upgrades, because Kubernetes components must be upgraded deliberately |
| `v1.35` in the repository URL | The Kubernetes minor version to install. Change it to install a different one |

## 6.3 Copy and run it on all three VMs

**Run in: Windows PowerShell**

```powershell
foreach ($vm in "master","worker1","worker2") {
  multipass transfer common.sh "${vm}:/home/ubuntu/common.sh"
  multipass exec $vm -- sed -i 's/\r$//' /home/ubuntu/common.sh
  multipass exec $vm -- bash /home/ubuntu/common.sh
}
```

PowerShell writes Windows line endings (`\r\n`), which break bash scripts. The `sed` line removes them first.

This takes several minutes per VM. Success looks like this, three times:

```
DONE: common setup finished
```

If a VM fails, read the last error lines, fix the cause (often a temporary network problem), and re-run the script on that VM only. The script is safe to run again.

# 7. Initialize the control plane (master)

This is step 4. Open a shell inside the master:

**Run in: Windows PowerShell**

```powershell
multipass shell master
```

You are now inside the master VM (the prompt shows `ubuntu@master`). Run:

**Run in: master VM**

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=<MASTER_IP>

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

What the options mean: `--pod-network-cidr=10.244.0.0/16` is the address range pods will use (it must match what flannel expects). `--apiserver-advertise-address` is the master's own IP, which workers will connect to. The last three lines copy the admin credentials to your user so `kubectl` works.

## 7.1 Be patient: it may look frozen

Initialization first downloads about seven container images. The output stops at these lines while it downloads:

```
[preflight] Pulling images required for setting up a Kubernetes cluster
[preflight] This might take a minute or two, depending on the speed of your internet connection
```

On a fast connection this takes a minute or two. On a slow one it can take **30 minutes or more**. In the worked example each image took 2-4 minutes. **Do not press Ctrl+C.**

To check progress, open a **second** PowerShell window:

```powershell
multipass exec master -- sudo ctr -n k8s.io images ls -q
multipass exec master -- sudo journalctl -u containerd -n 30 --no-pager
```

- Images appearing in the list means the download is working. Keep waiting.
- The journal shows `PullImage` lines and how long each took.
- A quick connectivity check: `multipass exec master -- curl -sI https://registry.k8s.io` should return `HTTP/2 307` or similar. That is a healthy redirect, not an error.

> **Note:** the tool `crictl` is not installed on these VMs, so `sudo crictl ...` gives "command not found". Use `ctr` instead, as shown above.

## 7.2 Speed up the workers while waiting

Your workers will need the same images. You can download them in advance, in a second window, so joining later is fast:

```powershell
multipass exec worker1 -- sudo kubeadm config images pull
multipass exec worker2 -- sudo kubeadm config images pull
```

This competes for bandwidth with the master's download. If the master seems to stall, do the workers afterwards instead.

## 7.3 The success message

When init finishes you will see:

```
Your Kubernetes control-plane has initialized successfully!
...
kubeadm join <MASTER_IP>:6443 --token <token> \
        --discovery-token-ca-cert-hash sha256:<hash>
```

**Copy the whole `kubeadm join` command somewhere safe.** You need it in Section 9. If you lose it, regenerate it later (see Section 9).

Check the node:

```bash
kubectl get nodes
```

The master shows `NotReady`. This is expected: no pod network exists yet.

If init fails, reset and try again:

```bash
sudo kubeadm reset -f
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=<MASTER_IP>
```

# 8. Install the pod network (flannel)

This is step 5. Nodes stay `NotReady` until a pod network plugin is installed. Flannel's default range matches the `10.244.0.0/16` you used in init.

You can type `exit` to leave the master shell and run these from PowerShell, or run them inside the master without the `multipass exec master --` prefix.

**Run in: Windows PowerShell**

```powershell
multipass exec master -- kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
multipass exec master -- kubectl get pods -A
```

Wait, repeating the second command, until every pod shows `Running`. With slow downloads this can take a few minutes. A healthy result looks like this:

```
NAMESPACE      NAME                             READY   STATUS    RESTARTS   AGE
kube-flannel   kube-flannel-ds-xxxxx            1/1     Running   0          5m
kube-system    coredns-xxxxxxxxxx-xxxxx         1/1     Running   0          2h
kube-system    coredns-xxxxxxxxxx-xxxxx         1/1     Running   0          2h
kube-system    etcd-master                      1/1     Running   0          2h
kube-system    kube-apiserver-master            1/1     Running   0          2h
kube-system    kube-controller-manager-master   1/1     Running   0          2h
kube-system    kube-proxy-xxxxx                 1/1     Running   0          2h
kube-system    kube-scheduler-master            1/1     Running   0          2h
```

Then confirm the master is ready:

```powershell
multipass exec master -- kubectl get nodes
```

It should now say `Ready`.

> **Calico instead of flannel?** It works too, but its default range is `192.168.0.0/16`, so the `--pod-network-cidr` in Section 7 would have to match.

# 9. Join the worker nodes

This is step 6. Use the exact `kubeadm join` command printed at the end of init, with `sudo` in front, once for each worker.

**Run in: Windows PowerShell**

```powershell
multipass exec worker1 -- sudo kubeadm join <MASTER_IP>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
multipass exec worker2 -- sudo kubeadm join <MASTER_IP>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

Replace `<MASTER_IP>`, `<token>` and `<hash>` with your own values. Each command should end with:

```
This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new secure connection details.
```

A warning about `bindAddress` in `KubeProxyConfiguration` is harmless. Ignore it.

## 9.1 If the token expired

Join tokens last 24 hours. If a join reports an invalid or expired token, create a new command on the master:

```powershell
multipass exec master -- sudo kubeadm token create --print-join-command
```

Run the command it prints on the worker, with `sudo` in front.

# 10. Verify the cluster

**Run in: Windows PowerShell**

```powershell
multipass exec master -- kubectl get nodes -o wide
```

Right after joining, a worker may show `NotReady` for several minutes. It has to download the flannel image and start its flannel and kube-proxy pods. In the worked example, one worker was `NotReady` for about ten minutes on a slow connection. This is normal. Watch progress with:

```powershell
multipass exec master -- kubectl get pods -A -o wide
```

Wait until each worker has a `kube-flannel-ds-...` and a `kube-proxy-...` pod in `Running`. The final result should look like this:

```
NAME      STATUS   ROLES           AGE    VERSION
master    Ready    control-plane   132m   v1.35.9
worker1   Ready    <none>          11m    v1.35.9
worker2   Ready    <none>          11m    v1.35.9
```

If a pod stays in `ContainerCreating` or `ImagePullBackOff` for more than ten minutes, inspect it:

```powershell
multipass exec master -- kubectl describe pod <pod-name> -n <namespace>
```

Look at the **Events** section at the bottom for the reason.

## Optional: label the workers

The empty ROLES column is only cosmetic, but labeling makes the output clearer:

```powershell
multipass exec master -- kubectl label node worker1 node-role.kubernetes.io/worker=
multipass exec master -- kubectl label node worker2 node-role.kubernetes.io/worker=
```

Your cluster is now complete: 1 master and 2 workers, built with kubeadm.

# 11. Run pods and test the cluster

Every command in this section and the next ones starts with `multipass exec master --`, so you can paste it into Windows PowerShell. See Section 5.1 if you are unsure which window to use.

## 11.1 Create a deployment with four pods

A Deployment keeps a set number of identical pods running. Create one with four copies of nginx (a web server):

**Run in: Windows PowerShell**

```powershell
multipass exec master -- kubectl create deployment nginx --image=nginx --replicas=4
multipass exec master -- kubectl get pods -o wide
```

The first pods may take a few minutes in `ContainerCreating`, because each worker has to download the nginx image. Then you should see something like this:

```
NAME                     READY   STATUS    RESTARTS   AGE   IP           NODE
nginx-56c45fd5ff-9wkj4   1/1     Running   0          25s   10.244.2.3   worker2
nginx-56c45fd5ff-d2tk6   1/1     Running   0          25s   10.244.1.2   worker1
nginx-56c45fd5ff-n8c6z   1/1     Running   0          25s   10.244.2.2   worker2
nginx-56c45fd5ff-x9n4f   1/1     Running   0          25s   10.244.1.3   worker1
```

What this tells you:

- Pods are spread across **worker1 and worker2**, and none run on master, because the master's control-plane taint keeps regular pods off it.
- Each worker hands out pod IPs from its own slice of the `10.244.0.0/16` range: worker1 uses `10.244.1.x`, worker2 uses `10.244.2.x`. That is flannel doing its job.
- A pod name has three parts: the Deployment name, a hash identifying the pod template version (`56c45fd5ff`), and a random suffix.

## 11.2 Test networking between nodes

This checks that pods on different nodes can talk, which is the most important thing flannel provides. Pick the IP of a pod on worker1 from your output (here `10.244.1.2`) and fetch its web page from a temporary pod:

```powershell
multipass exec master -- kubectl run test --image=busybox --restart=Never --rm -it -- wget -qO- 10.244.1.2
```

If you see the "Welcome to nginx!" HTML, pod networking works. The temporary pod is deleted automatically (`--rm`).

That test pod could have landed on worker1 itself, in which case the request never crossed nodes. To be certain, pin the test pod to **worker2** using a YAML file, as shown next.

## 11.3 Create pods from a YAML file (the reliable method)

Pods can be described in YAML. The `nodeName` field forces a pod onto a particular node. The reliable way to apply YAML from Windows is a three-step pattern: **write the file, copy it into the master, apply it.**

**Run in: Windows PowerShell**

```powershell
@'
apiVersion: v1
kind: Pod
metadata:
  name: test2
spec:
  nodeName: worker2
  restartPolicy: Never
  containers:
  - name: busybox
    image: busybox
    command: ["wget", "-qO-", "10.244.1.2"]
'@ | Out-File -Encoding ascii test2.yaml

multipass transfer test2.yaml master:/home/ubuntu/test2.yaml
multipass exec master -- kubectl apply -f /home/ubuntu/test2.yaml
```

Wait a few seconds, then check:

```powershell
multipass exec master -- kubectl get pod test2 -o wide
multipass exec master -- kubectl logs test2
```

`get pod` should show `Completed` and `NODE` = `worker2`. `logs` should print the nginx welcome page. Because the pod ran on worker2 and the target is on worker1, that proves cross-node networking. Clean up:

```powershell
multipass exec master -- kubectl delete pod test2
```

> **Note:** do not pipe YAML straight into `multipass exec master -- kubectl apply -f -`. In the worked example this hung and never created the pod. The write-copy-apply pattern above worked every time.

> **Note:** do not use `kubectl run ... --overrides='{"spec":{"nodeName":"worker2"}}'` in PowerShell. It fails with `error: Invalid JSON Patch`, because PowerShell strips the inner double quotes. Use a YAML file instead.

An alternative is to open a shell in the master and create the file there with a heredoc:

```powershell
multipass shell master
```

```bash
cat <<EOF > test2.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test2
spec:
  nodeName: worker2
  restartPolicy: Never
  containers:
  - name: busybox
    image: busybox
    command: ["wget", "-qO-", "10.244.1.2"]
EOF
kubectl apply -f test2.yaml
```

Type `exit` to leave the master afterwards.

## 11.4 Everyday pod commands

| Command | What it does |
|---|---|
| `kubectl get pods -o wide` | List pods with their IPs and nodes |
| `kubectl describe pod NAME` | Detailed info and an Events log (first stop when something fails) |
| `kubectl logs NAME` | Show a pod's output |
| `kubectl exec -it NAME -- sh` | Open a shell inside a pod |
| `kubectl delete pod NAME` | Delete a pod (a Deployment will recreate it) |
| `kubectl scale deployment nginx --replicas=6` | Change the number of copies |
| `kubectl get deployments` | List deployments |

Run these in PowerShell with `multipass exec master -- ` in front.

> **Note:** `NAME` and anything written in angle brackets, such as `<pod-name>`, is a placeholder. Replace the whole thing, brackets included, with a real name from `kubectl get pods`. If you leave the brackets, PowerShell fails with `The '<' operator is reserved for future use`.

# 12. Services and endpoints

A Pod's IP changes every time the pod is replaced. A **Service** gives a group of pods one stable address and spreads traffic across them. The Service finds its pods using a label selector.

## 12.1 Expose nginx with a NodePort Service

**Run in: Windows PowerShell**

```powershell
multipass exec master -- kubectl expose deployment nginx --port=80 --type=NodePort
multipass exec master -- kubectl get svc nginx
```

The output looks like this:

```
NAME    TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
nginx   NodePort   10.107.185.30   <none>        80:31260/TCP   3s
```

`80:31260` means the Service listens on port 80 inside the cluster, and port **31260** (the NodePort, in the 30000-32767 range) is opened on **every node**.

> **Warning:** if you type plain `kubectl expose ...` in Windows PowerShell, you get a long error such as `dial tcp 127.0.0.1:55170: connectex: No connection could be made`. Windows has its own kubectl, pointed at a different (stopped) cluster. Your kubeadm cluster lives inside the VMs, so always use `multipass exec master -- kubectl ...`.

## 12.2 Reach the Service from Windows

Your Windows laptop can reach the VM IPs directly. Use any node's IP with the NodePort:

```powershell
curl.exe -s http://<WORKER1_IP>:31260
curl.exe -s http://<WORKER2_IP>:31260
curl.exe -s http://<MASTER_IP>:31260
```

All three should return the nginx welcome page, **including the master**, even though no nginx pod runs there. kube-proxy on the master forwards the request across the network to a pod on a worker. A NodePort answers on every node.

> **Note:** in PowerShell, plain `curl` is an alias for `Invoke-WebRequest`. It shows a security prompt and prints a long object instead of the page. Use `curl.exe` for the real curl, or add `-UseBasicParsing` to the alias.

## 12.3 See which pods a Service uses

The Service keeps a list of healthy pod IPs, called endpoints.

```powershell
multipass exec master -- kubectl get endpoints nginx
multipass exec master -- kubectl describe svc nginx
```

Both truncate long lists with text like `+ 1 more...`. To see all of them:

```powershell
multipass exec master -- kubectl get endpoints nginx -o jsonpath='{.subsets[*].addresses[*].ip}'
multipass exec master -- kubectl get endpointslices -l kubernetes.io/service-name=nginx -o yaml
multipass exec master -- kubectl get pods -l app=nginx -o wide
```

The first prints the four pod IPs on one line. The second prints full YAML. The third lists the pods the Service matches (`app=nginx`), which should be exactly the same four IPs.

`kubectl get endpoints` prints a warning that `v1 Endpoints is deprecated`. It is harmless. EndpointSlices are the newer replacement, and Kubernetes keeps them up to date for you.

In the EndpointSlice YAML, each endpoint has `ready: true`, `serving: true` and `terminating: false`. A pod that is starting up or shutting down is not ready, so the Service skips it. That is how Kubernetes avoids sending requests to pods that cannot answer.

## 12.4 Reading `describe svc`

| Field | Meaning |
|---|---|
| `Selector: app=nginx` | The Service sends traffic to any pod with this label |
| `IP: 10.107.185.30` | The Service's stable cluster-internal address |
| `Port` / `TargetPort` | The Service listens on 80 and forwards to port 80 in the pod |
| `NodePort: 31260/TCP` | The port opened on every node |
| `External Traffic Policy: Cluster` | A request to any node may be forwarded to a pod on another node |
| `Session Affinity: None` | Each request may go to a different pod |

# 13. Self-healing, drain and rolling updates

## 13.1 Self-healing: delete a pod

Pick a pod name from `kubectl get pods` and delete it:

**Run in: Windows PowerShell**

```powershell
multipass exec master -- kubectl delete pod nginx-56c45fd5ff-d2tk6
multipass exec master -- kubectl get pods -l app=nginx -o wide
multipass exec master -- kubectl get endpoints nginx -o jsonpath='{.subsets[*].addresses[*].ip}'
```

Run the last two commands again after a few seconds. What you should see:

| Moment | What happens |
|---|---|
| Immediately | The deleted pod disappears. A replacement with a **new name** is created within about two seconds and shows `ContainerCreating` with no IP yet |
| The Service | The old IP is already removed from the endpoints. The new pod is not added until it is `Ready`, so no traffic reaches a pod that cannot answer |
| A few seconds later | The replacement is `Running` with a **new IP**, and the endpoints list has four addresses again |

The Service address and NodePort never changed. This is why applications talk to Services and not to pod IPs. The Deployment's job is to keep four replicas, notice a difference, and fix it.

## 13.2 Drain and uncordon a node

Draining empties a node for maintenance. This is the standard CKA pattern: **drain, do the work, uncordon.**

```powershell
multipass exec master -- kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data
multipass exec master -- kubectl get pods -o wide
multipass exec master -- kubectl get nodes
curl.exe -s http://<MASTER_IP>:31260
multipass exec master -- kubectl uncordon worker1
```

What happens:

| Output | Meaning |
|---|---|
| `node/worker1 cordoned` | worker1 is marked unschedulable, so no new pods land there |
| `Warning: ignoring DaemonSet-managed Pods` | Expected. The flannel and kube-proxy pods are DaemonSets and stay, because every node needs its own copy |
| `evicting pod ...` | The nginx pods on worker1 are removed |
| New pods on worker2 | The Deployment recreates them within seconds, on the only schedulable worker (the master is tainted) |
| `Ready,SchedulingDisabled` in `get nodes` | worker1 is healthy but closed to new pods |

While the pods restarted, the `curl` still worked, because the older pods on worker2 kept serving. That is why you run several replicas: a node going out of service does not cause downtime.

If you forget `--ignore-daemonsets`, drain refuses to proceed. That is a common exam mistake.

## 13.3 Rebalance with a rolling restart

`uncordon` re-opens worker1 but **does not move any pods back**. Kubernetes only places a pod when it is created, so all four pods stay on worker2. To rebalance, recreate them:

```powershell
multipass exec master -- kubectl rollout restart deployment nginx
multipass exec master -- kubectl rollout status deployment nginx
multipass exec master -- kubectl get pods -o wide
```

The pods are replaced gradually and the Service stays available. The default scheduler spreads best effort, so you usually get two and two, but not always. You can run the restart again if it comes out uneven.

While `rollout status` runs, you may briefly see five pods (for example three old and two new). By default a rolling update may create 25% extra pods (`maxSurge`) and allow 25% to be unavailable. Old pods are removed only after new ones are ready.

## 13.4 Rollouts, history and rollback

Every change to a Deployment's pod template creates a new **ReplicaSet**. A rollout moves replicas from the old one to the new one. The old ReplicaSet stays at zero pods so that you can roll back.

```powershell
multipass exec master -- kubectl get rs
```

```
NAME               DESIRED   CURRENT   READY   AGE
nginx-56c45fd5ff   0         0         0       14h
nginx-79f698694b   4         4         4       48s
```

The hash in a pod's name is a fingerprint of its template, which is how you tell which ReplicaSet owns it. View the history and roll back:

```powershell
multipass exec master -- kubectl rollout history deployment nginx
multipass exec master -- kubectl rollout undo deployment nginx
multipass exec master -- kubectl get rs
multipass exec master -- kubectl get pods -o wide
```

Run `get rs` immediately after the undo to catch both ReplicaSets mid-change, with one scaling up and the other down.

### Revision numbers can surprise you

Before the undo, the history was:

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

After the undo it became revisions 2 and 3. A rollback does not go back in time. Kubernetes makes the old template the newest revision, so revision 1 reappears as revision 3 and the old entry disappears. Revision numbers only ever go up.

Compare what each revision contains:

```powershell
multipass exec master -- kubectl rollout history deployment nginx --revision=2
multipass exec master -- kubectl rollout history deployment nginx --revision=3
```

The only difference between them is an annotation, `kubectl.kubernetes.io/restartedAt`, added by `rollout restart`. That one change was enough to create a new template hash, a new ReplicaSet and new pod names. You can roll back to a specific revision with `kubectl rollout undo deployment nginx --to-revision=2`.

To make the history readable, record a reason right after a change:

```powershell
multipass exec master -- kubectl annotate deployment nginx kubernetes.io/change-cause="baseline nginx, 4 replicas" --overwrite
```

### Optional: change the image, and a failed rollout

These steps were not run in the worked example, so treat them as extra practice. A realistic update changes the image:

```powershell
multipass exec master -- kubectl set image deployment/nginx nginx=nginx:1.27
multipass exec master -- kubectl rollout status deployment nginx
```

Then try an image tag that does not exist:

```powershell
multipass exec master -- kubectl set image deployment/nginx nginx=nginx:does-not-exist
multipass exec master -- kubectl get pods
multipass exec master -- kubectl rollout undo deployment nginx
```

The new pods should show `ErrImagePull` or `ImagePullBackOff`, while some old pods keep running and serving traffic. Use `kubectl describe pod` on a broken pod and read the Events. The undo restores a healthy state. This shows why rolling updates are safe.

# 14. Scheduling: selectors, taints and tolerations

These controls decide **where** a pod may run. Two ideas:

- **Selectors and affinity** are set on the **pod**, and they choose which nodes qualify.
- **Taints** are set on the **node**, and pods must opt in with a **toleration**.

All of them are checked only when a pod is being **scheduled**. Changing a taint later does not move pods that are already running (except with `NoExecute`, see 14.5).

## 14.1 Node selectors

Every node already has a label `kubernetes.io/hostname` equal to its name, so you can target a node without adding labels. You can also add your own:

**Run in: Windows PowerShell**

```powershell
multipass exec master -- kubectl label node worker1 disk=ssd
multipass exec master -- kubectl get nodes --show-labels
```

A pod uses `nodeSelector` to require a label:

```yaml
spec:
  nodeSelector:
    disk: ssd
```

## 14.2 Taint a node (`NoSchedule`)

```powershell
multipass exec master -- kubectl taint nodes worker1 key=value:NoSchedule
multipass exec master -- kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key
multipass exec master -- kubectl describe node worker1 | Select-String Taints
```

The taint format is `key=value:effect`. You should see three nodes in the list:

| Node | Taint | Effect on new pods |
|---|---|---|
| master | `node-role.kubernetes.io/control-plane` | Blocked. kubeadm adds this, which is why nginx never ran there |
| worker1 | `key` (yours) | Blocked unless the pod has a matching toleration |
| worker2 | none | Open to everything |

`NoSchedule` only blocks **new** pods. Your pods already on worker1 stay. To see the effect, restart the Deployment so the pods are created again:

```powershell
multipass exec master -- kubectl rollout restart deployment nginx
multipass exec master -- kubectl rollout status deployment nginx
multipass exec master -- kubectl get pods -o wide
```

All four new pods land on worker2, because the scheduler had to place them and worker1 repels pods without a toleration.

## 14.3 Tolerations and the `Pending` message

This experiment uses two pods that are identical except for a toleration. Both are forced onto worker1 with a `nodeSelector`, and worker1 is still tainted.

Create the first pod with **no toleration**, using the write-copy-apply pattern from Section 11.3:

```powershell
@'
apiVersion: v1
kind: Pod
metadata:
  name: no-toleration
spec:
  nodeSelector:
    kubernetes.io/hostname: worker1
  containers:
  - name: nginx
    image: nginx
'@ | Out-File -Encoding ascii no-toleration.yaml

multipass transfer no-toleration.yaml master:/home/ubuntu/no-toleration.yaml
multipass exec master -- kubectl apply -f /home/ubuntu/no-toleration.yaml
multipass exec master -- kubectl get pod no-toleration
multipass exec master -- kubectl describe pod no-toleration | Select-String -Pattern "FailedScheduling","untolerated"
```

The pod stays `Pending`. The scheduler explains why:

```
0/3 nodes are available: 1 node(s) didn't match Pod's node affinity/selector,
2 node(s) had untolerated taint(s).
```

The counts add up to your three nodes:

| Message | Nodes | Which ones |
|---|---|---|
| `didn't match Pod's node affinity/selector` | 1 | worker2, because the selector demands worker1 |
| `had untolerated taint(s)` | 2 | master (control-plane taint) and worker1 (your taint) |

The text `Preemption is not helpful` means the scheduler checked whether evicting other pods would help and decided it would not. When a pod is stuck in `Pending`, read this message first. It tells you whether the cause is resources, taints, selectors or affinity.

Now create the second pod **with** a toleration:

```powershell
@'
apiVersion: v1
kind: Pod
metadata:
  name: with-toleration
spec:
  nodeSelector:
    kubernetes.io/hostname: worker1
  tolerations:
  - key: "key"
    operator: "Equal"
    value: "value"
    effect: "NoSchedule"
  containers:
  - name: nginx
    image: nginx
'@ | Out-File -Encoding ascii with-toleration.yaml

multipass transfer with-toleration.yaml master:/home/ubuntu/with-toleration.yaml
multipass exec master -- kubectl apply -f /home/ubuntu/with-toleration.yaml
multipass exec master -- kubectl get pod with-toleration -o wide
```

It runs on worker1. The two controls do different jobs: the selector says "I must go to worker1", and the toleration says "I am allowed past worker1's taint". A toleration alone only permits a node, it never attracts a pod to it.

Now remove the taint while `no-toleration` is still `Pending`:

```powershell
multipass exec master -- kubectl taint nodes worker1 key=value:NoSchedule-
multipass exec master -- kubectl get pod no-toleration -o wide
```

Within a few seconds the pod goes from `Pending` to `ContainerCreating` to `Running` on worker1, without being recreated. The scheduler keeps retrying `Pending` pods until a node qualifies.

## 14.4 Clean up

```powershell
multipass exec master -- kubectl delete pod no-toleration with-toleration
multipass exec master -- kubectl rollout restart deployment nginx
multipass exec master -- kubectl rollout status deployment nginx
multipass exec master -- kubectl get pods -o wide
```

Removing a taint never moves pods back, so the restart is what rebalances them across both workers.

## 14.5 The `NoExecute` effect

`NoExecute` also **evicts** pods that are already running and do not tolerate the taint.

```powershell
multipass exec master -- kubectl taint nodes worker1 key=value:NoExecute
multipass exec master -- kubectl get pods -o wide
multipass exec master -- kubectl taint nodes worker1 key=value:NoExecute-
```

Run `get pods` a couple of times, a few seconds apart. What happens depends on who owns the pod:

| Pod type | Result |
|---|---|
| Pods owned by a Deployment | Evicted from worker1, and the Deployment immediately creates replacements on worker2. The pods briefly show `Completed` first |
| Standalone pods (created from YAML, no controller) | Evicted and **never recreated**. They disappear |

In the worked example, the standalone `with-toleration` pod was also evicted, even though it had a toleration. A toleration is specific to an **effect**. A toleration for `NoSchedule` does not protect a pod from `NoExecute`. To survive both, a pod needs a toleration with no `effect` (matches all effects), or one toleration per effect.

The last command removes the taint. It needs the exact same `key=value:effect` followed by a minus sign. After removing it, run `rollout restart` again to rebalance.

# 15. Node failure behavior

## 15.1 Default tolerations

You never wrote them, but Kubernetes adds two tolerations to every pod automatically. See them on a real pod (use a real pod name from `kubectl get pods`):

**Run in: Windows PowerShell**

```powershell
multipass exec master -- kubectl describe pod nginx-6ff888b778-4hhr8 | Select-String -Pattern "Tolerations" -Context 0,3
```

```
Tolerations:  node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
              node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
```

When a node stops responding, the control plane taints it with `unreachable` or `not-ready`. Pods tolerate that taint for **300 seconds**, then are evicted. If a Deployment owns them, replacements start on healthy nodes. That is how a Deployment survives a dead node, but only after about five minutes by default.

You can shorten the grace period per pod in the pod template:

```yaml
spec:
  tolerations:
  - key: "node.kubernetes.io/unreachable"
    operator: "Exists"
    effect: "NoExecute"
    tolerationSeconds: 30
```

Faster failover suits stateless web apps, but may cause unnecessary restarts on a flaky network.

## 15.2 Optional: simulate a node failure

This was run in the worked example. Allow about ten minutes. Be aware that a restarted VM may come back with a different IP (see Section 17).

```powershell
multipass stop worker1
multipass exec master -- kubectl get nodes -w
```

Within roughly 40 seconds worker1 should become `NotReady`, and the control plane adds `node.kubernetes.io/unreachable` taints (effects `NoSchedule` and `NoExecute`) by itself. After about five minutes the Deployment creates replacement pods on worker2. The old pods on worker1 stay in `Terminating`, because the node is down and cannot confirm they stopped. Check:

```powershell
multipass exec master -- kubectl get pods -o wide
multipass exec master -- kubectl describe node worker1 | Select-String Taints
```

Press Ctrl+C to stop watching, then restart the VM and check its IP:

```powershell
multipass start worker1
multipass list
multipass exec master -- kubectl get nodes -o wide
```

In the worked example worker1 came back with a **different IP** (`172.25.255.71` instead of `172.25.249.246`). It still rejoined by itself: the kubelet re-registered the new address, the node became `Ready`, and the `INTERNAL-IP` column updated. The master's IP did not change, and that is the one that matters (see Section 17).

When the node is back, the taints are removed automatically and the `Terminating` pods are cleaned up. The replacement pods stay on worker2 until you recreate them with `kubectl rollout restart deployment nginx`.

# 16. Use kubectl from WSL (optional)

This section was not run in the worked example. Right now you run everything through `multipass exec master`. To use plain `kubectl` from WSL against this cluster, copy the kubeconfig out of the master.

**Run in: Windows PowerShell**

```powershell
multipass exec master -- sudo cat /etc/kubernetes/admin.conf > $HOME\kubeadm-vms.conf
```

Then in WSL, for a one-off use without changing your main config:

**Run in: WSL Ubuntu**

```bash
KUBECONFIG=/mnt/c/Users/<you>/kubeadm-vms.conf kubectl get nodes
```

If you want to merge it into `~/.kube/config` permanently, first rename the cluster, user and context in the copy. The default names `kubernetes` and `kubernetes-admin` would clash with any older kubeadm cluster already in your config.

> **Security:** this file contains admin credentials. Do not paste it into chats or commit it to Git.

# 17. Daily operations: stop, start, clean up

## Shut down and resume

```powershell
multipass stop --all
multipass start --all
multipass list
```

After starting, **always check `multipass list`** and compare the IPs with the ones you used. Hyper-V may give a VM a new address after it is stopped and started.

- **If the master's IP changes, the cluster breaks.** The kubelets and your kubeconfig point at the master's address, and the API server certificate was created for it. You would have to rebuild the cluster or reconfigure it.
- **If a worker's IP changes, it usually does not matter.** The kubelet re-registers the new address and the node returns to `Ready` by itself, as happened in Section 15.2. If pod networking misbehaves afterwards, delete that node's flannel pod and let the DaemonSet recreate it.

Prefer `multipass stop --all` over rebooting Windows when you can, and check `multipass list` after every restart.

## Remove the practice workloads

```powershell
multipass exec master -- kubectl delete deployment nginx
multipass exec master -- kubectl delete svc nginx
```

## Delete everything

```powershell
multipass delete --all
multipass purge
```

This removes all VMs permanently. Because the whole build is scripted, you can recreate the cluster from Sections 5 to 9 whenever you want to practice again. Rebuilding from scratch is itself good practice.

# 18. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `multipass` is not recognized | PATH not refreshed | Open a new PowerShell window, or use the alias / PATH fix in Section 4.1 |
| `launch` fails about the hypervisor | Hyper-V not enabled, or Windows Home | Enable Hyper-V (Pro) or switch to VirtualBox (Home), Section 4.2 |
| Script fails with strange `\r` errors | Windows line endings | Run the `sed -i 's/\r$//'` line from Section 6.3 |
| `kubeadm init` seems stuck at preflight | Slow image downloads | Wait, and check `ctr -n k8s.io images ls -q`. Do not press Ctrl+C |
| `sudo: crictl: command not found` | crictl is not installed | Use `sudo ctr -n k8s.io images ls` |
| Master `NotReady` after init | No pod network yet | Install flannel (Section 8) |
| Worker `NotReady` after join | Still pulling flannel and kube-proxy images | Wait up to ten minutes and watch `kubectl get pods -A -o wide` |
| Pod in `ImagePullBackOff` | Slow or failed download | Wait, then `kubectl describe pod` and read Events |
| Pod in `CrashLoopBackOff` | The container keeps failing | `kubectl logs <pod>` and `kubectl describe pod <pod>` |
| Join says token invalid or expired | Tokens last 24 hours | `kubeadm token create --print-join-command` on the master |
| `error: Invalid JSON Patch` in PowerShell | PowerShell strips double quotes | Use a YAML file or escape the quotes (Section 11.3) |
| `dial tcp 127.0.0.1:...: connectex` when running kubectl | Plain kubectl in Windows PowerShell uses a different cluster | Use `multipass exec master -- kubectl ...` (Section 5.1) |
| Piping YAML into `multipass exec ... kubectl apply -f -` hangs | stdin handling on Windows | Write the file, `multipass transfer` it, apply the copy (Section 11.3) |
| `The '<' operator is reserved for future use` | You left `<placeholder>` brackets in a command | Replace the whole placeholder with a real name (Section 11.4) |
| `curl` shows a security prompt and a long object | PowerShell aliases `curl` to `Invoke-WebRequest` | Use `curl.exe` (Section 12.2) |
| Pods all on one node after `uncordon` | Kubernetes never moves running pods | `kubectl rollout restart deployment nginx` (Section 13.3) |
| Pod stuck in `Pending` | Resources, taints, selector or affinity | `kubectl describe pod NAME` and read the `FailedScheduling` event (Section 14.3) |
| Pod evicted and never came back | Standalone pod hit a `NoExecute` taint | Only controller-owned pods are recreated. Use a Deployment (Section 14.5) |
| Cluster broken after restarting Windows | The master's IP changed | Compare `multipass list` with the master IP used at init. A worker IP change is usually harmless (Section 17) |
| `kubeadm init` failed halfway | Partial setup | `sudo kubeadm reset -f`, then run init again |

When asking for help, include the exact command you ran and the full error text, plus the output of `kubectl get nodes -o wide` and `kubectl get pods -A`.

# 19. Security notes

- A kubeconfig file (`~/.kube/config` or `admin.conf`) contains **client certificates and private keys**. Anyone with it can control the cluster. Never paste a whole kubeconfig into a chat, forum or Git repository. To view a config safely, use `kubectl config view`, which hides the secret data by default.
- Join tokens and the discovery hash let a machine join your cluster. They expire after 24 hours, but treat them as secrets while valid.
- This practice cluster is local to your laptop, so the practical risk is low. Build good habits anyway, because the same mistakes are serious on real clusters.

# 20. Command cheat sheet

## Windows PowerShell (Multipass)

| Command | Purpose |
|---|---|
| `multipass launch 24.04 --name <n> --cpus 2 --memory 2G --disk 20G` | Create a VM |
| `multipass list` | Show VMs and IPs |
| `multipass shell <n>` | Open a shell in a VM |
| `multipass exec <n> -- <cmd>` | Run one command in a VM |
| `multipass stop --all` / `start --all` | Stop / start all VMs |
| `multipass delete --all` then `multipass purge` | Remove all VMs |
| `curl.exe -s http://<node-ip>:<nodeport>` | Test a Service from Windows (not plain `curl`) |
| `multipass transfer file.yaml master:/home/ubuntu/file.yaml` | Copy a YAML file into the master |

## Cluster setup (kubeadm)

| Command | Purpose |
|---|---|
| `kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=<IP>` | Create the control plane |
| `kubeadm token create --print-join-command` | Get a fresh join command |
| `kubeadm join <IP>:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h>` | Join a worker |
| `kubeadm config images pull` | Pre-download the images |
| `kubeadm reset -f` | Undo kubeadm on a node |

## kubectl

| Command | Purpose |
|---|---|
| `kubectl get nodes -o wide` | List nodes |
| `kubectl get pods -A -o wide` | List all pods in all namespaces |
| `kubectl describe <type> <name>` | Detailed info and events |
| `kubectl logs <pod>` | Pod output |
| `kubectl create deployment <n> --image=<img> --replicas=<k>` | Create a deployment |
| `kubectl scale deployment <n> --replicas=<k>` | Change replicas |
| `kubectl expose deployment <n> --port=80 --type=NodePort` | Create a service |
| `kubectl drain <node> --ignore-daemonsets` / `uncordon <node>` | Empty / re-enable a node |
| `kubectl taint nodes <node> key=value:NoSchedule` | Add a taint (add `-` at the end to remove) |
| `kubectl label node <node> key=value` | Label a node |
| `kubectl config get-contexts` / `use-context <name>` | List / switch clusters |
| `kubectl apply -f <file>` / `delete -f <file>` | Create / remove from YAML |
| `kubectl rollout restart deployment <n>` | Recreate pods gradually (also rebalances) |
| `kubectl rollout status deployment <n>` | Watch a rollout |
| `kubectl rollout history deployment <n>` | List revisions (`--revision=N` shows one) |
| `kubectl rollout undo deployment <n>` | Roll back (`--to-revision=N` for a specific one) |
| `kubectl set image deployment/<n> <container>=<image>` | Change the image |
| `kubectl get rs` | List ReplicaSets |
| `kubectl get endpoints <svc>` / `get endpointslices` | See the pods behind a Service |
| `kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key` | Show taints on all nodes |
| `kubectl taint nodes <node> key=value:NoExecute` | Taint that also evicts running pods |

You now know how to inspect clusters, build one from scratch with kubeadm, run and debug workloads, and tear it all down. Rebuild it a few times without looking at this guide and the six kubeadm steps will become second nature.

# 21. What to practice next

This guide covered building a cluster, Deployments, Services, rolling updates, drain and uncordon, selectors, taints and tolerations. Good next topics, in rough order of value for CKA:

| Topic | What to try |
|---|---|
| etcd backup and restore | `etcdctl snapshot save` and `snapshot restore` on the master |
| `kubeadm upgrade` | `kubeadm upgrade plan` and `apply`, one node at a time with drain and uncordon |
| Node affinity | `requiredDuringSchedulingIgnoredDuringExecution`, the flexible form of `nodeSelector` |
| Resource requests and limits | Ask for more CPU or memory than a 2 GB VM has and read the `Pending` message |
| Topology spread constraints | Force an even spread of pods across nodes |
| Troubleshooting a broken kubelet | `systemctl status kubelet` and `journalctl -u kubelet` on a worker |

Rebuild the whole cluster a few times without looking at this guide. The six kubeadm steps will become second nature.
