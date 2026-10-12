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
