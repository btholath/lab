bijut@b:~/repos/lab/k8s$ kind get clusters
kind
bijut@b:~/repos/lab/k8s$ kind delete cluster --name kind
kind create cluster --name btlabs-k8s
Deleting cluster "kind" ...
Deleted nodes: ["kind-control-plane"]
Creating cluster "btlabs-k8s" ...
 ✓ Ensuring node image (kindest/node:v1.32.0) 🖼 
 ✓ Preparing nodes 📦  
 ✓ Writing configuration 📜 
 ✓ Starting control-plane 🕹️ 
 ✓ Installing CNI 🔌 
 ✓ Installing StorageClass 💾 
Set kubectl context to "kind-btlabs-k8s"
You can now use your cluster with:

kubectl cluster-info --context kind-btlabs-k8s

Have a question, bug, or feature request? Let us know! https://kind.sigs.k8s.io/#community 🙂

bijut@b:~/repos/lab/k8s$ kind get clusters
btlabs-k8s
bijut@b:~/repos/lab/k8s$ 

kubectl config use-context kubernetes-admin@kubernetes

kubectl config use-context kind-btlabs-k8s

bijut@b:~/repos/lab/k8s$ kubectl config use-context kind-btlabs-k8s
Switched to context "kind-btlabs-k8s".
bijut@b:~/repos/lab/k8s$ ls -l ~/.kube/
total 20
drwxr-x--- 4 bijut bijut  4096 Mar 21  2025 cache
-rw------- 1 bijut bijut 11182 Oct  1 14:45 config
-rw------- 1 bijut bijut   106 Mar 24  2025 config.aws


bijut@b:~/repos/lab/k8s$ cat ~/.kube/config
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: <REDACTED>
    server: https://127.0.0.1:44269
  name: kind-btlabs-k8s
- cluster:
    certificate-authority-data: <REDACTED>
    server: https://192.168.155.98:6443
  name: kubernetes
contexts:
- context:
    cluster: kind-btlabs-k8s
    user: kind-btlabs-k8s
  name: kind-btlabs-k8s
- context:
    cluster: kubernetes
    namespace: mealie
    user: kubernetes-admin
  name: kubernetes-admin@kubernetes
current-context: kind-btlabs-k8s
kind: Config
users:
- name: kind-btlabs-k8s
  user:
    client-certificate-data: <REDACTED>
    client-key-data: <REDACTED>
- name: kubernetes-admin
  user:
    client-certificate-data: <REDACTED>
    client-key-data: <REDACTED>
bijut@b:~/repos/lab/k8s$ 

bijut@b:~/repos/lab/k8s$ kubectl get nodes
NAME                       STATUS   ROLES           AGE     VERSION
btlabs-k8s-control-plane   Ready    control-plane   7m28s   v1.32.0
bijut@b:~/repos/lab/k8s$ 

-----------------------------------------------------
filename: kind-config.yaml

kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: btlabs-k8s
nodes:
  - role: control-plane
  - role: worker

bijut@b:~/repos/lab/kind$ kind delete cluster --name btlabs-k8s
kind create cluster --config kind-config.yaml
Deleting cluster "btlabs-k8s" ...
Deleted nodes: ["btlabs-k8s-control-plane"]
Creating cluster "btlabs-k8s" ...
 ✓ Ensuring node image (kindest/node:v1.32.0) 🖼 
 ✓ Preparing nodes 📦 📦  
 ✓ Writing configuration 📜 
 ✓ Starting control-plane 🕹️ 
 ✓ Installing CNI 🔌 
 ✓ Installing StorageClass 💾 
 ✓ Joining worker nodes 🚜 
Set kubectl context to "kind-btlabs-k8s"
You can now use your cluster with:

kubectl cluster-info --context kind-btlabs-k8s

Not sure what to do next? 😅  Check out https://kind.sigs.k8s.io/docs/user/quick-start/
bijut@b:~/repos/lab/kind$ kubectl cluster-info --context kind-btlabs-k8s
Kubernetes control plane is running at https://127.0.0.1:46495
CoreDNS is running at https://127.0.0.1:46495/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.
bijut@b:~/repos/lab/kind$ docker ps -a | grep btlabs
746677860e9d   kindest/node:v1.32.0                               "/usr/local/bin/entr…"   56 seconds ago   Up 46 seconds         127.0.0.1:46495->6443/tcp   btlabs-k8s-control-plane
95689e539b41   kindest/node:v1.32.0                               "/usr/local/bin/entr…"   56 seconds ago   Up 46 seconds                                     btlabs-k8s-worker
bijut@b:~/repos/lab/kind$ kubectl get nodes
NAME                       STATUS   ROLES           AGE   VERSION
btlabs-k8s-control-plane   Ready    control-plane   36s   v1.32.0
btlabs-k8s-worker          Ready    <none>          24s   v1.32.0
bijut@b:~/repos/lab/kind$ kubectl describe node btlabs-k8s-control-plane | grep Taints
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
bijut@b:~/repos/lab/kind$ 

--------------------------------------------------

