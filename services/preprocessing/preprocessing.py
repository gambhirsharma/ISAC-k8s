import os
import time
import threading
from concurrent import futures

import grpc
import numpy as np
from prometheus_client import start_http_server, Counter, Histogram

from proto import isac_pb2
from proto import isac_pb2_grpc

INFERENCE_TARGET = os.environ.get("INFERENCE_SERVICE", "localhost:50053")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "50052"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8002"))
INFERENCE_TIMEOUT_S = float(os.environ.get("INFERENCE_TIMEOUT_S", "0.5"))
INFERENCE_MAX_RETRIES = int(os.environ.get("INFERENCE_MAX_RETRIES", "2"))
INFERENCE_RETRY_BACKOFF_S = float(os.environ.get("INFERENCE_RETRY_BACKOFF_S", "0.1"))

frames_processed = Counter("preprocessing_frames_processed", "Frames processed")
frames_dropped = Counter("preprocessing_frames_dropped", "Frames dropped after inference call timed out or failed")
process_latency = Histogram("preprocessing_process_latency_ms", "Preprocessing latency")
running = True

class PreprocessingServicer(isac_pb2_grpc.PreprocessingServiceServicer):
    def __init__(self):
        self._channel_lock = threading.Lock()
        self._connect()

    def _connect(self):
        # Edge hop (phone -> central) can drop mid-call; reconnect mirrors simulator.py's pattern.
        with self._channel_lock:
            self.inference_channel = grpc.insecure_channel(INFERENCE_TARGET)
            self.inference_stub = isac_pb2_grpc.InferenceServiceStub(self.inference_channel)

    def _detect_with_retry(self, preprocessed):
        for attempt in range(INFERENCE_MAX_RETRIES + 1):
            try:
                return self.inference_stub.Detect(preprocessed, timeout=INFERENCE_TIMEOUT_S)
            except grpc.RpcError as e:
                print(f"[preprocessing] inference call failed (attempt {attempt + 1}): {e}")
                self._connect()
                if attempt < INFERENCE_MAX_RETRIES:
                    time.sleep(INFERENCE_RETRY_BACKOFF_S)
        frames_dropped.inc()
        return None

    def ProcessFrame(self, request, context):
        start = time.time()
        amps = np.array(request.amplitudes, dtype=np.float64)
        mean_amp = float(np.mean(amps))
        var_amp = float(np.var(amps))
        max_delta = float(np.max(amps) - np.min(amps))
        preprocessed = isac_pb2.PreprocessedFrame(
            sequence=request.sequence,
            timestamp_ns=request.timestamp_ns,
            mean_amplitude=mean_amp,
            variance_amplitude=var_amp,
            max_amplitude_delta=max_delta,
            num_subcarriers=request.num_subcarriers,
        )
        self._detect_with_retry(preprocessed)
        frames_processed.inc()
        elapsed_ms = (time.time() - start) * 1000
        process_latency.observe(elapsed_ms)
        return preprocessed

def main():
    start_http_server(METRICS_PORT)
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    isac_pb2_grpc.add_PreprocessingServiceServicer_to_server(PreprocessingServicer(), server)
    server.add_insecure_port(f"0.0.0.0:{LISTEN_PORT}")
    server.start()
    print(f"[preprocessing] Listening on :{LISTEN_PORT}, forwarding to {INFERENCE_TARGET}")
    try:
        while running:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    server.stop(0)
    print("[preprocessing] Shutting down")

if __name__ == "__main__":
    main()
