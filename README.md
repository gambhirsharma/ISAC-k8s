# ISAC-k8s — multi-edge sensing fleet

Pipeline: 5 gRPC microservices (`simulator → ingestion → preprocessing → inference → output`) with Prometheus/Grafana, on **one real k3s cluster** with a **fleet of edge nodes** (phones / Pis / VMs). Each edge node runs the whole detection hot-path (`simulator → ingestion → preprocessing → inference`) locally; only the resulting `DetectionResult` fans in over the network to a single central `output` collector, which tracks how many edge nodes are connected and serves a web dashboard with a searchable detection log. Add an edge node → label it → its pipeline auto-schedules and starts reporting.

Design + the KubeEdge-vs-k3s-agent decision: [`edge-fleet-plan.md`](edge-fleet-plan.md). Original single-phone rationale: [`mobile-integration-plan.md`](mobile-integration-plan.md). This README is the "what's implemented + how to run it" companion.

There is no separate local dev cluster (KIND) — everything runs on the one k3s cluster, since KIND can't have a physical phone join it as a node. For a fast local loop, add a second k3s node (any VM/PC) as the "central" node and label a throwaway node `isac-edge=true` as a stand-in edge — same manifests, same Makefile.

## Cluster shape

| Node | Role | Runs |
|---|---|---|
| k3s server (LAN host: spare PC / mini PC / Pi / VM) | control-plane + central worker | `output` (collector+dashboard), `prometheus`, `grafana` |
| edge node ×N (phone/Pi/VM, `k3s agent`, label `isac-edge=true`) | edge worker | `simulator`, `ingestion`, `preprocessing`, `inference` (one set per edge node, via DaemonSets) |

The edge workloads are **DaemonSets** gated on `isac-edge=true`, so every labeled node gets exactly one set and adding a node is just labeling it. `simulator/ingestion/preprocessing/inference` communicate **node-locally** — their Services use `internalTrafficPolicy: Local`, so a node's traffic never leaves the node until the final `DetectionResult → output` hop. `output` is pinned OFF edge nodes (nodeAffinity `isac-edge NotIn true`). `prometheus`/`grafana` land wherever the scheduler puts them (typically the server).

Two namespaces, one cluster:
- `isac-sensing` — the 5 pipeline services. This is deliberately the *only* namespace they're in, split across nodes via `nodeSelector`/`affinity`, not namespace. Namespace has nothing to do with node placement — splitting edge vs. central pods into separate namespaces would only add cross-namespace FQDN service names (`inference.isac-sensing.svc.cluster.local` instead of `inference:50053`) for no benefit.
- `isac-monitoring` — `prometheus` + `grafana`. Split out purely for RBAC/blast-radius separation from the pipeline namespace. Prometheus's scrape config still targets `isac-sensing` pods across the namespace boundary (`kubernetes_sd_configs.namespaces.names: [isac-sensing]`), and its RBAC `Role`/`RoleBinding` live in `isac-sensing` (granting `get/list/watch` on pods there) while its `ServiceAccount` lives in `isac-monitoring` — a cross-namespace `RoleBinding` subject, not a `ClusterRole`.

Single `kubectl` context (default name `k3s-isac`, override with `CONTEXT=`). All Make targets operate on it.

## What changed in this repo

### `cluster/manifests/02-simulator.yaml`
Added `nodeSelector: {isac-edge: "true"}`. Previously had none — with more than one node in the cluster it could land off the phone.

### `cluster/manifests/05-inference.yaml`
Removed the `podAffinity` to `app: ingestion`. It was forcing inference onto the same node as ingestion — i.e. onto the phone — the opposite of the intended split. `04-preprocessing.yaml` keeps the equivalent affinity; that one is correct, it's what colocates preprocessing with ingestion on the phone.

### `cluster/manifests/02-05-06-*.yaml`: `imagePullPolicy: IfNotPresent` → `Always`
With KIND gone there's no local image cache on any node — every pod pulls from `$(REGISTRY)` over the LAN. `:latest` is a mutable tag, so `IfNotPresent` would silently keep running a stale image after a rebuild; `Always` makes `make deploy` actually pick up new pushes.

### `services/preprocessing/preprocessing.py`
The `preprocessing → inference` gRPC call now crosses a real WiFi hop to/from the phone instead of pod-to-pod on one Docker host. Previously `inference_stub.Detect()` had no timeout, no retry, no deadline. Added:
- `INFERENCE_TIMEOUT_S` (default 0.5s) — explicit timeout per call.
- Retry with reconnect: on `grpc.RpcError`, rebuild the channel/stub and retry up to `INFERENCE_MAX_RETRIES` (default 2) times with `INFERENCE_RETRY_BACKOFF_S` (default 0.1s) between attempts — mirrors the reconnect loop already in `simulator.py`.
- `preprocessing_frames_dropped` Prometheus counter — increments when all retries are exhausted. The frame is dropped, not queued (matches the project's no-buffering, low-latency-over-durability design); `ProcessFrame` still returns the preprocessed frame so ingestion's call doesn't itself fail.

All three are env-overridable, no other behavior change.

### `01-namespace.yaml`, `08-monitoring-rbac.yaml`, `09-prometheus.yaml`, `10-grafana.yaml` — monitoring split into `isac-monitoring`
Added a second `Namespace` (`isac-monitoring`) and moved `prometheus`/`grafana`'s Deployments/Services/ConfigMaps into it. `08-monitoring-rbac.yaml`'s `ServiceAccount` moved to `isac-monitoring`; the `Role`/`RoleBinding` stay in `isac-sensing` with the `RoleBinding` subject pointing cross-namespace at `isac-monitoring`'s service account. `09-prometheus.yaml`'s scrape config is unchanged — it already scoped `kubernetes_sd_configs` to `namespaces.names: [isac-sensing]` explicitly, so it keeps discovering the pipeline pods regardless of which namespace Prometheus itself runs in. `07-network-policies.yaml`'s Prometheus ingress rule got a `k8s:io.kubernetes.pod.namespace: isac-monitoring` label added to its `fromEndpoints` selector (Cilium's default same-namespace match no longer applies once the source moved out); the dead `grafana → :9090` rule (leftover from when both were in `isac-sensing`) was removed.

### `Makefile` — rewritten for k3s only
Removed: `kind-up`, `load-images`, and the `kind delete cluster`/`docker rmi` steps in `clean`. Removed `cluster/kind-config.yaml` (no longer needed).

Every target now takes `--context $(CONTEXT)`:
- `cilium` — install Cilium on the k3s cluster (`cluster/cilium-values.yaml`, unchanged, reused as-is). Skip this + `07-network-policies.yaml` if you take the flannel fallback (see Setup).
- `label-edge` — label the phone's node `isac-edge=true`.
- `namespace` — apply `01-namespace.yaml`.
- `build-images` — `docker buildx build --platform linux/amd64,linux/arm64 ... --push` for all 5 services to `$(REGISTRY)`. Every node (server + phone) now pulls from a registry — there's no `kind load docker-image` equivalent.
- `deploy` — apply all manifests, then `kubectl set image` each workload to `$(REGISTRY)/isac-*:latest` (manifests themselves stay registry-agnostic), then wait for pods.
- `validate` — pod placement + node labels/arch.
- `smoke-test` — throwaway busybox pod scheduled with `nodeSelector: {isac-edge: "true"}`, to confirm the phone accepts and runs pods before trusting it with real services.
- `clean` — delete both the `isac-sensing` and `isac-monitoring` namespaces (does **not** tear down the k3s cluster itself — that's real infrastructure now, not disposable local KIND; use `k3s-uninstall.sh` / `k3s-agent-uninstall.sh` on the respective hosts if you actually want to tear the cluster down).
- `all` chains `cilium label-edge namespace build-images deploy` — it does **not** create the cluster or join the phone, since those happen on remote hosts this Makefile doesn't control (see Setup below).

Override any of `CONTEXT`, `EDGE_NODE_NAME`, `REGISTRY` on the command line, e.g.:
```
make deploy CONTEXT=k3s-isac EDGE_NODE_NAME=android-edge-01 REGISTRY=192.168.1.50:5000
```

### Not changed (verified correct as-is)
- `03-ingestion.yaml` — already `hostNetwork: true` DaemonSet with `nodeSelector: {isac-edge: "true"}`.
- `04-preprocessing.yaml` — podAffinity to ingestion kept, it's the mechanism that forces phone colocation.
- `cluster/cilium-values.yaml` — reused as-is.
- `output.py` — latency calc (`time.time_ns() - request.timestamp_ns`) unchanged in code, but see **Clock sync** below — it's now clock-skew sensitive since the timestamp originates on the phone.
- `07-network-policies.yaml` (beyond the Prometheus selector fix above) — `CiliumNetworkPolicy`; only applies if you install Cilium (skip it if you take the flannel fallback).

## Latency-review fixes

Following a latency-focused audit ([`SYSTEM-REVIEW.md`](SYSTEM-REVIEW.md)), the pipeline was changed to make the latency numbers trustworthy and to stop the phone-hop round trip from throttling the whole pipeline:

- **Decoupled the WiFi hop (`preprocessing.py`).** `ProcessFrame` used to block on the full `inference.Detect` round trip before returning to `ingestion`, so the simulator could never emit faster than `1 / round_trip_latency`. It now does local preprocessing synchronously, pushes the frame onto a bounded queue (`DISPATCH_QUEUE_SIZE`, default 50), and returns immediately; a background worker thread drains the queue and calls `inference.Detect`. A full queue drops the frame (`preprocessing_frames_dropped_total{reason="queue_full"}`) instead of blocking. `INFERENCE_TIMEOUT_S` default dropped to 0.05s and reconnect-on-error is now only triggered by `UNAVAILABLE`, not `DEADLINE_EXCEEDED` — a mere timeout no longer pays for a fresh TCP/HTTP2 handshake.
- **Isolated the WiFi-hop metric.** New `preprocessing_inference_rpc_latency_ms` histogram times only the `Detect` RPC — this is the number that answers "what does the phone↔server hop cost," separate from local compute at either end.
- **Clock-skew correction.** New `ClockSyncService` (on `output`) + a background probe loop in `simulator` estimate the phone↔server clock offset (NTP-style, min-RTT of `CLOCK_SYNC_SAMPLES` per round) and publish `simulator_clock_offset_ms` / `simulator_clock_sync_rtt_ms`. `output_end_to_end_latency_ms` was renamed to `output_end_to_end_latency_raw_ms` to make clear it is **not** skew-corrected; Grafana Panel 10 subtracts the offset gauge from it.
- **Custom histogram buckets** (`0.5ms`–`2000ms`) on every latency histogram in all 5 services — the previous `prometheus_client` defaults clip at 10ms, which silently broke `histogram_quantile` p95/p99 the moment latency crossed that line.
- **Per-stage latency now reaches `DetectionResult`.** `ingestion_latency_ns`/`preprocessing_latency_ns` were declared in the proto but never populated; `CSIFrame` and `PreprocessedFrame` now carry each stage's own local timing forward instead of losing it.
- **Detection accuracy is now measurable.** `ground_truth` was dropped at the `preprocessing` boundary; it's now carried through to `inference`, which emits `inference_detection_confusion_total{ground_truth,detected}` (Grafana Panel 11: precision/recall). Previously there was no way to tell whether the detector detected anything real.
- **Dead code removed.** `SimulatorService.StreamFrames` (proto) and the unused `simulator` headless Service (`:50050`) — `simulator` has no gRPC server, only a metrics endpoint.
- **Readiness/liveness probes** added to all 5 workloads (`tcpSocket` on each gRPC/metrics port) so a rollout's first frames don't hit the retry path before the pod is actually accepting connections.
- **Prometheus scrape interval** 5s → 2s — reduces (does not eliminate) aliasing against the 100Hz frame rate on gauges like `preprocessing_dispatch_queue_depth`.
- **`CiliumNetworkPolicy`** updated: `simulator` now also allowed to reach `output:50054` directly (the clock-sync probe bypasses the pipeline chain on purpose, so its ingress rule is separate from the `inference → output` rule).

Not fixed by code (need infra/hardware, tracked in `SYSTEM-REVIEW.md` §6): true NTP/PTP hard sync between the two hosts (the offset gauge is a monitored estimate, not a fix); CSI realism (still synthetic Gaussian, no real Doppler/multipath); VXLAN/Cilium encapsulation overhead on the WiFi hop is unmeasured; no statistical repetition/CI across runs yet.

## Setup — steps outside this repo (manual, not scriptable)

### 1. Stand up k3s
On an always-on LAN host (spare PC / Pi / mini PC — avoid WAN for the first attempt):
```
curl -sfL https://get.k3s.io | sh -s - server --flannel-backend=none --disable-network-policy --disable=traefik
```
Get kubeconfig from `/etc/rancher/k3s/k3s.yaml`, merge into local kubeconfig as context `k3s-isac`. Then:
```
make cilium CONTEXT=k3s-isac
```
Flannel fallback: skip `make cilium`, skip `07-network-policies.yaml` (`deploy` already `|| true`s that apply), accept no network policy enforcement.

### 2. Join an edge node
Per device (phone via Termux needs no root). This is the one-time cluster join; the
ISAC-specific onboarding (labeling + waiting for the pipeline) is step 4 below.
1. Confirm the device and k3s server are on the same LAN, and the router does **not** have client/AP isolation enabled.
2. Install the k3s agent, pointed at the server (leave the `isac-edge` label OFF for now — `onboard-edge` adds it once the node is confirmed healthy):
   ```
   k3s agent --server https://<server-lan-ip>:6443 \
     --token <contents of /var/lib/rancher/k3s/server/node-token on the server> \
     --node-name edge-02
   ```
3. `kubectl --context k3s-isac get nodes -o wide` — confirm `Ready` and the arch.
4. **Soak for several hours unattended** before onboarding — a flapping node (phone Doze/battery/OEM killing) should be caught here, not while debugging the pipeline.

**Go/no-go checkpoint**: if k3s agent won't run stably under Termux/proot on non-rooted Android, the fallback is a Raspberry Pi as the edge device, not more debugging — see Risks below.

### 3. Images, namespace, pipeline
```
make build-images REGISTRY=<registry-reachable-from-every-node>
make namespace CONTEXT=k3s-isac
make deploy CONTEXT=k3s-isac REGISTRY=<same registry>   # applies all DaemonSets/Services; edge pods stay 0 until a node is labeled
```
The edge DaemonSets have 0 pods until at least one node carries `isac-edge=true` — that's what `onboard-edge` does next.

### 4. Onboard edge nodes (the per-node flow)
For each joined, soaked node:
```
make smoke-test CONTEXT=k3s-isac                          # optional: confirm the node runs a throwaway pod
make onboard-edge CONTEXT=k3s-isac EDGE_NODE_NAME=edge-02 # labels isac-edge=true + waits for the node's pipeline to be Ready
```
`onboard-edge` (script: `scripts/onboard-edge.sh`) labels the node, then `kubectl rollout status` each edge DaemonSet so it returns only once that node's `simulator/ingestion/preprocessing/inference` are all up. The node then shows as **online** on the dashboard within seconds. Repeat for every edge device — that's the whole scale-out story.

Remove a node from the fleet: `make offboard-edge EDGE_NODE_NAME=edge-02` (unlabels; edge pods drain off it).

### 5. Fleet dashboard
The custom web UI (edge-node count + per-node cards + searchable detection log) is served by `output` on `:8080`, exposed as NodePort `30080`:
```
make dashboard-url CONTEXT=k3s-isac          # prints http://<node-ip>:30080/
# or, without NodePort:
make port-forward-dashboard CONTEXT=k3s-isac # -> http://localhost:8080/
```
APIs behind it: `GET /api/nodes` (connected count + per-node stats), `GET /api/logs?node=&q=&limit=` (filterable detection log). Prometheus also gets `output_edge_nodes_connected` for a Grafana panel.

Deploy in the staged order from `mobile-integration-plan.md` Phase 6 if you want to verify each stage independently rather than all at once via `make deploy`.

## Clock sync

`output.py`'s end-to-end latency is `time.time_ns() - request.timestamp_ns`, and that timestamp now originates on the phone. Two independently-clocked machines means clock skew silently corrupts the Grafana e2e panel (Panel 6) — it won't error, it'll just report wrong numbers. Before trusting that panel:
```
date -u   # on the k3s server host
date -u   # on the phone (Termux)
```
Android normally auto-syncs NTP over WiFi; verify rather than assume.

## Verification checklist

- `kubectl --context k3s-isac get nodes -o wide` — phone `Ready`, `arch=arm64`.
- `kubectl --context k3s-isac get pods -n isac-sensing -o wide` — simulator/ingestion/preprocessing on the phone node, inference/output elsewhere.
- `kubectl --context k3s-isac get pods -n isac-monitoring -o wide` — prometheus/grafana running, independent of the `isac-sensing` pods.
- Grafana Panel 6 (e2e latency p50/p95/p99) and Panel 7 (throughput/stage) show continuous non-zero data — same dashboard as before, no new instrumentation needed. This is the number that answers "was moving to the phone worth it."
- `preprocessing_frames_dropped` stays near zero during a clean run; a rising count under load is the phone-hop reliability signal.
- Manual `date` check both sides before trusting e2e latency.
- Multi-hour soak with node/pod status watched for flapping — the real pass/fail gate on phone feasibility, separate from the latency measurement itself.

## Current status

Validated end-to-end on the real k3s cluster as a single-node baseline (`gam-hetzner`, temporarily labeled `isac-edge=true` itself) before the phone joins — all 5 pipeline services plus `prometheus`/`grafana` running, images pushed to a local `registry:2` container (`localhost:5000`) on the server since server and image-build host were the same box. `output_results_stored_total` matched `preprocessing_frames_processed_total` with `preprocessing_frames_dropped_total` at 0, average e2e latency ≈4ms — the pre-phone baseline the plan's Phase 6 step 7 asks to compare the post-phone number against. `localhost:5000` only works because the node and registry currently share a host; once the phone joins, `REGISTRY` must point at the server's real LAN/public IP instead, and the phone's containerd needs that registry marked insecure (no TLS) if it's not fronted with a cert.

## Risks

- **Biggest unknown: k3s agent under Termux/proot on non-rooted Android is unproven.** Go/no-go checkpoint after joining the phone. Fallback is a Raspberry Pi, not more debugging.
- Android's Doze/battery optimization/OEM background killing will flap the node — treat as baseline behavior, not an anomaly.
- Thermal throttling at sustained 100Hz shows up as latency variance in the same metrics used to validate the experiment — use Hubble (if Cilium installed) plus per-stage histograms to tell "network" apart from "phone throttling."
- Single point of failure: 3 of 5 stages on one phone, any hiccup takes down most of the pipeline. Acceptable for a spike, not for production.
- No arm64 images built/tested yet as of this change — base image and deps look compatible on paper (multi-arch `python:3.11-slim`, `manylinux_aarch64` wheels for all of `grpcio`/`numpy`/`protobuf`/`prometheus-client`), but budget real time to confirm with `make build-images`.
- WiFi client/AP isolation on the router is a common silent failure mode — check first if phone↔server networking mysteriously doesn't work.
- `insecure_channel` (no TLS) stays acceptable only because the LAN is trusted for this experimental phase — if the phone ever moves to an untrusted network, put it behind WireGuard/Tailscale rather than adding gRPC TLS.
- Losing the k3s server host now means losing the whole pipeline (previously KIND was an isolated disposable dev cluster) — this cluster is real infrastructure, treat it that way (don't casually `k3s-uninstall.sh` it).
