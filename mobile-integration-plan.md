# Plan: Android Phone as Real k3s Edge Node for ISAC Pipeline

## Context

`new-mobile-integration.md` sketches a future ISAC edge-sensing architecture (phone sensor → edge processing → KubeEdge → K3s → Kafka/AI → Grafana), but it predates the actual repo and doesn't match what's built. Exploration found:

- The real cluster today is **KIND** (Docker-in-Docker, 1 control-plane + 2 workers, Cilium CNI), not k3s.
- The pipeline already exists as 5 Python gRPC microservices (`simulator → ingestion → preprocessing → inference → output`), each with Prometheus metrics, deployed in namespace `isac-sensing`, with monitoring (Prometheus+Grafana) just added in the last commit.
- The architecture was **already built edge-aware**: `ingestion` is a hostNetwork DaemonSet with `nodeSelector: {isac-edge: "true"}`, and `preprocessing` uses required podAffinity to colocate with `ingestion` on the same node. This is not a redesign — it's finishing a design that was already half-built for exactly this purpose.
- No MQTT/Kafka broker exists anywhere; the project's `master-plan.md` deliberately avoids one for latency reasons.

The goal now: make the phone a **real k3s worker node** (not an app-only sensor client, not KubeEdge), move `simulator + ingestion + preprocessing` onto it, keep `inference + output` on the central cluster, and reuse the existing gRPC + Prometheus/Grafana instrumentation to measure the real latency cost of the phone hop. These directions were confirmed with the user over the KIND-vs-k3s gap, phone role, workload split, and broker question — all decided in favor of the "reuse what's already built" path below.

This is explicitly an **experimental spike** (matches the doc's own "Option B — Experimental" framing), not a production milestone. Root/kernel constraints on Android are the single biggest open unknown — call this out at every review point, don't bury it.

## Key facts verified in code (not assumptions)

- `Makefile`'s `label-edge` target: `kubectl label node isac-worker isac-edge=true --overwrite` — labels a KIND-specific node name. Reusable pattern, just needs a target pointed at the phone's node name on the new k3s context.
- `cluster/manifests/03-ingestion.yaml`: DaemonSet, `hostNetwork: true`, `nodeSelector: {isac-edge: "true"}` — already correct, no changes needed.
- `cluster/manifests/04-preprocessing.yaml`: required podAffinity to `app: ingestion` — correct, keep it, this is what forces exact node colocation.
- `cluster/manifests/05-inference.yaml`: **also has the same podAffinity to `app: ingestion`** — this is a bug relative to the intended split. It currently forces inference onto the edge node too. Must be removed so inference stays central.
- `cluster/manifests/02-simulator.yaml`: plain Deployment, **no nodeSelector at all** — must add `nodeSelector: {isac-edge: "true"}` or it won't reliably land on the phone once the k3s cluster has more than one node.
- All 5 Dockerfiles use `python:3.11-slim`, confirmed multi-arch (includes arm64/v8). All deps in `requirements-base.txt` (`grpcio`, `numpy`, `protobuf`, `prometheus-client`) have prebuilt `manylinux_aarch64` wheels — arm64 builds should work without Dockerfile changes, just need `docker buildx build --platform linux/amd64,linux/arm64` and a way to get images onto the phone (k3s isn't KIND — no `kind load docker-image`; need a registry reachable from the phone, e.g. one on the k3s server host).
- All gRPC calls (`ingestion.py`, `preprocessing.py`, `inference.py`) use `insecure_channel` with **no timeout, no retry, no deadline** — fine for pod-to-pod today, risky once one hop (`preprocessing → inference`) crosses a real WiFi link to a phone that can sleep/throttle/drop. `simulator.py` already has a reconnect/retry loop — mirror that pattern into `preprocessing.py`'s call to inference.
- `output.py` computes end-to-end latency as `time.time_ns() - request.timestamp_ns`, where the timestamp now originates on the phone. This becomes **clock-skew sensitive** across two independently-clocked machines — NTP sync matters or the Grafana e2e panel silently reports garbage.
- Cilium network policy (`07-network-policies.yaml`) is Cilium-specific (`CiliumNetworkPolicy` kind); only applies if Cilium is actually installed on the new k3s cluster.

## Plan

### Phase 1 — New standalone k3s cluster (KIND stays untouched)
Stand up a **separate** real k3s cluster on an always-on LAN host (spare PC, Raspberry Pi, mini PC, or bridged-network VM — avoid cloud/WAN for the first attempt to remove a variable). Install k3s server. Decide Cilium vs. flannel:
- Recommended: `k3s server --flannel-backend=none --disable-network-policy --disable=traefik`, then install Cilium via the existing `cluster/cilium-values.yaml` (values port over as-is — not KIND-specific). Keeps dataplane consistent with KIND and keeps Hubble for diagnosing the phone hop.
- Acceptable fallback: keep flannel, skip Cilium, drop `07-network-policies.yaml` from this cluster's apply list, document the gap (no network policy enforcement).

`01-namespace.yaml`, `02-simulator.yaml` (after Phase 3 edit), `06-output.yaml`, `08-monitoring-rbac.yaml`, `09-prometheus.yaml`, `10-grafana.yaml` need no structural change to run on k3s. Keep KIND fully separate — no shared control plane. Use distinct kubeconfig/context and new Makefile target names (e.g. `k3s-context`, `edge-deploy`) so nobody accidentally runs `make deploy` against the wrong cluster.

### Phase 2 — Join the phone as a k3s agent node
- Runtime: Termux (no root needed to install, most precedent) as the starting point over UserLAnd/full VM. **Root/cgroup/containerd compatibility under Android's kernel via proot is the biggest unknown in this whole plan** — spike-test this first with a go/no-go checkpoint before investing further. If it doesn't work, the fallback is not "debug harder," it's "use a Raspberry Pi instead if the goal is architecture validation rather than literally-a-phone."
- Network: start with phone and k3s server on the same WiFi LAN (check the router doesn't have client/AP isolation enabled — a common silent failure mode). Layer in WireGuard/Tailscale later only if the phone needs to roam off that LAN.
- Join: `k3s agent` pointed at `https://<server-lan-ip>:6443` with the node token from `/var/lib/rancher/k3s/server/node-token`. Use `--node-label isac-edge=true` and a distinct `--node-name` (e.g. `android-edge-01`) at join time.
- Verify `kubectl get nodes` shows it `Ready` with `kubernetes.io/arch=arm64`, and soak for several hours unattended before proceeding — Android's Doze/battery-optimization/OEM background killing can flap the node; catch that instability here, isolated from pipeline debugging later.

### Phase 3 — Manifest changes
1. `02-simulator.yaml`: add `nodeSelector: {isac-edge: "true"}`.
2. `03-ingestion.yaml`: no change (already correct).
3. `04-preprocessing.yaml`: keep the podAffinity to `ingestion` — it's what actually enforces phone colocation.
4. `05-inference.yaml`: **remove** the podAffinity-to-`ingestion` block. Leave it unconstrained so it lands on a central node (with 2+ nodes in the k3s cluster — phone + at least one other — this is sufficient; add a `NotIn isac-edge=true` anti-affinity only if extra insurance is wanted).
5. `06-output.yaml`: no change.
6. Build arm64 (or multi-arch) images for simulator/ingestion/preprocessing via `docker buildx`; push to a registry reachable from the phone (k3s has no `kind load` equivalent).
7. `preprocessing.py`: add an explicit `timeout=` on the call into `inference`, plus a retry/backoff wrapper mirroring `simulator.py`'s existing reconnect pattern, plus a "drop and count" Prometheus counter for timed-out frames (consistent with the project's no-buffering, low-latency-over-durability philosophy — don't add queueing).

### Phase 4 — Networking/latency/TLS/clock
- `inference`'s Service stays plain ClusterIP — correct, no NodePort/LB/Ingress needed (the phone is a cluster member, not an external client).
- TLS: acceptable to stay on `insecure_channel` for this experimental phase if the LAN is trusted — document as a conscious risk acceptance, revisit if the phone ever moves to an untrusted network (let a WireGuard/Tailscale tunnel provide transport security rather than adding gRPC TLS).
- NTP: ensure phone and k3s hosts are clock-synced (Android auto-syncs via WiFi normally) — spot check with `date` on both sides before trusting the Grafana e2e latency panel post-migration.

### Phase 5 — Monitoring
Deploy Prometheus+Grafana once, on the new k3s cluster only (KIND keeps its own separate stack if left running for dev/CI — no cross-cluster federation, that's out of scope). Prometheus's `kubernetes_sd_configs` pod-discovery is node-agnostic — pods on the phone are auto-discovered exactly like any other pod, as long as Prometheus can reach the phone's pod IP over the pod network (same reachability requirement as the gRPC traffic in Phase 4). Grafana dashboard JSON needs no changes — its PromQL queries are metric-name based with no node filters. Panel 6 ("End-to-end latency p50/p95/p99") is the number to watch for validating this whole effort.

### Phase 6 — Staged rollout/validation (do in this order, verify green before advancing)
1. Join phone, confirm `Ready`, soak for hours, watch for flapping.
2. Deploy namespace + RBAC + Prometheus + Grafana only — confirm base cluster + monitoring work before adding pipeline complexity.
3. Schedule one throwaway pod with `nodeSelector: {isac-edge: "true"}` onto the phone as a smoke test (`kubectl logs`/`exec` working) before trusting it with real services.
4. Deploy `ingestion` alone, confirm its metrics show up in Grafana from a phone-hosted pod.
5. Deploy `simulator` + `preprocessing`, confirm all 3 land on the phone (`kubectl get pods -o wide`), check `ingestion_forward_latency_ms`/`preprocessing_process_latency_ms` are sane.
6. Deploy `inference` + `output` centrally, confirm they land off the phone.
7. Watch panels 6 (e2e latency) and 7 (throughput per stage) with all 5 services running; record new baseline vs. the original same-node KIND baseline — this is the actual "was it worth it" measurement.
8. Extended soak test, watching specifically for phone sleep/throttle/WiFi-drop failure modes (see Risks) — treat this as a phone-reliability experiment as much as a latency experiment.

## Risks (state plainly, don't bury)
- **Feasibility of a real k3s agent under Termux/proot on non-rooted Android is unproven.** Go/no-go checkpoint after Phase 2; fallback is a different edge device class (Raspberry Pi), not more debugging.
- **Android process lifecycle actively fights long-running daemons** (Doze, battery optimization, OEM background killing) — expect intermittent node flapping as a baseline characteristic, not an anomaly to eliminate.
- **Thermal throttling** under sustained 100Hz load will show up as latency variance in the exact metrics being used to validate the experiment — distinguish "network latency" from "phone throttling" using Hubble (if enabled) + per-stage histograms together.
- **Single point of failure**: 3 of 5 pipeline stages on one phone — any phone hiccup takes down most of the pipeline. Acceptable for a spike, state it as a limitation.
- **No arm64 images built/tested yet** — ingredients look compatible on paper (multi-arch base image, manylinux wheels) but budget real time to confirm, don't assume zero risk.
- **WiFi client/AP isolation** — common router setting, easy to miss, first thing to check if phone-to-server networking mysteriously fails.
- **Clock drift** breaks the e2e latency panel silently (see Phase 4) — a correctness risk for the measurement itself, not just an ops nuisance.
- **Pre-existing gRPC gap** (no timeout/retry/TLS anywhere in the codebase) becomes materially risky specifically at the phone hop — in scope to harden `preprocessing.py`, not optional polish.

## Critical files
- `cluster/manifests/02-simulator.yaml` — add nodeSelector
- `cluster/manifests/05-inference.yaml` — remove erroneous podAffinity
- `cluster/manifests/04-preprocessing.yaml` — keep podAffinity as-is (verify only)
- `services/preprocessing/preprocessing.py` — add timeout/retry/drop-counter on call to inference
- `services/output/output.py` — e2e latency calc, clock-skew sensitive once simulator is on phone
- `Makefile` — new k3s/phone-specific targets, separate from KIND targets
- `cluster/cilium-values.yaml` — reusable as-is if Cilium chosen for k3s too

## Verification
- `kubectl --context <k3s> get nodes -o wide` — phone shows `Ready`, `arch=arm64`.
- `kubectl --context <k3s> get pods -n isac-sensing -o wide` — simulator/ingestion/preprocessing on phone node, inference/output elsewhere.
- Grafana panels (emit rate, per-stage latency, e2e latency, throughput) show continuous non-zero data flowing after full pipeline deploy — this is the existing dashboard, no new instrumentation needed.
- Manual `date` check on phone vs. k3s host to rule out clock-skew before trusting e2e latency numbers.
- Soak test (hours) with node/pod status watched for flapping as the real pass/fail gate on phone feasibility.
