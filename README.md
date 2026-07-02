# ISAC-k8s — multi-edge sensing fleet on KubeEdge

Pipeline: 5 gRPC microservices (`simulator → ingestion → preprocessing → inference → output`)
with Prometheus/Grafana, on **KubeEdge** — a kind cloud control plane (cloudcore) with a
fleet of **edgecore** edge nodes. Each edge node runs the whole detection hot-path
(`simulator → ingestion → preprocessing → inference`) locally; only the resulting
`DetectionResult` fans in over the network to a single central `output` collector, which tracks
how many edge nodes are connected, records their latency, and serves a web dashboard with a
searchable detection log. Add an edge node → join it with `keadm` → label it → its pipeline
auto-schedules and starts reporting.

The `simulator` generates synthetic CSI as a stand-in for a future **6G ISAC sensor** feed — only
that component gets swapped for real hardware later; everything downstream is source-agnostic.

Design + the k3s→KubeEdge migration rationale and locked decisions:
[`kubeedge-migration-plan.md`](kubeedge-migration-plan.md). Fleet/collector design:
[`edge-fleet-plan.md`](edge-fleet-plan.md). This README is the "what's implemented + how to run it"
companion.

## Why KubeEdge (vs the previous k3s build)

KubeEdge replaces k3s-agent with **edgecore** (~70 MB idle, no kube-proxy/etcd, edge autonomy on
cloud disconnect). cloudcore runs on an upstream Kubernetes — here a **kind** cluster (real k8s
inside Docker: isolated, no host changes, coexists with anything else on the box). Edge devices
join cloudcore over a websocket, not as k8s nodes, so the cloud's CNI is irrelevant to them — which
is exactly why kind works as the cloud even with a physical device as the edge. The app code and
the fan-in/dashboard design are unchanged. See the migration plan for the full reasoning.

## Cluster shape

| Node | KubeEdge role | Runs |
|---|---|---|
| cloud host (**kind** cluster, single untainted node) | `cloudcore` (CloudHub + cloudStream + dynamicController) | `output` (collector+dashboard), `prometheus`, `grafana` |
| edge node ×N (`edgecore`, label `isac-edge=true`) | `edged` + `edgehub` + `metamanager` + `edgeStream` | `simulator`, `ingestion`, `preprocessing`, `inference` (one set per edge node, via DaemonSets) |

Edge workloads are **DaemonSets** gated on `isac-edge=true` and tolerating the edge node-role
taint, so labeling a node schedules the whole pipeline onto it. `output`/monitoring are pinned OFF
edge nodes (nodeAffinity `isac-edge NotIn true`).

### Networking (the KubeEdge-specific part)

Edge nodes have **no kube-proxy and no cluster DNS**, so the design routes deliberately:

- **Node-local hot path** (`simulator→ingestion→preproc→inference`): all four DaemonSets run
  `hostNetwork: true` and talk over **`localhost:<port>`**. DaemonSet = exactly one pod per node,
  so `localhost:50052` is always *this* node's preprocessing. No Service, no kube-proxy, no
  cross-node smear, sub-ms. The old `internalTrafficPolicy: Local` Services are gone.
- **Cross-node fan-in** (`inference→output`, `simulator→output` for clock-sync): the ONE hop that
  leaves the node. Current default is the **NodePort** `output` on `30054` — edge `OUTPUT_SERVICE` /
  `CLOCK_SYNC_TARGET` point at `<cloud-ip>:30054` (simple, reliable). **EdgeMesh** (native service
  resolution of `output:50054`, edge pods carry `dnsPolicy: ClusterFirstWithHostNet` for it) is the
  planned upgrade — deferred in v1; the manifests still name `output:50054` as the default.

### Observability (push-through-fan-in)

The cloud **cannot scrape edge pod IPs** under KubeEdge. So all edge latency observability rides
the gRPC fan-in: every `DetectionResult` already carries per-stage timings, and `output` re-exports
them as Prometheus metrics **labeled per edge node**:
- `output_end_to_end_latency_raw_ms{edge_node}` — e2e latency (raw, not clock-skew corrected)
- `output_end_to_end_latency_corrected_ms{edge_node}` — e2e minus the edge's reported clock offset
- `output_stage_latency_ms{edge_node,stage}` — per-stage local latency (`ingestion`/`preprocessing`/`inference`)
- `output_edge_clock_offset_ms{edge_node}` — offset the edge reports via the clock-sync probe
- `output_results_stored_total{edge_node}`, `output_edge_nodes_connected`

The edge computes its clock offset (NTP min-RTT) and reports it to `output` on each clock-sync
probe; `output` subtracts it to produce the corrected e2e. Prometheus scrapes **only the cloud-side
`output` pod** (`09-prometheus.yaml` keeps `app=output`). Grafana's dashboard (`10-grafana.yaml`) is
built around these per-node metrics. Edge-internal-only gauges (dispatch queue depth, drop reasons)
aren't collected in v1 — see the migration plan §2.2 / §6.

Two namespaces: `isac-sensing` (the pipeline) and `isac-monitoring` (prometheus+grafana, RBAC via a
cross-namespace RoleBinding — unchanged from before).

## Setup

### 0. Topology

- **Cloud:** a **kind** cluster (real k8s in Docker) on any Linux host, running cloudcore +
  `output`/prometheus/grafana. Isolated — no host changes, coexists with other workloads.
- **Edge:** either a real Linux device/VM running edgecore (see 2a), or a co-located test edge
  container on the same host (see 2b).
- Edges reach cloudcore over a chosen network — a **Tailscale** IP is the clean default (encrypted,
  no public exposure, works across networks).

Everything above the node/network layer is identical to the eventual 6G deployment.

### 1. Cloud control plane (once)

Needs only Docker (kind/kubectl/keadm auto-install to `~/.local/bin`, sudo-free):
```
make cloud-init CLOUDCORE_IP=<ip edges will dial, e.g. your Tailscale IP>
```
`cloud-init.sh` creates the kind cluster (`cluster/kind-cloud-config.yaml`, cloudcore ports
published only on `CLOUDCORE_IP`), runs `keadm init` with `cloudStream` (kubectl logs/exec to edge)
and `dynamicController` (EdgeMesh) enabled, and patches kube-proxy + kindnet off edge nodes. Context
becomes `kind-isac`.

### 2. Images + pipeline (once)
Default `REGISTRY` is the public Docker Hub namespace `gambhir` (images public → edge pulls with no
insecure-registry config). Override for your own namespace or a private/LAN registry.
```
make build-images REGISTRY=gambhir             # docker buildx --push to docker.io/gambhir/isac-*
make namespace CONTEXT=kind-isac
make deploy CONTEXT=kind-isac REGISTRY=gambhir # edge DaemonSets stay 0 pods until a node is labeled
```

### 3a. Add a real edge device (Linux VM/host)
One command on the device does everything — installs containerd if missing, keadm, a minimal CNI,
then joins:
```
make keadm-token                                              # on the cloud host
sudo ./scripts/join-edge.sh <CLOUDCORE_IP> <node> <token>    # on the edge device
```
Public Docker Hub images → omit the registry arg. Private/LAN registry → pass it as a 4th arg (or
run `scripts/setup-edge-registry.sh <registry>`). Then onboard from the cloud host:
```
make onboard-edge CONTEXT=kind-isac EDGE_NODE_NAME=<node>    # label isac-edge=true + wait for the hot-path
```

### 3b. Or a co-located test edge (same host, no extra device)
One command builds a privileged `kindest/node` container, joins it, and onboards it:
```
make edge-container CONTEXT=kind-isac CLOUDCORE_IP=<ip> EDGE_NODE_NAME=edge-hetzner
```
Great for validating the pipeline on one box. It uses the kind node's internal IP for the fan-in
(co-located fast path). Remove: `docker rm -f isac-edge-<node> && kubectl --context kind-isac delete node <node>`.

### 4. Fleet dashboard + latency
```
make port-forward-dashboard CONTEXT=kind-isac   # -> http://localhost:8080/  (nodes + per-node latency + log)
make port-forward-grafana   CONTEXT=kind-isac   # -> http://localhost:3000/  (fleet latency dashboards)
```
The dashboard (served by `output`) shows the live edge-node count, per-node cards (frames,
detections, **avg e2e latency corrected + raw**, clock offset, uptime), and a searchable detection
log. It is a ClusterIP (unauthenticated) — reach it via `port-forward`, not a node port.
Remove a node: `make offboard-edge CONTEXT=kind-isac EDGE_NODE_NAME=<node>`.

## Verification checklist

- `kubectl --context kind-isac get nodes -o wide` — edge nodes `Ready`, carry
  `node-role.kubernetes.io/edge`, correct arch.
- **Edge autonomy:** kill the cloud link; confirm edge hot-path pods keep running (KubeEdge's key
  advantage over k3s-agent). Results resume fanning in when the link returns.
- `kubectl --context kind-isac get pods -n isac-sensing -o wide` — hot-path pods on each edge
  node; `output` on the cloud node.
- EdgeMesh: from an edge pod, `output` resolves and `inference` delivers results (or use the
  `:30054` NodePort fallback).
- `kubectl --context kind-isac logs -n isac-sensing -l app=inference` — works (stream tunnel).
- Dashboard shows every edge node online with per-node avg e2e latency.
- Grafana: fleet-wide + per-node e2e latency and per-stage latency show continuous data. Compare the
  e2e number against the k3s baseline (~4 ms) to quantify the runtime swap.
- Onboard a 2nd edge node → appears within seconds, no per-node manifests.

## Clock sync

`output`'s end-to-end latency is `time.time_ns() - request.timestamp_ns`, and that timestamp
originates on the edge node. Two independently-clocked machines means clock skew silently corrupts
the raw e2e number. `simulator` still probes `output`'s `ClockSyncService` (NTP-style min-RTT
offset), but under the push-through-fan-in model that offset gauge is no longer scraped from the
edge in v1 — so the Grafana e2e panels are labeled **raw**. Verify clocks manually before trusting
absolute e2e numbers:
```
date -u   # on the cloud host
date -u   # on the edge device
```

## Risks

- **edgecore under Termux/proot on non-rooted Android is unproven** — arguably worse than k3s-agent
  was (edgecore expects containerd). The draft targets a laptop/VM edge; keep a Pi/VM fallback before
  trying a phone.
- **EdgeMesh is the most failure-prone new piece.** The `:30054` NodePort fallback de-risks the
  critical fan-in hop independently of EdgeMesh.
- **kind cloud** is a dev-grade control plane (single Docker node, no HA) — fine for this
  spike/portfolio; a production cloud would be a managed/HA k8s, cloudcore unchanged on top.
- **Version skew:** keadm/KubeEdge must match the kind node's k8s minor version (KubeEdge 1.23 → k8s
  ≤1.32; pinned to node image v1.32.5) — pin deliberately.
- **Lost edge-internal metrics** (queue depth/drops/clock offset) under pure push — accepted for v1,
  revisit via a side-channel if needed (migration plan §6).
- `insecure_channel` (no TLS) and the insecure registry stay acceptable only on a trusted LAN. Put
  edges behind WireGuard/Tailscale if they ever move to an untrusted network.
