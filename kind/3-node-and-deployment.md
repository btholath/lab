Here's the three-node version — one control-plane, two workers:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: btlabs-k8s
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

Save as `kind-config.yaml` (overwrite the two-node version if you already created it).

```bash
kind delete cluster --name btlabs-k8s
kind create cluster --config kind-config.yaml
```

**Expected output:**
```
Creating cluster "btlabs-k8s" ...
 ✓ Ensuring node image (kindest/node:v1.32.0) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-btlabs-k8s"
```

Three boxes (`📦 📦 📦`) this time.

```bash
kubectl get nodes
```

**Expected output:**
```
NAME                       STATUS   ROLES           AGE   VERSION
btlabs-k8s-control-plane   Ready    control-plane   30s   v1.32.0
btlabs-k8s-worker          Ready    <none>          20s   v1.32.0
btlabs-k8s-worker2         Ready    <none>          20s   v1.32.0
```

```bash
docker ps -a | grep btlabs
```

**Expected:** three containers — `btlabs-k8s-control-plane`, `btlabs-k8s-worker`, `btlabs-k8s-worker2`.

## A genuinely good first exercise on a real multi-node cluster

Create a Deployment with several replicas and watch them actually spread:

```bash
kubectl create deployment spread-test --image=nginx --replicas=6
kubectl get pods -o wide
```

**Expected:** 6 pods, split across `btlabs-k8s-worker` and `btlabs-k8s-worker2` — **none on the control-plane**, because of that `NoSchedule` taint from the last message. This is the first time in this whole series `-o wide`'s `NODE` column has actually varied.

Clean up when done:
```bash
kubectl delete deployment spread-test
```

Run the recreate and paste `kubectl get nodes` — once confirmed, this is a solid moment to also circle back to the still-open git cleanup from earlier (the `Zone.Identifier` files and the uncommitted Lab 9-11 backlog), since none of the Kind cluster work touches that. 