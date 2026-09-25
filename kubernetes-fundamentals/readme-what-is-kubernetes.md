# Kubernetes Introduction — Study Notes

---

## 1. The Problem Kubernetes Solves (Historical Context)

**Before containers (traditional VM era):**

- Infrastructure was a large pool of virtual machines (VMs), each running a full OS (e.g. Ubuntu).
- Each VM typically hosted **one application** — sometimes just one or two binaries.
- Heavy resource usage: every VM needs its own OS overhead.

**2013 — Docker and the rise of containerization:**

- Containerization itself is much older (roots trace back to 1970s Unix-style process/resource isolation), but **Docker (2013)** is what made it mainstream.
- Containers let multiple applications share one VM's OS, CPU, and memory — much lighter than one-VM-per-app.
- Benefit: fewer VMs to patch/manage, since each VM can now host several containers.

**The next problem — orchestration at scale:**

- A single container can only handle a limited number of requests → you need **multiple replicas** (e.g., several instances of a web frontend talking to a database).
- Manual setup: multiple VMs, each running several Docker containers, provisioned via **Ansible** (a _push-based_ model — YAML playbooks pushed daily to install Docker, pull images, start containers).
- **The core limitation:** containers had no awareness of each other. If Container A needed to talk to Container B, nothing in the system tracked _where_ B was running.

**The stopgap solution — load balancers:**

- A large **HAProxy** load balancer sat in front of everything.
- Routed incoming requests to backend VMs/containers, typically **round-robin** (not "intelligent" placement).
- Scaling meant manually deciding "we need X VMs running Y containers," then manually provisioning, wiring up, and upgrading each one.
- Upgrades required manually taking VMs in and out of rotation while tracking replica counts by hand.

**Why this broke down:** it required a lot of manual coordination, and neither the containers nor the load balancer had any _intelligent, shared understanding_ of overall cluster capacity or health.

---

## 2. What Kubernetes Actually Is

> **"Kubernetes is the operating system of the cloud."**

Underneath, a Kubernetes cluster is still just a group of virtual machines running Linux — nothing magical about the machines themselves. The difference is _coordination_:

- Kubernetes lets a group of machines **communicate with each other and share workload intelligently**.
- It replaces the manual "which VM, which container, is it still alive" bookkeeping with a system that manages that automatically.

### Core architecture

| Component         | Role                                                                                                                                            |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **Control Plane** | The "brain" of the cluster — accepts your desired state, decides where workloads should run, and continuously reconciles actual state to match. |
| **Worker Nodes**  | The machines that actually run your application containers.                                                                                     |

```mermaid
graph TB
    subgraph "Kubernetes Cluster"
        CP[Control Plane<br/>the brain]
        W1[Worker Node 1]
        W2[Worker Node 2]
        W3[Worker Node 3]
        CP -->|schedules workloads onto| W1
        CP -->|schedules workloads onto| W2
        CP -->|schedules workloads onto| W3
    end
    User[Operator] -->|"I want 3 replicas of image X"<br/>(declared in YAML)| CP
```

---

## 3. The Declarative Model

This is the central shift from the old Ansible/HAProxy approach:

- You don't tell Kubernetes _how_ to do something step by step (imperative).
- You declare the **desired end state** in a YAML file — e.g., _"I want 3 replicas of this image running."_
- The **control plane** figures out:
  - Which worker nodes have enough spare capacity
  - Where to schedule each replica
  - How to keep that state true over time

> "You tell it a certain status, and Kubernetes finds out \[how to get there\]. That's the beauty of Kubernetes."

This removes the need for a separate load balancer configuration to manually track container locations — Kubernetes' own networking model handles routing to wherever a given pod actually lives.

---

## 4. Why This Matters at Scale

The 3-replica example is intentionally simple. The real value shows up at scale:

- Imagine needing **100 replicas** of an application instead of 3.
- The old way: manually write playbooks, manually provision every VM, manually track placement.
- The Kubernetes way: declare "I want 100 replicas." Kubernetes:
  1. Calculates how many replicas fit per node (e.g., "4 docker containers per node")
  2. Determines how many additional nodes are needed
  3. **In cloud environments** (e.g., Azure Kubernetes Service), can automatically provision new nodes to satisfy that capacity
  4. Schedules the 100 replicas across the (now-expanded) set of nodes

---

## 5. Self-Healing

Because you declare _desired state_ rather than a one-time action:

- If you declare "I want 3 replicas" and one container crashes, Kubernetes detects the mismatch (actual = 2, desired = 3).
- It automatically removes the failed container and starts a replacement — **without manual intervention.**
- At small scale this is a nice convenience; at scale (hundreds of replicas, where crashes are statistically inevitable), this is essential. Kubernetes handles it continuously in the background, and can be paired with alerting so operators are notified something needed attention.

---

## 6. Autoscaling (Two Kinds)

### a) Time-based / predictable load patterns

Example: a news website with predictable daily traffic curves (e.g., peak readership around 9am, a bump at lunch, decline overnight).

- You can scale the cluster **up** ahead of anticipated peak load (e.g., starting around 8am, since node provisioning takes some time) and scale **down** during low-traffic periods (e.g., overnight, keeping just enough capacity for baseline traffic).

### b) Metric-based / reactive scaling

Example: an unexpected traffic spike (e.g., a viral article driving millions of unplanned visitors).

- Kubernetes can scale based on live metrics — commonly **CPU usage** or **request count** hitting an ingress controller.
- When Kubernetes detects the metric threshold is crossed (and traffic is verified as legitimate), it scales **both** the nodes and the containers to absorb the load, aiming to preserve a good user experience automatically.

---

## 7. Summary Definition

> **Kubernetes is an intelligent way of running containerized workloads at scale.**

Its core power is translating a declared desired state (e.g., "run 100 replicas of this image") into:

- Actual scheduling of workloads across nodes
- Cluster-level scaling (adding/removing nodes) in cloud environments
- Continuous reconciliation (self-healing) when reality drifts from the declared state
- Traffic-aware or metric-aware scaling up and down over time

---

## Quick-Reference Glossary

| Term                               | Meaning                                                                                                        |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| **Control Plane**                  | Cluster's decision-making component; accepts desired state, schedules workloads, reconciles drift              |
| **Worker Node**                    | A machine (VM or physical) that runs application containers                                                    |
| **Replica**                        | One running instance of a given container/application                                                          |
| **Declarative config (YAML)**      | A file stating _what_ you want, not _how_ to achieve it                                                        |
| **Scheduling**                     | The control plane's process of deciding which node a given workload should run on, based on available capacity |
| **Self-healing**                   | Kubernetes automatically replacing failed containers to match declared replica counts                          |
| **Cluster autoscaling**            | Adding/removing worker nodes based on demand                                                                   |
| **Horizontal scaling (HPA-style)** | Adding/removing container replicas based on live metrics (CPU, request count, etc.)                            |
