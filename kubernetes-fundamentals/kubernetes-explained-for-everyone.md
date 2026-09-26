# Kubernetes, Explained Like a Harbor

*A companion to the animated diagram (`kubernetes-harbor-animation.html`) —
read this alongside it, or on its own.*

Imagine a busy shipping harbor. Ships come and go, cranes load and unload
cargo, and a control tower makes sure everything ends up where it's
supposed to be — without any single dockworker needing to know the whole
plan. That's a genuinely good picture of what Kubernetes does for computer
programs.

---

## The problem, before Kubernetes existed

Before harbors had control towers, imagine every ship captain had to
personally negotiate with every dock, track which crane was free, and
manually radio other ships to avoid collisions. It worked, but only with a
huge amount of manual coordination — and if a captain got sick or a radio
broke, cargo could sit stranded with nobody noticing.

This used to be how companies ran their computer programs too: engineers
manually decided which computer would run which piece of software, watched
it constantly, and fixed things by hand when something crashed. It worked,
but it didn't scale, and it broke easily.

**Kubernetes is the control tower that harbor was missing.**

---

## The cast of characters

### 🧑‍💻 You (the developer)

You're not a dockworker yourself — you're the person placing an order.
Instead of personally loading cargo, you write down **what you want**:

> "I want 3 copies of my website running, always."

You don't say *how* to do it. You don't pick which ship, which crane, or
which dock. You just describe the destination, in a simple text file
(Kubernetes calls this **YAML**), and hand it to the harbor.

### 🗼 The Control Tower (the Control Plane)

This is the brain of the whole operation, and it's actually three workers
sharing one office:

- **The API Server** is the receptionist. Every request — yours, or a
  dockworker reporting status — goes through this desk first. Nothing
  happens in the harbor without passing through here.
- **etcd** is the tower's notebook. It writes down the current plan and the
  current reality, so if the tower itself needs to be rebuilt, nothing is
  forgotten.
- **The Scheduler** is the dispatcher. When a new order comes in, it looks
  at every ship in the harbor and decides: *which one has room for this
  cargo right now?*

Together, these three figure out **where** your request should go — you
never have to know or care which specific ship ends up running your app.

### 🚢 The Ship (a Worker Node)

This is an actual machine — a real computer — that does the physical work
of running your program. Every ship has two crew members permanently
aboard:

- **kubelet** is the ship's foreman. It constantly checks in with the
  control tower: *"Here's what I'm currently running. Does that still match
  the plan?"* If it doesn't, kubelet fixes it — without waiting to be told
  twice.
- **containerd** is the crane operator. When kubelet says "load this cargo,"
  containerd is what actually starts the software running.

### 📦 The Crates (Pods)

Each crate on the ship's deck is one running copy of your program — in
Kubernetes terms, a **Pod**. If you asked for 3 copies, you get 3 crates,
each running independently, each capable of being replaced individually
without disturbing the others.

Every crate gets its **own real address** — like its own street address in
the harbor — so it can be found and reached directly, and so crates can
talk to each other without confusion about who's who.

### 🔗 The Roads Between Crates (the Network — Calico)

A harbor full of crates that can't talk to each other isn't very useful.
Underneath the deck, a network of roads connects every crate to every other
crate, automatically, the moment it's placed down. This is the job of
Kubernetes' **networking layer** (in the cluster we built together, a
system called **Calico**). You never have to wire this up by hand — it's
just there, working, as soon as a crate exists.

---

## What happens when you place an order

Here's the whole journey, start to finish, matching the animation:

1. **You** write down what you want ("3 copies of `httpd`") and hand it to the harbor.
2. **The API Server** receives it and writes it into **etcd**'s notebook.
3. **The Scheduler** looks around the harbor and decides which ship(s) have room.
4. **kubelet**, aboard the chosen ship, gets the instruction and tells **containerd** to actually start each crate.
5. As each crate comes online, **the network** automatically gives it a real address and connects it to its neighbors.
6. Your app is now running — and reachable — without you ever having personally touched a single machine.

---

## The part that makes Kubernetes genuinely special: self-healing

Here's the moment that separates a harbor with a control tower from one
without: **what happens when something goes wrong.**

Say a crate falls overboard — a container crashes. In the old way of doing
things, nobody would notice until a person checked, or a customer
complained. In this harbor:

- **kubelet** is *always* comparing "what's actually running" against "what
  the plan says should be running."
- The moment it notices a mismatch — 2 crates instead of the promised 3 — it
  doesn't wait for permission. It quietly loads a replacement crate,
  automatically.

You, the person who placed the order, never even find out unless you go
looking. The harbor just... fixes itself, continuously, forever, as long as
it's running.

This is the single biggest reason companies use Kubernetes: not because it
runs software, but because it **keeps** software running, by itself,
without a human standing watch 24 hours a day.

---

## One more thing worth knowing: growing the harbor

If suddenly a huge order comes in — say, 100 crates instead of 3 — the
Scheduler doesn't panic. It checks whether the current ships have enough
room. If they don't, in a cloud-hosted harbor, it can even **call for more
ships** automatically, load the crates across all of them, and — once the
rush is over — send the extra ships back out, so you're not paying for
harbor space you don't need anymore.

---

## Quick Glossary

| Harbor word | Real Kubernetes word | What it actually is |
|---|---|---|
| You, placing an order | Developer using `kubectl` | The person/tool describing desired state |
| The order itself | A YAML manifest | A text file describing what should run |
| Control Tower | Control Plane | The decision-making brain of the cluster |
| Receptionist | API Server | The single entry point for every request |
| The tower's notebook | etcd | Where the cluster's current state is stored |
| Dispatcher | Scheduler | Decides which machine runs what |
| A Ship | Worker Node | An actual machine that runs your programs |
| Ship's foreman | kubelet | Keeps a node's real state matching the plan |
| Crane operator | containerd | Actually starts/stops containers |
| A Crate | Pod | One running instance of your program |
| Roads between crates | CNI network (e.g. Calico) | Gives every pod a real, reachable address |
| Fixing a fallen crate | Self-healing | Automatic replacement of failed containers |
| Calling for more ships | Cluster autoscaling | Adding machines automatically under heavy load |

---

## Why this matters, in one sentence

**Kubernetes lets you describe the outcome you want, and then quietly,
continuously makes reality match that description — so your software keeps
running even when individual pieces of it fail, without you having to watch
it every minute of every day.**
