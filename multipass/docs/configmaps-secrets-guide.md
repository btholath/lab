# Kubernetes ConfigMaps and Secrets

## Creating them, using them, what happens when they change or go missing, and what a Secret really protects, tested on a real cluster

**ConfigMaps** and **Secrets** carry configuration into pods. This guide creates both in several ways, measures what a pod sees when they change, breaks them on purpose, and then reads a Secret straight out of etcd. It was run on a real kubeadm cluster (1 control plane, 2 workers, Kubernetes v1.36.5). The console output after each lab is copied from the run. Where a prediction was wrong, the guide says so, and explanations marked as inferences are best guesses, not results. The credentials used are invented demonstration strings.

**Contents**

1. ConfigMap and Secret side by side
2. Four ways to create a ConfigMap
3. Environment variables against volumes
4. Missing ConfigMaps and keys
5. Immutable ConfigMaps
6. Secrets: encoding, and a trap in `kubectl apply`
7. Using a Secret in a pod
8. A Secret in etcd, and in a backup
9. Who can read a Secret
10. Practical guidance
11. Practical tips for running these labs
12. Troubleshooting
13. Command cheat sheet
14. Glossary
15. What was run, and what was not

---

# 1. ConfigMap and Secret side by side

| | ConfigMap | Secret |
|---|---|---|
| For | Non-confidential settings | Credentials, keys, tokens |
| Stored as | Plain text in the object | **Base64** in the object |
| Used by a pod as | Environment variables, or files in a mounted volume | The same |
| A volume is backed by | The node's **disk** (observed) | **Memory**, as `tmpfs` (observed) |
| Updated in a running pod | A volume updates after a delay. An environment variable and a `subPath` mount never do | The same rules |
| `view` role | Included | **Not included** (the RBAC guide) |

---

# 2. Four ways to create a ConfigMap

```bash
kubectl create namespace cfg
kubectl config set-context --current --namespace=cfg
mkdir -p ~/cfg-lab && cd ~/cfg-lab
printf 'log_level=info\nmode=demo\n' > app.properties
printf 'DB_HOST=db.local\nDB_PORT=5432\n' > db.env
kubectl create configmap from-literal --from-literal=color=blue --from-literal=size=large
kubectl create configmap from-file --from-file=app.properties
kubectl create configmap from-file-key --from-file=settings=app.properties
kubectl create configmap from-envfile --from-env-file=db.env
kubectl get configmaps
for c in from-literal from-file from-file-key from-envfile; do echo "== $c"; kubectl get configmap $c -o jsonpath='{.data}{"\n"}'; done
```

### Observed on the real cluster

```text
-rw-rw-r-- 1 ubuntu ubuntu 25 Oct 12 16:53 app.properties
-rw-rw-r-- 1 ubuntu ubuntu 30 Oct 12 16:53 db.env

NAME               DATA   AGE
from-envfile       2      0s
from-file          1      0s
from-file-key      1      0s
from-literal       2      0s
kube-root-ca.crt   1      75s

== from-literal
{"color":"blue","size":"large"}
== from-file
{"app.properties":"log_level=info\nmode=demo\n"}
== from-file-key
{"settings":"log_level=info\nmode=demo\n"}
== from-envfile
{"DB_HOST":"db.local","DB_PORT":"5432"}
```

| Source | What becomes a key |
|---|---|
| `--from-literal` | The key you write |
| `--from-file=FILE` | The **file name**, with the whole file as one value |
| `--from-file=KEY=FILE` | The key **you choose**, with the whole file as the value |
| `--from-env-file=FILE` | **Each line**, as its own key and value |

That choice decides how a pod can use the data later. In `from-file`, the value ends with a newline (`\n`), which matters when a program compares it with a string.

`kube-root-ca.crt` was **75 seconds old** while the four you created were 0 seconds, and you had created the namespace about 75 seconds earlier. So it appeared **by itself, when the namespace was created**. As I recall it, a controller publishes the cluster's CA certificate into every namespace so pods can verify the API server. I haven't verified which controller does it.

---

# 3. Environment variables against volumes

When a ConfigMap changes, does a running pod notice? It depends on **how** the pod consumes it. One pod uses it three ways: an environment variable, a mounted volume, and a mount of a single key through `subPath`.

```bash
cd ~/cfg-lab
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
echo "env=$(kubectl exec cm-demo -- printenv COLOR_ENV)  file=$(kubectl exec cm-demo -- cat /etc/cfg/color)  subpath=$(kubectl exec cm-demo -- cat /etc/color-subpath)"
kubectl exec cm-demo -- ls -la /etc/cfg
```

The `terminationGracePeriodSeconds: 1` is deliberate: the container's main process is a shell, which ignores the termination signal, so the default would make deleting the pod take 30 seconds (the probes guide).

### Observed on the real cluster

```text
env=blue  file=blue  subpath=blue
drwxrwxrwx    3 root     root          4096 Oct 12 23:59 .
drwxr-xr-x    2 root     root          4096 Oct 12 23:59 ..2026_10_12_23_59_41.2509085303
lrwxrwxrwx    1 root     root            32 Oct 12 23:59 ..data -> ..2026_10_12_23_59_41.2509085303
lrwxrwxrwx    1 root     root            12 Oct 12 23:59 color -> ..data/color
```

The mounted files are **symlinks** into a timestamped directory, reached through `..data`. Now change the ConfigMap, and poll:

```bash
kubectl patch configmap live --type merge -p '{"data":{"color":"red"}}'
t0=$(date +%s)
for i in $(seq 1 30); do
  f=$(kubectl exec cm-demo -- cat /etc/cfg/color)
  s=$(kubectl exec cm-demo -- cat /etc/color-subpath)
  e=$(kubectl exec cm-demo -- printenv COLOR_ENV)
  echo "t+$(( $(date +%s) - t0 ))s  file=$f  subpath=$s  env=$e"
  sleep 4
done
kubectl exec cm-demo -- ls -la /etc/cfg
```

### Observed on the real cluster

```text
t+1s    file=blue  subpath=blue  env=blue
t+39s   file=blue  subpath=blue  env=blue
t+44s   file=red   subpath=blue  env=blue
[... file=red subpath=blue env=blue until t+125s ...]

drwxr-xr-x    2 root     root          4096 Oct 13 00:07 ..2026_10_13_00_07_12.1676845679
lrwxrwxrwx    1 root     root            32 Oct 13 00:07 ..data -> ..2026_10_13_00_07_12.1676845679
lrwxrwxrwx    1 root     root            12 Oct 12 23:59 color -> ..data/color
```

| Item | Predicted | Observed |
|---|---|---|
| The mounted file | Turns red after 10 to 90 s | **Red at `t+44s`**, still blue at `t+39s`: about **40 to 44 seconds** |
| The `subPath` file | Stays `blue` | **`blue` for all 125 seconds** |
| The environment variable | Stays `blue` | **`blue` for all 125 seconds** |
| `ls -la` after | `..data` points to a different directory | **Yes**: a new directory stamped `00:07:12`, and the old directory is gone |

The update is a **symlink swap**: only `..data` was repointed, while the `color` symlink (still dated `23:59`) never changed. A program reading the file sees either the whole old content or the whole new content, never a half-written file. That is my reading of the design, and the listing matches it.

The delay was about 40 seconds on this cluster. As I recall it, the delay on a default kubelet is "up to about a minute plus", so treat 40 s as one measurement and not a constant. And if your application reads a file only at startup, it won't notice the change either, whatever the volume does.

After a restart, all three agree:

```text
$ kubectl delete pod cm-demo ; kubectl apply -f cm-demo.yaml ; kubectl wait ...
env=red  file=red  subpath=red
```

| Consumed as | Updates in a running pod? |
|---|---|
| A **volume** | **Yes**, after a delay (about 40 s here) |
| A **`subPath`** mount | **No**, never |
| An **environment variable** | **No**: it is fixed when the container starts |

---

# 4. Missing ConfigMaps and keys

What does a pod do when the ConfigMap it names doesn't exist, or lacks the key? Five pods:

| Pod | What is wrong |
|---|---|
| `p-env-nocm` | An environment variable from ConfigMap `later`, which doesn't exist yet |
| `p-vol-nocm` | A volume from ConfigMap `later`, which doesn't exist yet |
| `p-env-nokey` | An environment variable from `live`, whose key `nokey` doesn't exist |
| `p-env-opt` | A missing ConfigMap `nope`, marked `optional: true` |
| `p-vol-opt` | A missing ConfigMap `nope` as a volume, marked `optional: true` |

```bash
cd ~/cfg-lab
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
    env:
    - name: COLOR
      valueFrom:
        configMapKeyRef:
          name: live
          key: nokey
---
apiVersion: v1
kind: Pod
metadata:
  name: p-env-opt
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
          name: nope
          key: color
          optional: true
---
apiVersion: v1
kind: Pod
metadata:
  name: p-vol-opt
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: cfg
      mountPath: /etc/optcfg
  volumes:
  - name: cfg
    configMap:
      name: nope
      optional: true
EOF
kubectl apply -f block3.yaml
sleep 40
kubectl get pods
kubectl get events --field-selector type=Warning -o custom-columns=POD:.involvedObject.name,REASON:.reason,MSG:.message
echo "p-env-opt  COLOR=[$(kubectl exec p-env-opt -- printenv COLOR)]"
kubectl exec p-vol-opt -- ls -la /etc/optcfg
```

### Observed on the real cluster

```text
NAME          READY   STATUS                       RESTARTS   AGE
p-env-nocm    0/1     CreateContainerConfigError   0          40s
p-env-nokey   0/1     CreateContainerConfigError   0          40s
p-env-opt     1/1     Running                      0          40s
p-vol-nocm    0/1     ContainerCreating            0          40s
p-vol-opt     1/1     Running                      0          40s

POD           REASON        MSG
p-env-nocm    Failed        Error: configmap "later" not found
p-env-nokey   Failed        Error: couldn't find key nokey in ConfigMap cfg/live
p-vol-nocm    FailedMount   MountVolume.SetUp failed for volume "cfg" : configmap "later" not found

command terminated with exit code 1
p-env-opt  COLOR=[]
drwxr-xr-x    2 root     root          4096 Oct 13 00:11 ..2026_10_13_00_11_00.1563719441
lrwxrwxrwx    1 root     root            32 Oct 13 00:11 ..data -> ..2026_10_13_00_11_00.1563719441
```

| Pod | Predicted | Observed |
|---|---|---|
| `p-env-nocm`, `p-env-nokey` | `CreateContainerConfigError` | **Exactly that**, with the `Failed` events above |
| `p-vol-nocm` | `ContainerCreating`, with `FailedMount` | **Exactly that**: my guessed wording matched |
| `p-env-opt` | Running, variable unset | **Running**, and `printenv` exits with status 1 because the variable is absent |
| `p-vol-opt` | Running, with an empty directory | **Running**, but not quite empty: the timestamped directory and the `..data` symlink exist, with **no key files** |

The two failure kinds differ on purpose. A bad **environment reference** fails when the container is created (`CreateContainerConfigError`, event reason `Failed`), and a bad **volume** fails earlier, while the pod's volumes are being set up (`ContainerCreating`, event reason `FailedMount`). Check which one you are looking at before you debug. An `optional: true` reference lets the pod start without the data, with the variable absent or the directory empty.

## The pods recover by themselves

Create the missing ConfigMap, and watch:

```bash
kubectl create configmap later --from-literal=color=green
t0=$(date +%s)
for i in $(seq 1 24); do
  a=$(kubectl get pod p-env-nocm --no-headers | awk '{print $2, $3}')
  b=$(kubectl get pod p-vol-nocm --no-headers | awk '{print $2, $3}')
  c=$(kubectl get pod p-env-nokey --no-headers | awk '{print $2, $3}')
  echo "t+$(( $(date +%s) - t0 ))s  env-nocm=[$a]  vol-nocm=[$b]  env-nokey=[$c]"
  sleep 5
done
kubectl exec p-env-nocm -- printenv COLOR
kubectl exec p-vol-nocm -- cat /etc/later/color
```

### Observed on the real cluster

```text
t+0s    env-nocm=[0/1 CreateContainerConfigError]  vol-nocm=[0/1 ContainerCreating]  env-nokey=[0/1 CreateContainerConfigError]
t+5s    env-nocm=[1/1 Running]                     vol-nocm=[0/1 ContainerCreating]  env-nokey=[0/1 CreateContainerConfigError]
t+10s   env-nocm=[1/1 Running]                     vol-nocm=[1/1 Running]            env-nokey=[0/1 CreateContainerConfigError]
[... env-nokey still broken at t+120s ...]
green
green
```

| Item | Predicted | Observed |
|---|---|---|
| Both recover without being touched | Within 5 to 90 s | **`p-env-nocm` within 5 s, `p-vol-nocm` within 10 s**: at the fast end of my range |
| `p-env-nokey` stays broken | Yes | **Yes**, for the whole 120 s |

The kubelet retried by itself: no pod was restarted, recreated or touched. A pod with a missing **key** stays stuck until the key exists. Adding it:

```bash
kubectl patch configmap live --type merge -p '{"data":{"nokey":"now-present"}}'
```

made `p-env-nokey` `Running` within 3 seconds, and `printenv COLOR` printed `now-present`.

---

# 5. Immutable ConfigMaps

```bash
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
```

### Observed on the real cluster

```text
configmap/frozen created
The ConfigMap "frozen" is invalid: data: Forbidden: field is immutable when `immutable` is set
{"color":"blue"}
configmap "frozen" deleted from cfg namespace
```

The patch was refused, and the value is unchanged. As I recall it, the only way to change an immutable ConfigMap is to delete and recreate it. The reason it exists, as I recall the documentation, is that the cluster can stop watching an immutable object, and a bad edit can't reach every pod at once. I haven't measured the watch load. Secrets can be immutable in the same way (untested).

---

# 6. Secrets: encoding, and a trap in `kubectl apply`

```bash
cd ~/cfg-lab
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
```

### Observed on the real cluster

```text
NAME      TYPE     DATA   AGE
db-pass   Opaque   1      0s
{"password":"UzNjcjN0LWRlbW8="}
decoded: S3cr3t-demo

Type:  Opaque

Data
====
password:  11 bytes

secret/via-stringdata created
{"password":"QW5vdGhlci1kZW1v"}
{"kubectl.kubernetes.io/last-applied-configuration":"{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"annotations\":{},\"name\":\"via-stringdata\",\"namespace\":\"cfg\"},\"stringData\":{\"password\":\"Another-demo\"},\"type\":\"Opaque\"}\n"}
```

| Item | Observed |
|---|---|
| `.data` | **`UzNjcjN0LWRlbW8=`**: base64, and the value matched the one I computed in advance |
| `decoded:` | **`S3cr3t-demo`**, with no key of any kind |
| `describe secret` | Shows the key and its **size** (`11 bytes`), not the value. That is a courtesy, not security |
| `stringData` | Converted to base64 `data` on the way in, and never stored under that name |
| **The annotation** | **`"stringData":{"password":"Another-demo"}` in plaintext** |

**Base64 is an encoding, not protection.** The only thing keeping the value from a reader is the access control in front of it.

**The `apply` trap:** `kubectl apply` stores your original manifest in the `last-applied-configuration` annotation, so a Secret created from a manifest with `stringData` carries a **plaintext copy** next to the base64 `data`. Anything that shows metadata but redacts `data` still reveals the value. Create Secrets with `kubectl create secret`, or accept the annotation knowingly.

---

# 7. Using a Secret in a pod

```bash
cd ~/cfg-lab
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
kubectl exec sec-demo -- sh -c 'mount | grep /etc/sec'
kubectl exec cm-demo -- sh -c 'mount | grep /etc/cfg'
kubectl describe pod sec-demo | grep -A1 PASS_ENV
```

### Observed on the real cluster

```text
env: S3cr3t-demo
file: S3cr3t-demo
drwxrwxrwt    3 root     root           100 Oct 13 14:50 .
drwxr-xr-x    2 root     root            60 Oct 13 14:50 ..2026_10_13_14_50_23.3112609812
lrwxrwxrwx    1 root     root            32 Oct 13 14:50 ..data -> ..2026_10_13_14_50_23.3112609812
lrwxrwxrwx    1 root     root            15 Oct 13 14:50 password -> ..data/password
-rw-r--r--    1 root     root            11 Oct 13 14:50 /etc/sec/password

tmpfs on /etc/sec type tmpfs (ro,relatime,size=1845584k,inode64,noswap)
/dev/sda1 on /etc/cfg type ext4 (ro,relatime,discard,errors=remount-ro,commit=30)
      PASS_ENV:  <set to the key 'password' in secret 'db-pass'>  Optional: false
```

| Item | Predicted | Observed |
|---|---|---|
| `env` and `file` | Both the real value | **Both `S3cr3t-demo`**: the container gets the plaintext |
| The file's mode | `0644` | **`-rw-r--r--`**, 11 bytes (the length of `S3cr3t-demo`) |
| **The Secret volume** | `tmpfs` | **`tmpfs`**: it lives in **memory** |
| **The ConfigMap volume** | Disk-backed | **`/dev/sda1 ... ext4`**: it lives on the node's **disk** |
| `describe pod` | The reference, not the value | **`<set to the key 'password' in secret 'db-pass'>`** |

- **A mounted Secret never touches the node's disk**, while a ConfigMap volume is written to it. That is one reason to put credentials in a Secret and not in a ConfigMap. The directories tell the same story: the Secret's is `drwxrwxrwt` (a sticky bit, as `tmpfs` roots have), and the ConfigMap's was `drwxrwxrwx`.
- **The file is world-readable inside the container** (`0644`). That is the default, and `defaultMode` on the volume can tighten it. I did not test that.
- `size=1845584k` equals a worker's allocatable memory from the scheduling guide. I take it to be a cap and not a reservation, but I didn't confirm which node ran the pod, nor the rule.
- **The protection is in what is visible outside the container**: `describe pod` shows only the reference.

---

# 8. A Secret in etcd, and in a backup

The API server stores every object in etcd. This reads the Secret straight out of the database, with the tools from the etcd backup labs. `tr` turns unprintable bytes into dots, so the binary storage format can't mangle your terminal:

```bash
EC="sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"
$EC get /registry/secrets/cfg/db-pass | tr -c '[:print:]\n' '.' | head -c 400; echo
$EC get /registry/secrets/cfg/db-pass --print-value-only | head -c 4 | od -c | head -1
echo "plaintext 'S3cr3t-demo' occurrences: $($EC get /registry/secrets/cfg/db-pass --print-value-only | grep -a -o 'S3cr3t-demo' | wc -l)"
echo "base64 'UzNjcjN0LWRlbW8=' occurrences: $($EC get /registry/secrets/cfg/db-pass --print-value-only | grep -a -o 'UzNjcjN0LWRlbW8=' | wc -l)"
echo "via-stringdata, plaintext 'Another-demo': $($EC get /registry/secrets/cfg/via-stringdata --print-value-only | grep -a -o 'Another-demo' | wc -l)"
sudo grep -c encryption-provider-config /etc/kubernetes/manifests/kube-apiserver.yaml
sudo ls -l /etc/kubernetes/pki/etcd/server.key
```

### Observed on the real cluster

```text
/registry/secrets/cfg/db-pass
k8s.
.v1..Secret...
.db-pass....cfg".*$cab3a20e-...
.kubectl-create..Update..v1"...FieldsV1:1
/{"f:data":{".":{},"f:password":{}},"f:type":{}}B...
.password..S3cr3t-demo..Opaque..".

0000000   k   8   s  \0
plaintext 'S3cr3t-demo' occurrences: 1
base64 'UzNjcjN0LWRlbW8=' occurrences: 0
via-stringdata, plaintext 'Another-demo': 2
0
-rw------- 1 root root 1679 Oct  7 17:16 /etc/kubernetes/pki/etcd/server.key
```

| Item | Predicted | Observed |
|---|---|---|
| The stored value | Plaintext | **`S3cr3t-demo`** in the readable bytes |
| The first bytes | `k8s\0`, no encryption prefix | **`k   8   s  \0`** |
| The base64 occurrences | **0** | **0**: the base64 in `kubectl get` is how the API **presents** the bytes, not how they are stored |
| `Another-demo` | 2 | **2**: the raw value, and the plaintext annotation |
| Encryption at rest | Not configured | **`0`** matches of `encryption-provider-config` |
| `server.key` | Root only | **`-rw-------`, root** |

So on this cluster a Secret is stored in etcd as **plaintext**. Anyone who can read etcd (root on the master, with the client key) reads every Secret. A ConfigMap is stored the same way, with names and values readable. The stored bytes also include `managedFields`, which records which tool set which field, not values. `server.key` is dated the minute of the upgrade, which suggests the key was regenerated when the certificates were renewed (an inference).

## A backup holds the same plaintext

A snapshot contains every object, so it should hold the Secret in plaintext. This takes one, searches it **without printing it**, and deletes it at once:

```bash
sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key snapshot save /tmp/leak-test.db 2>&1 | tail -1
echo "plaintext 'S3cr3t-demo' in the snapshot: $(sudo grep -a -o 'S3cr3t-demo' /tmp/leak-test.db | wc -l)"
sudo ls -l /tmp/leak-test.db
sudo rm -f /tmp/leak-test.db
ls /tmp/leak-test.db 2>&1
```

### Observed on the real cluster

```text
Server version 3.6.0
plaintext 'S3cr3t-demo' in the snapshot: 1
-rw------- 1 root root 3797024 Oct 13 08:01 /tmp/leak-test.db
ls: cannot access '/tmp/leak-test.db': No such file or directory
```

The count is 1: **a snapshot holds the Secret in plaintext**, so a backup is as sensitive as the cluster. (My prediction that `tail -1` would show `Snapshot saved at ...` was wrong: `etcdctl` prints the "saved" line first, so the last line was the version.)

One general caution that was **not tested**: encryption at rest would protect the etcd files and snapshots, but not a request through the API. The API server decrypts for anyone authorized to `get` a Secret, so access control stays the main protection either way.

---

# 9. Who can read a Secret

The RBAC guide showed that `view` leaves Secrets out. Two ways to read one without being allowed to `get` it, tested with service accounts and impersonation:

```bash
cd ~/cfg-lab
kubectl create serviceaccount lister
kubectl create role secret-lister --verb=list --resource=secrets
kubectl create rolebinding lister-binding --role=secret-lister --serviceaccount=cfg:lister
L=system:serviceaccount:cfg:lister
echo "may get secrets:  $(kubectl auth can-i get secrets --as=$L)"
echo "may list secrets: $(kubectl auth can-i list secrets --as=$L)"
kubectl get secret db-pass --as=$L
kubectl get secrets --as=$L -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.data}{"\n"}{end}'
```

### Observed on the real cluster

```text
may get secrets:  no
may list secrets: yes
Error from server (Forbidden): secrets "db-pass" is forbidden: User "system:serviceaccount:cfg:lister" cannot get resource "secrets" in API group "" in the namespace "cfg"
db-pass  {"password":"UzNjcjN0LWRlbW8="}
via-stringdata  {"password":"QW5vdGhlci1kZW1v"}
```

**`list` returns every whole object, values included**, so a rule that grants only `list` (or `watch`) on Secrets is effectively a rule to read them.

## Creating a pod is enough

A role that can create pods and read their logs, with **no rule for Secrets at all**:

```bash
cd ~/cfg-lab
kubectl create serviceaccount podmaker
kubectl create role pod-maker --verb=create,get --resource=pods,pods/log
kubectl create rolebinding podmaker-binding --role=pod-maker --serviceaccount=cfg:podmaker
M=system:serviceaccount:cfg:podmaker
echo "may get secrets:  $(kubectl auth can-i get secrets --as=$M)"
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
```

### Observed on the real cluster

```text
may get secrets:  no
may list secrets: no
Error from server (Forbidden): secrets "db-pass" is forbidden: User "system:serviceaccount:cfg:podmaker" cannot get resource "secrets" in API group "" in the namespace "cfg"
pod/peek created
NAME   READY   STATUS      RESTARTS   AGE
peek   0/1     Completed   0          10s
S3cr3t-demo
```

`podmaker` was refused when it asked for the Secret directly, yet **read its value** by creating a pod that mounts it. The API server did not check whether the pod's creator may read what the pod mounts. So **in a namespace, the right to create pods is the right to read every Secret in it.** Protecting Secrets means controlling who can create pods there, and not only who can `get` Secrets. As I recall it, the documentation says the same, and I did not try any mitigation (pod security rules, or restricting which Secrets a service account may mount).

---

# 10. Practical guidance

This section collects the lessons. What was observed is marked; the rest is general practice and was **not tested** here.

| Guidance | Basis |
|---|---|
| Treat base64 as formatting, not protection | **Observed** (Section 6) |
| Avoid `kubectl apply` of manifests with plaintext `stringData`: the annotation keeps a copy | **Observed** (Section 6) |
| Treat etcd, and every etcd snapshot, as holding all your Secrets in plaintext | **Observed** (Section 8) |
| Do not grant `list` or `watch` on Secrets casually | **Observed** (Section 9) |
| Remember that **creating pods** reads every Secret in the namespace | **Observed** (Section 9) |
| Mount a Secret as a volume if it must not reach a disk | **Observed** (`tmpfs` against `ext4`) |
| For values that change, use a **volume** and have the application re-read the file. An environment variable or `subPath` never updates | **Observed** (Section 3) |
| Consider encryption at rest for etcd | Not tested: it needs an API-server configuration change and a restart |
| Consider an external secret manager | Not tested |
| Environment variables are easier to leak than files (process listings, crash dumps, `printenv` through `exec`) | General practice, not tested |
| Tighten a Secret volume's file mode with `defaultMode` | Not tested |

---

# 11. Practical tips for running these labs

- **Use invented values.** Every credential in this guide is a demonstration string, and the output of these labs can be pasted safely for that reason.
- **Paste long blocks in pieces.** The terminal wrapped a long manifest and fused two commands into it (`kubectl get pods block3.yamlleep 3600"]`). All five pods were still created correctly.
- **Re-pasting a block is usually harmless, but not always.** A block that creates a ConfigMap fails with `already exists`, and an `apply` says `configured` or `unchanged`.
- **Check the clocks before timed measurements.** `check-clocks.ps1` in the repo found a VM 213.7 seconds behind just before the 40-second ConfigMap measurement, and `-Fix` corrected it.
- **Use `--as` to test access.** It needs no certificates, and your admin rights allow it.

---

# 12. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| A pod is stuck in `CreateContainerConfigError` | An environment reference to a ConfigMap, Secret or key that doesn't exist | `kubectl describe pod` and read `Error: ...`. Create it, or mark the reference `optional: true` |
| A pod is stuck in `ContainerCreating`, with `FailedMount` | A volume refers to a ConfigMap or Secret that doesn't exist | Read the event. It recovers by itself within seconds of the object appearing |
| A pod does not see a changed ConfigMap | It uses an environment variable or a `subPath` | Restart the pod, or use a plain volume and re-read the file |
| A mounted file takes a while to change | The kubelet syncs periodically (about 40 s here) | Wait, and make the application re-read the file |
| `field is immutable when `immutable` is set` | The ConfigMap or Secret is immutable | Delete it and recreate it |
| `kubectl describe secret` shows only sizes | It never prints values | Use `-o jsonpath='{.data.KEY}' \| base64 -d` (if you are allowed) |
| A Secret's value appears in a manifest annotation | `kubectl apply` of a manifest with `stringData` | Use `kubectl create secret`, or remove the annotation |
| A user without `get secrets` still reads one | They can `list`/`watch` Secrets, or create pods in the namespace | Review who has those rights |

---

# 13. Command cheat sheet

| Task | Command |
|---|---|
| ConfigMap from a literal | `kubectl create configmap NAME --from-literal=KEY=VALUE` |
| From a file (file name as key) | `kubectl create configmap NAME --from-file=FILE` |
| From a file, choosing the key | `kubectl create configmap NAME --from-file=KEY=FILE` |
| From an env file | `kubectl create configmap NAME --from-env-file=FILE` |
| A Secret from a literal | `kubectl create secret generic NAME --from-literal=KEY=VALUE` |
| The data of a ConfigMap | `kubectl get configmap NAME -o jsonpath='{.data}'` |
| Decode a Secret's value | `kubectl get secret NAME -o jsonpath='{.data.KEY}' \| base64 -d` |
| Change a ConfigMap | `kubectl patch configmap NAME --type merge -p '{"data":{"KEY":"VALUE"}}'` |
| See a pod's mount types | `kubectl exec POD -- sh -c 'mount \| grep /path'` |
| Warning events | `kubectl get events --field-selector type=Warning` |
| Test access as someone else | `kubectl auth can-i get secrets --as=USER` |

---

# 14. Glossary

| Term | Meaning |
|---|---|
| **ConfigMap** | An object holding non-confidential configuration as key-value data |
| **Secret** | An object for credentials, stored as base64 |
| **Base64** | A reversible encoding, not encryption |
| **Volume mount** | A ConfigMap or Secret appears as files in the container |
| **`subPath`** | Mounting one key as a single file. It never receives updates |
| **`optional: true`** | Lets a pod start when the referenced ConfigMap, Secret or key is missing |
| **`immutable`** | Marks an object unchangeable after creation |
| **`stringData`** | A write-only convenience field that becomes base64 `data` |
| **`tmpfs`** | A memory-backed filesystem. Secret volumes use it |
| **Encryption at rest** | Encrypting objects as the API server stores them. Not enabled here |
| **Last-applied annotation** | A copy of the manifest that `kubectl apply` stores on the object |

---

# 15. What was run, and what was not

## Run on the real cluster (the output above is from these)

- Four ways to create a ConfigMap, and the automatic `kube-root-ca.crt`
- An environment variable, a volume and a `subPath` after a change (the 40-second measurement), and a restart
- Five broken or optional references, the two failure kinds with their events, and the automatic recovery
- An immutable ConfigMap, and the refusal to change it
- A Secret: base64, `describe`, `stringData`, and the plaintext annotation
- A Secret as an environment variable and as a volume: its mode, `tmpfs` against `ext4`, and `describe pod`
- A Secret read from etcd (plaintext, no encryption prefix, no base64), the API server's lack of an encryption configuration, and a snapshot holding the plaintext
- Reading a Secret through `list`, and through creating a pod

## Not run

- **Encryption at rest**, and external secret managers
- **`defaultMode` on a Secret volume**, and immutable Secrets
- **Other Secret types** (TLS, Docker registry) and Secrets for service-account tokens
- **Pod security rules and other mitigations** against reading a Secret through a pod
- **How the kubelet's refresh interval is set**: the 40-second delay is one measurement
- **Large ConfigMaps**, and their size limit (I recall 1 MiB)

The explanations marked as inferences in the text (the origin of `kube-root-ca.crt`, the symlink swap, the `size=` of the `tmpfs`, the regenerated `server.key`) are the best fit to the evidence, and not verified. Check the official Kubernetes documentation for the version you run.

## Clean up everything from this guide

```bash
kubectl delete namespace cfg
kubectl config set-context --current --namespace=default
rm -rf ~/cfg-lab
```

The first command removes every ConfigMap, Secret, pod, service account, role and binding from the labs. The second puts your kubeconfig back on the `default` namespace. The third removes the lab files, which held only invented values. The two `.db` snapshot files in your home directory are **not** removed by these commands, and contain every Secret that existed when they were taken.
