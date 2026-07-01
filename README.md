# ISAC-k8s — Phone-as-k3s-edge-node

Pipeline: 5 gRPC microservices (`simulator → ingestion → preprocessing → inference → output`) with Prometheus/Grafana, moving `simulator + ingestion + preprocessing` onto a real Android phone acting as a **k3s worker node**. `inference + output` stay on the central cluster. This is an experimental spike measuring real WiFi-hop latency cost, not a production milestone.

Full design rationale: [`mobile-integration-plan.md`](mobile-integration-plan.md). This README is the "what's implemented + how to run it" companion.

## Two clusters, kept separate

| | KIND (existing) | k3s (new, this doc) |
|---|---|---|
| Purpose | Dev/CI, same-node baseline | Phone-edge experiment |
| Context | `kind-isac` | `k3s-isac` (override with `K3S_CONTEXT`) |
| Nodes | control-plane + 2 workers, all Docker | k3s server + phone (`android-edge-01`) + optional extra worker |
| CNI | Cilium | Cilium (recommended) or flannel fallback |
| Make targets | `make all`, `deploy`, `label-edge`, ... | `make edge-deploy`, `label-edge-k3s`, ... |

No shared control plane, no cross-cluster federation. KIND targets are untouched — nothing in `make all`/`make deploy`/etc. changed.

## What changed in this repo

### `cluster/manifests/02-simulator.yaml`
Added `nodeSelector: {isac-edge: "true"}`. Previously had none — on a multi-node k3s cluster it could've landed off the phone.

### `cluster/manifests/05-inference.yaml`
Removed the `podAffinity` to `app: ingestion`. It was forcing inference onto the same node as ingestion — i.e. onto the phone — which is the opposite of the intended split (inference should stay central). `04-preprocessing.yaml` keeps the equivalent affinity unchanged; that one is correct, it's what colocates preprocessing with ingestion on the phone.

### `services/preprocessing/preprocessing.py`
The `preprocessing → inference` gRPC call now crosses a real WiFi hop instead of pod-to-pod on one Docker host. Previously `inference_stub.Detect()` had no timeout, no retry, no deadline. Added:
- `INFERENCE_TIMEOUT_S` (default 0.5s) — explicit timeout per call.
- Retry with reconnect: on `grpc.RpcError`, rebuild the channel/stub and retry up to `INFERENCE_MAX_RETRIES` (default 2) times with `INFERENCE_RETRY_BACKOFF_S` (default 0.1s) between attempts — mirrors the reconnect loop already in `simulator.py`.
- `preprocessing_frames_dropped` Prometheus counter — increments when all retries are exhausted. The frame is dropped, not queued (matches the project's no-buffering, low-latency-over-durability design); `ProcessFrame` still returns the preprocessed frame so ingestion's call doesn't itself fail.

All three are env-overridable, no other behavior change.

### `Makefile`
Added a block of `edge-*`/`k3s-*` targets, fully additive:
- `k3s-context` — sanity-check the k3s kubeconfig context exists.
- `k3s-cilium` — install Cilium on the k3s cluster (`cluster/cilium-values.yaml`, unchanged, reused as-is).
- `label-edge-k3s` — label the phone's node `isac-edge=true` (parallel to the existing KIND `label-edge`).
- `edge-namespace` — apply `01-namespace.yaml` to the k3s cluster.
- `build-images-multiarch` — `docker buildx build --platform linux/amd64,linux/arm64 ... --push` for all 5 services to `$(REGISTRY)`. k3s has no `kind load docker-image` equivalent, so images must go through a real registry reachable from the phone.
- `edge-deploy` — apply all manifests to the k3s cluster, wait for pods.
- `edge-validate` — show pod placement + node labels/arch.
- `edge-smoke-test` — Phase 6 step 3: throwaway busybox pod scheduled with `nodeSelector: {isac-edge: "true"}`, to confirm the phone accepts and runs pods before trusting it with real services.
- `edge-clean` — delete the `isac-sensing` namespace from the k3s cluster.

Override any of `K3S_CONTEXT`, `EDGE_NODE_NAME`, `REGISTRY` on the command line, e.g.:
```
make edge-deploy K3S_CONTEXT=k3s-isac EDGE_NODE_NAME=android-edge-01 REGISTRY=192.168.1.50:5000
```

### Not changed (verified correct as-is)
- `03-ingestion.yaml` — already `hostNetwork: true` DaemonSet with `nodeSelector: {isac-edge: "true"}`.
- `04-preprocessing.yaml` — podAffinity to ingestion kept, it's the mechanism that forces phone colocation.
- `06-output.yaml`, `01-namespace.yaml`, `08-monitoring-rbac.yaml`, `09-prometheus.yaml`, `10-grafana.yaml` — no structural k3s-specific changes needed.
- `cluster/cilium-values.yaml` — reused as-is for the k3s cluster.
- `output.py` — latency calc (`time.time_ns() - request.timestamp_ns`) unchanged in code, but see **Clock sync** below — it's now clock-skew sensitive since the timestamp originates on the phone.
- `07-network-policies.yaml` — `CiliumNetworkPolicy`; only applies if you install Cilium on the k3s cluster (skip it if you take the flannel fallback).

## Setup — steps outside this repo (manual, not scriptable)

### Phase 1 — stand up k3s
On an always-on LAN host (spare PC / Pi / mini PC — avoid WAN for the first attempt):
```
curl -sfL https://get.k3s.io | sh -s - server --flannel-backend=none --disable-network-policy --disable=traefik
```
Get kubeconfig from `/etc/rancher/k3s/k3s.yaml`, merge into local kubeconfig as context `k3s-isac`. Then:
```
make k3s-cilium K3S_CONTEXT=k3s-isac
```
Flannel fallback: skip `k3s-cilium`, skip `07-network-policies.yaml` (edge-deploy already `|| true`s that apply), and accept no network policy enforcement on this cluster.

### Phase 2 — join the phone
On the phone, via Termux (no root required):
1. Confirm phone and k3s server are on the same WiFi LAN, and the router does **not** have client/AP isolation enabled.
2. Install k3s agent under Termux/proot, pointed at the server:
   ```
   k3s agent --server https://<server-lan-ip>:6443 \
     --token <contents of /var/lib/rancher/k3s/server/node-token on the server> \
     --node-name android-edge-01 --node-label isac-edge=true
   ```
3. `kubectl --context k3s-isac get nodes -o wide` — confirm `Ready`, `kubernetes.io/arch=arm64`.
4. **Soak for several hours unattended** before proceeding — Doze/battery optimization/OEM background killing can flap the node. Catch instability here, not while debugging the pipeline later.

**Go/no-go checkpoint**: if k3s agent won't run stably under Termux/proot on non-rooted Android, the fallback is a Raspberry Pi as the edge device, not more debugging — see Risks below.

### Phase 3 — images
```
make build-images-multiarch REGISTRY=<registry-reachable-from-phone>
```
Then point the manifests' `image:` fields at `$(REGISTRY)/isac-*:latest` (currently they reference bare `isac-*:latest`, which is fine for KIND's local image cache but won't resolve on k3s without a registry — update the `image:` field per manifest, or template it, before `edge-deploy`).

### Phase 6 — staged rollout (verify green before advancing)
```
make label-edge-k3s K3S_CONTEXT=k3s-isac EDGE_NODE_NAME=android-edge-01
make edge-namespace
# deploy monitoring + RBAC only first, confirm base cluster healthy
kubectl --context k3s-isac apply -f cluster/manifests/08-monitoring-rbac.yaml
kubectl --context k3s-isac apply -f cluster/manifests/09-prometheus.yaml
kubectl --context k3s-isac apply -f cluster/manifests/10-grafana.yaml
make edge-smoke-test K3S_CONTEXT=k3s-isac
kubectl --context k3s-isac apply -f cluster/manifests/03-ingestion.yaml   # ingestion alone first
# then simulator + preprocessing, then inference + output
make edge-deploy K3S_CONTEXT=k3s-isac
make edge-validate K3S_CONTEXT=k3s-isac
```

## Clock sync

`output.py`'s end-to-end latency is `time.time_ns() - request.timestamp_ns`, and that timestamp now originates on the phone, not a KIND-cluster pod. Two independently-clocked machines means clock skew silently corrupts the Grafana e2e panel (Panel 6) — it won't error, it'll just report wrong numbers. Before trusting that panel:
```
date -u   # on the k3s server host
date -u   # on the phone (Termux)
```
Android normally auto-syncs NTP over WiFi; verify rather than assume.

## Verification checklist

- `kubectl --context k3s-isac get nodes -o wide` — phone `Ready`, `arch=arm64`.
- `kubectl --context k3s-isac get pods -n isac-sensing -o wide` — simulator/ingestion/preprocessing on the phone node, inference/output elsewhere.
- Grafana Panel 6 (e2e latency p50/p95/p99) and Panel 7 (throughput/stage) show continuous non-zero data — same dashboard as KIND, no new instrumentation needed. This is the number that answers "was moving to the phone worth it."
- `preprocessing_frames_dropped` stays near zero during a clean run; a rising count under load is the phone-hop reliability signal.
- Manual `date` check both sides before trusting e2e latency.
- Multi-hour soak with node/pod status watched for flapping — the real pass/fail gate on phone feasibility, separate from the latency measurement itself.

## Risks

- **Biggest unknown: k3s agent under Termux/proot on non-rooted Android is unproven.** Go/no-go checkpoint after Phase 2. Fallback is a Raspberry Pi, not more debugging.
- Android's Doze/battery optimization/OEM background killing will flap the node — treat as baseline behavior, not an anomaly.
- Thermal throttling at sustained 100Hz shows up as latency variance in the same metrics used to validate the experiment — use Hubble (if Cilium installed) plus per-stage histograms to tell "network" apart from "phone throttling."
- Single point of failure: 3 of 5 stages on one phone, any hiccup takes down most of the pipeline. Acceptable for a spike, not for production.
- No arm64 images built/tested yet as of this change — base image and deps look compatible on paper (multi-arch `python:3.11-slim`, `manylinux_aarch64` wheels for all of `grpcio`/`numpy`/`protobuf`/`prometheus-client`), but budget real time to confirm with `build-images-multiarch`.
- WiFi client/AP isolation on the router is a common silent failure mode — check first if phone↔server networking mysteriously doesn't work.
- `insecure_channel` (no TLS) stays acceptable only because the LAN is trusted for this experimental phase — if the phone ever moves to an untrusted network, put it behind WireGuard/Tailscale rather than adding gRPC TLS.
