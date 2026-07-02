# Edge fleet: multi-edge onboarding + central collector/dashboard

This is the design for turning the single-phone spike into a **multi-edge fleet**:
add an edge node → it auto-runs the sensing pipeline → its detection results fan in
to one central collector → a web dashboard shows how many edge nodes are connected
and a searchable log of what they're detecting.

## Goal (from the request)

- Adding an edge device sets up a simulation pod on it that generates data.
- That data flows to the main cluster.
- In the main cluster you can see the logs.
- A simple dashboard: how many edge nodes are connected + the log data, searchable.
- An onboarding process for adding a new node that brings the resources it needs.

## The runtime decision: k3s-agent + DaemonSets now, KubeEdge later

The original idea was KubeEdge (edgecore on each device, cloudcore on the k3s
cluster). We evaluated it against extending the current k3s-agent setup:

| | k3s-agent + DaemonSet (**chosen now**) | KubeEdge + EdgeMesh |
|---|---|---|
| Edge idle RAM | ~250–512 MB (full kubelet+containerd+CNI+kube-proxy) | ~70 MB (lightweight `edged`, no kube-proxy/etcd) — genuinely lighter |
| Onboarding | `k3s agent --token …` then label node | `keadm join --token …` (purpose-built) |
| Networking | Services/DNS work today | breaks; needs **EdgeMesh** for edge↔cloud pod traffic |
| Offline / WAN edge | weak (agent flaps on disconnect) | strong (edge autonomy) |
| IoT device mgmt | none | device twins / MQTT |
| Setup risk | low; proven on this LAN | high; `edgecore` under Termux/proot is unproven |

**Decision:** build the feature on **k3s-agent + DaemonSets** now — it satisfies every
requirement on the LAN with low risk, and the design keeps a clean **edge/center seam**
so switching the *node-join mechanism* to KubeEdge later is a node-layer change only
(nothing above it moves — same philosophy as the earlier kind→k3s migration).

**KubeEdge becomes the right call when** edge devices go remote/intermittent over WAN,
edge RAM is the binding constraint, or the IoT device-twin story is wanted. At that
point: install cloudcore on the central node, join devices with `keadm`, deploy
EdgeMesh, and point the pipeline's node-local Services at EdgeMesh instead of
`internalTrafficPolicy: Local`. The app code and the collector/dashboard don't change.

## Architecture

```
  EDGE NODE (label isac-edge=true)          EDGE NODE (label isac-edge=true)      CENTRAL NODE
  ┌───────────────────────────────┐         ┌───────────────────────────────┐    ┌──────────────────────┐
  │ simulator → ingestion →        │         │ simulator → ingestion →        │    │ output (collector):  │
  │   preprocessing → inference    │         │   preprocessing → inference    │    │  - fan-in results    │
  │ (all node-local, sub-ms)       │         │ (all node-local, sub-ms)       │    │  - per-node tracking │
  └───────────────┬───────────────┘         └───────────────┬───────────────┘    │  - web dashboard     │
                  │  DetectionResult (only this crosses net) │                    │  Prometheus/Grafana  │
                  └──────────────────────────┬───────────────┘───────────────────>└──────────────────────┘
```

### Key design choices

1. **Whole hot-path on each edge node.** `simulator → ingestion → preprocessing →
   inference` all run on the edge node. Previously `inference` was central, so every
   frame crossed WiFi and the central node was a per-frame bottleneck. Now only the
   low-rate `DetectionResult` leaves the node. This is the real latency + scalability
   win, independent of the runtime choice.

2. **DaemonSets, not Deployments.** `simulator/ingestion/preprocessing/inference` are
   DaemonSets with `nodeSelector: isac-edge=true`. Labeling a node schedules the whole
   pipeline onto it automatically — that *is* the "add a node → it runs a sim pod"
   behavior, with no custom controller. The pod specs carry CPU/memory requests+limits,
   so "the resources it needs to generate data" travel with the workload.

3. **Node-local routing via `internalTrafficPolicy: Local`.** A plain ClusterIP would
   load-balance simulator(edge-A) frames to ingestion(edge-B). `internalTrafficPolicy:
   Local` on the ingestion/preprocessing/inference Services pins each node's traffic to
   its own node's pods. DaemonSet guarantees a local endpoint always exists.

4. **Node identity.** `inference` reads its own node name via the downward API
   (`spec.nodeName`) into `EDGE_NODE_NAME` and stamps it on `DetectionResult.edge_node`.
   Since the hot-path is colocated, inference's node == the frame's origin edge node.

5. **Central collector + dashboard (`output`).** `output` groups results by
   `edge_node`, marks a node "connected" if it reported within `NODE_TIMEOUT_S` (15s),
   exposes `output_edge_nodes_connected` to Prometheus, and serves a stdlib-only web UI
   (no extra deps) on `:8080` (NodePort `30080`): live node count, per-node cards, and a
   searchable/filterable detection log. `output` is pinned OFF edge nodes via
   nodeAffinity so it doesn't consume edge resources.

## Onboarding a node

1. Join the device to the cluster as a k3s agent (one-time, per device — see README).
2. `make onboard-edge EDGE_NODE_NAME=<node>` (or `./scripts/onboard-edge.sh <node>`):
   labels the node `isac-edge=true` and waits for its pipeline pods to be Ready.
3. The node appears on the dashboard as online within seconds.
Removing a node: `make offboard-edge EDGE_NODE_NAME=<node>` (unlabels; pods drain off).

## Limitations / follow-ups

- Clock-skew: `simulator_clock_offset_ms` is now per-node (each simulator probes the
  central `output` ClockSyncService); e2e latency is still uncorrected in the raw metric.
- The dashboard log is an in-memory rolling buffer (`LOG_BUFFER_SIZE`, default 2000) on
  `output` — not durable across restarts. For persistence, add Loki or a DB behind the
  same API.
- `internalTrafficPolicy: Local` means a node with no local pipeline pod (mislabeled /
  pod crashed) black-holes that node's traffic rather than spilling to another node —
  intended, but worth watching during churn.
