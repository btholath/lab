# Ingress errors lab: 404, 503 and 502

## Making Traefik fail on purpose, and reading what it says

> **Status: all parts have now run on the cluster (October 16 and 19, 2026).** The first run got two of eight predictions wrong, and they taught the main lesson: a Service with no ready Pods gets a **404**, not a 503, by default. The repeat run and the `flag` run, both on October 19, answered every open question from the first run, and found one thing nobody predicted: a **hang** during one scale-down (Section 4).

---

# 1. What each status means

| Status | When Traefik answers it | Which layer to look at |
|---|---|---|
| **404** | The request **cannot be matched with a router**. Traefik answers itself, and no Pod is involved | The **Ingress** (host, path, class), **or the Pods** (see Section 3) |
| **503** | A router **has matched**, but there are **no servers ready** | The **Pods**: replicas, readiness, endpoints |
| **502** | An **error happens while contacting the upstream**: a router matched, a server was chosen, and the connection failed | The **port**: the Service's `targetPort` against what the container listens on |

(From Traefik's FAQ, "Why is Traefik answering XXX HTTP response status code?". A fourth status, **504 Gateway Timeout**, means a backend that is alive but too slow, and this lab does not cover it.)

---

# 2. What the first run showed (Observed)

| Case | Request | Predicted | **Observed** | Traefik's access log (`router=` and `backend=`) |
|---|---|---|---|---|
| `ok` | `ok.lab/` | 200 | **200** ✓ | a router named after the Ingress, backend = a **Pod address** on port 80 |
| `unknown` | `unknown.lab/` | 404 | **404** ✓ | `router=-` `backend=-` |
| `paths-only` | `paths.lab/only` | 200 | **200** ✓ | a router named `...paths-lab-only`, backend = a Pod address |
| `paths-other` | `paths.lab/other` | 404 | **404** ✓ | `router=-` `backend=-` |
| **`zero`** | `zero.lab/` (0 replicas) | 503 | **404** ✗ | `router=-` `backend=-`, still 404 **after 20 seconds** |
| **`notready`** | `notready.lab/` (Pod Running, never Ready) | 503 | **404** ✗ | `router=-` `backend=-`, still 404 **after 20 seconds** |
| `refused` | `refused.lab/` (`targetPort` 81) | 502 | **502** ✓, body `Bad Gateway` | a router named `...refused-lab`, backend = **a Pod address on port 81**: Traefik tried, and the connection failed |
| `nosvc` | `nosvc.lab/` (Service does not exist) | 404 (a guess) | **404** ✓ | `router=-` `backend=-` |

The access-log fields behave as they were predicted to: **`router=-` means no route was built**, and a backend ending in `:81` shows the failed connection to the wrong port.

**The timing test** (scale a working app, `ok`, to 0 and back, with a status poll every half second):

| Step | Seen | Seconds |
|---|---|---|
| Scale to 0 | `200 → 503` | **0.6 s**. No 502 and no stray 200 |
| Scale to 1 | `503 → 200` | **1.6 s** |

That test stopped at the first 503, so it didn't show whether the 503 **lasts**. The repeat run (below) does.

## The repeat run (October 19): 8 of 8, and the timing in full

With the two predictions corrected (`zero` and `notready` now predict 404), **all eight cases answered as predicted**. The timing parts, with the seconds counted from the scale command:

| Part | Statuses seen, in order | When each appeared |
|---|---|---|
| `ok` to 0 (a route that exists loses its Pod) | `200 → 503 → 404` | 503 at **0.6 s**, **404 at 2.7 s**, then it stayed 404 for the rest of the 15 s |
| `ok` back to 1 | `404 → 200` | 200 at **1.1 s** |
| `zero` to 1 (a Service that never had a Pod gets one) | `404 → 200` | 200 at **2.1 s**, with no 503 on the way |
| `zero` to 0 | `200 → 000 → 404` | `000` at **8.6 s**, 404 at 9.1 s (see Section 4) |

## The `flag` run (October 19): the documented option works

| Case | Default | `allowEmptyServices` on | Traefik's log with it on |
|---|---|---|---|
| `zero` | 404 | **503**, body `no available server` | a router named `...zero-lab`, `backend=-` |
| `notready` | 404 | **503**, body `no available server` | a router named `...notready-lab`, `backend=-` |
| `nosvc` | 404 | still **404** | `router=-` |
| `ok` | 200 | 200 (after a 2 s settle following the restart) | a router, backend = a Pod address |

Reverting removed the flag from Traefik's Deployment, and `zero` returned to 404.

## The three response bodies, all observed

| Status | Body | Access log |
|---|---|---|
| 404 | `404 page not found` | `router=-` `backend=-` |
| 503 | `no available server` | a router named, `backend=-` |
| 502 | `Bad Gateway` | a router named, `backend=` a Pod address on the wrong port |

---

# 3. Why `zero` and `notready` gave 404 (documented)

Traefik's Kubernetes Ingress provider has an option, **`allowEmptyServices`**, and its **default is off**. The documentation says that turning it on allows a route to a Service that has no endpoint available, so that Traefik answers **503**. With it off, **no route is created** for such a Service, and the request matches nothing: a **404**. That is exactly what the log showed (`router=-`).

So the FAQ's 503 rule is real, but it applies **once a route exists**, and by default the Ingress provider does not build one for a Service with no available endpoints. The practical consequence:

> **With the default settings, a 404 can mean either "no route matches" or "the Service has no ready Pods".**

That changes the debugging checklist:

| You see | The layer | Check first |
|---|---|---|
| **404** on a host that should work | Routing **or Pods** | `kubectl describe ingress` (host, path, class), **and** `kubectl get pods` / `kubectl get endpointslices`: `READY 0/1` or no endpoints gives a 404 too. Traefik's access log shows `router=-` either way, so the log alone does not tell them apart |
| **503** | A route that already existed lost its servers (see Section 4), or `allowEmptyServices` is on | `kubectl get endpointslices`, the readiness probe |
| **502** | The connection | The Service's `targetPort` against what the container really listens on, or a Pod that died after becoming Ready |

---

# 4. What the later runs answered (Observed, October 19)

| Question from the first run | Answer | Detail |
|---|---|---|
| Does the **503** on a route that loses its Pods **last**? | **No.** It became a 404 | `200 → 503 → 404`: the 503 lasted about **2 seconds** (0.6 s to 2.7 s), then the status settled at 404, as the documented default says. One run |
| Does a **route appear** when a Service that never had a Pod gets its first Ready one? | **Yes** | `404 → 200` at 2.1 s, with no 503 on the way |
| Does the documented option really turn the 404s into **503**s? | **Yes** | `zero` and `notready` answered 503 with the body `no available server`. `nosvc` stayed 404 |
| How long does Traefik take to notice? | **About 0.6 to 2.7 seconds** in this run | Down: 503 at 0.6 s and 404 at 2.7 s. Up: 200 at 1.1 s and 2.1 s. The documented `providersThrottleDuration` default is 2 s, and the 503 phase lasted about that long. That is consistent with it, but **the mechanism was not established** |
| Is the command-line form of the option right? | **Yes** | Traefik v3.7.12 accepted `--providers.kubernetesingress.allowemptyservices=true` |

## A finding nobody predicted: a hang during a scale-down

In `zero to 0` the statuses were `200`, then **`000` at 8.6 s**, then `404` at 9.1 s. `000` means curl received **no HTTP answer at all**: that poll's request hung until curl's 8-second limit. A client would have seen a **hang** for several seconds, not an error status.

| What we know | What we don't |
|---|---|
| It happened **once**, in `zero to 0` | Whether it repeats |
| `zero` has **no readiness probe**. `ok`, which has one, scaled down twice with no hang | Whether the probe matters, or it is chance |
| The status ended at the documented 404 | **The cause.** A guess, untested: Traefik still held the old Pod's address after the Pod was gone, and a connection to an address that no longer exists gets no reply, so it waits |

If the guess holds, the lesson is that **scale-downs and rollouts can produce hangs and timeouts, not only 502, 503 and 404.** To see whether it repeats, run the script again and read the `zero to 0` line.

## Still open

- The cause of the 2-second 503 phase and of the one hang (above)
- Whether the hang repeats
- 504 and the other topics in Section 8

---

# 5. The lab

Everything lives in its own namespace, **`errors-lab`**, so the Ingress lab is untouched and cleanup is one command. It reuses the `traefik/whoami` image.

| Case | What is set up | Predicted now | Why |
|---|---|---|---|
| `ok` | A healthy Pod behind a route | **200** | The control |
| `unknown` | No Ingress names this host | **404** | No router matches |
| `paths-only` | An Ingress for the path `/only` | **200** | Host and path match |
| `paths-other` | The same Ingress, another path | **404** | No router matches |
| `zero` | A Deployment with 0 replicas | **404** | Documented: no route for a Service without endpoints |
| `notready` | A Pod Running but never Ready (its probe watches port 81) | **404** | The same |
| `refused` | A Service with `targetPort` 81 selecting the healthy Pod | **502** | A route matches and the connection to port 81 fails |
| `nosvc` | An Ingress naming a Service that does not exist | **404** | Observed |

## Run it

The Ingress lab must be up. On the master:

```powershell
multipass transfer ingress-errors-lab.sh master:/home/ubuntu/
multipass exec master -- bash /home/ubuntu/ingress-errors-lab.sh
```

It is safe to repeat. A second run prints `unchanged`, and it first scales `ok` back to 1 replica and `zero` back to 0 **explicitly**, so a repeat run (or an interrupted timing test) starts from a known state. It does not rely on what `kubectl apply` would do with a manual scale: I assumed it would leave one alone, never tested that, and now think it probably resets it. Observed on October 19: the repeat run printed `unchanged` for every object and started cleanly.

| Stage | Expected |
|---|---|
| `== 3. The status codes` | **8 of 8 as predicted** (observed on October 19) |
| **4a** `ok to 0` | **Observed:** `200 → 503 → 404`, settling at 404 after about 2.7 s |
| `ok to 1` | **Observed:** `404 → 200` in 1.1 s |
| **4b** `zero to 1` | **Observed:** `404 → 200` in 2.1 s: a route appears, with no 503 |
| `zero to 0` | **Observed once:** `200 → 000 → 404`, with a hang of several seconds in the middle (Section 4) |

---

# 6. The `flag` subcommand: one option turns the 404s into 503s

```powershell
multipass exec master -- bash /home/ubuntu/ingress-errors-lab.sh flag
```

It runs after the main run (it needs `errors-lab`). **It changes Traefik's own Deployment**, so it is opt-in and built to undo itself:

1. Probes `zero`, `notready` and `nosvc` with the default setting (predicted **404** for all).
2. Adds `--providers.kubernetesingress.allowemptyservices=true` to Traefik's arguments. **Traefik restarts**, so expect a brief interruption.
3. Probes again. Predicted: `ok` **200**, `zero` **503**, `notready` **503**, and `nosvc` still **404** (the Service does not exist, so there is nothing to make an empty route for: this one is my inference, not documented).
4. **Removes the argument again** and checks that `zero` is back to 404.

**Observed (October 19):** every prediction held, the flag was added, Traefik restarted, the flag was removed again, and `zero` returned to 404. Afterwards, `bash ingress-lab.sh` printed `deployment.apps/traefik unchanged` and `19 passed, 0 failed, 0 warnings`: apply found no difference between Traefik's live Deployment and its manifest, so the revert left nothing behind.

Safety: an exit trap removes the flag even if the script fails halfway, and the script checks at the end that it is gone. If the flag was already on when it started, it says so and **leaves it as it found it**. If anything goes wrong, `bash ingress-lab.sh reset` restores Traefik from its manifest.

Whether to keep the option **on** in the lab is a real choice: 503 is the more accurate answer for "the Service exists but has no Pods", and the option also lets Traefik apply middleware to such requests. The cost is a non-default setting. This lab leaves it off.

---

# 7. Clean up

```powershell
multipass exec master -- bash /home/ubuntu/ingress-errors-lab.sh down
```

It deletes the namespace `errors-lab`, waits, and checks that it is gone. The Ingress lab is not touched.

---

# 8. What this lab does not cover

- **504 Gateway Timeout** (a backend that accepts and never answers), and **500-class errors** from the app itself
- Retries, circuit breakers, health checks and custom error pages
- A **catch-all 503** instead of 404 (Traefik's FAQ describes the catch-all router for it)
- **TLS errors**: the TLS lab comes later

---

# 9. Where the facts came from

Consulted October 16, 2026. Facts are paraphrased.

| Topic | Source |
|---|---|
| What 404, 503 and 502 mean in Traefik, and the catch-all router | Traefik documentation, FAQ "Why is Traefik answering XXX HTTP response status code?" (doc.traefik.io/traefik/getting-started/faq/) |
| `allowEmptyServices` (default off; on gives 503 instead of 404), `providersThrottleDuration` (default 2 s), `disableClusterScopeResources`, `strictPrefixMatching` | Traefik documentation v3.7, "Kubernetes Ingress" provider reference (doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress/) |
| The CLI form of the option (`--providers.kubernetesingress.allowemptyservices`) | First **inferred** from the page's CLI examples for other options, then **verified**: Traefik v3.7.12 accepted it, and the behaviour changed as documented |
| Everything marked Observed | The first run of `ingress-errors-lab.sh` on this cluster |
