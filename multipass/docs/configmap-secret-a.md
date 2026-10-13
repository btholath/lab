ubuntu@master:~/rbac-lab$ kubectl create namespace cfg
kubectl config set-context --current --namespace=cfg
mkdir -p ~/cfg-lab && cd ~/cfg-lab
printf 'log_level=info\nmode=demo\n' > app.properties
printf 'DB_HOST=db.local\nDB_PORT=5432\n' > db.env
ls -l
namespace/cfg created
Context "kubernetes-admin@kubernetes" modified.
total 8
-rw-rw-r-- 1 ubuntu ubuntu 25 Oct 12 16:53 app.properties
-rw-rw-r-- 1 ubuntu ubuntu 30 Oct 12 16:53 db.env
ubuntu@master:~/cfg-lab$ cd ~/cfg-lab
kubectl create configmap from-literal --from-literal=color=blue --from-literal=size=large
kubectl create configmap from-file --from-file=app.properties
kubectl create configmap from-file-key --from-file=settings=app.properties
kubectl create configmap from-envfile --from-env-file=db.env
kubectl get configmaps
configmap/from-literal created
configmap/from-file created
configmap/from-file-key created
configmap/from-envfile created
NAME DATA AGE
from-envfile 2 0s
from-file 1 0s
from-file-key 1 0s
from-literal 2 0s
kube-root-ca.crt 1 75s
ubuntu@master:~/cfg-lab$ for c in from-literal from-file from-file-key from-envfile; do echo "== $c"; kubectl get configmap $c -o jsonpath='{.data}{"\n"}'; done
== from-literal
{"color":"blue","size":"large"}
== from-file
{"app.properties":"log_level=info\nmode=demo\n"}
== from-file-key
{"settings":"log_level=info\nmode=demo\n"}
== from-envfile
{"DB_HOST":"db.local","DB_PORT":"5432"}
ubuntu@master:~/cfg-lab$ for c in from-literal from-file from-file-key from-envfile; do echo "== $c"; kubectl get configmap $c -o jsonpath='{.data}{"\n"}'; done
== from-literal
{"color":"blue","size":"large"}
== from-file
{"app.properties":"log_level=info\nmode=demo\n"}
== from-file-key
{"settings":"log_level=info\nmode=demo\n"}
== from-envfile
{"DB_HOST":"db.local","DB_PORT":"5432"}
ubuntu@master:~/cfg-lab$

PS Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\Ubuntu\home\bijut\repos\lab\multipass\scripts> .\check-clocks.ps1 -Fix
Restarted systemd-timesyncd on master, worker1, worker2. Waiting 40 seconds...
Windows UTC: 00:06:04

VM OffsetSeconds RoundTripMs Status

---

master -0.2 660 ok
worker1 -0.2 686 ok
worker2 -0.2 734 ok

All clocks agree with Windows within the threshold.
PS Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\Ubuntu\home\bijut\repos\lab\multipass\scripts>

ubuntu@master:~/cfg-lab$ cd ~/cfg-lab
cat > cm-demo.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
name: cm-demo
spec:
terminationGracePeriodSeconds: 1
containers:

- name: app
  image: busybox
  command: ["sh", "-c", "sleep 3600"]
  env:
  - name: COLOR_ENV
    valueFrom:
    configMapKeyRef:
    name: live
    key: color
    volumeMounts:
  - name: cfg
    mountPath: /etc/cfg
  - name: cfg
    mountPath: /etc/color-subpath
    subPath: color
    volumes:
- name: cfg
  configMap:
  name: live
  EOF
  kubectl create configmap live --from-literal=color=blue
  kubectl apply -f cm-demo.yaml
  kubectl wait --for=condition=Ready pod/cm-demo --timeout=60s
  error: failed to create configmap: configmaps "live" already exists
  pod/cm-demo configured
  pod/cm-demo condition met
  ubuntu@master:~/cfg-lab$ echo "env=$(kubectl exec cm-demo -- printenv COLOR_ENV)  file=$(kubectl exec cm-demo -- cat /etc/cfg/color) subpath=$(kubectl exec cm-demo -- cat /etc/color-subpath)"
kubectl exec cm-demo -- ls -la /etc/cfg
env=blue  file=blue  subpath=blue
total 12
drwxrwxrwx    3 root     root          4096 Oct 12 23:59 .
drwxr-xr-x    1 root     root          4096 Oct 12 23:59 ..
drwxr-xr-x    2 root     root          4096 Oct 12 23:59 ..2026_10_12_23_59_41.2509085303
lrwxrwxrwx    1 root     root            32 Oct 12 23:59 ..data -> ..2026_10_12_23_59_41.2509085303
lrwxrwxrwx    1 root     root            12 Oct 12 23:59 color -> ..data/color
ubuntu@master:~/cfg-lab$ kubectl patch configmap live --type merge -p '{"data":{"color":"red"}}'
  t0=$(date +%s)
for i in $(seq 1 30); do
  f=$(kubectl exec cm-demo -- cat /etc/cfg/color)
  s=$(kubectl exec cm-demo -- cat /etc/color-subpath)
  e=$(kubectl exec cm-demo -- printenv COLOR_ENV)
  echo "t+$(( $(date +%s) - t0 ))s  file=$f subpath=$s  env=$e"
  sleep 4
  done
  kubectl exec cm-demo -- ls -la /etc/cfg
  configmap/live patched
  t+1s file=blue subpath=blue env=blue
  t+5s file=blue subpath=blue env=blue
  t+9s file=blue subpath=blue env=blue
  t+14s file=blue subpath=blue env=blue
  t+18s file=blue subpath=blue env=blue
  t+22s file=blue subpath=blue env=blue
  t+26s file=blue subpath=blue env=blue
  t+31s file=blue subpath=blue env=blue
  t+35s file=blue subpath=blue env=blue
  t+39s file=blue subpath=blue env=blue
  t+44s file=red subpath=blue env=blue
  t+48s file=red subpath=blue env=blue
  t+52s file=red subpath=blue env=blue
  t+56s file=red subpath=blue env=blue
  t+61s file=red subpath=blue env=blue
  t+65s file=red subpath=blue env=blue
  t+69s file=red subpath=blue env=blue
  t+74s file=red subpath=blue env=blue
  t+78s file=red subpath=blue env=blue
  t+82s file=red subpath=blue env=blue
  t+86s file=red subpath=blue env=blue
  t+91s file=red subpath=blue env=blue
  t+95s file=red subpath=blue env=blue
  t+100s file=red subpath=blue env=blue
  t+104s file=red subpath=blue env=blue
  t+108s file=red subpath=blue env=blue
  t+112s file=red subpath=blue env=blue
  t+117s file=red subpath=blue env=blue
  t+121s file=red subpath=blue env=blue
  t+125s file=red subpath=blue env=blue
  total 12
  drwxrwxrwx 3 root root 4096 Oct 13 00:07 .
  drwxr-xr-x 1 root root 4096 Oct 12 23:59 ..
  drwxr-xr-x 2 root root 4096 Oct 13 00:07 ..2026_10_13_00_07_12.1676845679
  lrwxrwxrwx 1 root root 32 Oct 13 00:07 ..data -> ..2026_10_13_00_07_12.1676845679
  lrwxrwxrwx 1 root root 12 Oct 12 23:59 color -> ..data/color
  ubuntu@master:~/cfg-lab$ cd ~/cfg-lab
  kubectl delete pod cm-demo
  kubectl apply -f cm-demo.yaml
  kubectl wait --for=condition=Ready pod/cm-demo --timeout=60s
  echo "env=$(kubectl exec cm-demo -- printenv COLOR_ENV)  file=$(kubectl exec cm-demo -- cat /etc/cfg/color) subpath=$(kubectl exec cm-demo -- cat /etc/color-subpath)"
pod "cm-demo" deleted from cfg namespace
pod/cm-demo created
pod/cm-demo condition met
env=red  file=red  subpath=red
ubuntu@master:~/cfg-lab$

ubuntu@master:~/cfg-lab$ cd ~/cfg-lab
cat > block3.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
name: p-env-nocm
spec:
terminationGracePeriodSeconds: 1
containers:

- name: app
  image: busybox
  command: ["sh", "-c", "sleep 3600"]
  env:
  - name: COLOR
    valueFrom:
    configMapKeyRef:
    name: later
    key: color

---

apiVersion: v1
kind: Pod
metadata:
name: p-vol-nocm
spec:
terminationGracePeriodSeconds: 1
containers:

- name: app
  image: busybox
  command: ["sh", "-c", "sleep 3600"]
  volumeMounts:
  - name: cfg
    mountPath: /etc/later
    volumes:
- name: cfg
  configMap:
  name: later

---

apiVersion: v1
kind: Pod
metadata:
name: p-env-nokey
spec:
terminationGracePeriodSeconds: 1
containers:

- name: app
  image: busybox
  command: ["sh", "-c", "sleep 3600"]
  env: - name: COLOR
  valueFrom:
  configMapKeyRef:
  kubectl get pods block3.yamlleep 3600"]
  pod/p-env-nocm created
  pod/p-vol-nocm created
  pod/p-env-nokey created
  pod/p-env-opt created
  pod/p-vol-opt created
  NAME READY STATUS RESTARTS AGE
  cm-demo 1/1 Running 0 2m47s
  p-env-nocm 0/1 CreateContainerConfigError 0 40s
  p-env-nokey 0/1 CreateContainerConfigError 0 40s
  p-env-opt 1/1 Running 0 40s
  p-vol-nocm 0/1 ContainerCreating 0 40s
  p-vol-opt 1/1 Running 0 40s
  ubuntu@master:~/cfg-lab$
ubuntu@master:~/cfg-lab$ kubectl get events --field-selector type=Warning -o custom-columns=POD:.involvedObject.name,REASON:.reason,MSG:.message
  echo "p-env-opt COLOR=[$(kubectl exec p-env-opt -- printenv COLOR)]"
  kubectl exec p-vol-opt -- ls -la /etc/optcfg
  POD REASON MSG
  p-env-nocm Failed Error: configmap "later" not found
  p-env-nokey Failed Error: couldn't find key nokey in ConfigMap cfg/live
  p-vol-nocm FailedMount MountVolume.SetUp failed for volume "cfg" : configmap "later" not found
  command terminated with exit code 1
  p-env-opt COLOR=[]
  total 12
  drwxrwxrwx 3 root root 4096 Oct 13 00:11 .
  drwxr-xr-x 1 root root 4096 Oct 13 00:11 ..
  drwxr-xr-x 2 root root 4096 Oct 13 00:11 ..2026_10_13_00_11_00.1563719441
  lrwxrwxrwx 1 root root 32 Oct 13 00:11 ..data -> ..2026_10_13_00_11_00.1563719441
  ubuntu@master:~/cfg-lab$
ubuntu@master:~/cfg-lab$

ubuntu@master:~/cfg-lab$ kubectl create configmap later --from-literal=color=green
t0=$(date +%s)
for i in $(seq 1 24); do
  a=$(kubectl get pod p-env-nocm --no-headers | awk '{print $2, $3}')
  b=$(kubectl get pod p-vol-nocm --no-headers | awk '{print $2, $3}')
  c=$(kubectl get pod p-env-nokey --no-headers | awk '{print $2, $3}')
  echo "t+$(( $(date +%s) - t0 ))s  env-nocm=[$a] vol-nocm=[$b] env-nokey=[$c]"
sleep 5
done
kubectl exec p-env-nocm -- printenv COLOR
kubectl exec p-vol-nocm -- cat /etc/later/color
configmap/later created
t+0s env-nocm=[0/1 CreateContainerConfigError] vol-nocm=[0/1 ContainerCreating] env-nokey=[0/1 CreateContainerConfigError]
t+5s env-nocm=[1/1 Running] vol-nocm=[0/1 ContainerCreating] env-nokey=[0/1 CreateContainerConfigError]
t+10s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+16s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+21s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+26s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+31s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+36s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+42s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+47s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+52s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+57s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+63s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+68s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+73s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+79s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+84s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+89s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+94s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+99s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+105s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+110s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+115s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
t+120s env-nocm=[1/1 Running] vol-nocm=[1/1 Running] env-nokey=[0/1 CreateContainerConfigError]
green
greenubuntu@master:~/cfg-lab$

ubuntu@master:~/cfg-lab$ kubectl patch configmap live --type merge -p '{"data":{"nokey":"now-present"}}'
t0=$(date +%s)
for i in $(seq 1 12); do echo "t+$(( $(date +%s) - t0 ))s  $(kubectl get pod p-env-nokey --no-headers | awk '{print $2, $3}')"; sleep 3; done
kubectl exec p-env-nokey -- printenv COLOR
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: frozen
immutable: true
data:
  color: blue
EOF
kubectl patch configmap frozen --type merge -p '{"data":{"color":"red"}}'
kubectl get configmap frozen -o jsonpath='{.data}{"\n"}'
kubectl delete configmap frozen
configmap/live patched
t+0s  0/1 CreateContainerConfigError
t+3s  1/1 Running
t+6s  1/1 Running
t+9s  1/1 Running
t+12s  1/1 Running
t+15s  1/1 Running
t+18s  1/1 Running
t+21s  1/1 Running
t+24s  1/1 Running
t+27s  1/1 Running
t+30s  1/1 Running
t+33s  1/1 Running
now-present
configmap/frozen created
The ConfigMap "frozen" is invalid: data: Forbidden: field is immutable when `immutable` is set
{"color":"blue"}
configmap "frozen" deleted from cfg namespace
ubuntu@master:~/cfg-lab$

ubuntu@master:~/cfg-lab$ cd ~/cfg-lab
kubectl create secret generic db-pass --from-literal=password='S3cr3t-demo'
kubectl get secret db-pass
kubectl get secret db-pass -o jsonpath='{.data}{"\n"}'
echo "decoded: $(kubectl get secret db-pass -o jsonpath='{.data.password}' | base64 -d)"
kubectl describe secret db-pass | tail -6
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
name: via-stringdata
type: Opaque
stringData:
password: Another-demo
EOF
kubectl get secret via-stringdata -o jsonpath='{.data}{"\n"}'
kubectl get secret via-stringdata -o jsonpath='{.metadata.annotations}{"\n"}'
secret/db-pass created
NAME TYPE DATA AGE
db-pass Opaque 1 0s
{"password":"UzNjcjN0LWRlbW8="}
decoded: S3cr3t-demo

Type: Opaque

# Data

password: 11 bytes
secret/via-stringdata created
{"password":"QW5vdGhlci1kZW1v"}
{"kubectl.kubernetes.io/last-applied-configuration":"{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"annotations\":{},\"name\":\"via-stringdata\",\"namespace\":\"cfg\"},\"stringData\":{\"password\":\"Another-demo\"},\"type\":\"Opaque\"}\n"}
ubuntu@master:~/cfg-lab$

ubuntu@master:~/cfg-lab$ cd ~/cfg-lab
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
name: sec-demo
spec:
terminationGracePeriodSeconds: 1
containers:

- name: app
  image: busybox
  command: ["sh", "-c", "sleep 3600"]
  env:
  - name: PASS_ENV
    valueFrom:
    secretKeyRef:
    name: db-pass
    key: password
    volumeMounts:
  - name: sec
    mountPath: /etc/sec
    readOnly: true
    volumes:
- name: sec
  secret:
  secretName: db-pass
  EOF
  kubectl wait --for=condition=Ready pod/sec-demo --timeout=60s
  echo "env: $(kubectl exec sec-demo -- printenv PASS_ENV)"
echo "file: $(kubectl exec sec-demo -- cat /etc/sec/password)"
kubectl exec sec-demo -- ls -la /etc/sec
kubectl exec sec-demo -- ls -laL /etc/sec/password
echo "--- the Secret volume:"
kubectl exec sec-demo -- sh -c 'mount | grep /etc/sec'
echo "--- the ConfigMap volume of cm-demo:"
kubectl exec cm-demo -- sh -c 'mount | grep /etc/cfg'
kubectl describe pod sec-demo | grep -A1 PASS_ENV
pod/sec-demo created
pod/sec-demo condition met
env: S3cr3t-demo
file: S3cr3t-demo
total 4
drwxrwxrwt    3 root     root           100 Oct 13 14:50 .
drwxr-xr-x    1 root     root          4096 Oct 13 14:50 ..
drwxr-xr-x    2 root     root            60 Oct 13 14:50 ..2026_10_13_14_50_23.3112609812
lrwxrwxrwx    1 root     root            32 Oct 13 14:50 ..data -> ..2026_10_13_14_50_23.3112609812
lrwxrwxrwx    1 root     root            15 Oct 13 14:50 password -> ..data/password
-rw-r--r--    1 root     root            11 Oct 13 14:50 /etc/sec/password
--- the Secret volume:
tmpfs on /etc/sec type tmpfs (ro,relatime,size=1845584k,inode64,noswap)
--- the ConfigMap volume of cm-demo:
/dev/sda1 on /etc/cfg type ext4 (ro,relatime,discard,errors=remount-ro,commit=30)
      PASS_ENV:  <set to the key 'password' in secret 'db-pass'>  Optional: false
    Mounts:
ubuntu@master:~/cfg-lab$

ubuntu@master:~/cfg-lab$ cd ~/cfg-lab
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
name: sec-demo
spec:
terminationGracePeriodSeconds: 1
containers:

- name: app
  image: busybox
  command: ["sh", "-c", "sleep 3600"]
  env:
  - name: PASS_ENV
    valueFrom:
    secretKeyRef:
    name: db-pass
    key: password
    volumeMounts:
  - name: sec
    mountPath: /etc/sec
    readOnly: true
    volumes:
- name: sec
  secret:
  secretName: db-pass
  EOF
  kubectl wait --for=condition=Ready pod/sec-demo --timeout=60s
  echo "env: $(kubectl exec sec-demo -- printenv PASS_ENV)"
echo "file: $(kubectl exec sec-demo -- cat /etc/sec/password)"
kubectl exec sec-demo -- ls -la /etc/sec
kubectl exec sec-demo -- ls -laL /etc/sec/password
echo "--- the Secret volume:"
kubectl exec sec-demo -- sh -c 'mount | grep /etc/sec'
echo "--- the ConfigMap volume of cm-demo:"
kubectl exec cm-demo -- sh -c 'mount | grep /etc/cfg'
kubectl describe pod sec-demo | grep -A1 PASS_ENV
pod/sec-demo created
pod/sec-demo condition met
env: S3cr3t-demo
file: S3cr3t-demo
total 4
drwxrwxrwt    3 root     root           100 Oct 13 14:50 .
drwxr-xr-x    1 root     root          4096 Oct 13 14:50 ..
drwxr-xr-x    2 root     root            60 Oct 13 14:50 ..2026_10_13_14_50_23.3112609812
lrwxrwxrwx    1 root     root            32 Oct 13 14:50 ..data -> ..2026_10_13_14_50_23.3112609812
lrwxrwxrwx    1 root     root            15 Oct 13 14:50 password -> ..data/password
-rw-r--r--    1 root     root            11 Oct 13 14:50 /etc/sec/password
--- the Secret volume:
tmpfs on /etc/sec type tmpfs (ro,relatime,size=1845584k,inode64,noswap)
--- the ConfigMap volume of cm-demo:
/dev/sda1 on /etc/cfg type ext4 (ro,relatime,discard,errors=remount-ro,commit=30)
      PASS_ENV:  <set to the key 'password' in secret 'db-pass'>  Optional: false
    Mounts:
ubuntu@master:~/cfg-lab$ EC="sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"
  $EC get /registry/secrets/cfg/db-pass | tr -c '[:print:]\n' '.' | head -c 400; echo
echo "--- first 4 bytes of the stored value:"
$EC get /registry/secrets/cfg/db-pass --print-value-only | head -c 4 | od -c | head -1
  echo "plaintext 'S3cr3t-demo' occurrences: $($EC get /registry/secrets/cfg/db-pass --print-value-only | grep -a -o 'S3cr3t-demo' | wc -l)"
  echo "base64 'UzNjcjN0LWRlbW8=' occurrences: $($EC get /registry/secrets/cfg/db-pass --print-value-only | grep -a -o 'UzNjcjN0LWRlbW8=' | wc -l)"
  echo "via-stringdata, plaintext 'Another-demo': $($EC get /registry/secrets/cfg/via-stringdata --print-value-only | grep -a -o 'Another-demo' | wc -l)"
  $EC get /registry/configmaps/cfg/live | tr -c '[:print:]\n' '.' | head -c 300; echo
echo "--- encryption at rest configured?"
sudo grep -c encryption-provider-config /etc/kubernetes/manifests/kube-apiserver.yaml
sudo ls -l /etc/kubernetes/pki/etcd/server.key
/registry/secrets/cfg/db-pass
k8s.
.
.v1..Secret...
..
.db-pass....cfg".*$cab3a20e-4776-40af-8c1b-1973fdb07bba2.8.B...........e
  .kubectl-create..Update..v1".........2.FieldsV1:1
  /{"f:data":{".":{},"f:password":{}},"f:type":{}}B...
  .password..S3cr3t-demo..Opaque..".

--- first 4 bytes of the stored value:
0000000 k 8 s \0
plaintext 'S3cr3t-demo' occurrences: 1
base64 'UzNjcjN0LWRlbW8=' occurrences: 0
via-stringdata, plaintext 'Another-demo': 2
/registry/configmaps/cfg/live
k8s.
.
.v1..ConfigMap...
..
.live....cfg".\*$d21c0ccf-d27a-4b04-a149-a2d1027128f12.8.B...........C
.kubectl-create..Update..v1".........2.FieldsV1:.
.{"f:data":{}}B...[
.kubectl-patch..Update..v1".........2.FieldsV1:(
&{"f:data":{"f:color":{},"f:nokey":{}}}B...
.color..r
--- encryption at rest configured?
0
-rw------- 1 root root 1679 Oct  7 17:16 /etc/kubernetes/pki/etcd/server.key
ubuntu@master:~/cfg-lab$ sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key snapshot save /tmp/leak-test.db 2>&1 | tail -1
echo "plaintext 'S3cr3t-demo' in the snapshot: $(sudo grep -a -o 'S3cr3t-demo' /tmp/leak-test.db | wc -l)"
sudo ls -l /tmp/leak-test.db
sudo rm -f /tmp/leak-test.db
ls /tmp/leak-test.db 2>&1
Server version 3.6.0
plaintext 'S3cr3t-demo' in the snapshot: 1
-rw------- 1 root root 3797024 Oct 13 08:01 /tmp/leak-test.db
ls: cannot access '/tmp/leak-test.db': No such file or directory
ubuntu@master:~/cfg-lab$

ubuntu@master:~/cfg-lab$ cd ~/cfg-lab
kubectl create serviceaccount lister
kubectl create role secret-lister --verb=list --resource=secrets
kubectl create rolebinding lister-binding --role=secret-lister --serviceaccount=cfg:lister
L=system:serviceaccount:cfg:lister
echo "may get secrets: $(kubectl auth can-i get secrets --as=$L)"
echo "may list secrets: $(kubectl auth can-i list secrets --as=$L)"
kubectl get secret db-pass --as=$L
kubectl get secrets --as=$L -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.data}{"\n"}{end}'
serviceaccount/lister created
role.rbac.authorization.k8s.io/secret-lister created
rolebinding.rbac.authorization.k8s.io/lister-binding created
may get secrets: no
may list secrets: yes
Error from server (Forbidden): secrets "db-pass" is forbidden: User "system:serviceaccount:cfg:lister" cannot get resource "secrets" in API group "" in the namespace "cfg"
db-pass {"password":"UzNjcjN0LWRlbW8="}
via-stringdata {"password":"QW5vdGhlci1kZW1v"}
ubuntu@master:~/cfg-lab$ cd ~/cfg-lab
kubectl create serviceaccount podmaker
kubectl create role pod-maker --verb=create,get --resource=pods,pods/log
kubectl create rolebinding podmaker-binding --role=pod-maker --serviceaccount=cfg:podmaker
M=system:serviceaccount:cfg:podmaker
echo "may get secrets: $(kubectl auth can-i get secrets --as=$M)"
echo "may list secrets: $(kubectl auth can-i list secrets --as=$M)"
kubectl get secret db-pass --as=$M
kubectl apply --as=$M -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
name: peek
spec:
restartPolicy: Never
terminationGracePeriodSeconds: 1
containers:

- name: app
  image: busybox
  command: ["sh", "-c", "cat /etc/sec/password; echo"]
  volumeMounts:
  - name: sec
    mountPath: /etc/sec
    volumes:
- name: sec
  secret:
  secretName: db-pass
  EOF
  sleep 10
  kubectl get pod peek --as=$M
kubectl logs peek --as=$M
  serviceaccount/podmaker created
  role.rbac.authorization.k8s.io/pod-maker created
  rolebinding.rbac.authorization.k8s.io/podmaker-binding created
  may get secrets: no
  may list secrets: no
  Error from server (Forbidden): secrets "db-pass" is forbidden: User "system:serviceaccount:cfg:podmaker" cannot get resource "secrets" in API group "" in the namespace "cfg"
  pod/peek created
  NAME READY STATUS RESTARTS AGE
  peek 0/1 Completed 0 10s
  S3cr3t-demo
  ubuntu@master:~/cfg-lab$
