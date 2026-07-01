# ISAC-k8s — Phone-as-k3s-edge-node

Pipeline: 5 gRPC microservices (`simulator → ingestion → preprocessing → inference → output`) with Prometheus/Grafana, running on a **single real k3s cluster** where an Android phone is a real worker node. `simulator + ingestion + preprocessing` run on the phone; `inference + output` run on the other (central) k3s node(s). This is an experimental spike measuring real WiFi-hop latency cost, not a production milestone.

Full design rationale: [`mobile-integration-plan.md`](mobile-integration-plan.md). This README is the "what's implemented + how to run it" companion.

There is no separate local dev cluster (KIND) anymore — everything runs on the one k3s cluster described below, since a Docker-in-Docker cluster like KIND can't have a physical phone join it as a node. If you need a fast local iteration loop, add a second k3s node (any VM/PC) as a stand-in "central" node and just don't join the phone yet — same manifests, same Makefile.

## Cluster shape

| Node | Role | Runs |
|---|---|---|
| k3s server (LAN host: spare PC / mini PC / Pi / VM) | control-plane + central worker | `inference`, `output` |
| phone (Termux, `k3s agent`, node name `android-edge-01`, label `isac-edge=true`) | edge worker | `simulator`, `ingestion`, `preprocessing` |

`prometheus`/`grafana` aren't pinned to either node (no `nodeSelector`) — they land wherever the scheduler puts them, typically the server.

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

### 2. Join the phone
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

### 3. Images, namespace, pipeline
```
make build-images REGISTRY=<registry-reachable-from-every-node>
make label-edge CONTEXT=k3s-isac EDGE_NODE_NAME=android-edge-01
make namespace CONTEXT=k3s-isac
make smoke-test CONTEXT=k3s-isac   # confirm the phone runs pods before trusting it further
make deploy CONTEXT=k3s-isac REGISTRY=<same registry>
make validate CONTEXT=k3s-isac
```
Deploy in the staged order from `mobile-integration-plan.md` Phase 6 if you want to verify each stage independently (namespace+monitoring first, then `ingestion` alone, then `simulator`+`preprocessing`, then `inference`+`output`) rather than all at once via `make deploy`.

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
