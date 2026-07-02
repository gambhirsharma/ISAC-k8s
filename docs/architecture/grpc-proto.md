---
title: gRPC & the .proto contract
layout: default
parent: Architecture
nav_order: 2
description: "The isac.proto service and message definitions, and why gRPC is the transport."
---

# gRPC & the `.proto` contract

Every hop in the pipeline is a **gRPC** call. The wire contract lives in a single file,
`services/proto/isac.proto`, and is compiled to `isac_pb2.py` / `isac_pb2_grpc.py` by
[`services/codegen.sh`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/services/codegen.sh).

## Why gRPC

- **Low latency** — HTTP/2, binary Protobuf framing, persistent connections. This matters when the
  whole point is measuring a single-digit-millisecond sensing hop.
- **A typed, versioned contract** — the `.proto` *is* the interface between five services written and
  deployed independently. Fields carry semantics (e.g. per-stage latency in nanoseconds) end to end.
- **Streaming when needed** — `GetResultStream` is a server-streaming RPC; the rest are simple unary
  calls.

## Services

```protobuf
service IngestionService     { rpc ForwardFrame(CSIFrame) returns (Ack); }
service PreprocessingService { rpc ProcessFrame(CSIFrame) returns (PreprocessedFrame); }
service InferenceService     { rpc Detect(PreprocessedFrame) returns (DetectionResult); }
service OutputService {
  rpc StoreResult(DetectionResult) returns (Empty);
  rpc GetResultStream(Empty) returns (stream DetectionResult);
}
service ClockSyncService     { rpc Probe(ClockProbe) returns (ClockProbe); }
```

`ClockSyncService` runs alongside `OutputService` on the cloud node. The `simulator` probes it
**directly, bypassing the pipeline**, so the offset estimate isn't distorted by pipeline queueing or
retry latency. → [Latency & clock sync](latency)

## Messages

### `CSIFrame` — raw sensor data (edge → ingestion → preprocessing)

```protobuf
message CSIFrame {
  int64  sequence = 1;
  int64  timestamp_ns = 2;          // stamped on the edge at emission — the e2e clock origin
  int32  num_subcarriers = 3;
  repeated double amplitudes = 4;
  reserved 5;                        // was `phases` — generated but never read; dropped to cut wire size
  bool   ground_truth = 6;           // was an object injected? used for the accuracy confusion matrix
  int64  ingestion_latency_ns = 7;   // set by ingestion, carried forward
}
```

### `PreprocessedFrame` — extracted features (preprocessing → inference)

```protobuf
message PreprocessedFrame {
  int64  sequence = 1;
  int64  timestamp_ns = 2;
  double mean_amplitude = 3;
  double variance_amplitude = 4;     // the detector's primary signal
  double max_amplitude_delta = 5;
  int64  num_subcarriers = 6;
  bool   ground_truth = 7;
  int64  ingestion_latency_ns = 8;
  int64  preprocessing_latency_ns = 9;
}
```

### `DetectionResult` — the only thing that leaves the edge node (inference → output)

```protobuf
message DetectionResult {
  int64  sequence = 1;
  int64  timestamp_ns = 2;
  bool   object_detected = 3;
  double confidence = 4;
  int64  ingestion_latency_ns = 5;      // per-stage timings ride the result...
  int64  preprocessing_latency_ns = 6;
  int64  inference_latency_ns = 7;
  string edge_node = 8;                 // origin k8s node name (downward API spec.nodeName)
}
```

The design idea worth noticing: **the per-stage timings travel *with* the result.** Because the
whole hot-path is colocated on one node, by the time a `DetectionResult` reaches the cloud it carries
a complete latency breakdown *and* the name of the node it came from. That's what lets `output`
reconstruct per-node, per-stage latency **without the cloud ever scraping an edge pod** — the crux of
the [observability model](observability).

### `ClockProbe` — NTP-style offset exchange (simulator ↔ output)

```protobuf
message ClockProbe {
  int64  client_send_ns = 1;
  int64  server_recv_ns = 2;
  int64  server_send_ns = 3;
  string edge_node = 4;         // keys the stored offset per node
  int64  edge_offset_ns = 5;    // latest (server_clock - edge_clock) estimate the edge computed
}
```

The edge has all four timestamps, so it computes the offset itself and reports its latest estimate
back on each probe. The cloud can't scrape that edge-side gauge under KubeEdge, so the probe doubles
as the reporting channel. → [Latency & clock sync](latency)

### Small helpers

```protobuf
message Empty {}
message Ack { bool ok = 1; }
```

## Notes on evolution

- Field `5` on `CSIFrame` is `reserved` — it used to be `phases`, computed and serialized every frame
  (~512 B each way) but never read downstream. Dropping it cut wire size on the hot hop. Reserving
  the number prevents a future field from silently reusing it.
- `Ack{ok}` is intentionally coarse — under the drop-don't-block design a dropped frame can still
  return `ok=true` upstream; drops are surfaced via counters, not RPC status.
