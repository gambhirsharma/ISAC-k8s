# ISAC-k8s — multi-edge sensing fleet on KubeEdge

Pipeline: 5 gRPC microservices (`simulator → ingestion → preprocessing → inference → output`)
with Prometheus/Grafana, on **KubeEdge** — a kubeadm cloud control plane (cloudcore) with a
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
cloud disconnect) and the k3s server with a **kubeadm** control plane running **cloudcore**. The
app code and the fan-in/dashboard design are unchanged — this was a node-layer + networking-layer
swap. See the migration plan for the full reasoning.

## Cluster shape

| Node | KubeEdge role | Runs |
|---|---|---|
| cloud host (kubeadm control-plane, **untainted**) | `cloudcore` (CloudHub + cloudStream + dynamicController) | `output` (collector+dashboard), `prometheus`, `grafana`, `edgemesh-agent` |
| edge node ×N (`edgecore`, label `isac-edge=true`) | `edged` + `edgehub` + `metamanager` + `edgeStream` + `metaServer` | `simulator`, `ingestion`, `preprocessing`, `inference` (one set per edge node, via DaemonSets) + `edgemesh-agent` |

Edge workloads are **DaemonSets** gated on `isac-edge=true` and tolerating the edge node-role
taint, so labeling a node schedules the whole pipeline onto it. `output`/monitoring are pinned OFF
edge nodes (nodeAffinity `isac-edge NotIn true`).

### Networking (the KubeEdge-specific part)

Edge nodes have **no kube-proxy and no cluster DNS**, so the design routes deliberately:

- **Node-local hot path** (`simulator→ingestion→preproc→inference`): all four DaemonSets run
  `hostNetwork: true` and talk over **`localhost:<port>`**. DaemonSet = exactly one pod per node,
  so `localhost:50052` is always *this* node's preprocessing. No Service, no kube-proxy, no
  cross-node smear, sub-ms. The old `internalTrafficPolicy: Local` Services are gone.
- **Cross-node fan-in** (`inference→output:50054`, `simulator→output:50054` for clock-sync): the
  ONE hop that leaves the node. Resolved by **EdgeMesh** (edge pods use
  `dnsPolicy: ClusterFirstWithHostNet` so cluster DNS/EdgeMesh works despite hostNetwork).
  **Fallback:** `output` is also a NodePort (`30054`) — set `OUTPUT_SERVICE` / `CLOCK_SYNC_TARGET`
  to `<cloud-ip>:30054` on the edge DaemonSets if EdgeMesh routing isn't available.

### Observability (push-through-fan-in)

The cloud **cannot scrape edge pod IPs** under KubeEdge. So all edge latency observability rides
the gRPC fan-in: every `DetectionResult` already carries per-stage timings, and `output` re-exports
them as Prometheus metrics **labeled per edge node**:
- `output_end_to_end_latency_raw_ms{edge_node}` — e2e latency (raw, not clock-skew corrected)
- `output_stage_latency_ms{edge_node,stage}` — per-stage local latency (`ingestion`/`preprocessing`/`inference`)
- `output_results_stored_total{edge_node}`, `output_edge_nodes_connected`

Prometheus scrapes **only the cloud-side `output` pod** (`09-prometheus.yaml` keeps `app=output`).
Grafana's dashboard (`10-grafana.yaml`) is rebuilt around these per-node metrics. Edge-internal-only
gauges (queue depth, drops, clock offset) are not collected in v1 — see the migration plan §2.2 / §6.

Two namespaces: `isac-sensing` (the pipeline) and `isac-monitoring` (prometheus+grafana, RBAC via a
cross-namespace RoleBinding — unchanged from before).

## Setup

### 0. Draft (local) topology

For the first pass everything runs on/near your laptop:
- **Cloud:** a kubeadm single-node cluster (a VM or a second host), untainted, with cloudcore.
- **Edge:** your laptop runs edgecore and joins cloudcore over the LAN, running the hot-path.

Everything above the node/network layer is identical to the eventual 6G deployment.

### 1. Cloud control plane (once, on the cloud host, root)

Stand up a kubeadm single-node cluster (untaint the control-plane so it runs app pods), install a
CNI, and merge its kubeconfig locally as context `kubeadm-isac`. Install `keadm`
(https://kubeedge.io/docs/setup/install-with-keadm). Then:
```
make cloud-init CONTEXT=kubeadm-isac CLOUDCORE_IP=<cloud host LAN/public IP>
make edgemesh   CONTEXT=kubeadm-isac EDGEMESH_PSK=$(openssl rand -base64 32)
```
`cloud-init` runs `keadm init` with `cloudStream` (for `kubectl logs`/`exec` to edge) and
`dynamicController` (for EdgeMesh) enabled, then patches kube-proxy off edge nodes.

### 2. Join an edge device (once per device)

Get a token on the cloud host, then join from the edge device (one command does everything —
installs containerd if missing, keadm, a minimal CNI, then joins):
```
make keadm-token                                        # on the cloud host
sudo ./scripts/join-edge.sh <cloudcore-ip> <node> <token>   # on the edge device
```
With the default **public Docker Hub** images, omit the registry arg — the edge pulls over TLS with
no extra config. For a private/LAN registry, pass it as a 4th arg (or run
`scripts/setup-edge-registry.sh <registry>`), which writes containerd's insecure-registry config.
edgecore needs a CNI to report `Ready` even though the hot-path pods are hostNetwork —
`join-edge.sh` installs one via `scripts/setup-edge-cni.sh`. Confirm with
`kubectl --context kind-isac get nodes -o wide` (node `Ready`, correct arch). **Soak it** before
onboarding — a flapping node should be caught here, not while debugging the pipeline.

### 3. Images, namespace, pipeline
Default `REGISTRY` is the public Docker Hub namespace `gambhir` (images public → edge pulls with no
insecure-registry config). Override for your own namespace or a private/LAN registry.
```
make build-images REGISTRY=gambhir            # docker buildx --push to docker.io/gambhir/isac-*
make namespace CONTEXT=kind-isac
make deploy CONTEXT=kind-isac REGISTRY=gambhir # edge DaemonSets stay 0 pods until a node is labeled
```

### 4. Onboard edge nodes (per node)
```
make smoke-test CONTEXT=kubeadm-isac                              # optional: throwaway pod on an edge node
make onboard-edge CONTEXT=kubeadm-isac EDGE_NODE_NAME=<node>      # labels isac-edge=true + waits for the pipeline
```
`onboard-edge` labels the node, then `kubectl rollout status` each edge DaemonSet so it returns only
once that node's `simulator/ingestion/preprocessing/inference` are up. The node then shows as
**online** on the dashboard within seconds. Remove a node: `make offboard-edge EDGE_NODE_NAME=<node>`.

### 5. Fleet dashboard + latency
```
make port-forward-dashboard CONTEXT=kubeadm-isac   # -> http://localhost:8080/  (nodes + per-node latency + log)
make port-forward-grafana   CONTEXT=kubeadm-isac   # -> http://localhost:3000/  (fleet latency dashboards)
```
The dashboard (served by `output`) shows the live edge-node count, per-node cards (frames,
detections, **avg e2e latency**, uptime), and a searchable/filterable detection log. It is a
ClusterIP (unauthenticated) — reach it via `port-forward`, not a node port.

## Verification checklist

- `kubectl --context kubeadm-isac get nodes -o wide` — edge nodes `Ready`, carry
  `node-role.kubernetes.io/edge`, correct arch.
- **Edge autonomy:** kill the cloud link; confirm edge hot-path pods keep running (KubeEdge's key
  advantage over k3s-agent). Results resume fanning in when the link returns.
- `kubectl --context kubeadm-isac get pods -n isac-sensing -o wide` — hot-path pods on each edge
  node; `output` on the cloud node.
- EdgeMesh: from an edge pod, `output` resolves and `inference` delivers results (or use the
  `:30054` NodePort fallback).
- `kubectl --context kubeadm-isac logs -n isac-sensing -l app=inference` — works (stream tunnel).
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
- **kubeadm single-node** is heavier ops than k3s (etcd, certs, upgrades) — the cost of "no k3s".
- **Version skew:** keadm/KubeEdge must match the kubeadm k8s minor version — pin deliberately.
- **Lost edge-internal metrics** (queue depth/drops/clock offset) under pure push — accepted for v1,
  revisit via a side-channel if needed (migration plan §6).
- `insecure_channel` (no TLS) and the insecure registry stay acceptable only on a trusted LAN. Put
  edges behind WireGuard/Tailscale if they ever move to an untrusted network.
