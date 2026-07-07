# simulator.py — line-by-line notes

## Imports & setup (1-12)
Standard libs + numpy for math, grpc for RPC, prometheus_client for metrics export.
`proto` module = generated gRPC stubs/messages (isac_pb2, isac_pb2_grpc) — CSI frame format + service definitions.

## Config constants (14-25)
- `NUM_SUBCARRIERS=64` — CSI frame width (simulated WiFi channel state info, 64 OFDM subcarriers).
- `FRAME_RATE_HZ=100` — target emit rate, 100 frames/sec.
- `INGESTION_TARGET` — env var, default `localhost:50051`, where frames get sent.
- `METRICS_PORT=8000` — Prometheus scrape port.
- `CLOCK_SYNC_TARGET` — output node's ClockSyncService addr, default `output:50054`. Probed directly, bypassing pipeline, so latency estimate not polluted by pipeline queue/retry.
- `CLOCK_SYNC_INTERVAL_S=10` — how often to resync clock.
- `CLOCK_SYNC_SAMPLES=5` — samples per sync round (best-of-N).
- `EDGE_NODE_NAME` — this node's k8s downward-API name, sent to output so output can track per-node offset.

## Metrics (27-36)
- `LATENCY_BUCKETS_MS` — histogram bucket edges, 0.5ms to 2000ms.
- `frame_counter` — total frames sent.
- `rate_gauge` — current emit Hz (measured, not target).
- `latency_hist` — RTT to ingestion service per ForwardFrame call.
- `clock_offset_gauge` — estimated phone↔server clock offset (server minus phone), NTP-style.
- `clock_sync_rtt_gauge` — best RTT of clock sync probe.
- `running` — global flag, kill switch for both loops.

## generate_csi_frame (38-53)
Builds one fake CSI frame.
- `ts = time.time_ns()` — nanosecond timestamp.
- `base_amp` — 64 subcarrier amplitudes, baseline 0.5 + gaussian noise (σ=0.1).
- if `object_present`: pick random reflection center + width (2-8 subcarriers), bump amplitude in that band by 0.2-0.5 — simulates radar reflection off object.
- Returns protobuf `CSIFrame` msg: sequence num, timestamp, subcarrier count, amplitude array, ground truth label.

## simulate_live (55-90)
Main frame-emit loop, runs in thread.
- Outer while `running`: reconnect loop. Lazy-create grpc channel/stub if None.
- Inner while `running`: actual emit loop.
  - `object_present = (sequence % 100) < 20` — synthetic pattern: object present 20% of duty cycle (first 20 of every 100 frames).
  - Build frame, time the RPC call `stub.ForwardFrame(frame)`, record elapsed ms to histogram.
  - Increment frame counter, sequence, window_count.
  - Every 1 sec, compute actual measured rate → `rate_gauge`.
  - Sleep to pace to `frame_interval` (1/100s), subtracting time already spent — self-correcting frame pacing.
- `except grpc.RpcError`: print, drop stub, close channel, sleep 2s, retry (outer loop reconnects).

## clock_sync_loop (92-131)
NTP-style offset probe, separate thread, independent of pipeline (avoids pipeline latency contaminating offset estimate).
- `last_offset_ns` — carried forward each round, sent to output so output can apply immediately even before this round's result lands (1-round lag acceptable).
- Loop while running: lazy connect stub.
  - `CLOCK_SYNC_SAMPLES` (5) probes per round:
    - `client_send_ns` = local send time.
    - Build `ClockProbe` with send time, node name, last offset.
    - `stub.Probe(...)` — RPC, 2s timeout.
    - `client_recv_ns` = local recv time.
    - `rtt_ns` = round trip minus server processing time (`server_send - server_recv`) — classic NTP RTT calc.
    - `offset_ns` = midpoint formula: avg of (server_recv - client_send) and (server_send - client_recv) — classic NTP offset calc.
    - Track best (lowest RTT) sample — reduces jitter/scheduling-hiccup noise.
  - After samples: update `last_offset_ns`, push to gauges (convert ns→ms).
- except RpcError: print, drop stub/channel, retry.
- `time.sleep(CLOCK_SYNC_INTERVAL_S)` — 10s between rounds (outside inner sample loop).

## main (133-146)
- Start Prometheus HTTP server on 8000.
- Print startup msg.
- Spawn both loops as daemon threads.
- SIGINT handler → `set_running(False)`.
- Idle-wait loop (`while running: sleep(1)`) — keeps main thread alive so daemon threads keep running.
- Print shutdown msg on exit.

## set_running (148-150)
Trivial global setter, used by signal handler (needed since lambda can't reassign global directly).

## Entry point (152-153)
Standard `if __name__ == "__main__": main()`.

## Summary
Sim phone-side CSI generator. Two threads — frame emitter (pipeline path) + NTP-style clock sync (bypass path, for latency skew correction downstream at `output` node).
