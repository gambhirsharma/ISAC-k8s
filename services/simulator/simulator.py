import os
import time
import signal
import threading
import numpy as np
from concurrent import futures

import grpc
from prometheus_client import start_http_server, Counter, Gauge, Histogram

from proto import isac_pb2
from proto import isac_pb2_grpc

NUM_SUBCARRIERS = 64
FRAME_RATE_HZ = 100
INGESTION_TARGET = os.environ.get("INGESTION_SERVICE", "localhost:50051")
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8000"))
# ClockSyncService lives on the output node; probed directly (bypassing the pipeline)
# so the offset estimate isn't itself distorted by pipeline queueing/retry latency.
CLOCK_SYNC_TARGET = os.environ.get("CLOCK_SYNC_TARGET", "output:50054")
CLOCK_SYNC_INTERVAL_S = float(os.environ.get("CLOCK_SYNC_INTERVAL_S", "10"))
CLOCK_SYNC_SAMPLES = int(os.environ.get("CLOCK_SYNC_SAMPLES", "5"))
# This edge node's name (downward API spec.nodeName), reported to output on each clock probe
# so output can key the offset per node and skew-correct that node's e2e latency.
EDGE_NODE_NAME = os.environ.get("EDGE_NODE_NAME", "unknown")

LATENCY_BUCKETS_MS = (0.5, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 250, 500, 1000, 2000)

frame_counter = Counter("simulator_frames_sent", "Frames sent to ingestion")
rate_gauge = Gauge("simulator_emit_rate_hz", "Current emission rate")
latency_hist = Histogram("simulator_ingestion_latency_ms", "Latency to ingestion service", buckets=LATENCY_BUCKETS_MS)
# NTP-style min-RTT offset estimate between this phone and the output node's clock.
# Subtract this from output_end_to_end_latency_raw_ms to get a skew-corrected e2e figure.
clock_offset_gauge = Gauge("simulator_clock_offset_ms", "Estimated phone->server clock offset (server - phone)")
clock_sync_rtt_gauge = Gauge("simulator_clock_sync_rtt_ms", "Round-trip time of the best clock sync probe sample")
running = True

def generate_csi_frame(sequence, object_present):
    ts = time.time_ns()
    base_amp = 0.5 + 0.1 * np.random.randn(NUM_SUBCARRIERS)
    if object_present:
        reflection_center = np.random.randint(0, NUM_SUBCARRIERS)
        reflection_width = np.random.randint(2, 8)
        start_idx = max(0, reflection_center - reflection_width // 2)
        end_idx = min(NUM_SUBCARRIERS, reflection_center + reflection_width // 2)
        base_amp[start_idx:end_idx] += np.random.uniform(0.2, 0.5)
    return isac_pb2.CSIFrame(
        sequence=sequence,
        timestamp_ns=ts,
        num_subcarriers=NUM_SUBCARRIERS,
        amplitudes=base_amp.tolist(),
        ground_truth=object_present,
    )

def simulate_live():
    global running
    stub = None
    channel = None
    while running:
        try:
            if stub is None:
                channel = grpc.insecure_channel(INGESTION_TARGET)
                stub = isac_pb2_grpc.IngestionServiceStub(channel)
            sequence = 0
            object_present = False
            frame_interval = 1.0 / FRAME_RATE_HZ
            window_start = time.time()
            window_count = 0
            while running:
                object_present = (sequence % 100) < 20
                frame = generate_csi_frame(sequence, object_present)
                start = time.time()
                stub.ForwardFrame(frame)
                elapsed_ms = (time.time() - start) * 1000
                frame_counter.inc()
                latency_hist.observe(elapsed_ms)
                sequence += 1
                window_count += 1
                now = time.time()
                if now - window_start >= 1.0:
                    rate_gauge.set(window_count / (now - window_start))
                    window_start = now
                    window_count = 0
                time.sleep(max(0, frame_interval - (time.time() - start)))
        except grpc.RpcError as e:
            print(f"[simulator] Connection error: {e}, reconnecting...")
            stub = None
            if channel:
                channel.close()
            time.sleep(2)

def clock_sync_loop():
    """NTP-style min-RTT offset probe against output's ClockSyncService.

    Runs independently of the pipeline so a busy/degraded pipeline doesn't
    contaminate the offset estimate. Best-of-N sample selection (min RTT)
    reduces the effect of a probe that happened to hit a scheduling hiccup.
    """
    channel = None
    stub = None
    last_offset_ns = 0   # reported to output on each probe; stable, so a 1-round lag is fine
    while running:
        try:
            if stub is None:
                channel = grpc.insecure_channel(CLOCK_SYNC_TARGET)
                stub = isac_pb2_grpc.ClockSyncServiceStub(channel)
            best_rtt_ns = None
            best_offset_ns = None
            for _ in range(CLOCK_SYNC_SAMPLES):
                client_send_ns = time.time_ns()
                # Carry node name + last-known offset so output can store & apply it per-node.
                probe = isac_pb2.ClockProbe(client_send_ns=client_send_ns,
                                            edge_node=EDGE_NODE_NAME,
                                            edge_offset_ns=int(last_offset_ns))
                response = stub.Probe(probe, timeout=2.0)
                client_recv_ns = time.time_ns()
                rtt_ns = (client_recv_ns - client_send_ns) - (response.server_send_ns - response.server_recv_ns)
                offset_ns = ((response.server_recv_ns - client_send_ns) + (response.server_send_ns - client_recv_ns)) / 2
                if best_rtt_ns is None or rtt_ns < best_rtt_ns:
                    best_rtt_ns = rtt_ns
                    best_offset_ns = offset_ns
            if best_offset_ns is not None:
                last_offset_ns = best_offset_ns
                clock_offset_gauge.set(best_offset_ns / 1e6)
                clock_sync_rtt_gauge.set(best_rtt_ns / 1e6)
        except grpc.RpcError as e:
            print(f"[simulator] Clock sync probe failed: {e}, reconnecting...")
            stub = None
            if channel:
                channel.close()
        time.sleep(CLOCK_SYNC_INTERVAL_S)

def main():
    start_http_server(METRICS_PORT)
    print(f"[simulator] Starting CSI simulator at {FRAME_RATE_HZ} Hz -> {INGESTION_TARGET}")
    t = threading.Thread(target=simulate_live, daemon=True)
    t.start()
    sync_t = threading.Thread(target=clock_sync_loop, daemon=True)
    sync_t.start()
    signal.signal(signal.SIGINT, lambda s, f: set_running(False))
    try:
        while running:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    print("[simulator] Shutting down")

def set_running(val):
    global running
    running = val

if __name__ == "__main__":
    main()
