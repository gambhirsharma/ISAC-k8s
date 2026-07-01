import os
import time
import queue
import threading
from concurrent import futures

import grpc
import numpy as np
from prometheus_client import start_http_server, Counter, Histogram, Gauge

from proto import isac_pb2
from proto import isac_pb2_grpc

INFERENCE_TARGET = os.environ.get("INFERENCE_SERVICE", "localhost:50053")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "50052"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8002"))
# Frame budget at 100Hz is 10ms; this is a fast-fail timeout for a single WiFi hop,
# not a generous one — a stale sensing frame isn't worth waiting half a second for.
INFERENCE_TIMEOUT_S = float(os.environ.get("INFERENCE_TIMEOUT_S", "0.05"))
INFERENCE_MAX_RETRIES = int(os.environ.get("INFERENCE_MAX_RETRIES", "1"))
INFERENCE_RETRY_BACKOFF_S = float(os.environ.get("INFERENCE_RETRY_BACKOFF_S", "0.01"))
# Bounded so a stalled WiFi hop degrades to dropping frames, not unbounded memory growth
# or (worse) blocking the producer — this is the fix for the old fully-synchronous chain
# where the whole pipeline throttled to 1/round_trip_latency.
DISPATCH_QUEUE_SIZE = int(os.environ.get("DISPATCH_QUEUE_SIZE", "50"))

LATENCY_BUCKETS_MS = (0.5, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 250, 500, 1000, 2000)

frames_processed = Counter("preprocessing_frames_processed", "Frames locally preprocessed (independent of inference dispatch outcome)")
frames_dropped = Counter("preprocessing_frames_dropped", "Frames dropped, by reason", ["reason"])
process_latency = Histogram("preprocessing_process_latency_ms", "Local preprocessing compute latency (excludes inference RPC)", buckets=LATENCY_BUCKETS_MS)
# This is the metric the whole phone-as-edge-node experiment exists to produce: the
# actual phone<->server WiFi round trip, isolated from local compute on either side.
inference_rpc_latency = Histogram("preprocessing_inference_rpc_latency_ms", "Round-trip latency of the Detect RPC to inference (the WiFi hop)", buckets=LATENCY_BUCKETS_MS)
dispatch_queue_depth = Gauge("preprocessing_dispatch_queue_depth", "Frames queued for async dispatch to inference")
running = True

class PreprocessingServicer(isac_pb2_grpc.PreprocessingServiceServicer):
    def __init__(self):
        self._channel_lock = threading.Lock()
        self._connect()
        self._queue = queue.Queue(maxsize=DISPATCH_QUEUE_SIZE)
        self._worker = threading.Thread(target=self._dispatch_loop, daemon=True)
        self._worker.start()

    def _connect(self):
        # Edge hop (phone -> central) can drop mid-call; reconnect mirrors simulator.py's pattern.
        with self._channel_lock:
            self.inference_channel = grpc.insecure_channel(INFERENCE_TARGET)
            self.inference_stub = isac_pb2_grpc.InferenceServiceStub(self.inference_channel)

    def _get_stub(self):
        with self._channel_lock:
            return self.inference_stub

    def _detect_with_retry(self, preprocessed):
        attempt = 0
        while True:
            stub = self._get_stub()
            start = time.time()
            try:
                stub.Detect(preprocessed, timeout=INFERENCE_TIMEOUT_S)
                inference_rpc_latency.observe((time.time() - start) * 1000)
                return
            except grpc.RpcError as e:
                inference_rpc_latency.observe((time.time() - start) * 1000)
                code = e.code() if hasattr(e, "code") else None
                if code == grpc.StatusCode.UNAVAILABLE and attempt < INFERENCE_MAX_RETRIES:
                    print(f"[preprocessing] inference unavailable (attempt {attempt + 1}): {e}, reconnecting...")
                    self._connect()
                    time.sleep(INFERENCE_RETRY_BACKOFF_S)
                    attempt += 1
                    continue
                # DEADLINE_EXCEEDED or retries exhausted: the frame is stale, drop it now
                # rather than retrying a sensing reading nobody will act on in time.
                frames_dropped.labels(reason="inference_failed").inc()
                return

    def _dispatch_loop(self):
        while running:
            try:
                preprocessed = self._queue.get(timeout=0.5)
            except queue.Empty:
                continue
            dispatch_queue_depth.set(self._queue.qsize())
            self._detect_with_retry(preprocessed)

    def ProcessFrame(self, request, context):
        start = time.time()
        amps = np.array(request.amplitudes, dtype=np.float64)
        mean_amp = float(np.mean(amps))
        var_amp = float(np.var(amps))
        max_delta = float(np.max(amps) - np.min(amps))
        elapsed_ns = int((time.time() - start) * 1e9)
        preprocessed = isac_pb2.PreprocessedFrame(
            sequence=request.sequence,
            timestamp_ns=request.timestamp_ns,
            mean_amplitude=mean_amp,
            variance_amplitude=var_amp,
            max_amplitude_delta=max_delta,
            num_subcarriers=request.num_subcarriers,
            ground_truth=request.ground_truth,
            ingestion_latency_ns=request.ingestion_latency_ns,
            preprocessing_latency_ns=elapsed_ns,
        )
        try:
            self._queue.put_nowait(preprocessed)
            dispatch_queue_depth.set(self._queue.qsize())
        except queue.Full:
            frames_dropped.labels(reason="queue_full").inc()
        frames_processed.inc()
        process_latency.observe((time.time() - start) * 1000)
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
