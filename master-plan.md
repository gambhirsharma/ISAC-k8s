# ISAC sensing pipeline — Kubernetes build master plan

This is the full architecture and execution plan. No code — this is the checklist
and reasoning to follow while you build it yourself.

---

## 1. Local Kubernetes distribution: kind

**Decision: kind, multi-node, on your Hetzner/Proxmox box.**

What this means for the rest of the plan, and what to watch out for, since kind
has real tradeoffs versus a "real" multi-host cluster:

- Every kind "node" is a Docker container on one underlying host, sitting on
  top of Docker's own bridge network. This means:
  - **Absolute latency numbers you measure locally won't transfer directly to
    a real multi-host deployment** — there's an extra virtualization/bridge
    layer here that won't exist later. Treat kind's numbers as *relative*
    (does affinity help vs. not, does Cilium help vs. kube-proxy) rather than
    *absolute* production latency figures.
  - `hostNetwork: true` on a kind node binds to that node-container's network
    namespace, not literally to your physical host's NIC. It's still useful
    for validating that the manifest/architecture is correct (DaemonSet
    scheduling, affinity, bypassing the pod network) — just know it's one
    layer removed from bare metal.
  - Since all "nodes" run on one physical machine, resource limits (section 8)
    matter even more here than on separate VMs — nodes are sharing the same
    real CPU/RAM, so noisy-neighbor effects between kind nodes are easy to
    mistake for architecture problems.
- **Why kind still makes sense for this project**: it's fast to stand up and
  tear down, trivial to version-control the cluster topology, and it fully
  supports swapping out the default CNI for Cilium — which is the networking
  decision that actually matters most here. Multi-node kind still exercises
  real scheduling, real affinity rules, and real DaemonSet/Service behavior at
  the Kubernetes API level, even though the underlying transport is
  containerized rather than bare-metal.
- **Topology to build:**
  - At least **1 control-plane node + 2 worker nodes** in the kind cluster
    config.
  - Label one worker node as your "edge" node (where the simulator/ingestion/
    preprocessing/inference stack will be pinned) and treat the other as
    general cluster capacity — same logical topology as a real edge/core
    split, just running as containers instead of VMs.
  - Give the edge-designated node a distinguishing label and, later, a taint
    if you want to guarantee only pipeline workloads land there.
- **When you eventually want real cross-host latency numbers**: that's the
  point to move this same manifest set to k3s across separate Proxmox VMs (or
  physical edge hardware). Nothing above the CNI/node layer needs to change —
  workload design, affinity rules, and service patterns all carry over
  unmodified. Keep that migration in mind as a later milestone, not a
  rewrite.

---

## 2. Cluster networking layer

- Create the kind cluster **with its default CNI disabled from the start**
  (kind supports this directly in its cluster config) — you'll replace it, so
  bring the cluster up without the default networking rather than swapping it
  out after the fact.
- Install **Cilium** as the CNI, in **kube-proxy replacement mode** (Cilium's
  eBPF datapath fully replacing iptables/IPVS-based service routing). This is
  the single highest-leverage networking decision in the whole system — it
  removes the iptables hop for every service-to-service call.
- Enable **Hubble** (Cilium's built-in observability layer). This gives you
  flow-level visibility and latency data for free, with no extra agents to
  build — and it's eBPF-based, which fits directly with your existing
  interests. Use it as your first latency-diagnosis tool before reaching for
  anything custom.
- Confirm the CNI swap actually took effect: check that kube-proxy is disabled
  and that Cilium reports itself as the active service router before building
  anything on top. Don't skip this verification step — a half-migrated
  kube-proxy/Cilium state is a common source of confusing latency results.

---

## 3. Namespace and workload organization

- One namespace for the whole pipeline (e.g. `isac-sensing`) — no need to
  over-segment at this scale, but keep it isolated from other workloads on the
  cluster for cleaner resource accounting and network policy scoping later.
- Logical grouping within that namespace:
  - **Source tier**: simulator
  - **Data-plane tier**: ingestion, preprocessing, inference (the colocated group)
  - **Output tier**: result stream / API, metrics

---

## 4. Workload design per component

**Simulator**
- Deployment (not DaemonSet) — it's a single logical data source standing in
  for a future radio. One replica is enough; this isn't the performance-critical
  part.
- No special networking needed; it just needs a stable service endpoint for
  the ingestion agent to connect to.

**Ingestion agent**
- **DaemonSet**, so it runs on every node designated to receive sensing data —
  in your simulated setup, that's your edge-labeled node (use a node selector
  or affinity so it doesn't spread pointlessly across all workers).
- `hostNetwork: true` for this workload specifically — deliberately bypass the
  pod network for this hop. This is also where a real SDR/NIC would plug in
  later via SR-IOV, so keep this component's boundary clean and single-purpose:
  its only job is "get bytes off the wire and into the cluster as fast as
  possible," nothing else.

**Preprocessing and inference**
- Deployments, but **pinned to the same node as the ingestion agent** using pod
  affinity keyed on node hostname. This is the most important scheduling
  decision in the system — without it, Kubernetes' default scheduler will
  happily spread these pods across nodes and reintroduce exactly the network
  hop you removed by dropping kube-proxy.
- Keep these as separate Deployments rather than merging into one pod/container
  — separating stages keeps each one independently scalable and testable, and
  the affinity rule already guarantees they land together.

**Output stage**
- A regular Deployment + Service exposing the detection result stream. This
  one doesn't need the same locality constraints — consumers of "object
  present/absent" downstream aren't as latency-sensitive as the detection
  pipeline itself.

---

## 5. Scheduling and affinity strategy (the core of the latency design)

- Use a **node label** to mark the edge-designated node distinctly from general
  cluster nodes.
- Use **node affinity** (not just a node selector) for the ingestion DaemonSet
  so it's restricted to edge-labeled nodes only, in case you later add more
  edge nodes and don't want ingestion agents anywhere else.
- Use **pod affinity with `topologyKey: kubernetes.io/hostname`** for
  preprocessing and inference, targeting the ingestion agent's pod labels. This
  is what actually enforces "same node" placement, not just "same node label."
- Consider **pod anti-affinity** for the simulator relative to the data-plane
  tier if you want to keep the "source" cleanly separate from the "sensor," but
  this is optional — the simulator isn't part of the hot path once the
  ingestion agent has received the data.
- Do **not** use taints/tolerations as your only mechanism to keep pipeline
  pods together — taints control *what's excluded*, affinity controls *what's
  together*. You need the latter here.

---

## 6. Service communication pattern

- Within the colocated tier (ingestion → preprocessing → inference), prefer
  **direct pod-to-pod communication** over a ClusterIP service where practical
  — a ClusterIP still goes through Cilium's service routing layer, which is
  fast but not free. Since these pods are guaranteed colocated, connecting
  directly (e.g. via a well-known local port) shaves off that layer entirely.
- For anything crossing tiers (e.g. output stage, monitoring scrape targets),
  normal Kubernetes Services are fine — those aren't on the latency-critical
  path.
- Avoid any component in the hot path going through an Ingress controller or
  external load balancer — those add hops meant for external traffic patterns,
  not intra-cluster low-latency streaming.

---

## 7. Observability plan

- **Hubble** (from Cilium) as your first line of network-level latency
  visibility — flow logs and latency metrics without deploying anything extra.
- **Prometheus** for application-level metrics — each pipeline stage should
  expose a latency histogram (time spent in that stage) and a throughput
  counter (frames processed). This is where you'll get your actual "input to
  detection" latency number by summing or tracing across stages.
- **Grafana** on top of Prometheus for dashboards once you have a few metrics
  worth looking at — not needed on day one, add it once the pipeline is
  producing real numbers.
- **bpftrace** as your deep-diagnosis tool when Hubble/Prometheus show a
  latency anomaly but not the cause — this is where you go to see exactly
  where time is being spent at the socket/scheduler level. Treat it as a
  targeted debugging tool, not a permanently-running component.

---

## 8. Resource and capacity planning

- Set explicit CPU/memory **requests and limits** on every pipeline component
  from the start, even in this dev/local setup — unbounded pods on a shared
  node can starve each other and produce misleading latency results that are
  actually just scheduling contention, not architecture problems.
- Give the inference component more headroom than the others if you're running
  any model heavier than a threshold-based detector — CPU-bound inference is
  the most likely bottleneck once the network hops are optimized away.

---

## 9. Security baseline (don't skip even for a local project)

- Restrict the ingestion agent's `hostNetwork` exposure — even locally, a pod
  with host networking has broad access to the node's interfaces, so scope
  what it listens on deliberately rather than binding wide-open.
- Apply Cilium **network policies** to restrict which pods can talk to which —
  e.g., only the ingestion agent should be able to reach preprocessing, only
  preprocessing should reach inference. This also makes Hubble's flow logs
  much more meaningful, since unexpected flows will stand out as policy
  violations rather than blending into normal traffic.
- Keep this namespace isolated from any other workloads you run on the same
  kind cluster.

---

## 10. Validation and testing plan

Before you consider the architecture "done," validate these explicitly:

1. **Placement check**: confirm ingestion, preprocessing, and inference pods
   are actually landing on the same node — don't assume the affinity rules
   worked, check it.
2. **CNI verification**: confirm kube-proxy is off and Cilium is handling
   service routing, and that Hubble is reporting flows.
3. **Baseline latency measurement**: with the simulator running, measure
   end-to-end latency from frame emission to detection output, using your
   Prometheus histograms. Record this as your baseline.
4. **Node-hop cost comparison**: as a deliberate experiment, temporarily remove
   the pod affinity rule and let the scheduler spread the pods across nodes,
   then re-measure latency. This gives you a concrete before/after number for
   why the affinity design matters — good for a portfolio write-up too.
5. **Load behavior**: increase the simulator's emission rate and watch where
   the pipeline first backs up (Prometheus counters will show which stage's
   throughput plateaus first) — that's your next optimization target.

---

## 11. Path to real hardware (keep this in mind, don't build it yet)

- Only the simulator component gets replaced — everything from the ingestion
  agent onward is designed to be source-agnostic.
- When a real SDR or WiFi-CSI-capable NIC is introduced, the ingestion agent's
  `hostNetwork` pod becomes the place to add **SR-IOV device plugin** support
  (for direct virtual-function access to the NIC) and, if needed, **Multus**
  for attaching that secondary high-throughput interface alongside the pod's
  normal cluster-facing network.
- If the real data arrives over Ethernet at high rate, this is also where an
  **XDP/AF_XDP** based capture path would sit, ahead of the normal socket path
  — the same eBPF investment you're making with Cilium now transfers directly
  to this later step.

---

## Build order checklist

1. Write a kind cluster config with 1 control-plane + 2+ worker nodes, default
   CNI disabled.
2. Install Cilium (kube-proxy replacement mode), enable Hubble, verify.
3. Label the edge-designated worker node.
4. Create the `isac-sensing` namespace.
5. Deploy the simulator.
6. Deploy the ingestion agent as a DaemonSet with `hostNetwork`, restricted to
   the edge node via node affinity.
7. Deploy preprocessing and inference with pod affinity to the ingestion agent.
8. Deploy the output stage and its Service.
9. Add resource requests/limits to all components.
10. Add Cilium network policies scoping allowed traffic between stages.
11. Instrument each stage with Prometheus metrics; deploy Prometheus + Grafana.
12. Run the validation plan (section 10) and record baseline latency numbers.
13. Only after all of the above: begin planning the real-hardware swap-in.
