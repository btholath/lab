# Kubernetes RBAC: Who May Do What

## Roles, bindings, service accounts, certificate-based users, groups, anonymous access and escalation prevention, tested on a real cluster

**RBAC** (role-based access control) decides what an authenticated user may do. This guide reads the roles a kubeadm cluster starts with, builds a service account and a certificate-based user, and tests what each can and cannot do. It was run on a real kubeadm cluster (1 control plane, 2 workers, Kubernetes v1.36.5). The console output after each lab is copied from the run. Where a prediction was wrong, the guide says so, and explanations marked as inferences are best guesses, not results.

**Contents**

1. How access control works
2. Reading what already exists
3. Aggregated roles, and a side effect of metrics-server
4. A service account, a Role and a RoleBinding
5. Subresources, and a trap in `can-i`
6. A certificate-based user
7. 401 or 403
8. Groups: the credential is the claim
9. Anonymous access
10. Escalation prevention and `bind`
11. The certificate's life: deletion, expiry, revocation
12. Practical tips for running these labs
13. Troubleshooting
14. Command cheat sheet
15. Glossary
16. What was run, and what was not

---

# 1. How access control works

Every request to the API server passes through two separate checks:

| Step | Question | Fails with |
|---|---|---|
| **Authentication** | Who are you? | **401 Unauthorized** |
| **Authorization** (RBAC) | Are you allowed to do this? | **403 Forbidden** |

Kubernetes has **no user objects**. A "user" is a name and a set of groups, carried by a credential such as a client certificate (`CN` is the name, each `O` is a group). RBAC then grants permissions to those names and groups.

## The four RBAC objects

| Object | Scope | Meaning |
|---|---|---|
| `Role` | One namespace | A set of permissions: verbs on resources |
| `ClusterRole` | Whole cluster | The same, but cluster-wide, or reusable across namespaces |
| `RoleBinding` | One namespace | Gives a Role (or a ClusterRole) to users, groups or service accounts **in that namespace** |
| `ClusterRoleBinding` | Whole cluster | Gives a ClusterRole to subjects **everywhere** |

RBAC is **additive**: there are no deny rules, and anything not granted is refused. A subject's permissions are the union of every binding that names it.

A rule combines **verbs** (`get`, `list`, `watch`, `create`, `update`, `patch`, `delete` and a few special ones), **resources** (`pods`, `secrets`, and subresources such as `pods/log`) and the **API group** they belong to.

---

# 2. Reading what already exists

All of this only reads. Run it in the master shell:

```bash
kubectl get clusterrolebinding kubeadm:cluster-admins -o yaml
kubectl get clusterrole cluster-admin -o yaml
kubectl auth can-i --list | head -8
kubectl get clusterroles | grep -E "^(cluster-admin|admin|edit|view) "
kubectl describe clusterrole view
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -noout -subject -dates
```

The last command prints only the certificate's subject and dates. Never print the matching `client-key-data`.

### Observed on the real cluster

```text
kind: ClusterRoleBinding
metadata:
  creationTimestamp: "2026-10-05T21:42:49Z"
  name: kubeadm:cluster-admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: kubeadm:cluster-admins

kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  creationTimestamp: "2026-10-05T21:42:50Z"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: cluster-admin
rules:
- apiGroups: ['*']
  resources: ['*']
  verbs: ['*']
- nonResourceURLs: ['*']
  verbs: ['*']

Resources                                       Non-Resource URLs   Resource Names   Verbs
*.*                                             []                  []               [*]
                                                [*]                 []               [*]
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                [/api/*]            []               [get]

admin           2026-10-05T21:42:50Z
cluster-admin   2026-10-05T21:42:50Z
edit            2026-10-05T21:42:50Z
view            2026-10-05T21:42:50Z

subject=O = kubeadm:cluster-admins, CN = kubernetes-admin
notBefore=Oct  8 00:11:29 2026 GMT
notAfter=Oct  8 00:16:29 2027 GMT
```

| Item | Predicted | Observed |
|---|---|---|
| The binding | `cluster-admin`, bound to one `Group` | **Exactly that**: the group `kubeadm:cluster-admins` |
| `cluster-admin` | Every verb on every resource, plus non-resource URLs | **Two rules**, each with `'*'` |
| The first `can-i` rows | `*.*` with `[*]`, then `[/*]` | `*.*` `[*]`, but the second row is **`[*]`**: all non-resource URLs. My guess was too narrow |
| The four roles | Present, created on the build day | **All four, in the same second** |
| `view` | Read verbs only, and **no `secrets`** | **Correct**: only `get list watch`, and no `secrets` in the whole list |
| Your identity | `O = kubeadm:cluster-admins, CN = kubernetes-admin`, `notAfter` in October 2027 | **Exactly that** |

What the output teaches:

- **Your power comes from the group**, not the name. The certificate says `CN = kubernetes-admin` and `O = kubeadm:cluster-admins`, and the binding grants `cluster-admin` to the **group**. Any certificate the cluster signs with that organization is an admin.
- **`can-i --list` merges every binding that applies to you.** Below the `*.*` row come rows such as `selfsubjectreviews ... [create]` and `[/api/*] [get]`. They come from roles bound to the group `system:authenticated`, which every logged-in user belongs to.
- **The binding is one second older than the role it names** (`21:42:49` against `21:42:50`). A binding to a role that does not exist yet is allowed, and grants nothing until the role appears. That fits kubeadm creating the binding before the default roles were reconciled, but I am inferring the order.
- **`cluster-admin` carries `rbac.authorization.kubernetes.io/autoupdate: "true"`.** As I recall, that tells the API server to restore the default rules if someone edits them, at its next start. That was not tested.

There is a second admin identity in a kubeadm cluster, `super-admin.conf`, whose group `system:masters` bypasses RBAC altogether. I did not look at it.

---

# 3. Aggregated roles, and a side effect of metrics-server

The `view` role listed `nodes.metrics.k8s.io` and `pods.metrics.k8s.io`, which I do not think the stock role includes. The two checks below confirm where they came from:

```bash
kubectl get clusterrole view -o jsonpath='{.aggregationRule}{"\n"}'
kubectl get clusterrole system:aggregated-metrics-reader -o jsonpath='{.metadata.labels}{"\n"}{.rules}{"\n"}'
kubectl auth whoami
```

### Observed on the real cluster

```text
{"clusterRoleSelectors":[{"matchLabels":{"rbac.authorization.k8s.io/aggregate-to-view":"true"}}]}
{"k8s-app":"metrics-server","rbac.authorization.k8s.io/aggregate-to-admin":"true","rbac.authorization.k8s.io/aggregate-to-edit":"true","rbac.authorization.k8s.io/aggregate-to-view":"true"}
[{"apiGroups":["metrics.k8s.io"],"resources":["pods","nodes"],"verbs":["get","list","watch"]}]

ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubeadm:cluster-admins system:authenticated]
```

`view` is an **aggregated** role: its rules are collected from every ClusterRole labeled `aggregate-to-view: "true"`. The metrics-server manifest includes a ClusterRole, `system:aggregated-metrics-reader`, with the labels `aggregate-to-view`, `aggregate-to-edit` and `aggregate-to-admin`. So **installing metrics-server changed what `view`, `edit` and `admin` allow**, without anyone editing a binding. Add-ons use this to extend the defaults. Be aware of it when you reason about what a built-in role grants: the answer depends on what is installed.

`kubectl auth whoami` prints the name and groups the server sees. It also prints a credential identifier under `Extra`, which looks like a fingerprint of the certificate. It is not key material.

---

# 4. A service account, a Role and a RoleBinding

A **ServiceAccount** is an identity for a pod, and it is also the easiest subject to test with. `kubectl auth can-i` can **impersonate** a subject with `--as`, which the admin's rights allow:

```bash
kubectl create namespace rbac-demo
kubectl -n rbac-demo create serviceaccount reader
kubectl -n rbac-demo create role pod-reader --verb=get,list,watch --resource=pods
SA=system:serviceaccount:rbac-demo:reader
echo "before any binding: $(kubectl auth can-i list pods -n rbac-demo --as=$SA)"
kubectl -n rbac-demo create rolebinding reader-pods --role=pod-reader --serviceaccount=rbac-demo:reader
echo "after the binding:  $(kubectl auth can-i list pods -n rbac-demo --as=$SA)"
for what in "delete pods -n rbac-demo" "list secrets -n rbac-demo" "list services -n rbac-demo" "list pods -n default" "list pods --all-namespaces"; do echo "$what -> $(kubectl auth can-i $what --as=$SA)"; done
kubectl get pods -n rbac-demo --as=$SA
kubectl get pods -n default --as=$SA
```

### Observed on the real cluster

```text
before any binding: no
after the binding:  yes
delete pods -n rbac-demo -> no
list secrets -n rbac-demo -> no
list services -n rbac-demo -> no
list pods -n default -> no
list pods --all-namespaces -> no
No resources found in rbac-demo namespace.
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:rbac-demo:reader" cannot list resource "pods" in API group "" in the namespace "default"
```

| Check | Why |
|---|---|
| `no` before the binding | **A Role grants nothing until it is bound** |
| `yes` after | The RoleBinding connects the role to the subject |
| `delete`, `secrets`, `services` are `no` | A different verb, and different resources |
| `default` and `--all-namespaces` are `no` | **A RoleBinding is limited to its own namespace** |
| `No resources found` in `rbac-demo` | Allowed, and just empty |

The Forbidden message is a sentence with a fixed shape that tells you exactly which rule is missing:

```text
<resource> is forbidden: User "<who>" cannot <verb> resource "<type>" in API group "<group>" in the namespace "<ns>"
```

A delete says `pods "web" is forbidden`, naming the object, while a list says `pods is forbidden`. A delete targets one object, and a list targets the whole collection.

## A RoleBinding that points at a ClusterRole

```bash
kubectl -n rbac-demo create rolebinding reader-view --clusterrole=view --serviceaccount=rbac-demo:reader
for what in "list services -n rbac-demo" "list deployments.apps -n rbac-demo" "list secrets -n rbac-demo" "list services -n default" "list nodes"; do echo "$what -> $(kubectl auth can-i $what --as=$SA)"; done
kubectl -n rbac-demo get rolebindings
```

### Observed on the real cluster

```text
list services -n rbac-demo -> yes
list deployments.apps -n rbac-demo -> yes
list secrets -n rbac-demo -> no
list services -n default -> no
Warning: resource 'nodes' is not namespace scoped
list nodes -> no

NAME          ROLE               AGE
reader-pods   Role/pod-reader    43m
reader-view   ClusterRole/view   40s
```

A **RoleBinding to a ClusterRole** grants that role's permissions **only inside the binding's namespace**: `view` works in `rbac-demo`, not in `default`, and never reaches cluster-scoped resources such as nodes. This is the usual way to reuse one cluster-wide role across many namespaces. With both bindings in place, the account's permissions are the **union**: nothing is taken away.

---

# 5. Subresources, and a trap in `can-i`

`pods/log` is a **subresource**. A rule for `pods` does not cover it. With the `pod-reader` role alone, I expected `can-i get pods/log` to say `no`, and it said `yes`:

```text
get pods/log -n rbac-demo -> yes        <- my prediction was no
```

| With `view` | Without `view` (only `pod-reader`) |
|---|---|
| `pods/log=yes` `--subresource=log=yes` | `pods/log=yes` `pods/whatever=yes` `--subresource=log=no` `list pods=yes` |

In `kubectl auth can-i`, an argument of the form `TYPE/NAME` means a **type and an object name**, as in `get deployments/web`. So `pods/log` asked "may I `get` the pod *named* `log`?", and the `pods` rule allows any name, hence the `yes`, and the same `yes` for `pods/whatever`. That is my explanation, and the second column supports it. To ask about the log subresource itself, write:

```bash
kubectl auth can-i get pods --subresource=log -n rbac-demo --as=$SA
```

Without `view` that gives `no`, and with it `yes`, because `view` lists `pods/log`. The `can-i --list` output after the second binding showed the rows `pods/log`, `pods` and `pods.metrics.k8s.io` once each, since two roles granting the same verbs on `pods` merge into one row (I had predicted two).

---

# 6. A certificate-based user

A user is whatever name and groups a client certificate carries, signed by the cluster's CA. The cluster signs a **CertificateSigningRequest** (CSR) when an admin approves it.

> **Handle the key with care.** `jane.key` and the kubeconfig built from it hold a private key. Never paste them, show them with `cat`, or commit them. Keep them in a directory only you can enter, and delete them at the end.

## Key, request and signature

```bash
mkdir -p ~/rbac-lab && chmod 700 ~/rbac-lab && cd ~/rbac-lab
openssl genrsa -out jane.key 2048
chmod 600 jane.key
openssl req -new -key jane.key -out jane.csr -subj "/CN=jane/O=dev-team"
openssl req -in jane.csr -noout -subject
ls -l
```

Then submit and approve it:

```bash
cd ~/rbac-lab
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: jane
spec:
  request: $(base64 -w0 < jane.csr)
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 3600
  usages:
  - client auth
EOF
kubectl get csr jane
kubectl certificate approve jane
sleep 3
kubectl get csr jane
kubectl get csr jane -o jsonpath='{.status.certificate}' | base64 -d > jane.crt
openssl x509 -in jane.crt -noout -subject -issuer -dates
```

The CSR file holds only the public key and the subject, so it is safe to show. The base64 text is generated by the shell when the command runs.

### Observed on the real cluster

```text
subject=CN = jane, O = dev-team
-rw-rw-r-- 1 ubuntu ubuntu  911 Oct 12 15:41 jane.csr
-rw------- 1 ubuntu ubuntu 1704 Oct 12 15:41 jane.key

NAME   AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
jane   0s    kubernetes.io/kube-apiserver-client   kubernetes-admin   60m                 Pending
certificatesigningrequest.certificates.k8s.io/jane approved
jane   3s    kubernetes.io/kube-apiserver-client   kubernetes-admin   60m                 Approved,Issued

subject=O = dev-team, CN = jane
issuer=CN = kubernetes
notBefore=Oct 12 22:36:11 2026 GMT
notAfter=Oct 12 23:41:11 2026 GMT
```

| Item | Predicted | Observed |
|---|---|---|
| `jane.csr` mode | `-rw-r--r--` | **`-rw-rw-r--`**. The VM's default file mask is looser than I assumed. It is harmless here, since the directory is mode 700 |
| `jane.key` mode | `-rw-------` | **`-rw-------`** |
| The request | `Pending`, then `Approved,Issued` | **Both**, and `Issued` was already there 3 seconds later |

The cluster signs nothing on its own: the request stays `Pending` until someone with permission approves it.

## The 5-minute backdating

The lifetime came out at **65 minutes** though 60 were requested: `notBefore` is **5 minutes before the moment of signing**. Three certificates on this cluster show the same pattern:

| Certificate | `notBefore` | `notAfter` | Lifetime | Issued at (`notBefore` + 5 min) |
|---|---|---|---|---|
| The cluster CA | Oct 5 21:24:56 2026 | Oct 2 21:29:56 2036 | 3,650 days + 5 min | Oct 5 21:29:56 |
| The admin certificate | Oct 8 00:11:29 2026 | Oct 8 00:16:29 2027 | 365 days + 5 min | Oct 8 00:16:29 |
| `jane`'s | Oct 12 22:36:11 | Oct 12 23:41:11 | 60 min + 5 min | Oct 12 22:41:11 |

The signer backdates every certificate by 5 minutes. My reading is that this tolerates a node whose clock lags a little, which is not something I checked. It also gives a margin to measure the clock problems against: one VM in this cluster once lagged by about 9.7 minutes (see the workload controllers guide), which is more than the margin.

## Building her kubeconfig

```bash
cd ~/rbac-lab
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
openssl x509 -in ca.crt -noout -subject -dates
kubectl --kubeconfig=jane.kubeconfig config set-cluster kubernetes --server=$APISERVER --certificate-authority=ca.crt --embed-certs=true
kubectl --kubeconfig=jane.kubeconfig config set-credentials jane --client-certificate=jane.crt --client-key=jane.key --embed-certs=true
kubectl --kubeconfig=jane.kubeconfig config set-context jane --cluster=kubernetes --user=jane --namespace=rbac-demo
kubectl --kubeconfig=jane.kubeconfig config use-context jane
chmod 600 jane.kubeconfig
```

`ca.crt` is the cluster's **public** CA certificate, so it is safe to show.

```bash
KC=jane.kubeconfig
kubectl --kubeconfig=$KC auth whoami
kubectl --kubeconfig=$KC get pods
kubectl --kubeconfig=$KC auth can-i list pods
kubectl --kubeconfig=$KC auth can-i --list | head -10
```

### Observed on the real cluster

```text
api server: https://172.25.246.7:6443
subject=CN = kubernetes
notBefore=Oct  5 21:24:56 2026 GMT
notAfter=Oct  2 21:29:56 2036 GMT
Cluster "kubernetes" set.
User "jane" set.
Context "jane" created.
Switched to context "jane".
-rw------- 1 ubuntu ubuntu 5571 Oct 12 15:42 jane.kubeconfig

Username   jane
Groups     [dev-team system:authenticated]
Error from server (Forbidden): pods is forbidden: User "jane" cannot list resource "pods" in API group "" in the namespace "rbac-demo"
no
selfsubjectreviews.authentication.k8s.io        []   []   [create]
selfsubjectaccessreviews.authorization.k8s.io   []   []   [create]
selfsubjectrulesreviews.authorization.k8s.io    []   []   [create]
                                                [/api/*]   []   [get]
                                                [/api]     []   [get]
                                                [/apis/*]  []   [get]
                                                [/apis]    []   [get]
                                                [/healthz] []   [get]
```

`jane` is known (`whoami` works) and allowed nothing but the baseline every user gets. That is **authentication** succeeding and **authorization** saying no. The `[/healthz]` row appears twice, and I assume two default roles both grant it, without having checked which.

---

# 7. 401 or 403

The same request, sent three ways with `curl`, which shows the HTTP status that `kubectl` hides:

```bash
cd ~/rbac-lab
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
URL=$APISERVER/api/v1/namespaces/rbac-demo/pods
curl -s --cacert ca.crt -o /tmp/r1 -w "HTTP %{http_code}\n" $URL; grep -E '"message"' /tmp/r1
curl -s --cacert ca.crt -H "Authorization: Bearer not-a-real-token" -o /tmp/r2 -w "HTTP %{http_code}\n" $URL; grep -E '"message"' /tmp/r2
curl -s --cacert ca.crt --cert jane.crt --key jane.key -o /tmp/r3 -w "HTTP %{http_code}\n" $URL; grep -E '"message"' /tmp/r3
rm -f /tmp/r1 /tmp/r2 /tmp/r3
```

### Observed on the real cluster

| Request | Result | Message |
|---|---|---|
| No credentials at all | **HTTP 403** | `pods is forbidden: User "system:anonymous" cannot list resource "pods" ...` |
| An invalid bearer token | **HTTP 401** | `Unauthorized` |
| `jane`'s valid certificate | **HTTP 403** | `pods is forbidden: User "jane" cannot list resource "pods" ...` |

| Code | Meaning |
|---|---|
| **401** | The server cannot tell who you are: a credential was **present but wrong** |
| **403** | The server knows who you are, or treats you as the anonymous user, and your permissions do not allow the request |

A request with **no** credentials is treated as the user `system:anonymous`, then refused by RBAC, which gives 403. A credential that is present but invalid is **not** downgraded to anonymous: it fails outright with 401. The third row also proves that `jane`'s certificate works: the same request that got 401 with a bad token got 403 with hers.

---

# 8. Groups: the credential is the claim

A binding to the **group** `dev-team`, not to `jane`:

```bash
KC=jane.kubeconfig
echo "before: $(kubectl --kubeconfig=$KC auth can-i list pods)"
kubectl -n rbac-demo create rolebinding dev-team-pods --role=pod-reader --group=dev-team
kubectl -n rbac-demo run web --image=nginx
sleep 8
echo "after:  $(kubectl --kubeconfig=$KC auth can-i list pods)"
kubectl --kubeconfig=$KC get pods
kubectl --kubeconfig=$KC delete pod web
kubectl --kubeconfig=$KC get secrets
kubectl --kubeconfig=$KC get pods -n default
```

### Observed on the real cluster

```text
before: no
rolebinding.rbac.authorization.k8s.io/dev-team-pods created
after:  yes
NAME   READY   STATUS    RESTARTS   AGE
web    1/1     Running   0          8s
Error from server (Forbidden): pods "web" is forbidden: User "jane" cannot delete resource "pods" in API group "" in the namespace "rbac-demo"
Error from server (Forbidden): secrets is forbidden: User "jane" cannot list resource "secrets" in API group "" in the namespace "rbac-demo"
Error from server (Forbidden): pods is forbidden: User "jane" cannot list resource "pods" in API group "" in the namespace "default"
```

`jane` gained access within the 8 seconds, and **nothing on her side changed**: the same certificate, and the same kubeconfig. The binding names the group, her certificate carries `O=dev-team`, and the API server compares the two on every request.

## The group is only a claim

Impersonation shows that the name does not matter:

```bash
echo "as=jane only:                 $(kubectl auth can-i list pods -n rbac-demo --as=jane)"
echo "as=jane + group dev-team:     $(kubectl auth can-i list pods -n rbac-demo --as=jane --as-group=dev-team)"
echo "as=nobody + group dev-team:   $(kubectl auth can-i list pods -n rbac-demo --as=nobody --as-group=dev-team)"
echo "dev-team may delete pods:     $(kubectl auth can-i delete pods -n rbac-demo --as=nobody --as-group=dev-team)"
```

| Line | Observed |
|---|---|
| `as=jane only` | **`no`**: a bare name carries no groups |
| `as=jane + group dev-team` | **`yes`** |
| `as=nobody + group dev-team` | **`yes`**: the group alone is enough |
| `dev-team may delete pods` | **`no`** |

So **the group on the certificate is the credential.** Anyone who can get the cluster to sign a certificate with `O=dev-team` has the group's access, whatever name is on it. That is why approving a CertificateSigningRequest is a privileged act, and why the request's subject, including its organization, deserves a careful read before `kubectl certificate approve`.

## Removing the binding

```bash
kubectl -n rbac-demo delete rolebinding dev-team-pods
sleep 2
kubectl --kubeconfig=jane.kubeconfig get pods
kubectl --kubeconfig=jane.kubeconfig auth whoami | grep Username
```

### Observed on the real cluster

```text
Error from server (Forbidden): pods is forbidden: User "jane" cannot list resource "pods" in API group "" in the namespace "rbac-demo"
Username   jane
```

Her permissions changed within the 2-second wait, and her identity did not. Authentication and authorization are checked separately, on every request.

---

# 9. Anonymous access

```bash
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
curl -s --cacert ca.crt -o /dev/null -w "anonymous /version:    HTTP %{http_code}\n" $APISERVER/version
curl -s --cacert ca.crt -o /dev/null -w "anonymous /healthz:    HTTP %{http_code}\n" $APISERVER/healthz
curl -s --cacert ca.crt -o /dev/null -w "anonymous namespaces:  HTTP %{http_code}\n" $APISERVER/api/v1/namespaces
kubectl get clusterrolebinding system:public-info-viewer -o jsonpath='{.subjects}{"\n"}'
kubectl get clusterrole system:public-info-viewer -o jsonpath='{.rules}{"\n"}'
```

### Observed on the real cluster

```text
anonymous /version:    HTTP 200
anonymous /healthz:    HTTP 200
anonymous namespaces:  HTTP 403

[{"apiGroup":"rbac.authorization.k8s.io","kind":"Group","name":"system:authenticated"},{"apiGroup":"rbac.authorization.k8s.io","kind":"Group","name":"system:unauthenticated"}]
[{"nonResourceURLs":["/healthz","/livez","/readyz","/version","/version/"],"verbs":["get"]}]
```

This kubeadm cluster **allows anonymous requests**: they become the user `system:anonymous`, and RBAC decides. The role `system:public-info-viewer` is bound to both `system:authenticated` and `system:unauthenticated`, and grants `get` on a few non-resource URLs only. So anyone who can reach port 6443 can read the version and the health endpoints, and nothing else. The trade-off is worth knowing: the API server's port is not a secret.

---

# 10. Escalation prevention and `bind`

If a user can create RoleBindings, could they grant themselves anything? Kubernetes prevents it: **you can only grant permissions you already hold**, unless you have the special `bind` or `escalate` verbs.

## She can create bindings, but not grant what she lacks

```bash
kubectl -n rbac-demo apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: binder
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["rolebindings"]
  verbs: ["create", "get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jane-binder
subjects:
- kind: User
  name: jane
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: binder
  apiGroup: rbac.authorization.k8s.io
EOF
KC=jane.kubeconfig
echo "can create rolebindings: $(kubectl --kubeconfig=$KC auth can-i create rolebindings -n rbac-demo)"
kubectl --kubeconfig=$KC create rolebinding self-admin --clusterrole=admin --user=jane -n rbac-demo
kubectl --kubeconfig=$KC create rolebinding self-pods --role=pod-reader --user=jane -n rbac-demo
echo "can list pods now:       $(kubectl --kubeconfig=$KC auth can-i list pods -n rbac-demo)"
```

### Observed on the real cluster

```text
can create rolebindings: yes
error: failed to create rolebinding: rolebindings.rbac.authorization.k8s.io "self-admin" is forbidden: user "jane" (groups=["dev-team" "system:authenticated"]) is attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["bindings"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["configmaps"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
[... about 70 more rules, ending with ...]
{APIGroups:["rbac.authorization.k8s.io"], Resources:["rolebindings"], Verbs:["delete" "deletecollection" "patch" "update" "watch"]}
error: failed to create rolebinding: rolebindings.rbac.authorization.k8s.io "self-pods" is forbidden: user "jane" (groups=["dev-team" "system:authenticated"]) is attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["pods"], Verbs:["get" "list" "watch"]}
can list pods now:       no
```

Both attempts were refused, **including** the harmless `pod-reader`, because at that moment she did not hold those permissions herself. The message names her user and her groups, and then lists the rules she lacks. Read it as a to-do list: it is the **difference** between what she asked to grant and what she holds. It leaves out `rolebindings` `create`, `get` and `list`, which she has through `binder`.

The list also shows what the `admin` role contains on this cluster: `secrets` with every verb, `pods/exec`, and `serviceaccounts` with the verb **`impersonate`**, which lets its holder act as any service account in the namespace.

## The `bind` verb

```bash
kubectl -n rbac-demo apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: binder
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["rolebindings"]
  verbs: ["create", "get", "list"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles"]
  resourceNames: ["pod-reader"]
  verbs: ["bind"]
EOF
KC=jane.kubeconfig
kubectl --kubeconfig=$KC create rolebinding self-pods --role=pod-reader --user=jane -n rbac-demo
echo "can list pods now:       $(kubectl --kubeconfig=$KC auth can-i list pods -n rbac-demo)"
kubectl --kubeconfig=$KC create rolebinding self-admin --clusterrole=admin --user=jane -n rbac-demo
kubectl --kubeconfig=$KC auth can-i delete pods -n rbac-demo
```

### Observed on the real cluster

```text
rolebinding.rbac.authorization.k8s.io/self-pods created
can list pods now:       yes
error: failed to create rolebinding: ... "self-admin" is forbidden: ... is attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["pods"], Verbs:["create" "delete" "deletecollection" "patch" "update"]}
[...]
no
```

| Item | Predicted | Observed |
|---|---|---|
| `self-pods` after `bind` on `pod-reader` | `created` | **`created`** |
| `can list pods now` | `yes` | **`yes`** |
| `self-admin` | Still forbidden | **Still forbidden** |

The second refusal confirms the "difference" reading: the first list had `pods` with `create delete deletecollection patch update get list watch`, and this one has `pods` with only `create delete deletecollection patch update`, because she now holds `get list watch` through the binding she created. `bind`, scoped to one named role with `resourceNames`, let her hand out that role without covering anything else.

Giving someone `bind` on a powerful role, or the `escalate` verb on roles, is effectively giving them that power. The `escalate` verb was not tested.

---

# 11. The certificate's life: deletion, expiry, revocation

```bash
cd ~/rbac-lab
end=$(openssl x509 -in jane.crt -noout -enddate | cut -d= -f2)
echo "certificate expires: $end"
echo "seconds left: $(( $(date -d "$end" +%s) - $(date +%s) ))"
kubectl delete csr jane
kubectl get csr
kubectl --kubeconfig=jane.kubeconfig auth whoami
```

### Observed on the real cluster

```text
certificate expires: Oct 12 23:41:11 2026 GMT
seconds left: 845
certificatesigningrequest.certificates.k8s.io "jane" deleted
No resources found
Username   jane
Groups     [dev-team system:authenticated]
```

**Deleting the request does not revoke the certificate it produced.** `jane` still authenticated afterwards, and a later `curl` with the same certificate got HTTP 200. As far as I know, Kubernetes has no revocation list for client certificates, which is why the lifetime is the only limit on a stolen key. That last point is from my knowledge of the design, and it was not tested. Choose short lifetimes for credentials you hand out.

## What was not tested: the expired certificate

I expected a request with an **expired** certificate to get **401**, since the server would no longer accept it as an identity. That was **not tested**. The certificate had 845 seconds left when the check ran, so the check returned 200, and the key was deleted straight afterwards. The only 401 seen in these labs was for an invalid bearer token (Section 7). If you want the test, a fresh certificate with the shortest allowed lifetime can show it, as I recall the minimum being 10 minutes (600 seconds), which I have not verified.

## Clean up

```bash
kubectl delete namespace rbac-demo
rm -rf ~/rbac-lab
```

The first command removes the service account, the roles, the bindings and the `web` pod. The second removes the key and the kubeconfig that embeds it. The key was never in a repository.

---

# 12. Practical tips for running these labs

- **Never print or paste key material.** Avoid `cat` on a `.key` or a kubeconfig that embeds one, and avoid `kubectl config view --raw` outputs other than a single `jsonpath` field.
- **Impersonation is the fast way to test a role.** `kubectl auth can-i ... --as=...` and `--as-group=...` need no credentials, and your admin rights allow them.
- **Check the clocks before issuing certificates.** A new certificate starts 5 minutes in the past, which tolerates a small lag. A larger one (a VM was once 9.7 minutes behind) could make a certificate look not yet valid. The `check-clocks.ps1` script is in the repo.
- **Copy results, not commands.** A line pasted from a results table once ran as a command and created a stray file called `real` in a home directory.
- **A leftover namespace is easy to forget.** `kubectl delete namespace rbac-demo` removes everything that lives in it. Cluster-scoped objects and node labels are not part of a namespace.

---

# 13. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `Error from server (Forbidden): ... cannot list resource "X" ...` | The user lacks a rule for that verb and resource, and the message names both | Add a Role and a binding, or check the namespace of the binding |
| `You must be logged in to the server (Unauthorized)` or HTTP 401 | The credential is wrong or unknown (and, I expect, an expired certificate, which was not tested) | Check the certificate's dates and the kubeconfig |
| A Role exists, but access is still refused | A Role grants nothing until it is **bound** | Create a RoleBinding |
| Access works in one namespace and not another | A RoleBinding is limited to its own namespace | Bind in each namespace, or use a ClusterRoleBinding |
| `can-i get pods/log` says `yes` unexpectedly | `TYPE/NAME` means an **object name**, not a subresource | Use `--subresource=log` |
| `is attempting to grant RBAC permissions not currently held` | Escalation prevention: you cannot grant what you lack | Hold the permission, or get the `bind` verb for that role |
| A built-in role seems to grant more than the docs say | It is aggregated and an add-on extended it | `kubectl get clusterrole NAME -o jsonpath='{.aggregationRule}'` |
| A new certificate is rejected as not yet valid | A node's clock is behind by more than the 5-minute margin | Compare the clocks and restart the time service |
| A CSR stays `Pending` | Nobody approved it | `kubectl certificate approve NAME`, after reading its subject |
| Deleting a CSR did not stop the user | The issued certificate stays valid until it expires | Use short lifetimes, and bind permissions to groups you can remove |

---

# 14. Command cheat sheet

| Task | Command |
|---|---|
| Who am I | `kubectl auth whoami` |
| May I | `kubectl auth can-i VERB RESOURCE -n NS` |
| Everything I may do | `kubectl auth can-i --list -n NS` |
| Test as someone else | `kubectl auth can-i VERB RESOURCE --as=USER --as-group=GROUP` |
| Ask about a subresource | `kubectl auth can-i get pods --subresource=log` |
| Create a Role | `kubectl create role NAME --verb=get,list --resource=pods` |
| Bind a Role | `kubectl create rolebinding NAME --role=ROLE --user=USER` (or `--group=`, `--serviceaccount=NS:SA`) |
| Bind a ClusterRole in one namespace | `kubectl create rolebinding NAME --clusterrole=view --group=GROUP -n NS` |
| See the bindings | `kubectl get rolebindings,clusterrolebindings` |
| A role's rules | `kubectl describe clusterrole NAME` |
| Approve a user's CSR | `kubectl certificate approve NAME` |
| Read a certificate's subject and dates | `openssl x509 -in FILE -noout -subject -dates` |

---

# 15. Glossary

| Term | Meaning |
|---|---|
| **Authentication** | Establishing who you are (a certificate, a token) |
| **Authorization** | Deciding what you may do (RBAC) |
| **Subject** | A user, a group or a service account |
| **Role / ClusterRole** | A set of permissions, namespaced or cluster-wide |
| **RoleBinding / ClusterRoleBinding** | Grants a role to subjects, in one namespace or everywhere |
| **Verb** | An action such as `get`, `list`, `create`, `delete`, or a special one such as `bind` |
| **Subresource** | A part of a resource with its own permission, such as `pods/log` |
| **Aggregated role** | A ClusterRole whose rules are collected from other ClusterRoles by label |
| **Impersonation** | Acting as another subject with `--as`, which needs a permission of its own |
| **CSR** | A CertificateSigningRequest: asks the cluster to sign a client certificate |
| **Escalation prevention** | The rule that you cannot grant permissions you do not hold |
| **Anonymous user** | `system:anonymous`, the identity of a request with no credentials |

---

# 16. What was run, and what was not

## Run on the real cluster (the output above is from these)

- The default binding, the `cluster-admin` role and the four built-in roles, and the admin certificate's subject and dates
- An aggregated `view` role, and the metrics-server role that extends it
- A service account, a Role and RoleBindings, including one to a ClusterRole, and every boundary (verb, resource, namespace, cluster scope)
- The `can-i TYPE/NAME` trap, and `--subresource`
- A certificate-based user: key, CSR, approval, kubeconfig, and the three-way 401/403 comparison
- A group binding, impersonation with groups, and removing a binding
- Anonymous access, and the role that allows it
- Escalation prevention and the `bind` verb
- Deleting a CSR with its certificate still in use

## Not run

- **An expired certificate** (the expected 401 was not observed)
- **The `escalate` verb**, and ClusterRoleBindings to users and groups
- **`impersonate` as a granted permission** (the admin impersonated freely, and the `admin` role's `impersonate` was only read in an error message)
- **ServiceAccount tokens**, and how a pod uses its account
- **The `system:masters` group** and `super-admin.conf`
- **Auditing**, and external identity providers
- **`kubectl auth reconcile`**
- **The 5-minute backdating as a margin**: the evidence is three certificates, and the purpose is my reading

The explanations marked as inferences in the text (why `can-i pods/log` says `yes`, why the binding is a second older than its role, the purpose of the backdating) are the best fit to the evidence, and not verified. Check the official Kubernetes documentation for the version you run.

## Clean up everything from this guide

```bash
kubectl delete namespace rbac-demo
rm -rf ~/rbac-lab
rm -f ~/real
```

The first command removes every object the labs created, the second removes the key material, and the third removes a stray file. Neither the key nor the certificate was ever in a repository.
