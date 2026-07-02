---
title: Pipeline & services
layout: default
parent: Architecture
nav_order: 1
description: "The five gRPC microservices, stage by stage — what each does, its ports, and its metrics."
---

# Pipeline & services

The pipeline is five small Python gRPC services. Four of them (`simulator`, `ingestion`,
`preprocessing`, `inference`) make up the **hot-path** and run on every edge node; `output` is the
central collector on the cloud. Each service lives in `services/<name>/<name>.py` and shares the
generated proto stubs in `services/proto/`.

![Pipeline dataflow](../assets/pipeline.svg)

| Stage | Listens | Talks to | Placement |
|---|---|---|---|
| `simulator` | — (client only) | `ingestion` @ `localhost:50051`, `output` clock-sync | edge |
| `ingestion` | `:50051` | `preprocessing` @ `localhost:50052` | edge |
| `preprocessing` | `:50052` | `inference` @ `localhost:50053` (async) | edge |
| `inference` | `:50053` | `output` @ `output:50054` / `:30054` (async) | edge |
| `output` | `:50054` (gRPC), `:8080` (dashboard), `:8004` (metrics) | — | cloud |

Every service also serves Prometheus metrics on a dedicated `METRICS_PORT` (`8000`–`8004`).

---

## simulator — the sensor stand-in

`services/simulator/simulator.py`

Generates a synthetic `CSIFrame` at **100 Hz** (`NUM_SUBCARRIERS=64`). When an "object" is present it
adds a localized amplitude bump to a random band of subcarriers; otherwise it's baseline Gaussian
noise. The `ground_truth` flag records whether an object was injected (used downstream for accuracy).
Objects are present for 20 of every 100 frames.

- **Emit loop** (`simulate_live`): builds a frame, calls `ingestion.ForwardFrame`, and paces itself
  to hold the target rate. Reconnects on gRPC errors.
- **Clock-sync loop** (`clock_sync_loop`): independently probes `output`'s `ClockSyncService` with an
  NTP-style **best-of-N (min-RTT)** offset estimate, and reports the node's latest offset back so the
  cloud can skew-correct that node's e2e latency. Runs *out of band* so a busy pipeline can't
  contaminate the offset estimate. → [Latency & clock sync](latency)

This is the **only** component that becomes real hardware later. Everything downstream is agnostic to
where the CSI came from.

## ingestion — the edge entry point

`services/ingestion/ingestion.py`

The frame's first stop on the node. It receives a `CSIFrame`, stamps `ingestion_latency_ns` onto it
(so the timing travels with the data), and forwards synchronously to `preprocessing`. Deliberately
minimal — the node-local hop to preprocessing is sub-millisecond.

Key metrics: `ingestion_frames_received`, `ingestion_frames_forwarded`, `ingestion_in_flight`.

## preprocessing — feature extraction + async dispatch

`services/preprocessing/preprocessing.py`

Turns raw amplitudes into three features — **mean amplitude**, **amplitude variance**, and
**max amplitude delta** — and packs them into a `PreprocessedFrame`, carrying forward
`ingestion_latency_ns` and adding `preprocessing_latency_ns`.

The important part is the **async hand-off**: `ProcessFrame` puts the frame on a bounded queue
(`DISPATCH_QUEUE_SIZE=50`) and returns immediately; a background worker thread drains the queue and
calls `inference.Detect`. This decouples the producer from the network hop — if the queue fills, it
**drops** frames (`preprocessing_frames_dropped{reason="queue_full"}`) rather than blocking the whole
pipeline. A stale sensing frame isn't worth waiting for.

`_detect_with_retry` uses a **fast-fail** timeout (`INFERENCE_TIMEOUT_S=0.05`), at most one retry, and
only reconnects on `UNAVAILABLE` — never on `DEADLINE_EXCEEDED` (a timeout means the frame is already
stale). The `Detect` RPC is timed into `preprocessing_inference_rpc_latency_ms` — **the isolated
network-hop metric** the whole edge experiment exists to produce.

## inference — detection + async fan-in

`services/inference/inference.py`

A simple **threshold detector**: an object is "detected" when amplitude variance spikes above a
threshold, with a derived confidence. It stamps `inference_latency_ns` and the origin `edge_node`
(from the downward-API `spec.nodeName`) onto a `DetectionResult`.

Like preprocessing, the cross-node send to `output` is **decoupled**: `Detect` returns immediately
after local compute and enqueues the result; a **pool of 16 sender threads**
(`OUTPUT_SENDER_THREADS`) drains a bounded queue (`OUTPUT_QUEUE_SIZE=500`) with many `StoreResult`
RPCs in flight at once — so WAN throughput is `senders/RTT`, not `1/RTT`. The
`StoreResult` latency is recorded as `inference_output_rpc_latency_ms`.

It also records the **confusion matrix** vs `ground_truth` (`inference_detection_confusion_total`) —
the accuracy signal a sensing system needs alongside latency.

## output — central collector, dashboard, clock sync

`services/output/output.py`

The one cloud-side service. It:

- **Fans in** every edge node's `DetectionResult` stream (`StoreResult`), computes raw and
  clock-skew-corrected end-to-end latency, and keeps per-node aggregates in a `Collector`.
- Serves the **`ClockSyncService.Probe`** RPC and stores each node's reported offset.
- Re-exports per-node / per-stage latency as Prometheus metrics (the [observability](observability)
  story).
- Serves a **stdlib-only web dashboard** on `:8080` — live edge-node count, per-node cards, and a
  searchable detection log (JSON APIs `/api/nodes`, `/api/logs`).
- Marks a node "connected" if it reported within `NODE_TIMEOUT_S=15s`.

`output` is pinned **off** edge nodes (nodeAffinity `isac-edge NotIn true`) so it never competes for
scarce edge CPU/RAM.

## Regenerating the stubs

The proto is compiled with `services/codegen.sh` (invoked by `make codegen` / `make build-images`):

```bash
python3 -m grpc_tools.protoc -I=proto --python_out=proto --grpc_python_out=proto proto/isac.proto
```

Shared deps (`services/requirements-base.txt`): `grpcio`, `grpcio-tools`, `protobuf`,
`prometheus-client`, `numpy`. See [gRPC & the `.proto` contract](grpc-proto) for the message
definitions.
