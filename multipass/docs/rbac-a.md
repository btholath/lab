```bash
ubuntu@master:~$ kubectl get clusterrolebinding kubeadm:cluster-admins -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  creationTimestamp: "2026-10-05T21:42:49Z"
  name: kubeadm:cluster-admins
  resourceVersion: "12"
  uid: 1e498ca6-0058-431f-a8ca-ba9dc2a1ec5a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: kubeadm:cluster-admins
ubuntu@master:~$ kubectl get clusterrole cluster-admin -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  creationTimestamp: "2026-10-05T21:42:50Z"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: cluster-admin
  resourceVersion: "109"
  uid: 92130b9a-4b1a-4d1e-aaf2-96f1a5778938
rules:
- apiGroups:
  - '*'
  resources:
  - '*'
  verbs:
  - '*'
- nonResourceURLs:
  - '*'
  verbs:
  - '*'
ubuntu@master:~$ kubectl auth can-i --list | head -8
Resources                                       Non-Resource URLs   Resource Names   Verbs
*.*                                             []                  []               [*]
                                                [*]                 []               [*]
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                [/api/*]            []               [get]
                                                [/api]              []               [get]
ubuntu@master:~$ kubectl get clusterroles | grep -E "^(cluster-admin|admin|edit|view) "
admin                                                                  2026-10-05T21:42:50Z
cluster-admin                                                          2026-10-05T21:42:50Z
edit                                                                   2026-10-05T21:42:50Z
view                                                                   2026-10-05T21:42:50Z
ubuntu@master:~$ kubectl describe clusterrole view
Name:         view
Labels:       kubernetes.io/bootstrapping=rbac-defaults
              rbac.authorization.k8s.io/aggregate-to-edit=true
Annotations:  rbac.authorization.kubernetes.io/autoupdate: true
PolicyRule:
  Resources                                    Non-Resource URLs  Resource Names  Verbs
  ---------                                    -----------------  --------------  -----
  bindings                                     []                 []              [get list watch]
  configmaps                                   []                 []              [get list watch]
  endpoints                                    []                 []              [get list watch]
  events                                       []                 []              [get list watch]
  limitranges                                  []                 []              [get list watch]
  namespaces/status                            []                 []              [get list watch]
  namespaces                                   []                 []              [get list watch]
  persistentvolumeclaims/status                []                 []              [get list watch]
  persistentvolumeclaims                       []                 []              [get list watch]
  pods/log                                     []                 []              [get list watch]
  pods/status                                  []                 []              [get list watch]
  pods                                         []                 []              [get list watch]
  replicationcontrollers/scale                 []                 []              [get list watch]
  replicationcontrollers/status                []                 []              [get list watch]
  replicationcontrollers                       []                 []              [get list watch]
  resourcequotas/status                        []                 []              [get list watch]
  resourcequotas                               []                 []              [get list watch]
  serviceaccounts                              []                 []              [get list watch]
  services/status                              []                 []              [get list watch]
  services                                     []                 []              [get list watch]
  controllerrevisions.apps                     []                 []              [get list watch]
  daemonsets.apps/status                       []                 []              [get list watch]
  daemonsets.apps                              []                 []              [get list watch]
  deployments.apps/scale                       []                 []              [get list watch]
  deployments.apps/status                      []                 []              [get list watch]
  deployments.apps                             []                 []              [get list watch]
  replicasets.apps/scale                       []                 []              [get list watch]
  replicasets.apps/status                      []                 []              [get list watch]
  replicasets.apps                             []                 []              [get list watch]
  statefulsets.apps/scale                      []                 []              [get list watch]
  statefulsets.apps/status                     []                 []              [get list watch]
  statefulsets.apps                            []                 []              [get list watch]
  horizontalpodautoscalers.autoscaling/status  []                 []              [get list watch]
  horizontalpodautoscalers.autoscaling         []                 []              [get list watch]
  cronjobs.batch/status                        []                 []              [get list watch]
  cronjobs.batch                               []                 []              [get list watch]
  jobs.batch/status                            []                 []              [get list watch]
  jobs.batch                                   []                 []              [get list watch]
  endpointslices.discovery.k8s.io              []                 []              [get list watch]
  events.events.k8s.io                         []                 []              [get list watch]
  daemonsets.extensions/status                 []                 []              [get list watch]
  daemonsets.extensions                        []                 []              [get list watch]
  deployments.extensions/scale                 []                 []              [get list watch]
  deployments.extensions/status                []                 []              [get list watch]
  deployments.extensions                       []                 []              [get list watch]
  ingresses.extensions/status                  []                 []              [get list watch]
  ingresses.extensions                         []                 []              [get list watch]
  networkpolicies.extensions                   []                 []              [get list watch]
  replicasets.extensions/scale                 []                 []              [get list watch]
  replicasets.extensions/status                []                 []              [get list watch]
  replicasets.extensions                       []                 []              [get list watch]
  replicationcontrollers.extensions/scale      []                 []              [get list watch]
  nodes.metrics.k8s.io                         []                 []              [get list watch]
  pods.metrics.k8s.io                          []                 []              [get list watch]
  ingresses.networking.k8s.io/status           []                 []              [get list watch]
  ingresses.networking.k8s.io                  []                 []              [get list watch]
  networkpolicies.networking.k8s.io            []                 []              [get list watch]
  poddisruptionbudgets.policy/status           []                 []              [get list watch]
  poddisruptionbudgets.policy                  []                 []              [get list watch]
  resourceclaims.resource.k8s.io/status        []                 []              [get list watch]
  resourceclaims.resource.k8s.io               []                 []              [get list watch]
  resourceclaimtemplates.resource.k8s.io       []                 []              [get list watch]
ubuntu@master:~$
ubuntu@master:~$
ubuntu@master:~$
ubuntu@master:~$
ubuntu@master:~$

ubuntu@master:~$ kubectl config view --minify | grep -E "name:|user:|cluster:"
- cluster:
  name: kubernetes
    cluster: kubernetes
    user: kubernetes-admin
  name: kubernetes-admin@kubernetes
- name: kubernetes-admin
  user:
ubuntu@master:~$ kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -noout -subject -dates
subject=O = kubeadm:cluster-admins, CN = kubernetes-admin
notBefore=Oct  8 00:11:29 2026 GMT
notAfter=Oct  8 00:16:29 2027 GMT
ubuntu@master:~$
```
--- Phase A2: three more read-only checks
```bash
ubuntu@master:~$ kubectl auth whoami
ATTRIBUTE                                           VALUE
Username                                            kubernetes-admin
Groups                                              [kubeadm:cluster-admins system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [X509SHA256=46b558725ec0e57e72086529e4ae9ee3b761931e6c384f165a7c87d3193d9b31]
ubuntu@master:~$ kubectl get clusterrole view -o jsonpath='{.aggregationRule}{"\n"}'
{"clusterRoleSelectors":[{"matchLabels":{"rbac.authorization.k8s.io/aggregate-to-view":"true"}}]}
ubuntu@master:~$
ubuntu@master:~$ kubectl get clusterrole system:aggregated-metrics-reader -o yaml | sed -n '/labels:/,/rules:/p;/rules:/,$p' | head -20
  labels:
    k8s-app: metrics-server
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
    rbac.authorization.k8s.io/aggregate-to-view: "true"
  name: system:aggregated-metrics-reader
  resourceVersion: "1173145"
  uid: 2660ea34-b89c-4bbe-ad77-e2850e088192
rules:
rules:
- apiGroups:
  - metrics.k8s.io
  resources:
  - pods
  - nodes
  verbs:
  - get
  - list
  - watch
ubuntu@master:~$
ubuntu@master:~$ kubectl get clusterrolebindings -o custom-columns=NAME:.metadata.name,ROLE:.roleRef.name,SUBJECT:.subjects[*].name --no-headers | grep -E "^(cluster-admin|kubeadm|system:basic-user|system:discovery|system:public-info|system:node |system:kube-scheduler|system:kube-controller)"
cluster-admin                                                   cluster-admin                                                          system:masters
kubeadm:apiserver-kubelet-client                                system:kubelet-api-admin                                               kube-apiserver-kubelet-client
kubeadm:cluster-admins                                          cluster-admin                                                          kubeadm:cluster-admins
kubeadm:get-nodes                                               kubeadm:get-nodes                                                      system:bootstrappers:kubeadm:default-node-token
kubeadm:kubelet-bootstrap                                       system:node-bootstrapper                                               system:bootstrappers:kubeadm:default-node-token
kubeadm:node-autoapprove-bootstrap                              system:certificates.k8s.io:certificatesigningrequests:nodeclient       system:bootstrappers:kubeadm:default-node-token
kubeadm:node-autoapprove-certificate-rotation                   system:certificates.k8s.io:certificatesigningrequests:selfnodeclient   system:nodes
kubeadm:node-proxier                                            system:node-proxier                                                    kube-proxy
system:basic-user                                               system:basic-user                                                      system:authenticated
system:discovery                                                system:discovery                                                       system:authenticated
system:kube-controller-manager                                  system:kube-controller-manager                                         system:kube-controller-manager
system:kube-scheduler                                           system:kube-scheduler                                                  system:kube-scheduler
system:node                                                     system:node                                                            <none>
system:public-info-viewer                                       system:public-info-viewer                                              system:authenticated,system:unauthenticated
ubuntu@master:~$
```

---Phase B: a ServiceAccount, a Role, and what a Role does not do
```bash
ubuntu@master:~$ kubectl create namespace rbac-demo
namespace/rbac-demo created
ubuntu@master:~$
ubuntu@master:~$ kubectl -n rbac-demo create serviceaccount reader
serviceaccount/reader created
ubuntu@master:~$
ubuntu@master:~$ kubectl -n rbac-demo create role pod-reader --verb=get,list,watch --resource=pods
role.rbac.authorization.k8s.io/pod-reader created
ubuntu@master:~$
ubuntu@master:~$ SA=system:serviceaccount:rbac-demo:reader
ubuntu@master:~$
ubuntu@master:~$ echo "before any binding: $(kubectl auth can-i list pods -n rbac-demo --as=$SA)"
before any binding: no
ubuntu@master:~$
ubuntu@master:~$ kubectl -n rbac-demo create rolebinding reader-pods --role=pod-reader --serviceaccount=rbac-demo:reader
rolebinding.rbac.authorization.k8s.io/reader-pods created
ubuntu@master:~$
ubuntu@master:~$ echo "after the binding:  $(kubectl auth can-i list pods -n rbac-demo --as=$SA)"
after the binding:  yes
ubuntu@master:~$
ubuntu@master:~$ for what in "delete pods -n rbac-demo" "list secrets -n rbac-demo" "get pods/log -n rbac-demo" "list services -n rbac-demo" "list pods -n default" "list pods --all-namespaces"; do echo "$what -> $(kubectl auth can-i $what --as=$SA)"; done
delete pods -n rbac-demo -> no
list secrets -n rbac-demo -> no
get pods/log -n rbac-demo -> yes
list services -n rbac-demo -> no
list pods -n default -> no
list pods --all-namespaces -> no
ubuntu@master:~$
ubuntu@master:~$ kubectl get pods -n rbac-demo --as=$SA
No resources found in rbac-demo namespace.
ubuntu@master:~$
ubuntu@master:~$ kubectl get pods -n default --as=$SA
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:rbac-demo:reader" cannot list resource "pods" in API group "" in the namespace "default"
ubuntu@master:~$
ubuntu@master:~$
``` 


```bash
ubuntu@master:~$ SA=system:serviceaccount:rbac-demo:reader
ubuntu@master:~$ kubectl -n rbac-demo create rolebinding reader-view --clusterrole=view --serviceaccount=rbac-demo:reader
rolebinding.rbac.authorization.k8s.io/reader-view created
ubuntu@master:~$ for what in "list services -n rbac-demo" "list deployments.apps -n rbac-demo" "list secrets -n rbac-demo" "list services -n default" "list nodes"; do echo "$what -> $(kubectl auth can-i $what --as=$SA)"; done
list services -n rbac-demo -> yes
list deployments.apps -n rbac-demo -> yes
list secrets -n rbac-demo -> no
list services -n default -> no
Warning: resource 'nodes' is not namespace scoped

list nodes -> no
ubuntu@master:~$ kubectl -n rbac-demo get rolebindings
NAME          ROLE               AGE
reader-pods   Role/pod-reader    43m
reader-view   ClusterRole/view   40s
ubuntu@master:~$
ubuntu@master:~$ kubectl auth can-i --list -n rbac-demo --as=$SA | head -12
Resources                                       Non-Resource URLs                      Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                                     []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                                     []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                                     []               [create]
bindings                                        []                                     []               [get list watch]
configmaps                                      []                                     []               [get list watch]
endpoints                                       []                                     []               [get list watch]
events                                          []                                     []               [get list watch]
limitranges                                     []                                     []               [get list watch]
namespaces/status                               []                                     []               [get list watch]
namespaces                                      []                                     []               [get list watch]
persistentvolumeclaims/status                   []                                     []               [get list watch]
ubuntu@master:~$
```

--- Check the subresource, and A2
```bash
ubuntu@master:~$ SA=system:serviceaccount:rbac-demo:reader
ubuntu@master:~$
^C
ubuntu@master:~$ echo "with view:  pods/log=$(kubectl auth can-i get pods/log -n rbac-demo --as=$SA)  --subresource=log=$(kubectl auth can-i get pods --subresource=log -n rbac-demo --as=$SA)"
with view:  pods/log=yes  --subresource=log=yes
ubuntu@master:~$
ubuntu@master:~$
ubuntu@master:~$ kubectl -n rbac-demo delete rolebinding reader-view
rolebinding.rbac.authorization.k8s.io "reader-view" deleted from rbac-demo namespace
ubuntu@master:~$
ubuntu@master:~$ echo "no view:    pods/log=$(kubectl auth can-i get pods/log -n rbac-demo --as=$SA)  pods/whatever=$(kubectl auth can-i get pods/whatever -n rbac-demo --as=$SA)  --subresource=log=$(kubectl auth can-i get pods --subresource=log -n rbac-demo --as=$SA)  list pods=$(kubectl auth can-i list pods -n rbac-demo --as=$SA)"
no view:    pods/log=yes  pods/whatever=yes  --subresource=log=no  list pods=yes
ubuntu@master:~$
ubuntu@master:~$
ubuntu@master:~$ kubectl -n rbac-demo create rolebinding reader-view --clusterrole=view --serviceaccount=rbac-demo:reader
rolebinding.rbac.authorization.k8s.io/reader-view created
ubuntu@master:~$
ubuntu@master:~$
ubuntu@master:~$
ubuntu@master:~$ echo "view back:  --subresource=log=$(kubectl auth can-i get pods --subresource=log -n rbac-demo --as=$SA)"
view back:  --subresource=log=yes
ubuntu@master:~$
ubuntu@master:~$ kubectl auth can-i --list -n rbac-demo --as=$SA | grep -E "^Resources|^pods( |$)|pods/log|pods.metrics"
Resources                                       Non-Resource URLs                      Resource Names   Verbs
pods/log                                        []                                     []               [get list watch]
pods                                            []                                     []               [get list watch]
pods.metrics.k8s.io                             []                                     []               [get list watch]
ubuntu@master:~$
ubuntu@master:~$

ubuntu@master:~$ kubectl auth whoami
ATTRIBUTE                                           VALUE
Username                                            kubernetes-admin
Groups                                              [kubeadm:cluster-admins system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [X509SHA256=46b558725ec0e57e72086529e4ae9ee3b761931e6c384f165a7c87d3193d9b31]
ubuntu@master:~$ kubectl get clusterrole view -o jsonpath='{.aggregationRule}{"\n"}'
{"clusterRoleSelectors":[{"matchLabels":{"rbac.authorization.k8s.io/aggregate-to-view":"true"}}]}
ubuntu@master:~$
ubuntu@master:~$
ubuntu@master:~$ kubectl get clusterrole system:aggregated-metrics-reader -o jsonpath='{.metadata.labels}{"\n"}{.rules}{"\n"}'
{"k8s-app":"metrics-server","rbac.authorization.k8s.io/aggregate-to-admin":"true","rbac.authorization.k8s.io/aggregate-to-edit":"true","rbac.authorization.k8s.io/aggregate-to-view":"true"}
[{"apiGroups":["metrics.k8s.io"],"resources":["pods","nodes"],"verbs":["get","list","watch"]}]
ubuntu@master:~$
ubuntu@master:~$
```

--Phase C: a certificate-based user
```bash
Windows PowerShell
Copyright (C) Microsoft Corporation. All rights reserved.

PS Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\Ubuntu\home\bijut\repos\lab\multipass\scripts> .\check-clocks.ps1
.\check-clocks.ps1 : File \\wsl.localhost\Ubuntu\home\bijut\repos\lab\multipass\scripts\check-clocks.ps1 cannot be
loaded. The file \\wsl.localhost\Ubuntu\home\bijut\repos\lab\multipass\scripts\check-clocks.ps1 is not digitally
signed. You cannot run this script on the current system. For more information about running scripts and setting
execution policy, see about_Execution_Policies at https:/go.microsoft.com/fwlink/?LinkID=135170.
At line:1 char:1
+ .\check-clocks.ps1
+ ~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : SecurityError: (:) [], PSSecurityException
    + FullyQualifiedErrorId : UnauthorizedAccess
PS Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\Ubuntu\home\bijut\repos\lab\multipass\scripts>

PS Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\Ubuntu\home\bijut\repos\lab\multipass\scripts> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
PS Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\Ubuntu\home\bijut\repos\lab\multipass\scripts> .\check-clocks.ps1
Windows UTC: 22:39:33

VM      OffsetSeconds RoundTripMs Status
--      ------------- ----------- ------
master            0.2        1440 ok
worker1             0        1102 ok
worker2             0        1115 ok


All clocks agree with Windows within the threshold.
PS Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\Ubuntu\home\bijut\repos\lab\multipass\scripts>
```

```bash
ubuntu@master:~$ mkdir -p ~/rbac-lab && chmod 700 ~/rbac-lab && cd ~/rbac-lab
openssl genrsa -out jane.key 2048
chmod 600 jane.key
openssl req -new -key jane.key -out jane.csr -subj "/CN=jane/O=dev-team"
openssl req -in jane.csr -noout -subject
ls -l
subject=CN = jane, O = dev-team
total 8
-rw-rw-r-- 1 ubuntu ubuntu  911 Oct 12 15:41 jane.csr
-rw------- 1 ubuntu ubuntu 1704 Oct 12 15:41 jane.key
ubuntu@master:~/rbac-lab$ cd ~/rbac-lab
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
certificatesigningrequest.certificates.k8s.io/jane created
NAME   AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
jane   0s    kubernetes.io/kube-apiserver-client   kubernetes-admin   60m                 Pending
certificatesigningrequest.certificates.k8s.io/jane approved
NAME   AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
jane   3s    kubernetes.io/kube-apiserver-client   kubernetes-admin   60m                 Approved,Issued
subject=O = dev-team, CN = jane
issuer=CN = kubernetes
notBefore=Oct 12 22:36:11 2026 GMT
notAfter=Oct 12 23:41:11 2026 GMT
ubuntu@master:~/rbac-lab$


ubuntu@master:~$ mkdir -p ~/rbac-lab && chmod 700 ~/rbac-lab && cd ~/rbac-lab
openssl genrsa -out jane.key 2048
chmod 600 jane.key
openssl req -new -key jane.key -out jane.csr -subj "/CN=jane/O=dev-team"
openssl req -in jane.csr -noout -subject
ls -l
subject=CN = jane, O = dev-team
total 8
-rw-rw-r-- 1 ubuntu ubuntu  911 Oct 12 15:41 jane.csr
-rw------- 1 ubuntu ubuntu 1704 Oct 12 15:41 jane.key
ubuntu@master:~/rbac-lab$ cd ~/rbac-lab
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
certificatesigningrequest.certificates.k8s.io/jane created
NAME   AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
jane   0s    kubernetes.io/kube-apiserver-client   kubernetes-admin   60m                 Pending
certificatesigningrequest.certificates.k8s.io/jane approved
NAME   AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
jane   3s    kubernetes.io/kube-apiserver-client   kubernetes-admin   60m                 Approved,Issued
subject=O = dev-team, CN = jane
issuer=CN = kubernetes
notBefore=Oct 12 22:36:11 2026 GMT
notAfter=Oct 12 23:41:11 2026 GMT
ubuntu@master:~/rbac-lab$ cd ~/rbac-lab
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "api server: $APISERVER"
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
openssl x509 -in ca.crt -noout -subject -dates
kubectl --kubeconfig=jane.kubeconfig config set-cluster kubernetes --server=$APISERVER --certificate-authority=ca.crt --embed-certs=true
kubectl --kubeconfig=jane.kubeconfig config set-credentials jane --client-certificate=jane.crt --client-key=jane.key --embed-certs=true
kubectl --kubeconfig=jane.kubeconfig config set-context jane --cluster=kubernetes --user=jane --namespace=rbac-demo
kubectl --kubeconfig=jane.kubeconfig config use-context jane
chmod 600 jane.kubeconfig
ls -l
api server: https://172.25.246.7:6443
subject=CN = kubernetes
notBefore=Oct  5 21:24:56 2026 GMT
notAfter=Oct  2 21:29:56 2036 GMT
Cluster "kubernetes" set.
User "jane" set.
Context "jane" created.
Switched to context "jane".
total 24
-rw-rw-r-- 1 ubuntu ubuntu 1107 Oct 12 15:42 ca.crt
-rw-rw-r-- 1 ubuntu ubuntu 1111 Oct 12 15:41 jane.crt
-rw-rw-r-- 1 ubuntu ubuntu  911 Oct 12 15:41 jane.csr
-rw------- 1 ubuntu ubuntu 1704 Oct 12 15:41 jane.key
-rw------- 1 ubuntu ubuntu 5571 Oct 12 15:42 jane.kubeconfig
ubuntu@master:~/rbac-lab$ cd ~/rbac-lab
KC=jane.kubeconfig
kubectl --kubeconfig=$KC auth whoami
kubectl --kubeconfig=$KC get pods
kubectl --kubeconfig=$KC auth can-i list pods
kubectl --kubeconfig=$KC auth can-i --list | head -10
ATTRIBUTE                                           VALUE
Username                                            jane
Groups                                              [dev-team system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [X509SHA256=6f9c1c38e8d67361292a31f38255d0c824b0a890869eeff86e03c4b250770ce5]
Error from server (Forbidden): pods is forbidden: User "jane" cannot list resource "pods" in API group "" in the namespace "rbac-demo"
no
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                [/api/*]            []               [get]
                                                [/api]              []               [get]
                                                [/apis/*]           []               [get]
                                                [/apis]             []               [get]
                                                [/healthz]          []               [get]
                                                [/healthz]          []               [get]
ubuntu@master:~/rbac-lab$ cd ~/rbac-lab
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
URL=$APISERVER/api/v1/namespaces/rbac-demo/pods
echo "=== 1: no credentials at all"
curl -s --cacert ca.crt -o /tmp/r1 -w "HTTP %{http_code}\n" $URL; grep -E '"message"' /tmp/r1
echo "=== 2: an invalid bearer token"
curl -s --cacert ca.crt -H "Authorization: Bearer not-a-real-token" -o /tmp/r2 -w "HTTP %{http_code}\n" $URL; grep -E '"message"' /tmp/r2
echo "=== 3: jane's certificate (valid, but no permission)"
curl -s --cacert ca.crt --cert jane.crt --key jane.key -o /tmp/r3 -w "HTTP %{http_code}\n" $URL; grep -E '"message"' /tmp/r3
rm -f /tmp/r1 /tmp/r2 /tmp/r3
=== 1: no credentials at all
HTTP 403
  "message": "pods is forbidden: User \"system:anonymous\" cannot list resource \"pods\" in API group \"\" in the namespace \"rbac-demo\"",
=== 2: an invalid bearer token
HTTP 401
  "message": "Unauthorized",
=== 3: jane's certificate (valid, but no permission)
HTTP 403
  "message": "pods is forbidden: User \"jane\" cannot list resource \"pods\" in API group \"\" in the namespace \"rbac-demo\"",
ubuntu@master:~/rbac-lab$


ubuntu@master:~$ cd ~/rbac-lab
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
before: no
rolebinding.rbac.authorization.k8s.io/dev-team-pods created
pod/web created
after:  yes
NAME   READY   STATUS    RESTARTS   AGE
web    1/1     Running   0          8s
Error from server (Forbidden): pods "web" is forbidden: User "jane" cannot delete resource "pods" in API group "" in the namespace "rbac-demo"
Error from server (Forbidden): secrets is forbidden: User "jane" cannot list resource "secrets" in API group "" in the namespace "rbac-demo"
Error from server (Forbidden): pods is forbidden: User "jane" cannot list resource "pods" in API group "" in the namespace "default"
ubuntu@master:~/rbac-lab$


ubuntu@master:~/rbac-lab$ echo "as=jane only:                 $(kubectl auth can-i list pods -n rbac-demo --as=jane)"
echo "as=jane + group dev-team:     $(kubectl auth can-i list pods -n rbac-demo --as=jane --as-group=dev-team)"
echo "as=nobody + group dev-team:   $(kubectl auth can-i list pods -n rbac-demo --as=nobody --as-group=dev-team)"
echo "dev-team may delete pods:     $(kubectl auth can-i delete pods -n rbac-demo --as=nobody --as-group=dev-team)"
as=jane only:                 no
as=jane + group dev-team:     yes
as=nobody + group dev-team:   yes
dev-team may delete pods:     no
ubuntu@master:~/rbac-lab$
ubuntu@master:~/rbac-lab$
ubuntu@master:~/rbac-lab$ cd ~/rbac-lab
kubectl -n rbac-demo delete rolebinding dev-team-pods
sleep 2
kubectl --kubeconfig=jane.kubeconfig get pods
echo "jane still authenticates: $(kubectl --kubeconfig=jane.kubeconfig auth whoami | grep Username)"
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
curl -s --cacert ca.crt -o /dev/null -w "anonymous /version:    HTTP %{http_code}\n" $APISERVER/version
curl -s --cacert ca.crt -o /dev/null -w "anonymous /healthz:    HTTP %{http_code}\n" $APISERVER/healthz
curl -s --cacert ca.crt -o /dev/null -w "anonymous namespaces:  HTTP %{http_code}\n" $APISERVER/api/v1/namespaces
rolebinding.rbac.authorization.k8s.io "dev-team-pods" deleted from rbac-demo namespace
Error from server (Forbidden): pods is forbidden: User "jane" cannot list resource "pods" in API group "" in the namespace "rbac-demo"
jane still authenticates: Username                                            jane
anonymous /version:    HTTP 200
anonymous /healthz:    HTTP 200
anonymous namespaces:  HTTP 403
ubuntu@master:~/rbac-lab$


ubuntu@master:~/rbac-lab$ kubectl get clusterrolebinding system:public-info-viewer -o jsonpath='{.subjects}{"\n"}'
kubectl get clusterrole system:public-info-viewer -o jsonpath='{.rules}{"\n"}'
[{"apiGroup":"rbac.authorization.k8s.io","kind":"Group","name":"system:authenticated"},{"apiGroup":"rbac.authorization.k8s.io","kind":"Group","name":"system:unauthenticated"}]
[{"nonResourceURLs":["/healthz","/livez","/readyz","/version","/version/"],"verbs":["get"]}]
ubuntu@master:~/rbac-lab$
ubuntu@master:~/rbac-lab$
ubuntu@master:~/rbac-lab$ cd ~/rbac-lab
KC=jane.kubeconfig
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
sleep 2
echo "can create rolebindings: $(kubectl --kubeconfig=$KC auth can-i create rolebindings -n rbac-demo)"
echo "can list pods:           $(kubectl --kubeconfig=$KC auth can-i list pods -n rbac-demo)"
kubectl --kubeconfig=$KC create rolebinding self-admin --clusterrole=admin --user=jane -n rbac-demo
kubectl --kubeconfig=$KC create rolebinding self-pods --role=pod-reader --user=jane -n rbac-demo
echo "can list pods now:       $(kubectl --kubeconfig=$KC auth can-i list pods -n rbac-demo)"
role.rbac.authorization.k8s.io/binder created
rolebinding.rbac.authorization.k8s.io/jane-binder created
can create rolebindings: yes
can list pods:           no
error: failed to create rolebinding: rolebindings.rbac.authorization.k8s.io "self-admin" is forbidden: user "jane" (groups=["dev-team" "system:authenticated"]) is attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["bindings"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["configmaps"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["endpoints"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["events"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["limitranges"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["namespaces"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["namespaces/status"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["persistentvolumeclaims"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["persistentvolumeclaims/status"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["pods"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["pods/attach"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["pods/eviction"], Verbs:["create"]}
{APIGroups:[""], Resources:["pods/exec"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["pods/log"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["pods/portforward"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["pods/proxy"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["pods/status"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["replicationcontrollers"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["replicationcontrollers/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["replicationcontrollers/status"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["resourcequotas"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["resourcequotas/status"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["secrets"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["serviceaccounts"], Verbs:["impersonate" "create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["serviceaccounts/token"], Verbs:["create"]}
{APIGroups:[""], Resources:["services"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["services/proxy"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["services/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["apps"], Resources:["controllerrevisions"], Verbs:["get" "list" "watch"]}
{APIGroups:["apps"], Resources:["daemonsets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["daemonsets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["apps"], Resources:["deployments"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["deployments/rollback"], Verbs:["create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:["apps"], Resources:["deployments/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["deployments/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["apps"], Resources:["replicasets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["replicasets/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["replicasets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["apps"], Resources:["statefulsets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["statefulsets/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["statefulsets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["authorization.k8s.io"], Resources:["localsubjectaccessreviews"], Verbs:["create"]}
{APIGroups:["autoscaling"], Resources:["horizontalpodautoscalers"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["autoscaling"], Resources:["horizontalpodautoscalers/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["batch"], Resources:["cronjobs"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["batch"], Resources:["cronjobs/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["batch"], Resources:["jobs"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["batch"], Resources:["jobs/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["coordination.k8s.io"], Resources:["leases"], Verbs:["create" "delete" "deletecollection" "get" "list" "patch" "update" "watch"]}
{APIGroups:["discovery.k8s.io"], Resources:["endpointslices"], Verbs:["get" "list" "watch"]}
{APIGroups:["events.k8s.io"], Resources:["events"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["daemonsets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["daemonsets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["deployments"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["deployments/rollback"], Verbs:["create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:["extensions"], Resources:["deployments/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["deployments/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["ingresses"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["ingresses/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["networkpolicies"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["replicasets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["replicasets/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["replicasets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["replicationcontrollers/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["metrics.k8s.io"], Resources:["nodes"], Verbs:["get" "list" "watch"]}
{APIGroups:["metrics.k8s.io"], Resources:["pods"], Verbs:["get" "list" "watch"]}
{APIGroups:["networking.k8s.io"], Resources:["ingresses"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["networking.k8s.io"], Resources:["ingresses/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["networking.k8s.io"], Resources:["networkpolicies"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["policy"], Resources:["poddisruptionbudgets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["policy"], Resources:["poddisruptionbudgets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["rbac.authorization.k8s.io"], Resources:["rolebindings"], Verbs:["delete" "deletecollection" "patch" "update" "watch"]}
{APIGroups:["rbac.authorization.k8s.io"], Resources:["roles"], Verbs:["create" "delete" "deletecollection" "get" "list" "patch" "update" "watch"]}
{APIGroups:["resource.k8s.io"], Resources:["resourceclaims"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["resource.k8s.io"], Resources:["resourceclaims/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["resource.k8s.io"], Resources:["resourceclaimtemplates"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
error: failed to create rolebinding: rolebindings.rbac.authorization.k8s.io "self-pods" is forbidden: user "jane" (groups=["dev-team" "system:authenticated"]) is attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["pods"], Verbs:["get" "list" "watch"]}
can list pods now:       no
ubuntu@master:~/rbac-lab$
ubuntu@master:~/rbac-lab$
ubuntu@master:~/rbac-lab$ cd ~/rbac-lab
KC=jane.kubeconfig
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
sleep 2
kubectl --kubeconfig=$KC create rolebinding self-pods --role=pod-reader --user=jane -n rbac-demo
echo "can list pods now:       $(kubectl --kubeconfig=$KC auth can-i list pods -n rbac-demo)"
kubectl --kubeconfig=$KC create rolebinding self-admin --clusterrole=admin --user=jane -n rbac-demo
kubectl --kubeconfig=$KC auth can-i delete pods -n rbac-demo
role.rbac.authorization.k8s.io/binder configured
rolebinding.rbac.authorization.k8s.io/self-pods created
can list pods now:       yes
error: failed to create rolebinding: rolebindings.rbac.authorization.k8s.io "self-admin" is forbidden: user "jane" (groups=["dev-team" "system:authenticated"]) is attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["bindings"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["configmaps"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["endpoints"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["events"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["limitranges"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["namespaces"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["namespaces/status"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["persistentvolumeclaims"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["persistentvolumeclaims/status"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["pods"], Verbs:["create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["pods/attach"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["pods/eviction"], Verbs:["create"]}
{APIGroups:[""], Resources:["pods/exec"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["pods/log"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["pods/portforward"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["pods/proxy"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["pods/status"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["replicationcontrollers"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["replicationcontrollers/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["replicationcontrollers/status"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["resourcequotas"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["resourcequotas/status"], Verbs:["get" "list" "watch"]}
{APIGroups:[""], Resources:["secrets"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["serviceaccounts"], Verbs:["impersonate" "create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["serviceaccounts/token"], Verbs:["create"]}
{APIGroups:[""], Resources:["services"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:[""], Resources:["services/proxy"], Verbs:["get" "list" "watch" "create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:[""], Resources:["services/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["apps"], Resources:["controllerrevisions"], Verbs:["get" "list" "watch"]}
{APIGroups:["apps"], Resources:["daemonsets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["daemonsets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["apps"], Resources:["deployments"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["deployments/rollback"], Verbs:["create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:["apps"], Resources:["deployments/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["deployments/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["apps"], Resources:["replicasets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["replicasets/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["replicasets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["apps"], Resources:["statefulsets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["statefulsets/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["apps"], Resources:["statefulsets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["authorization.k8s.io"], Resources:["localsubjectaccessreviews"], Verbs:["create"]}
{APIGroups:["autoscaling"], Resources:["horizontalpodautoscalers"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["autoscaling"], Resources:["horizontalpodautoscalers/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["batch"], Resources:["cronjobs"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["batch"], Resources:["cronjobs/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["batch"], Resources:["jobs"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["batch"], Resources:["jobs/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["coordination.k8s.io"], Resources:["leases"], Verbs:["create" "delete" "deletecollection" "get" "list" "patch" "update" "watch"]}
{APIGroups:["discovery.k8s.io"], Resources:["endpointslices"], Verbs:["get" "list" "watch"]}
{APIGroups:["events.k8s.io"], Resources:["events"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["daemonsets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["daemonsets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["deployments"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["deployments/rollback"], Verbs:["create" "delete" "deletecollection" "patch" "update"]}
{APIGroups:["extensions"], Resources:["deployments/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["deployments/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["ingresses"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["ingresses/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["networkpolicies"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["replicasets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["replicasets/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["replicasets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["extensions"], Resources:["replicationcontrollers/scale"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["metrics.k8s.io"], Resources:["nodes"], Verbs:["get" "list" "watch"]}
{APIGroups:["metrics.k8s.io"], Resources:["pods"], Verbs:["get" "list" "watch"]}
{APIGroups:["networking.k8s.io"], Resources:["ingresses"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["networking.k8s.io"], Resources:["ingresses/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["networking.k8s.io"], Resources:["networkpolicies"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["policy"], Resources:["poddisruptionbudgets"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["policy"], Resources:["poddisruptionbudgets/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["rbac.authorization.k8s.io"], Resources:["rolebindings"], Verbs:["delete" "deletecollection" "patch" "update" "watch"]}
{APIGroups:["rbac.authorization.k8s.io"], Resources:["roles"], Verbs:["create" "delete" "deletecollection" "get" "list" "patch" "update" "watch"]}
{APIGroups:["resource.k8s.io"], Resources:["resourceclaims"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
{APIGroups:["resource.k8s.io"], Resources:["resourceclaims/status"], Verbs:["get" "list" "watch"]}
{APIGroups:["resource.k8s.io"], Resources:["resourceclaimtemplates"], Verbs:["create" "delete" "deletecollection" "patch" "update" "get" "list" "watch"]}
no
ubuntu@master:~/rbac-lab$

ubuntu@master:~/rbac-lab$ cd ~/rbac-lab
end=$(openssl x509 -in jane.crt -noout -enddate | cut -d= -f2)
echo "certificate expires: $end"
echo "seconds left: $(( $(date -d "$end" +%s) - $(date +%s) ))"
kubectl delete csr jane
kubectl get csr
kubectl --kubeconfig=jane.kubeconfig auth whoami
kubectl -n rbac-demo get roles,rolebindings,serviceaccounts
certificate expires: Oct 12 23:41:11 2026 GMT
seconds left: 845
certificatesigningrequest.certificates.k8s.io "jane" deleted
No resources found
ATTRIBUTE                                           VALUE
Username                                            jane
Groups                                              [dev-team system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [X509SHA256=6f9c1c38e8d67361292a31f38255d0c824b0a890869eeff86e03c4b250770ce5]
NAME                                        CREATED AT
role.rbac.authorization.k8s.io/binder       2026-10-12T23:10:47Z
role.rbac.authorization.k8s.io/pod-reader   2026-10-12T17:07:06Z

NAME                                                ROLE               AGE
rolebinding.rbac.authorization.k8s.io/jane-binder   Role/binder        16m
rolebinding.rbac.authorization.k8s.io/reader-pods   Role/pod-reader    6h16m
rolebinding.rbac.authorization.k8s.io/reader-view   ClusterRole/view   5h9m
rolebinding.rbac.authorization.k8s.io/self-pods     Role/pod-reader    16m

NAME                     AGE
serviceaccount/default   6h24m
serviceaccount/reader    6h20m
ubuntu@master:~/rbac-lab$ cd ~/rbac-lab
kubectl --kubeconfig=jane.kubeconfig get pods
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
curl -s --cacert ca.crt --cert jane.crt --key jane.key -o /dev/null -w "expired certificate: HTTP %{http_code}\n" $APISERVER/api/v1/namespaces/rbac-demo/pods
NAME   READY   STATUS    RESTARTS   AGE
web    1/1     Running   0          32m
expired certificate: HTTP 200
ubuntu@master:~/rbac-lab$ kubectl delete namespace rbac-demo
rm -rf ~/rbac-lab
ls ~
kubectl get ns
namespace "rbac-demo" deleted
common.sh       no-toleration.yaml  pods-before-upgrade.txt  real               with-toleration.yaml
etcd-backup.db  pin-ip.sh           pre-upgrade.db           upgrade-apply.log
NAME              STATUS   AGE
default           Active   7d1h
kube-flannel      Active   6d23h
kube-node-lease   Active   7d1h
kube-public       Active   7d1h
kube-system       Active   7d1h
ubuntu@master:~/rbac-lab$
```

