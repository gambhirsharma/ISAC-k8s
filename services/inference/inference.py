import os
import time
from concurrent import futures

import grpc
import numpy as np
from prometheus_client import start_http_server, Counter, Histogram

from proto import isac_pb2
from proto import isac_pb2_grpc

OUTPUT_TARGET = os.environ.get("OUTPUT_SERVICE", "localhost:50054")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "50053"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8003"))

LATENCY_BUCKETS_MS = (0.5, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 250, 500, 1000, 2000)

inferences = Counter("inference_total", "Inferences performed", ["result"])
inference_latency = Histogram("inference_latency_ms", "Local inference compute latency (excludes StoreResult call)", buckets=LATENCY_BUCKETS_MS)
# Confusion matrix vs simulator's injected ground_truth — the accuracy signal a
# sensing system needs alongside latency; without it "it responded fast" and
# "it detected correctly" are indistinguishable.
detection_confusion = Counter("inference_detection_confusion_total", "Detections vs ground truth", ["ground_truth", "detected"])
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
        )
        inferences.labels(result="detected" if detected else "not_detected").inc()
        inference_latency.observe(elapsed_ns / 1e6)
        detection_confusion.labels(
            ground_truth="true" if request.ground_truth else "false",
            detected="true" if detected else "false",
        ).inc()
        self.output_stub.StoreResult(result)
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
