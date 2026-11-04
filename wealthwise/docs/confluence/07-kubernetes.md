# Running on Kubernetes (kind)

## Topology
```
Browser -> localhost:8080 -> kind node :80 -> ingress-nginx -> Service web (2 pods, nginx + SPA)
                                                                  |  /api  (apikey added here)
                                                                  v
                                                          Service kong -> Service api -> Service postgres (StatefulSet + PVC)
                                                                               \-> Service elasticmq
```
Only the ingress is reachable from outside. Kong, the API, Postgres and the queue are ClusterIP only.

## Commands
| Command | Effect |
| --- | --- |
| `make k8s-setup` | Installs `kubectl` and `kind` into `~/.local/bin` |
| `make k8s-up` | Cluster, ingress-nginx, image build and load, apply, wait for readiness |
| `make k8s-deploy` | Rebuild images after code changes and roll out api and web |
| `make k8s-status` / `make k8s-logs APP=kong` | Inspect |
| `make k8s-smoke` | The same end-to-end script as Docker, through a port-forward to Kong |
| `make k8s-down` | Delete the cluster and its data |

## Design choices
- **Kustomize, one source of truth.** `kong.yml` and `elasticmq.conf` are shared with docker-compose via `configMapGenerator`, and a config change rolls the pods because the ConfigMap name is hashed.
- **Probes.** The API has a startup probe because it waits for Postgres before listening; readiness and liveness use `/health`.
- **Hardened API pod.** Non-root, read-only root filesystem (`/tmp` is an emptyDir), all capabilities dropped, memory limits on every workload.
- **Images are loaded, not pulled.** Tag `:local` with `imagePullPolicy: IfNotPresent`. In a real cluster CI pushes to a registry and the tag becomes the release version.
- **Replicas.** `web` runs 2. `api` starts at 1 because first boot creates and seeds the schema; scale afterwards with `kubectl -n wealthwise scale deploy/api --replicas=3`. Queue consumers compete for messages and audit writes are idempotent, so extra replicas are safe.

## Known gaps (backlog)
- Schema creation and seeding run in the API process; move to a migration Job before multi-replica first boot.
- Secrets are plain manifests for the demo; use External Secrets or Sealed Secrets.
- No NetworkPolicies, HPA or PodDisruptionBudgets yet.
- TLS is not configured on the ingress.

## Troubleshooting (lessons from real runs on WSL2 with Docker 29)
| Symptom | Cause and fix |
| --- | --- |
| `kind load` fails: `ctr images import --all-platforms --digests` | Docker 28/29 containerd image store. `scripts/k8s.sh` runs `docker save --platform` and imports into the node with plain `ctr images import`. |
| Pods in `ContainerCreating` for 10+ minutes | The node pulls images itself and does not share Docker's cache. Third-party images are preloaded; the ingress controller pulls once. Rollout waits are 15 minutes. |
| API restarts several times at first boot | Its startup probe expired while Postgres was still pulling. It recovers on its own once Postgres is Ready. |
| `kong` `OOMKilled`, exit 137 | nginx defaults to one worker per host CPU. `KONG_NGINX_WORKER_PROCESSES=1` and a 1 Gi limit are set in `k8s/kong.yaml`. |
| Ingress `apply` fails: `failed calling webhook ... connection refused` | Admission webhook not listening yet. The script waits for the controller pod and deletes the webhook (local only). |
| `ingress-nginx-admission-patch` in `CrashLoopBackOff` | Expected after the webhook is deleted; harmless. |
| Env vars like `KONG_PORT=tcp://...` inside pods | Kubernetes service links; `enableServiceLinks: false` is set on every workload. |
| Port 8080 busy | Edit `hostPort` in `k8s/kind-config.yaml`, then `make k8s-down k8s-up`. |
| `make k8s-smoke` cannot bind its port | The script tunnels to Kong on local port 8801 and refuses to run if that port is busy; set `KONG_PORT` to another value. |
| `localhost:8080` not reachable from Windows | Make sure `localhostForwarding` is not disabled in `%UserProfile%\.wslconfig`, then `wsl --shutdown`. |
| Windows-side program already uses a port | WSL forwards localhost to Windows listeners; find the owner with `curl -i` and the `Server` header. |
