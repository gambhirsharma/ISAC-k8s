---
title: Latency & clock sync
layout: default
parent: Architecture
nav_order: 6
description: "The end-to-end latency metric, clock-skew correction, throughput decoupling, and the review that hardened them."
---

# Latency & clock sync

The whole point of the system is to measure **end-to-end sensing latency** across the edge → cloud
hop, per node. Getting that number *right* is subtle: it spans two independently-clocked machines,
and a naive pipeline design silently caps throughput. This page covers the measurement design and the
review that hardened it.

## The headline metric

`output` computes, on each `StoreResult`:

```python
end_to_end_ms = (now_ns - request.timestamp_ns) / 1e6
```

where `timestamp_ns` was stamped on the **edge** at emission and `now_ns` is read on the **cloud**.
Two clocks — so the raw number is `true latency + (cloud − edge clock offset)`. At single-digit
milliseconds, that offset can dominate and even make the raw number go negative.

## Clock-skew correction

The fix is a two-part protocol:

1. **The edge estimates its own offset.** `simulator`'s `clock_sync_loop` runs an NTP-style
   **best-of-N (min-RTT)** probe against `output`'s `ClockSyncService`, out of band from the pipeline
   so queueing/retries can't contaminate it. Min-RTT sample selection rejects probes that hit a
   scheduling hiccup.
2. **The edge reports it; the cloud applies it.** The edge carries its latest `edge_offset_ns` on
   every `ClockProbe`. `output` stores it per node and subtracts it:

   ```python
   corrected_ms = max(0.0, (now_ns - request.timestamp_ns - offset_ns) / 1e6)
   ```

Why does the edge compute the offset rather than the cloud? Because the cloud can't scrape the
edge's own offset gauge under KubeEdge — so the probe doubles as the reporting channel. Both the raw
and corrected numbers are exposed (`output_end_to_end_latency_raw_ms` /
`_corrected_ms`) and shown side by side on the dashboard, so you can always see how much of the
figure was skew.

> Corrected e2e is the trustworthy cross-machine number. When comparing runs across machines, use
> `_corrected_ms`; treat `_raw_ms` as diagnostic. For **absolute** confidence, still verify clocks
> manually (`date -u` on both hosts) before trusting a millisecond figure.
{: .note }

## Isolating the network hop

Per-stage histograms used to be *nested* (each wrapped its downstream blocking call), so the WiFi/WAN
hop couldn't be read cleanly. Now `preprocessing` times the `Detect` RPC specifically into its own
histogram:

```
preprocessing_inference_rpc_latency_ms   # round trip of the Detect RPC = the isolated network hop
```

Subtract the tiny local `inference_latency_ms` to get the pure network cost. This is the single metric
the phone/edge-as-node experiment exists to produce.

## Throughput: decoupling the producer from the network

The original pipeline was a **fully synchronous nested blocking chain** — `simulator.ForwardFrame`
didn't return until `output` had stored the result and the response unwound all the way back. That
capped throughput at `1/round-trip-latency`: exactly one frame in flight, ever, and a single network
hiccup stalled the whole pipeline including the producer.

The current design breaks the chain at **two bounded async hand-offs**:

| Boundary | Mechanism | Effect |
|---|---|---|
| `preprocessing → inference` | bounded queue (50) + worker thread | `ProcessFrame` returns immediately; a full queue drops frames instead of blocking |
| `inference → output` (the WAN hop) | bounded queue (500) + **16 sender threads** | many `StoreResult` RPCs in flight → throughput is `senders/RTT`, not `1/RTT` |

The philosophy is **drop, don't block**: a stale sensing frame has no value, so under pressure the
system sheds load (surfaced via `*_frames_dropped` / `*_results_dropped` counters) rather than aging
frames or stalling the producer.

## Fast-fail RPCs

`preprocessing`'s call to `inference` uses a tight budget:

- `INFERENCE_TIMEOUT_S = 0.05` (the 100 Hz frame budget is 10 ms — this is fast-fail, not generous)
- `INFERENCE_MAX_RETRIES = 1`
- reconnect **only** on `UNAVAILABLE`, never on `DEADLINE_EXCEEDED` (a timeout means the frame is
  already stale; reconnecting just adds a TCP+HTTP/2 handshake to the hot path)

## Histogram buckets

All latency histograms use explicit millisecond buckets
(`0.5, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 250, 500, 1000, 2000`). The `prometheus_client`
defaults clip at 10 ms and dump the rest into `+Inf`, which makes `histogram_quantile` return garbage
p95/p99 the moment latency exceeds 10 ms — precisely when things get interesting.

## The review that drove all of this

The design was audited for latency correctness (see
[`SYSTEM-REVIEW.md`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/SYSTEM-REVIEW.md)). The
findings that shaped the current code:

| Finding | Was | Now |
|---|---|---|
| **C1** clock skew corrupts e2e | raw `server − edge` clock, could go negative | per-node offset reported + subtracted (`_corrected_ms`) |
| **C2** synchronous chain caps throughput at 1/latency | one frame in flight ever | two bounded async hand-offs |
| **C3** WiFi hop never measured in isolation | nested cumulative histograms | dedicated `preprocessing_inference_rpc_latency_ms` |
| **C4** retry path stalled pipeline up to 1.7s | 0.5s timeout ×3, reconnect on any error | 50 ms fast-fail, ≤1 retry, reconnect only on `UNAVAILABLE` |
| **C5** histogram buckets clip at 10 ms | default buckets | explicit ms buckets |
| **M1** no accuracy metric | `ground_truth` dropped | `inference_detection_confusion_total` |
| **M5** unused `phases` on the wire | ~512 B/frame each way | field `reserved`, dropped |

### Honest limitations that remain

- The `simulator` generates synthetic IID-Gaussian CSI in software — this is a valid measurement of
  *"what does relocating pipeline compute to an edge node across the network cost in latency"*, **not**
  a real ISAC sensing measurement. Feed real CSI (Wi-Fi CSI tool / SDR) to make the sensing claim.
- Absolute e2e still depends on clock quality; corrected e2e is only as good as the reported offset.
- Edge-internal-only gauges (queue depth, drop reasons) aren't scraped in v1 — see
  [Observability](observability).
- The **kind cloud** is a single-node, non-HA dev control plane — fine for a spike/portfolio; a
  production cloud would be managed/HA k8s with cloudcore unchanged on top.
