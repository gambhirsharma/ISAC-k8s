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

frame_counter = Counter("simulator_frames_sent", "Frames sent to ingestion")
rate_gauge = Gauge("simulator_emit_rate_hz", "Current emission rate")
latency_hist = Histogram("simulator_ingestion_latency_ms", "Latency to ingestion service")
running = True

def generate_csi_frame(sequence, object_present):
    ts = time.time_ns()
    base_amp = 0.5 + 0.1 * np.random.randn(NUM_SUBCARRIERS)
    phases = np.random.uniform(-np.pi, np.pi, NUM_SUBCARRIERS)
    if object_present:
        reflection_center = np.random.randint(0, NUM_SUBCARRIERS)
        reflection_width = np.random.randint(2, 8)
        start_idx = max(0, reflection_center - reflection_width // 2)
        end_idx = min(NUM_SUBCARRIERS, reflection_center + reflection_width // 2)
        base_amp[start_idx:end_idx] += np.random.uniform(0.2, 0.5)
        phases[start_idx:end_idx] += np.random.uniform(-0.3, 0.3)
    return isac_pb2.CSIFrame(
        sequence=sequence,
        timestamp_ns=ts,
        num_subcarriers=NUM_SUBCARRIERS,
        amplitudes=base_amp.tolist(),
        phases=phases.tolist(),
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

def main():
    start_http_server(METRICS_PORT)
    print(f"[simulator] Starting CSI simulator at {FRAME_RATE_HZ} Hz -> {INGESTION_TARGET}")
    t = threading.Thread(target=simulate_live, daemon=True)
    t.start()
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
