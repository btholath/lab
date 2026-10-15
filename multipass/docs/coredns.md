ubuntu@master:~$ cd ~
kubectl -n kube-system get deployment coredns
kubectl -n kube-system get deployment coredns -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system get svc kube-dns
kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'; echo
NAME READY UP-TO-DATE AVAILABLE AGE
coredns 2/2 2 2 8d
registry.k8s.io/coredns/coredns:v1.14.2
NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
coredns-589f44dc88-2tpjr 1/1 Running 0 5d21h 10.244.1.27 worker1 <none> <none>
coredns-589f44dc88-5pt72 1/1 Running 0 5d21h 10.244.0.8 master <none> <none>
NAME TYPE CLUSTER-IP EXTERNAL-IP PORT(S) AGE
kube-dns ClusterIP 10.96.0.10 <none> 53/UDP,53/TCP,9153/TCP 8d
NAME ADDRESSTYPE PORTS ENDPOINTS AGE
kube-dns-ggp9m IPv4 53,53,9153 10.244.0.8,10.244.1.27 8d
.:53 {
errors
health {
lameduck 5s
}
ready
kubernetes cluster.local in-addr.arpa ip6.arpa {
pods insecure
fallthrough in-addr.arpa ip6.arpa
ttl 30
}
prometheus :9153
forward . /etc/resolv.conf {
max_concurrent 1000
}
cache 30 {
disable success cluster.local
disable denial cluster.local
}
loop
reload
loadbalance
}

ubuntu@master:~$ cd ~
kubectl create namespace dns
kubectl config set-context --current --namespace=dns
cat > probe.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
name: probe
spec:
terminationGracePeriodSeconds: 1
containers:

- name: app
  image: busybox
  command: ["sh", "-c", "sleep 3600"]
  EOF
  kubectl apply -f probe.yaml
  kubectl wait --for=condition=Ready pod/probe --timeout=60s
  kubectl exec probe -- cat /etc/resolv.conf
  namespace/dns created
  Context "kubernetes-admin@kubernetes" modified.
  pod/probe created
  pod/probe condition met
  search dns.svc.cluster.local svc.cluster.local cluster.local mshome.net
  nameserver 10.96.0.10
  options ndots:5
  ubuntu@master:~$ for n in kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local kube-dns.kube-system; do echo "$n -> $(kubectl exec probe -- ping -c1 -W1 $n 2>&1 | head -1)"; done
  kubectl exec probe -- nslookup kubernetes.default.svc.cluster.local
  kubectl exec probe -- nslookup kube-dns.kube-system.svc.cluster.local
  kubectl exec probe -- nslookup 10.96.0.10
  kubectl exec probe -- nslookup nosuchname.default.svc.cluster.local
  kubernetes -> ping: bad address 'kubernetes'
  kubernetes.default -> PING kubernetes.default (10.96.0.1): 56 data bytes
  kubernetes.default.svc -> PING kubernetes.default.svc (10.96.0.1): 56 data bytes
  kubernetes.default.svc.cluster.local -> PING kubernetes.default.svc.cluster.local (10.96.0.1): 56 data bytes
  kube-dns.kube-system -> PING kube-dns.kube-system (10.96.0.10): 56 data bytes
  Server: 10.96.0.10
  Address: 10.96.0.10:53

Name: kubernetes.default.svc.cluster.local
Address: 10.96.0.1

Server: 10.96.0.10
Address: 10.96.0.10:53

Name: kube-dns.kube-system.svc.cluster.local
Address: 10.96.0.10

Server: 10.96.0.10
Address: 10.96.0.10:53

10.0.96.10.in-addr.arpa name = kube-dns.kube-system.svc.cluster.local

Server: 10.96.0.10
Address: 10.96.0.10:53

\*\* server can't find nosuchname.default.svc.cluster.local: NXDOMAIN

\*\* server can't find nosuchname.default.svc.cluster.local: NXDOMAIN

command terminated with exit code 1
ubuntu@master:~$

ubuntu@master:~$ cd ~
kubectl -n kube-system get deployment coredns
kubectl -n kube-system get deployment coredns -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system get svc kube-dns
kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'; echo
NAME READY UP-TO-DATE AVAILABLE AGE
coredns 2/2 2 2 8d
registry.k8s.io/coredns/coredns:v1.14.2
NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
coredns-589f44dc88-2tpjr 1/1 Running 0 5d21h 10.244.1.27 worker1 <none> <none>
coredns-589f44dc88-5pt72 1/1 Running 0 5d21h 10.244.0.8 master <none> <none>
NAME TYPE CLUSTER-IP EXTERNAL-IP PORT(S) AGE
kube-dns ClusterIP 10.96.0.10 <none> 53/UDP,53/TCP,9153/TCP 8d
NAME ADDRESSTYPE PORTS ENDPOINTS AGE
kube-dns-ggp9m IPv4 53,53,9153 10.244.0.8,10.244.1.27 8d
.:53 {
errors
health {
lameduck 5s
}
ready
kubernetes cluster.local in-addr.arpa ip6.arpa {
pods insecure
fallthrough in-addr.arpa ip6.arpa
ttl 30
}
prometheus :9153
forward . /etc/resolv.conf {
max_concurrent 1000
}
cache 30 {
disable success cluster.local
disable denial cluster.local
}
loop
reload
loadbalance
}

ubuntu@master:~$ cd ~
kubectl create namespace dns
kubectl config set-context --current --namespace=dns
cat > probe.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
name: probe
spec:
terminationGracePeriodSeconds: 1
containers:

- name: app
  image: busybox
  command: ["sh", "-c", "sleep 3600"]
  EOF
  kubectl apply -f probe.yaml
  kubectl wait --for=condition=Ready pod/probe --timeout=60s
  kubectl exec probe -- cat /etc/resolv.conf
  namespace/dns created
  Context "kubernetes-admin@kubernetes" modified.
  pod/probe created
  pod/probe condition met
  search dns.svc.cluster.local svc.cluster.local cluster.local mshome.net
  nameserver 10.96.0.10
  options ndots:5
  ubuntu@master:~$ for n in kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local kube-dns.kube-system; do echo "$n -> $(kubectl exec probe -- ping -c1 -W1 $n 2>&1 | head -1)"; done
  kubectl exec probe -- nslookup kubernetes.default.svc.cluster.local
  kubectl exec probe -- nslookup kube-dns.kube-system.svc.cluster.local
  kubectl exec probe -- nslookup 10.96.0.10
  kubectl exec probe -- nslookup nosuchname.default.svc.cluster.local
  kubernetes -> ping: bad address 'kubernetes'
  kubernetes.default -> PING kubernetes.default (10.96.0.1): 56 data bytes
  kubernetes.default.svc -> PING kubernetes.default.svc (10.96.0.1): 56 data bytes
  kubernetes.default.svc.cluster.local -> PING kubernetes.default.svc.cluster.local (10.96.0.1): 56 data bytes
  kube-dns.kube-system -> PING kube-dns.kube-system (10.96.0.10): 56 data bytes
  Server: 10.96.0.10
  Address: 10.96.0.10:53

Name: kubernetes.default.svc.cluster.local
Address: 10.96.0.1

Server: 10.96.0.10
Address: 10.96.0.10:53

Name: kube-dns.kube-system.svc.cluster.local
Address: 10.96.0.10

Server: 10.96.0.10
Address: 10.96.0.10:53

10.0.96.10.in-addr.arpa name = kube-dns.kube-system.svc.cluster.local

Server: 10.96.0.10
Address: 10.96.0.10:53

\*\* server can't find nosuchname.default.svc.cluster.local: NXDOMAIN

\*\* server can't find nosuchname.default.svc.cluster.local: NXDOMAIN

command terminated with exit code 1
ubuntu@master:~$ cd ~
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > ~/Corefile.orig
wc -l ~/Corefile.orig
cat > ~/coredns-log-patch.yaml <<'EOF'
data:
Corefile: |
.:53 {
errors
log
health {
lameduck 5s
}
ready
kubernetes cluster.local in-addr.arpa ip6.arpa {
pods insecure
fallthrough in-addr.arpa ip6.arpa
ttl 30
}
prometheus :9153
forward . /etc/resolv.conf {
max_concurrent 1000
}
cache 30 {
disable success cluster.local
disable denial cluster.local
}
loop
reload
loadbalance
}
EOF
kubectl -n kube-system patch configmap coredns --type merge --patch-file ~/coredns-log-patch.yaml
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -c "^ log$"
date -u +%T
23 /home/ubuntu/Corefile.orig
configmap/coredns patched
1
22:25:50
ubuntu@master:~$ t0=$(date +%s)
for i in $(seq 1 30); do
  n=$(kubectl -n kube-system logs -l k8s-app=kube-dns --since=10m | grep -c "Reloading complete")
echo "t+$(( $(date +%s) - t0 ))s  pods that reloaded: $n/2"
  [ "$n" -ge 2 ] && break
sleep 10
done
kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers | awk '{print $1, $2, $4}'
t+0s  pods that reloaded: 0/2
t+10s  pods that reloaded: 0/2
t+20s  pods that reloaded: 0/2
t+31s  pods that reloaded: 0/2
t+41s  pods that reloaded: 0/2
t+51s  pods that reloaded: 1/2
t+61s  pods that reloaded: 2/2
coredns-589f44dc88-2tpjr 1/1 0
coredns-589f44dc88-5pt72 1/1 0
ubuntu@master:~$ kubectl exec probe -- ping -c1 -W2 example.com 2>&1 | head -1
kubectl exec probe -- ping -c1 -W2 example.com. 2>&1 | head -1
sleep 2
kubectl -n kube-system logs -l k8s-app=kube-dns --since=30s | grep -E "example\.com" | cut -c1-150
echo "queries for example.com: $(kubectl -n kube-system logs -l k8s-app=kube-dns --since=30s | grep -c 'example\.com')"
echo "of those, for the absolute name example.com.: $(kubectl -n kube-system logs -l k8s-app=kube-dns --since=30s | grep -c ' example\.com\. ')"
PING example.com (104.20.23.154): 56 data bytes
PING example.com. (104.20.23.154): 56 data bytes
[INFO] 10.244.2.15:42039 - 3672 "AAAA IN example.com.cluster.local. udp 43 false 512" NXDOMAIN qr,aa,rd 136 0.000358058s
[INFO] 10.244.2.15:42039 - 36438 "A IN example.com.cluster.local. udp 43 false 512" NXDOMAIN qr,aa,rd 136 0.000450134s
[INFO] 10.244.2.15:58679 - 8805 "AAAA IN example.com.mshome.net. udp 40 false 512" NXDOMAIN qr,rd 40 0.034362639s
[INFO] 10.244.2.15:58679 - 64866 "A IN example.com.mshome.net. udp 40 false 512" NXDOMAIN qr,rd 40 0.040058652s
[INFO] 10.244.2.15:50660 - 55900 "AAAA IN example.com. udp 29 false 512" NOERROR qr,rd 107 0.00219946s
[INFO] 10.244.2.15:50660 - 94 "A IN example.com. udp 29 false 512" NOERROR qr,rd 83 0.002314356s
[INFO] 10.244.2.15:53527 - 6759 "A IN example.com.dns.svc.cluster.local. udp 51 false 512" NXDOMAIN qr,aa,rd 144 0.000240216s
[INFO] 10.244.2.15:53527 - 3688 "AAAA IN example.com.dns.svc.cluster.local. udp 51 false 512" NXDOMAIN qr,aa,rd 144 0.000367537s
[INFO] 10.244.2.15:35080 - 5490 "AAAA IN example.com.svc.cluster.local. udp 47 false 512" NXDOMAIN qr,aa,rd 140 0.000090838s
[INFO] 10.244.2.15:35080 - 24693 "A IN example.com.svc.cluster.local. udp 47 false 512" NXDOMAIN qr,aa,rd 140 0.000042825s
[INFO] 10.244.2.15:50616 - 9791 "AAAA IN example.com. udp 29 false 512" NOERROR qr,rd 107 0.021249701s
[INFO] 10.244.2.15:50616 - 47928 "A IN example.com. udp 29 false 512" NOERROR qr,rd 83 0.021135259s
queries for example.com: 12
of those, for the absolute name example.com.: 4
ubuntu@master:~$ cd ~
cat > ~/coredns-orig-patch.yaml <<'EOF'
data:
Corefile: |
.:53 {
errors
health {
lameduck 5s
}
ready
kubernetes cluster.local in-addr.arpa ip6.arpa {
pods insecure
fallthrough in-addr.arpa ip6.arpa
ttl 30
}
prometheus :9153
forward . /etc/resolv.conf {
max_concurrent 1000
}
cache 30 {
disable success cluster.local
disable denial cluster.local
}
loop
reload
loadbalance
}
EOF
kubectl -n kube-system patch configmap coredns --type merge --patch-file ~/coredns-orig-patch.yaml
diff <(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}') ~/Corefile.orig && echo "identical to the original"
configmap/coredns patched
identical to the original
ubuntu@master:~$
