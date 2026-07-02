import os
import time
import queue
import threading
from concurrent import futures

import grpc
import numpy as np
from prometheus_client import start_http_server, Counter, Histogram

from proto import isac_pb2
from proto import isac_pb2_grpc

OUTPUT_TARGET = os.environ.get("OUTPUT_SERVICE", "localhost:50054")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "50053"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8003"))
# The inference->output fan-in crosses the network (edge->cloud). A blocking StoreResult per
# frame throttled the whole pipeline to ~1/RTT (~20 f/s over WAN) and aged frames seconds in
# the upstream queue. Decouple it: Detect returns immediately after local compute; a pool of
# sender threads drains a bounded queue with many StoreResults in flight at once, so
# throughput is senders/RTT (not 1/RTT). Mirrors preprocessing's dispatch decoupling.
OUTPUT_QUEUE_SIZE = int(os.environ.get("OUTPUT_QUEUE_SIZE", "500"))
OUTPUT_SENDER_THREADS = int(os.environ.get("OUTPUT_SENDER_THREADS", "16"))
OUTPUT_RPC_TIMEOUT_S = float(os.environ.get("OUTPUT_RPC_TIMEOUT_S", "5"))
# Injected via downward API (spec.nodeName). Since simulator..inference are colocated
# on one edge node, this node name is the frame's origin edge node — stamped onto the
# result so the central collector can group/count live edge nodes.
EDGE_NODE_NAME = os.environ.get("EDGE_NODE_NAME", "unknown")

LATENCY_BUCKETS_MS = (0.5, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 250, 500, 1000, 2000)

inferences = Counter("inference_total", "Inferences performed", ["result"])
inference_latency = Histogram("inference_latency_ms", "Local inference compute latency (excludes StoreResult call)", buckets=LATENCY_BUCKETS_MS)
# Confusion matrix vs simulator's injected ground_truth — the accuracy signal a
# sensing system needs alongside latency; without it "it responded fast" and
# "it detected correctly" are indistinguishable.
detection_confusion = Counter("inference_detection_confusion_total", "Detections vs ground truth", ["ground_truth", "detected"])
# Results dropped before reaching output (queue full = fan-in can't keep up, or RPC error).
results_dropped = Counter("inference_results_dropped_total", "Results dropped before StoreResult", ["reason"])
# The edge->cloud StoreResult RPC latency — the real cost of the one network hop.
output_rpc_latency = Histogram("inference_output_rpc_latency_ms", "StoreResult (edge->cloud fan-in) RPC latency", buckets=LATENCY_BUCKETS_MS)
running = True

# Simple threshold-based detector: object present if amplitude variance spikes
def detect(preprocessed_frame):
    var = preprocessed_frame.variance_amplitude
    mean = preprocessed_frame.mean_amplitude
    threshold = 0.015
    confidence = min(1.0, abs(var - 0.01) / threshold) if var > 0.01 else 0.0
    detected = var > (0.01 + threshold)
    return detected, confidence

class InferenceServicer(isac_pb2_grpc.InferenceServiceServicer):
    def __init__(self):
        self.output_channel = grpc.insecure_channel(OUTPUT_TARGET)
        self.output_stub = isac_pb2_grpc.OutputServiceStub(self.output_channel)
        # Bounded hand-off queue drained by a pool of senders (concurrent in-flight RPCs).
        self.q = queue.Queue(maxsize=OUTPUT_QUEUE_SIZE)
        for _ in range(OUTPUT_SENDER_THREADS):
            threading.Thread(target=self._sender, daemon=True).start()

    def _sender(self):
        while running:
            try:
                result = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                t = time.time()
                self.output_stub.StoreResult(result, timeout=OUTPUT_RPC_TIMEOUT_S)
                output_rpc_latency.observe((time.time() - t) * 1000)
            except grpc.RpcError:
                results_dropped.labels(reason="rpc_error").inc()

    def Detect(self, request, context):
        start = time.time()
        detected, confidence = detect(request)
        elapsed_ns = int((time.time() - start) * 1e9)
        result = isac_pb2.DetectionResult(
            sequence=request.sequence,
            timestamp_ns=request.timestamp_ns,
            object_detected=detected,
            confidence=confidence,
            ingestion_latency_ns=request.ingestion_latency_ns,
            preprocessing_latency_ns=request.preprocessing_latency_ns,
            inference_latency_ns=elapsed_ns,
            edge_node=EDGE_NODE_NAME,
        )
        inferences.labels(result="detected" if detected else "not_detected").inc()
        inference_latency.observe(elapsed_ns / 1e6)
        detection_confusion.labels(
            ground_truth="true" if request.ground_truth else "false",
            detected="true" if detected else "false",
        ).inc()
        # Non-blocking hand-off: never let the WAN fan-in stall the local hot path.
        try:
            self.q.put_nowait(result)
        except queue.Full:
            results_dropped.labels(reason="queue_full").inc()
        return result

def main():
    start_http_server(METRICS_PORT)
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    isac_pb2_grpc.add_InferenceServiceServicer_to_server(InferenceServicer(), server)
    server.add_insecure_port(f"0.0.0.0:{LISTEN_PORT}")
    server.start()
    print(f"[inference] Listening on :{LISTEN_PORT}, sending results to {OUTPUT_TARGET}")
    try:
        while running:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    server.stop(0)
    print("[inference] Shutting down")

if __name__ == "__main__":
    main()
