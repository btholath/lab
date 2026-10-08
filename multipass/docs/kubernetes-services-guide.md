# Kubernetes Services: ClusterIP, NodePort and LoadBalancer

## A practical guide, built on a real three-node kubeadm cluster

Pods come and go, and every time a pod is replaced it gets a new IP address. A **Service** solves that: it gives a group of pods one stable address and spreads traffic across them. This guide explains how a Service works, covers each Service type, and shows the console output from a real cluster.

**Contents**

1. What a Service is, and why you need one
2. How a Service works
3. Ports explained
4. The four Service types at a glance
5. ClusterIP
6. NodePort
7. LoadBalancer
8. Headless Services and ExternalName
9. Traffic policy and session affinity
10. Inspecting a Service
11. Hands-on lab
12. YAML reference
13. Choosing a type
14. Troubleshooting
15. Command cheat sheet
16. Glossary
17. What was run, and what was not

---

# 1. What a Service is, and why you need one

A Deployment runs several identical pods, and each pod has its own IP. Those IPs are temporary. In the real cluster used for this guide, deleting one nginx pod produced a replacement with a **new name and a new IP**:

```text
Before:  nginx-56c45fd5ff-d2tk6   10.244.1.2
After:   nginx-56c45fd5ff-nx5ff   10.244.1.4
```

A client that had remembered `10.244.1.2` would now be talking to nothing. A Service fixes this with three ideas:

| Idea | What it gives you |
|---|---|
| **A stable address** | One IP (and one DNS name) that does not change while the Service exists |
| **A label selector** | The Service finds its pods by label, not by IP, so replacements join automatically |
| **Load balancing** | Requests are spread across all the healthy pods behind it |

> **Rule:** applications talk to Services, never to pod IPs.

---

# 2. How a Service works

## The pieces

```text
   client
     |
     v
 Service  (stable IP + DNS name, selector app=nginx)
     |
     |   the control plane keeps a list of ready pod IPs:
     v
 EndpointSlice  [10.244.1.3, 10.244.1.4, 10.244.2.2, 10.244.2.3]
     |
     |   kube-proxy on every node turns that list into network rules
     v
 one of the pods
```

| Piece | Role |
|---|---|
| **Service** | The object you create. It holds the selector, the ports and the type |
| **Label selector** | `app: nginx` means "every pod with the label `app=nginx`" |
| **EndpointSlice** | The live list of pod IPs that match the selector **and are ready**. Kubernetes maintains it for you |
| **kube-proxy** | Runs on every node (a DaemonSet). It programs the node's network rules, so a request to the Service address is forwarded to one of the endpoint IPs |
| **CoreDNS** | Gives the Service a DNS name |

kube-proxy has several modes (iptables, IPVS, nftables), depending on configuration. This guide does not assume which one a cluster uses. To check yours:

```bash
kubectl -n kube-system get configmap kube-proxy -o yaml | grep -i "mode:"
```

An empty `mode:` normally means the default for that release.

## Service addresses come from their own range

Pods and Services use **different address ranges**:

| Range | Used for | In the worked example |
|---|---|---|
| Pod CIDR | Pod IPs | `10.244.0.0/16` (set with `kubeadm init --pod-network-cidr`) |
| Service CIDR | Service ClusterIPs | kubeadm's default is `10.96.0.0/12`. The worked example's ClusterIP `10.107.185.30` fits inside it |

To check your cluster's Service range:

```bash
sudo grep service-cluster-ip-range /etc/kubernetes/manifests/kube-apiserver.yaml
```

## DNS names

CoreDNS gives every Service a name:

```text
<service>.<namespace>.svc.cluster.local
```

Inside the same namespace, the short name `nginx` is enough. From another namespace, use `nginx.default` or the full name.

## Only ready pods receive traffic

A pod that is starting up or shutting down is **not ready**, so it is left out of the EndpointSlice and receives no traffic. In the worked example, right after a pod was deleted, the Service listed three endpoints while the replacement was still `ContainerCreating`, then four once it was `Running`:

```text
10.244.1.3 10.244.2.2 10.244.2.3              (replacement still starting)
10.244.1.3 10.244.1.4 10.244.2.2 10.244.2.3   (replacement ready)
```

---

# 3. Ports explained

A Service has several port numbers, and mixing them up is the commonest beginner mistake.

| Field | Meaning | Where it applies |
|---|---|---|
| `port` | The port the **Service** listens on | The Service's ClusterIP |
| `targetPort` | The port **inside the pod** that receives the traffic. Defaults to `port` | The pod |
| `nodePort` | A port opened on **every node** (NodePort and LoadBalancer types) | The node's own IP |
| `protocol` | `TCP` (default), `UDP` or `SCTP` | Both |

```yaml
ports:
- port: 80          # clients call the Service on 80
  targetPort: 8080  # the container actually listens on 8080
  nodePort: 30080   # (NodePort only) reachable on every node at 30080
```

## Reading the `PORT(S)` column

```text
NAME    TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
nginx   NodePort   10.107.185.30   <none>        80:31260/TCP   3s
```

`80:31260/TCP` reads as **`port`:`nodePort`/protocol**. This Service listens on 80 inside the cluster, and port 31260 is open on every node.

The default NodePort range is **30000 to 32767**. The API server picks a free one if you do not choose.

## Named ports

A pod can name its port, and the Service can refer to the name. Then you can change the pod's number later without touching the Service:

```yaml
# in the pod
ports:
- name: web
  containerPort: 8080
# in the Service
ports:
- port: 80
  targetPort: web
```

---

# 4. The four Service types at a glance

| Type | Reachable from | Typical use |
|---|---|---|
| **ClusterIP** (default) | Inside the cluster only | Pod-to-pod traffic, internal APIs, databases |
| **NodePort** | Outside, at `<any node IP>:<nodePort>` | Quick access to an app, labs, or as a building block |
| **LoadBalancer** | Outside, through an external load balancer's IP | Production access in a cloud, or with an add-on on bare metal |
| **ExternalName** | Inside the cluster. A DNS alias to an outside name | Pointing an in-cluster name at an external service |

## The types build on each other

```text
   LoadBalancer  =  NodePort  +  an external load balancer
   NodePort      =  ClusterIP +  a port opened on every node
   ClusterIP     =  the base: a stable virtual IP inside the cluster
```

Every NodePort Service **also has a ClusterIP**, and every LoadBalancer Service **also has a NodePort and a ClusterIP**. In the worked example, the NodePort Service was reachable both ways:

- inside the cluster at its ClusterIP `10.107.185.30:80`, and
- from outside at any node's IP on port `31260`.

---

# 5. ClusterIP

## What it is

The default type. The Service gets a **virtual IP** from the Service CIDR. That IP is not assigned to any network card. kube-proxy on each node simply forwards traffic sent to it. It is only reachable **from inside the cluster**: from pods, and from the cluster's own nodes.

## Create one

```bash
kubectl expose deployment nginx --name=nginx-clusterip --port=80 --target-port=80
kubectl get svc nginx-clusterip
```

The equivalent YAML:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-clusterip
spec:
  type: ClusterIP          # the default, so this line is optional
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
```

The expected output looks like this (the address will differ):

```text
NAME              TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
nginx-clusterip   ClusterIP   10.x.x.x       <none>        80/TCP    5s
```

`EXTERNAL-IP` is `<none>` because there is no outside address. There is no node port in `PORT(S)`: just `80/TCP`.

## Reach it

| From | Works? | How |
|---|---|---|
| A pod in the cluster | Yes | `http://nginx-clusterip` (same namespace) or `http://nginx-clusterip.default.svc.cluster.local` |
| A cluster node (SSH into the master) | Yes | `curl http://<clusterIP>` |
| Your laptop's browser or PowerShell | **No** | The ClusterIP is not routable outside the cluster |

## When to use it

The default for anything that other pods call: a backend API, a cache, a database. It keeps the workload private.

---

# 6. NodePort

## What it is

A NodePort Service opens the **same port on every node**, and forwards traffic that arrives there to the Service's pods. You reach it from outside at `<node IP>:<nodePort>`, using **any** node's address, even a node that runs none of the pods.

## Create one (real run)

**Run in: Windows PowerShell** (the `multipass exec master --` prefix matters, see Section 14)

```powershell
multipass exec master -- kubectl expose deployment nginx --port=80 --type=NodePort
multipass exec master -- kubectl get svc nginx
```

```text
service/nginx exposed
NAME    TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
nginx   NodePort   10.107.185.30   <none>        80:31260/TCP   3s
```

### Explanation

| Output | Meaning |
|---|---|
| `TYPE NodePort` | The Service type |
| `CLUSTER-IP 10.107.185.30` | Its internal virtual IP (every NodePort Service has one) |
| `EXTERNAL-IP <none>` | Normal for a NodePort. There is no separate external address |
| `80:31260/TCP` | The Service port is 80, and **31260** is open on every node |

## Reach it from outside (real run)

The Windows laptop can reach the VMs' addresses directly. Using the **master**, the node that runs **no** nginx pods:

```powershell
curl.exe -s http://172.25.246.7:31260
```

```text
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
[...]
```

The same request to worker2 (`172.25.244.139` at the time) returned the page too, and worker1 (`172.25.249.246` at the time) answered with HTTP status 200. Three different node addresses, one port, one answer.

### Explanation

The master has **no nginx pods**, yet it answered. The request arrived on the master's port 31260, kube-proxy's rules there forwarded it across the network to a pod on a worker, and the reply came back the same way. That is the central property of a NodePort: **every node accepts the traffic, wherever the pods are.**

> **PowerShell tip:** in Windows PowerShell, plain `curl` is an alias for `Invoke-WebRequest`. It prints a security prompt and a long object instead of the page. Use `curl.exe` for the real curl.

## Inspect it (real run)

```powershell
multipass exec master -- kubectl describe svc nginx
```

```text
Name:                     nginx
Namespace:                default
Labels:                   app=nginx
Annotations:              <none>
Selector:                 app=nginx
Type:                     NodePort
IP Family Policy:         SingleStack
IP Families:              IPv4
IP:                       10.107.185.30
IPs:                      10.107.185.30
Port:                     <unset>  80/TCP
TargetPort:               80/TCP
NodePort:                 <unset>  31260/TCP
Endpoints:                10.244.2.2:80,10.244.2.3:80,10.244.1.2:80 + 1 more...
Session Affinity:         None
External Traffic Policy:  Cluster
Internal Traffic Policy:  Cluster
Events:                   <none>
```

| Field | Meaning |
|---|---|
| `Selector: app=nginx` | The Service sends traffic to every ready pod with this label. `kubectl expose` copied it from the Deployment |
| `Labels: app=nginx` | The Service's own labels (not the same thing as the selector) |
| `IP: 10.107.185.30` | The ClusterIP |
| `Port` / `TargetPort` | The Service listens on 80 and forwards to port 80 in the pod. The `<unset>` after `Port:` is the port's name, which this Service does not use |
| `NodePort: 31260/TCP` | The port opened on every node |
| `Endpoints: ... + 1 more...` | The pod IPs behind it. The listing is **truncated** (four pods, three shown). See Section 10 for all of them |
| `Session Affinity: None` | Each request may go to a different pod |
| `External Traffic Policy: Cluster` | A request to any node may be forwarded to a pod on another node. See Section 9 |

## Choose the node port yourself

Instead of letting the API server pick, you can fix it (it must be inside the range):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-nodeport
spec:
  type: NodePort
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
```

## Limits of NodePort

- The high port range (30000 to 32767) is awkward for users. Nobody wants a URL ending in `:31260`.
- You must know a node's IP, and nodes can change.
- Every node opens the port, so a firewall must allow it.
- No health-based failover between nodes by itself. If you give clients one node IP and that node dies, they fail.

A NodePort is excellent for labs, demos and as the base layer of a LoadBalancer. For real traffic you usually put a load balancer or an Ingress in front of it.

---

# 7. LoadBalancer

## What it is

A LoadBalancer Service asks the **environment** to create an external load balancer, and publishes its address in `EXTERNAL-IP`. The traffic path is:

```text
 client --> external load balancer (EXTERNAL-IP) --> NodePort on a node --> Service --> pod
```

Kubernetes itself does not create the load balancer. A component called a **cloud controller** (on AWS, Azure or Google Cloud) or an **add-on** does it. On a cluster without one, the request just waits.

## What it looks like with no load balancer provider (real output)

On the earlier single-node kubeadm cluster, a Helm chart created a LoadBalancer Service. This is what its listing showed (the header line is added here for readability):

```text
NAMESPACE   NAME       TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
helm-demo   my-nginx   LoadBalancer   10.108.158.12   <pending>     80:31731/TCP,443:32433/TCP   6d3h
```

### Explanation

| Output | Meaning |
|---|---|
| `TYPE LoadBalancer` | The type that requests an external load balancer |
| `EXTERNAL-IP <pending>` | **Nothing is providing a load balancer.** It had waited six days. This is the normal state on a bare-metal or laptop cluster |
| `80:31731/TCP,443:32433/TCP` | The node ports were allocated anyway. A LoadBalancer includes a NodePort |
| `CLUSTER-IP 10.108.158.12` | It also has a ClusterIP |

So a LoadBalancer Service still has a node port, here `<node IP>:31731`, and the LoadBalancer part is an addition on top. (On that particular cluster the pod was not ready, so the port had nothing to serve and it was never tested. The allocation itself shows how the types are layered.)

## Where the address comes from

| Environment | What provides the IP |
|---|---|
| A public cloud (AWS, Azure, Google Cloud) | The cloud provider's controller creates a real load balancer |
| **kind** | A helper, `cloud-provider-kind`, assigns addresses. In the earlier kind setup, a container named `kind-cloud-provider` was running next to the nodes, which appears to be that helper |
| **Bare metal, kubeadm on VMs** (this cluster) | Nothing, unless you install an add-on. **MetalLB** is the common choice. It hands out addresses from a pool you give it |
| **minikube** | `minikube tunnel` |

## Create one

```bash
kubectl expose deployment nginx --name=nginx-lb --port=80 --type=LoadBalancer
kubectl get svc nginx-lb
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-lb
spec:
  type: LoadBalancer
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
```

On a cluster like the worked example's, expect `EXTERNAL-IP` to stay `<pending>`, as shown above. A node port is still allocated.

## Why this matters

If you see `<pending>` forever, nothing is wrong with your Service. **Your cluster has no load-balancer provider.** The fixes are to install one (MetalLB), use a NodePort, or put an Ingress controller in front.

---

# 8. Headless Services and ExternalName

## Headless Service

Setting `clusterIP: None` creates a Service **with no virtual IP**. Instead of load balancing, DNS returns the IPs of all the ready pods directly. It is used when clients need to find each pod individually, for example with StatefulSets such as databases.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-headless
spec:
  clusterIP: None
  selector:
    app: nginx
  ports:
  - port: 80
```

```text
NAME             TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
nginx-headless   ClusterIP   None         <none>        80/TCP    4s
```

## ExternalName

An ExternalName Service has **no selector and no pods**. It is a DNS alias: a lookup of the Service's name returns a CNAME to an outside host name.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: external-db
spec:
  type: ExternalName
  externalName: db.example.com
```

Pods can then call `external-db`, and the cluster DNS answers with `db.example.com`. If the outside host changes later, you edit one Service instead of every application.

---

# 9. Traffic policy and session affinity

## `externalTrafficPolicy`

This setting matters for NodePort and LoadBalancer Services. The real Service above showed `External Traffic Policy: Cluster`.

| Value | Behavior | Trade-off |
|---|---|---|
| `Cluster` (default) | Any node accepts the traffic and may forward it to a pod on **another** node | Even spread, and every node works. The client's source IP is not preserved on the forwarded hop |
| `Local` | A node only sends traffic to pods **on that same node** | Preserves the client's source IP and avoids an extra hop. A node with no local pod cannot serve the request |

With `Local`, the master in the worked example (which runs no nginx pods) would not answer on its NodePort the way it did above.

## `internalTrafficPolicy`

The same idea for traffic from inside the cluster. The real Service showed `Internal Traffic Policy: Cluster`, meaning any ready pod in the cluster may be chosen.

## Session affinity

`Session Affinity: None` (the default) means each request can go to a different pod. Setting `sessionAffinity: ClientIP` sends requests from one client IP to the same pod for a while:

```yaml
spec:
  sessionAffinity: ClientIP
```

---

# 10. Inspecting a Service

## The commands

```bash
kubectl get svc
kubectl get svc nginx -o wide
kubectl describe svc nginx
kubectl get endpoints nginx
kubectl get endpointslices -l kubernetes.io/service-name=nginx
kubectl get pods -l app=nginx -o wide
```

## All the endpoints (real run)

Both `describe svc` and `get endpoints` **truncate** long lists with `+ 1 more...`. To see everything:

```powershell
multipass exec master -- kubectl get endpoints nginx -o jsonpath='{.subsets[*].addresses[*].ip}'
```

```text
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
10.244.1.2 10.244.1.3 10.244.2.2 10.244.2.3
```

The `Endpoints is deprecated` warning is harmless. **EndpointSlices** are the newer replacement, and Kubernetes keeps them up to date for you.

## The EndpointSlice (real run, shortened)

```powershell
multipass exec master -- kubectl get endpointslices -l kubernetes.io/service-name=nginx -o yaml
```

```yaml
- addressType: IPv4
  endpoints:
  - addresses:
    - 10.244.2.2
    conditions:
      ready: true
      serving: true
      terminating: false
    nodeName: worker2
    targetRef:
      kind: Pod
      name: nginx-56c45fd5ff-n8c6z
  [... three more endpoints, one per pod ...]
  kind: EndpointSlice
  metadata:
    labels:
      kubernetes.io/service-name: nginx
    name: nginx-gcc9p
    ownerReferences:
    - kind: Service
      name: nginx
  ports:
  - port: 80
    protocol: TCP
```

| Field | Meaning |
|---|---|
| `ready: true`, `serving: true`, `terminating: false` | The pod passes its readiness check and can receive traffic. A starting or stopping pod shows different values and is skipped |
| `nodeName` | Which node the pod runs on |
| `targetRef` | The exact pod behind this endpoint |
| `ownerReferences` pointing at the Service | The Service owns the slice. Delete the Service and the slice goes with it |
| `labels: kubernetes.io/service-name: nginx` | The label you filter on with `-l` |

The four IPs match the four pods the Service selects:

```text
10.244.1.2  worker1    10.244.1.3  worker1    10.244.2.2  worker2    10.244.2.3  worker2
```

You get the same list from `kubectl get pods -l app=nginx -o wide`. That is the whole mechanism: **the selector picks the pods, and the EndpointSlice lists them.**

---

# 11. Hands-on lab

Commands marked **(run)** were executed on the worked-example cluster. Those marked **(not run)** were not, so treat their expected output as an expectation, not a record.

**Where to run these:** the commands below use the `multipass exec master -- kubectl ...` form, for **Windows PowerShell**. Inside the master VM shell (`multipass shell master`) drop the prefix and just type `kubectl ...`.

## Lab 1: NodePort (run)

```powershell
multipass exec master -- kubectl create deployment nginx --image=nginx --replicas=4
multipass exec master -- kubectl expose deployment nginx --port=80 --type=NodePort
multipass exec master -- kubectl get svc nginx
curl.exe -s http://<NODE_IP>:<NODEPORT>
```

Replace `<NODE_IP>` and `<NODEPORT>` with a node's address and the port from `PORT(S)`, brackets included. Expect the nginx welcome page from **any** node.

## Lab 2: watch the endpoints follow the pods (run)

```powershell
multipass exec master -- kubectl get endpoints nginx -o jsonpath='{.subsets[*].addresses[*].ip}'
multipass exec master -- kubectl delete pod <ONE-NGINX-POD-NAME>
multipass exec master -- kubectl get pods -l app=nginx -o wide
multipass exec master -- kubectl get endpoints nginx -o jsonpath='{.subsets[*].addresses[*].ip}'
```

Right after the delete, a replacement appears with a new name and a new IP. The endpoint list briefly holds one fewer address while the replacement is `ContainerCreating`, then returns to four, with the new IP in place of the old one. The **Service address and NodePort never change.**

## Lab 3: ClusterIP, reached from inside a pod (not run)

```powershell
multipass exec master -- kubectl expose deployment nginx --name=nginx-clusterip --port=80 --target-port=80
multipass exec master -- kubectl get svc nginx-clusterip
multipass exec master -- kubectl run tmp --image=busybox --restart=Never --rm -it -- wget -qO- http://nginx-clusterip
```

Expect the nginx welcome page. The pod reached the Service **by name**, which is CoreDNS at work. The `kubectl run ... --rm -it` pattern (a temporary busybox pod) is the same one used earlier for the pod-to-pod network test.

To see the DNS answer itself, use an older busybox image, since newer ones have a flaky `nslookup`:

```powershell
multipass exec master -- kubectl run dns --image=busybox:1.28 --restart=Never --rm -it -- nslookup nginx-clusterip
```

Expect the Service's ClusterIP in the answer.

## Lab 4: prove a ClusterIP is not reachable from your laptop (not run)

```powershell
multipass exec master -- kubectl get svc nginx-clusterip
curl.exe -s --max-time 5 http://<CLUSTERIP>
```

Replace `<CLUSTERIP>` with the address from the first command. The `curl.exe` from Windows should time out, because the address is not routable outside the cluster. From inside the master VM it should work, because the master is a cluster node with kube-proxy's rules:

```bash
curl -s --max-time 5 http://<CLUSTERIP>
```

## Lab 5: LoadBalancer (not run on this cluster)

```powershell
multipass exec master -- kubectl expose deployment nginx --name=nginx-lb --port=80 --type=LoadBalancer
multipass exec master -- kubectl get svc nginx-lb
```

Expect `EXTERNAL-IP <pending>`, as in the real output in Section 7, and a node port in `PORT(S)`. The Service is still reachable on that node port.

## Lab 6: `externalTrafficPolicy: Local` (not run)

The JSON in a patch command breaks in PowerShell (the quotes get stripped), so run this **inside the master VM shell**:

```bash
kubectl patch svc nginx --type merge -p '{"spec":{"externalTrafficPolicy":"Local"}}'
kubectl describe svc nginx | grep "External Traffic Policy"
```

Then from Windows, request the NodePort on the **master**, which has no nginx pods, and on a worker that does. Expect the master to fail (no local pod) and the worker to answer. Set it back with `"Cluster"` afterwards.

## Lab 7: peek at kube-proxy's rules (not run)

Inside the master VM shell, if the cluster uses the iptables mode:

```bash
sudo iptables -t nat -L KUBE-SERVICES -n | head -20
```

You should see rules for your Services, with comments such as `default/nginx`. This is the machinery behind "a request to the Service address goes to a pod". The exact chain names depend on the kube-proxy mode and version.

## Clean up

```powershell
multipass exec master -- kubectl delete svc nginx nginx-clusterip nginx-lb nginx-headless --ignore-not-found
multipass exec master -- kubectl delete deployment nginx
```

---

# 12. YAML reference

## ClusterIP

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
```

## NodePort

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: NodePort
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080
```

## LoadBalancer

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
```

## Headless

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  clusterIP: None
  selector:
    app: my-app
  ports:
  - port: 80
```

## ExternalName

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: ExternalName
  externalName: db.example.com
```

## Two ports and a policy

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: NodePort
  selector:
    app: web
  externalTrafficPolicy: Local
  sessionAffinity: ClientIP
  ports:
  - name: http
    port: 80
    targetPort: 8080
  - name: https
    port: 443
    targetPort: 8443
```

With more than one port, **each port needs a `name`**.

## Applying a manifest from Windows

Piping YAML into `multipass exec ... kubectl apply -f -` hung in testing. The reliable pattern is to write the file, copy it into the master, then apply it:

```powershell
@'
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: NodePort
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
'@ | Out-File -Encoding ascii my-service.yaml

multipass transfer my-service.yaml master:/home/ubuntu/my-service.yaml
multipass exec master -- kubectl apply -f /home/ubuntu/my-service.yaml
```

---

# 13. Choosing a type

| You want to... | Use |
|---|---|
| Let pods talk to each other privately | **ClusterIP** |
| Reach an app from your laptop in a lab | **NodePort** |
| Give users a stable external IP, in a cloud | **LoadBalancer** |
| Give users a stable external IP on VMs or bare metal | **LoadBalancer** with MetalLB, or an Ingress controller in front of a NodePort |
| Reach each pod individually (databases, StatefulSets) | **Headless** |
| Point an in-cluster name at an outside host | **ExternalName** |
| Route many HTTP sites or paths through one address | An **Ingress** or **Gateway** (see below) |

## Services and Ingress

A Service works at the network level (TCP and UDP ports). An **Ingress** (or the newer **Gateway API**) works at the HTTP level: it routes by host name and path, and terminates TLS. It sits **in front of** ClusterIP Services. Typically one LoadBalancer or NodePort exposes the Ingress controller, and the Ingress then fans out to many ClusterIP Services.

---

# 14. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `kubectl get svc` in Windows PowerShell: `connection refused ... 127.0.0.1` | Plain `kubectl` in PowerShell talks to a different cluster | Use `multipass exec master -- kubectl ...`, or work inside the master VM shell |
| `multipass exec -- kubectl ...`: `instance "kubectl" does not exist` | The VM name is missing | `multipass exec master -- kubectl ...` |
| `curl` in PowerShell shows a security prompt and a long object | `curl` is an alias for `Invoke-WebRequest` | Use `curl.exe` |
| The Service has **no endpoints** (`ENDPOINTS <none>`) | The selector matches no pods, or the pods are not ready | Compare `kubectl get svc X -o yaml` (the selector) with `kubectl get pods --show-labels`. Check readiness with `kubectl describe pod` |
| Connection works on some requests and not others | One pod is unhealthy or not ready | `kubectl get endpoints X`, then look at the pods that are missing |
| Connection refused through the Service, but the pod answers directly | Wrong `targetPort` | The `targetPort` must be the port the container listens on |
| NodePort unreachable from outside | A firewall, the wrong node IP, or the wrong port | Check `PORT(S)` for the node port, and try another node's IP |
| NodePort answers on a worker but not on the master | `externalTrafficPolicy: Local` | Check `kubectl describe svc X`. Switch to `Cluster`, or use a node that has a pod |
| `EXTERNAL-IP <pending>` for a LoadBalancer | No load-balancer provider in the cluster | Install MetalLB, use a NodePort, or put an Ingress in front. This is expected on bare metal |
| Pods cannot resolve a Service name | CoreDNS is not running, or the name is wrong | `kubectl -n kube-system get pods -l k8s-app=kube-dns`, and check the name and namespace |
| `ClusterIP` works from the master but not from your laptop | Normal: ClusterIPs are not routable outside the cluster | Use a NodePort or LoadBalancer for outside access |
| `describe svc` shows `+ 1 more...` | Display truncation | Use the `jsonpath` command in Section 10 |

## The three-question check

When a Service misbehaves, ask these in order:

1. **Does the Service select any pods?** `kubectl get endpoints <svc>`. An empty list is a selector or readiness problem.
2. **Do the pods answer directly?** Send a request to a pod IP from a temporary pod. If that works, the pods are fine and the problem is the Service.
3. **Is the `targetPort` right?** It must match the port the container actually listens on.

---

# 15. Command cheat sheet

| Task | Command |
|---|---|
| Expose a Deployment as ClusterIP | `kubectl expose deployment NAME --port=80` |
| Expose as NodePort | `kubectl expose deployment NAME --port=80 --type=NodePort` |
| Expose as LoadBalancer | `kubectl expose deployment NAME --port=80 --type=LoadBalancer` |
| List Services | `kubectl get svc` |
| Details and events | `kubectl describe svc NAME` |
| The Service as YAML | `kubectl get svc NAME -o yaml` |
| Endpoints | `kubectl get endpoints NAME` |
| EndpointSlices | `kubectl get endpointslices -l kubernetes.io/service-name=NAME` |
| Pods a selector matches | `kubectl get pods -l app=NAME -o wide` |
| Edit a Service | `kubectl edit svc NAME` |
| Delete a Service | `kubectl delete svc NAME` |
| Check the Service CIDR | `sudo grep service-cluster-ip-range /etc/kubernetes/manifests/kube-apiserver.yaml` |
| Test from inside the cluster | `kubectl run tmp --image=busybox --restart=Never --rm -it -- wget -qO- http://NAME` |

---

# 16. Glossary

| Term | Meaning |
|---|---|
| **Service** | A stable address and load balancer for a group of pods |
| **ClusterIP** | The virtual IP a Service gets inside the cluster. Also the name of the default Service type |
| **NodePort** | A port opened on every node. Also a Service type |
| **LoadBalancer** | A Service type that requests an external load balancer |
| **Selector** | The labels a Service uses to find its pods |
| **Endpoint / EndpointSlice** | The list of ready pod IPs behind a Service |
| **kube-proxy** | The per-node component that turns Services into network rules |
| **CoreDNS** | The cluster's DNS server |
| **Service CIDR / Pod CIDR** | The address ranges for Service IPs and pod IPs. They are separate |
| **Headless Service** | A Service with `clusterIP: None`. DNS returns the pod IPs directly |
| **ExternalName** | A Service that is only a DNS alias to an outside host name |
| **Ingress / Gateway** | HTTP-level routing in front of Services |
| **MetalLB** | A popular load-balancer add-on for bare-metal and VM clusters |
| **Readiness** | Whether a pod is ready to receive traffic. Only ready pods are endpoints |

---

# 17. What was run, and what was not

**Run on the real cluster** (the console output above is from these):

- Creating a NodePort Service with `kubectl expose`, and listing and describing it
- Reaching the NodePort from Windows on the master and on both workers
- Listing the endpoints, the `jsonpath` form and the EndpointSlice
- Deleting a pod and watching the endpoints follow
- A LoadBalancer Service with `EXTERNAL-IP <pending>` (seen on the earlier single-node cluster, created by a Helm chart)

**Not run** (marked in the labs):

- A ClusterIP Service, including DNS resolution by name and the check that it is unreachable from Windows
- Creating a LoadBalancer Service on the three-node cluster
- `externalTrafficPolicy: Local` and session affinity
- Headless and ExternalName Services
- Inspecting kube-proxy's rules, and checking its mode
- MetalLB, and any Ingress or Gateway

Statements about those, and about what each cloud provider does, are general knowledge and not results from this cluster. Check the official Kubernetes documentation on Services for the version you run.
