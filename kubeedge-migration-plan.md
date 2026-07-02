# KubeEdge migration plan — replace k3s with KubeEdge (cloudcore/edgecore + EdgeMesh)

Goal: eliminate k3s entirely and run the same ISAC sensing architecture on **KubeEdge**.
Same logical shape — edge nodes run the sensing hot-path, results fan in to a central
cloud collector, cloud has the observability (latency), and a final UI shows every edge
node, its data, and its latency. This is a node-layer + networking-layer swap; the
application code and the fan-in/dashboard design mostly survive (that was the point of the
edge/center seam called out in `edge-fleet-plan.md`).

Status: **PLAN ONLY — not implemented.** Open decisions at the end need your input first.

---

## 1. What KubeEdge actually is (and what it forces)

KubeEdge is **not** a standalone cluster — it's an edge extension bolted onto an upstream
Kubernetes control plane. So "eliminate k3s" splits into two moves:

- **Edge join mechanism:** `k3s agent` → **edgecore** (`keadm join`). This is the real win —
  edgecore is ~70 MB idle vs k3s-agent's ~250–512 MB, has no kube-proxy/etcd, and gives
  edge autonomy (survives cloud disconnect via `metamanager`'s local metadata store).
- **Cloud control plane:** the k3s *server* still has to become *some* conformant k8s, because
  cloudcore runs on top of one. To fully drop k3s that means **kubeadm** (single node, control-plane
  untainted so it also runs `output`/prometheus/grafana). See Decision A — this is the one place
  we can't avoid picking a replacement.

Component model after migration:

```
  CLOUD NODE (kubeadm control-plane, untainted)        EDGE NODE ×N (keadm join, no kubelet/kube-proxy)
  ┌───────────────────────────────────────┐           ┌──────────────────────────────────────┐
  │ kube-apiserver / etcd / scheduler      │           │ edgecore:                              │
  │ CloudCore:                             │  websocket │   edged        (lightweight kubelet)   │
  │   CloudHub  (edges connect here)       │<==========>│   edgehub      (ws client to cloud)    │
  │   EdgeController / DeviceController     │  :10000/   │   metamanager  (offline autonomy)      │
  │   CloudStream  (kubectl logs/exec)     │  :10003/4  │   edgeStream   (logs/exec tunnel)      │
  │   dynamicController (EdgeMesh needs it) │           │   metaServer   (EdgeMesh needs it)     │
  │ output(collector)+dashboard, prom, graf │           │ simulator→ingestion→preproc→inference  │
  │ edgemesh-agent (DaemonSet)             │           │ edgemesh-agent (DaemonSet)             │
  └───────────────────────────────────────┘           └──────────────────────────────────────┘
                     ^  DetectionResult (only cross-node hop) via EdgeMesh / NodePort
                     └────────────────────────────────────────────────┘
```

---

## 2. The hard problems and how KubeEdge solves each

### 2.1 Networking — no kube-proxy/DNS on edge (biggest change)

Edge nodes have **no kube-proxy and no cluster DNS**. Today's design leans on both:
`internalTrafficPolicy: Local` is a kube-proxy feature, and every hop resolves a Service name
(`ingestion:50051`, `output:50054`). Under KubeEdge both stop working as-is.

Two hops to solve, they're different:

**(a) Node-local hot path** (`simulator→ingestion→preproc→inference`, same node):
- **EdgeMesh** (KubeEdge's service-mesh, a per-node `edgemesh-agent` DaemonSet) restores
  Service discovery + DNS on edge and edge↔edge/edge↔cloud proxying. It does **not** honor
  `internalTrafficPolicy: Local`, so we drop that field. To keep the hot path on-node we either:
  - **B1 (recommended):** make all four hot-path pods `hostNetwork: true` (ingestion already is)
    and rewire each stage to `localhost:<port>`. DaemonSet = exactly one pod per node, so
    `localhost:50052` is *always* this node's preprocessing. No mesh needed for intra-node hops,
    zero cross-node smear by construction, sub-ms preserved. Cleanest + most reliable.
  - **B2:** keep ClusterIP Services and rely on EdgeMesh routing (drop `internalTrafficPolicy`).
    More "mesh-native" but EdgeMesh may route a frame to another node's pod — reintroduces the
    hop we removed. Needs EdgeMesh topology/label pinning to be safe. More moving parts.

**(b) Cross-node fan-in** (`inference→output:50054`, `simulator→output:50054`, edge→cloud):
- **EdgeMesh** resolves `output` on the edge and proxies edge→cloud (the KubeEdge-native path,
  matches "all its nested features"). Requires cloudcore `dynamicController` + edgecore `metaServer`.
- **or NodePort/hostIP:** expose `output` on a NodePort and point edge at `<cloud-lan-ip>:3XXXX`.
  Dead-simple, bypasses EdgeMesh for the one hop, very reliable on a LAN. Good fallback / can
  coexist. See Decision B.

### 2.2 Observability — cloud can't scrape edge pod IPs (the subtle one)

Prometheus today uses `kubernetes_sd_configs: role: pod` and scrapes each pod's **raw pod IP**.
Edge pod IPs are **not routable from the cloud** under KubeEdge. So the current scrape config
silently collects nothing from edge (simulator/ingestion/preproc/inference metrics: queue depth,
drops, per-stage histograms, clock-offset). This is the core "check the latency" risk.

**Chosen strategy — push through the fan-in (recommended).** The key realization: *the latency
data already travels to the cloud.* Every `DetectionResult` carries `ingestion_latency_ns`,
`preprocessing_latency_ns`, `inference_latency_ns`, and the emission timestamp — and `output` on
the cloud already computes `output_end_to_end_latency_raw_ms` per node. So:
- Expand `output.py`'s Prometheus metrics to expose **per-node, per-stage latency histograms**
  from the fan-in it already receives (data's already there; just observe it into labeled histograms).
- Prometheus then scrapes **only cloud-side pods** (`output`), which are trivially reachable. No
  cloud→edge scraping at all. This is *more* correct for KubeEdge's disconnected model, not a hack.
- Edge-internal-only gauges (dispatch queue depth, `frames_dropped`, RPC-hop histogram) that aren't
  in `DetectionResult`: fold the important ones into a small side-channel (extra fields on the
  result or a lightweight periodic report to `output`), or accept losing them for v1. See Decision C.

Alternative (Decision C): keep pull-based scraping but route Prometheus→edge through the
**EdgeMesh gateway** / a per-edge metrics proxy. More KubeEdge-native but fragile (scraping raw
pod IPs through a mesh is awkward) and breaks the moment an edge goes offline.

### 2.3 `kubectl logs` / `exec` to edge pods — needs the stream tunnel

"See the logs" for edge pods requires KubeEdge's **CloudStream** (cloudcore) + **edgeStream**
(edgecore) + the `iptables-manager`, plus a streaming server cert. Off by default. We enable it in
cloudcore/edgecore config so `make logs-*` keeps working against edge pods. (App logs also surface
in the dashboard already — the tunnel is for `kubectl`-level debugging.)

### 2.4 DaemonSet scheduling onto edge nodes

KubeEdge taints edge nodes; the edge DaemonSets need a **toleration** for the edge node-role taint,
and we keep `nodeSelector: isac-edge=true` as the on-switch. Also: kubeadm's default kube-proxy
DaemonSet will try to run on edge nodes and fail — standard KubeEdge fix is to patch kube-proxy's
affinity to exclude `node-role.kubernetes.io/edge`. Add that to setup.

### 2.5 Registry / images

Same multi-arch registry approach (`buildx --platform amd64,arm64 --push`). edgecore uses
containerd — configure the insecure registry in each edge device's containerd config (not
`/etc/rancher/k3s/registries.yaml` anymore).

### 2.6 (Optional) Device twins / MQTT — the KubeEdge "nested feature"

KubeEdge's DeviceController + `eventbus` (MQTT) can model each edge node as a **Device with a twin**
(status/battery/temp/heartbeat). We could publish node health as a device twin and surface it on the
UI — this is the IoT feature k3s can't do and directly matches "all its nested features". Adds a
`Device`/`DeviceModel` CRD per node + an MQTT client on edge. Scope decision — see Decision D.

---

## 3. Per-artifact change list

| Artifact | Change |
|---|---|
| **Cloud bring-up** (new) | kubeadm single-node (untainted) + CNI (flannel/calico) for cloud pods. Replaces `curl get.k3s.io`. |
| **CloudCore** (new) | `keadm init` (or helm) with `cloudStream` + `dynamicController` enabled; expose CloudHub via hostIP/NodePort so edges reach it. |
| **EdgeMesh** (new) | `edgemesh-agent` DaemonSet + config on cloud & edge; set clusterDNS/clusterDomain; enable edgecore `metaServer`. |
| `scripts/onboard-edge.sh` | Rework: precondition is now `keadm join` (edgecore) not `k3s agent`. Label + rollout-wait logic mostly stays. |
| `scripts/join-edge.sh` (new) | Wrap `keadm join --cloudcore-ipport=… --token=… --edgenode-name=…` + containerd insecure-registry setup. |
| `02-simulator.yaml` `03-ingestion.yaml` `04-preprocessing.yaml` `05-inference.yaml` | Add edge-taint **toleration**. If B1: set `hostNetwork: true` on simulator/preproc/inference and rewire env targets to `localhost:<port>`; drop the node-local ClusterIP Services (or keep for cloud-side only). Keep `nodeSelector: isac-edge=true`. Drop `internalTrafficPolicy: Local`. |
| `05-inference.yaml` / `simulator` env | `OUTPUT_SERVICE` / `CLOCK_SYNC_TARGET`: `output:50054` (EdgeMesh) **or** `<cloud-ip>:<nodeport>` (Decision B). `EDGE_NODE_NAME` via downward API still works on edgecore. |
| `06-output.yaml` | If NodePort chosen for fan-in, add a NodePort Service for `:50054`. Dashboard Service unchanged (still cloud-side). |
| `07-network-policies.yaml` | **CiliumNetworkPolicy won't apply on edge** (no Cilium there). Either drop it, or replace with EdgeMesh-compatible policy / plain k8s NetworkPolicy on cloud only. Likely remove for v1. |
| `09-prometheus.yaml` | Rewrite scrape: cloud-side pods only (drop `role: pod` over edge). Rely on `output`'s pushed per-node metrics. |
| `10-grafana.yaml` | Dashboards: repoint stage-latency panels at the new `output`-side per-node metrics. |
| `output.py` | Add per-node/per-stage latency histograms observed from the fan-in it already receives (§2.2). Optionally ingest edge-side gauges via side-channel. Dashboard HTML: add per-node latency + (optional) device-twin status. |
| `services/*/`*.py | If B1: change hardcoded/env service targets to `localhost:<port>`. Otherwise minimal. |
| `Makefile` | Rip out `cilium` target (or repurpose as cloud CNI install). New targets: `cloud-init` (kubeadm+cloudcore), `edgemesh`, `keadm-token`, `join-edge`. `build-images`/`deploy`/`validate`/`clean` largely survive (retarget contexts). |
| `README.md` | Rewrite setup: kubeadm+cloudcore, `keadm join`, EdgeMesh, new observability model. |
| `cluster/cilium-values.yaml` | Remove or replace (Cilium no longer the edge CNI; EdgeMesh handles edge). |

---

## 4. New end-to-end flow (target)

```
# cloud, once
make cloud-init          # kubeadm single-node + CNI + cloudcore (cloudStream+dynamicController)
make edgemesh            # deploy edgemesh-agent + config
make build-images REGISTRY=<lan-ip>:5000
make namespace && make deploy REGISTRY=<lan-ip>:5000   # DaemonSets 0 pods until an edge is labeled

# per edge device, once
make keadm-token                                 # print join token
./scripts/join-edge.sh <cloudcore-ip> <node>     # keadm join + containerd insecure-registry
make onboard-edge EDGE_NODE_NAME=<node>          # label isac-edge=true + wait for pipeline Ready

# view
make dashboard-url        # http://<cloud-ip>:<nodeport>/  → fleet UI (nodes + latency + log)
make port-forward-grafana # latency dashboards
```

---

## 5. Validation plan

1. `kubectl get nodes` — edge nodes `Ready`, carry `node-role.kubernetes.io/edge`, correct arch.
2. edgecore healthy; CloudHub shows edges connected; **kill cloud link, confirm edge pods keep running** (autonomy — the KubeEdge selling point k3s lacks).
3. Placement: hot-path pods on each edge node, `output`/prom/grafana on cloud.
4. EdgeMesh: DNS resolves `output` from an edge pod; `inference→output` delivers results.
5. `kubectl logs` against an edge pod works (stream tunnel).
6. Dashboard shows every edge node online, per-node frames/detections, **per-node latency**.
7. Latency numbers land in Prometheus/Grafana from the `output`-side metrics; compare vs the k3s
   baseline (~4 ms e2e) recorded in the README to see the runtime swap's cost/benefit.
8. Onboard a 2nd edge node → appears on dashboard within seconds, no per-node manifests.

---

## 6. Risks / unknowns

- **edgecore under Termux/proot on non-rooted Android is unproven** (same risk k3s-agent had; arguably
  worse — edgecore expects containerd). If the phone is still the target device, keep the Pi/VM fallback.
- EdgeMesh adds real complexity; its edge↔cloud proxy is the most failure-prone new piece. NodePort
  fallback (Decision B) de-risks the critical fan-in hop independently of EdgeMesh.
- kubeadm single-node is heavier ops than k3s (etcd, certs, upgrades) — but it's the cost of "no k3s".
- Version skew: keadm/KubeEdge must match the kubeadm k8s minor version — pin deliberately.
- Losing per-edge internal gauges (queue depth/drops) if we go pure push (§2.2) — decide what's worth
  the side-channel.

---

## 7. DECISIONS — LOCKED (2026-07-02)

- **A. Cloud k8s distro:** ✅ **kubeadm single-node** (untainted, also runs output/prom/grafana).
- **B+E. Networking:** ✅ **hostNetwork+localhost for the on-node hot path (B1)** + **EdgeMesh for
  the edge→cloud fan-in, NodePort as fallback.** EdgeMesh stays in the stack for the cross-node hop;
  intra-node hops don't touch it.
- **C. Edge observability:** ✅ **push-through-fan-in** — `output` on cloud exposes per-node/per-stage
  latency histograms from the `DetectionResult` stream it already receives; Prometheus scrapes
  cloud-side only. Edge-internal-only gauges (queue depth/drops) deferred (v1 accepts losing them,
  revisit via side-channel later).
- **D. Device twins / MQTT:** ✅ **skip for v1** (core migration first; add later).
- **F. Edge device target:** ✅ **laptop as a Linux edge node** for the draft. The existing
  `simulator` (synthetic CSI) is the dummy-data stand-in for the future **6G ISAC sensor** — no
  data-gen change (master-plan §11: only the simulator gets swapped for real hardware later).

### Draft (v1) topology — local dev loop
- **Cloud:** kubeadm single-node (a VM or a second host), cloudcore + EdgeMesh + output/prom/grafana.
- **Edge:** the laptop runs edgecore, joins cloudcore over the LAN, runs the hot-path DaemonSets
  (simulator→ingestion→preproc→inference). Same-LAN registry pull, unchanged from k3s.
- Everything above the node/network layer is identical to the eventual 6G deployment — only the
  simulator is later replaced by the real sensor feed.

### Consequences of the locked choices
- All four hot-path DaemonSets become `hostNetwork: true`; stage targets rewired to `localhost:<port>`;
  node-local ClusterIP Services + `internalTrafficPolicy: Local` dropped. EdgeMesh only resolves `output`.
- `output.py` grows per-node/per-stage latency histograms; `09-prometheus.yaml` scrape rewritten to
  cloud-side pods only; Grafana panels repointed. No cloud→edge scraping.
- No Device/DeviceModel CRDs, no MQTT/eventbus work in v1.
```
