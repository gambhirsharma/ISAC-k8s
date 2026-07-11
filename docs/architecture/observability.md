---
title: Observability & metrics
layout: default
parent: Architecture
nav_order: 5
description: "Push-through-fan-in observability, the full Prometheus metrics catalogue, Grafana panels, and the web dashboard."
---

# Observability & metrics

Observability is where a distributed sensing experiment lives or dies — and under KubeEdge it needs
an unusual design, because **the cloud cannot scrape edge pod IPs**. This page explains that design
and catalogues every metric and view.

## The problem: no cloud → edge scrape

Prometheus normally uses `role: pod` service discovery and scrapes each pod's raw IP. Edge pod IPs
are **not routable from the cloud** under KubeEdge, so a naive scrape of the edge hot-path pods
(`simulator`/`ingestion`/`preprocessing`/`inference`) just times out and collects nothing.

## The solution: push through the fan-in

The key realization: **the latency data already travels to the cloud.** Every `DetectionResult`
carries `ingestion_latency_ns`, `preprocessing_latency_ns`, `inference_latency_ns`, and the emission
timestamp — and it all arrives at `output`. So:

1. `output` **re-exports** those timings as Prometheus metrics, **labeled per edge node**.
2. Prometheus scrapes **only the cloud-side `output` pod** — trivially reachable.
3. No cloud → edge scraping at all. This is *more* correct for KubeEdge's disconnected model, not a
   workaround.

![Pipeline dataflow — per-stage timings ride the message](../assets/pipeline.svg)

The Prometheus scrape config
([`prometheus.yaml`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/charts/isac-monitoring/templates/prometheus.yaml))
keeps `app=output` and drops everything else:

```yaml
relabel_configs:
  - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
    action: keep
    regex: "true"
  - source_labels: [__meta_kubernetes_pod_label_app]   # only the cloud-side output pod is scrapable
    action: keep
    regex: "output"
```

The trade-off: **edge-internal-only gauges** that *don't* ride the result — dispatch queue depth,
per-reason drop counters — aren't collected in v1. They're accepted as lost for now; a side-channel
report to `output` could recover them later.

## Metrics catalogue

### Exposed by `output` (cloud — scraped by Prometheus)

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `output_end_to_end_latency_raw_ms` | histogram | `edge_node` | e2e latency, **not** clock-skew corrected |
| `output_end_to_end_latency_corrected_ms` | histogram | `edge_node` | e2e minus the edge's reported clock offset |
| `output_stage_latency_ms` | histogram | `edge_node`, `stage` | per-stage local latency (`ingestion`/`preprocessing`/`inference`), reconstructed from the fan-in |
| `output_edge_clock_offset_ms` | gauge | `edge_node` | offset the edge reports via the clock-sync probe |
| `output_results_stored_total` | counter | `edge_node` | detections stored per node |
| `output_edge_nodes_connected` | gauge | — | nodes seen within `NODE_TIMEOUT_S` (15s) |

### Emitted by the edge services (not scraped in v1 — visible via `kubectl port-forward` to a pod)

These exist and are useful for local debugging even though Prometheus can't reach them:

- `simulator_frames_sent`, `simulator_emit_rate_hz`, `simulator_ingestion_latency_ms`,
  `simulator_clock_offset_ms`, `simulator_clock_sync_rtt_ms`
- `ingestion_frames_received`, `ingestion_frames_forwarded`, `ingestion_in_flight`
- `preprocessing_frames_processed`, `preprocessing_frames_dropped{reason}`,
  `preprocessing_process_latency_ms`, **`preprocessing_inference_rpc_latency_ms`** (the isolated
  network-hop metric), `preprocessing_dispatch_queue_depth`
- `inference_total{result}`, `inference_latency_ms`, `inference_detection_confusion_total`,
  `inference_results_dropped_total{reason}`, `inference_output_rpc_latency_ms`

### Histogram buckets

Every latency histogram uses explicit **millisecond** buckets:

```python
LATENCY_BUCKETS_MS = (0.5, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 250, 500, 1000, 2000)
```

The default `prometheus_client` buckets top out at 10 ms and dump everything above into `+Inf`,
which breaks `histogram_quantile` exactly when latency gets interesting. Custom buckets fix that —
see [Latency & clock sync](latency).

## Grafana dashboard

`grafana` (`:3000`, admin/admin, anonymous off) auto-provisions a datasource and the **"ISAC Fleet
(KubeEdge)"** dashboard
([`grafana.yaml`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/charts/isac-monitoring/templates/grafana.yaml)),
built entirely on the per-node `output` metrics:

| Panel | Shows |
|---|---|
| Edge nodes connected | `output_edge_nodes_connected` |
| Result throughput per edge node | `rate(output_results_stored_total[1m])` by `edge_node` |
| E2E latency (raw) fleet-wide | p50 / p95 / p99 of `output_end_to_end_latency_raw_ms` |
| E2E latency p95 per edge node | same, split by `edge_node` |
| Per-stage local latency p95 | `output_stage_latency_ms` by `stage` |
| Inference stage latency p95 per node | `output_stage_latency_ms{stage="inference"}` by `edge_node` |
| Total results stored per node | `output_results_stored_total` |

Prometheus itself scrapes at **2s** and retains **6h** — fine for a spike/portfolio run.

## The web dashboard

`output` also serves a **stdlib-only** dashboard (no extra deps) on `:8080`. It shows:

- A live **edge-node connected count** (green / red-zero).
- **Per-node cards**: frames, detections + rate, **avg e2e latency (corrected + raw)**, clock offset,
  uptime, online/last-seen.
- A **searchable, filterable detection log** (by node and free-text query).

It polls two JSON APIs — `/api/nodes` and `/api/logs` — every 2s, plus `/healthz`. Reach it with
`make port-forward-dashboard` → `http://localhost:8080/`. It's a ClusterIP (unauthenticated) by
design — see [Networking](networking#the-output-services).
