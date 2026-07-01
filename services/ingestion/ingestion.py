import os
import time
import threading
from concurrent import futures

import grpc
from prometheus_client import start_http_server, Counter, Histogram, Gauge

from proto import isac_pb2
from proto import isac_pb2_grpc

PREPROC_TARGET = os.environ.get("PREPROCESSING_SERVICE", "localhost:50052")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "50051"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8001"))

frames_received = Counter("ingestion_frames_received", "Frames received from simulator")
frames_forwarded = Counter("ingestion_frames_forwarded", "Frames forwarded to preprocessing")
forward_latency = Histogram("ingestion_forward_latency_ms", "Latency forwarding frame to preprocessing")
in_flight = Gauge("ingestion_in_flight", "Frames currently being forwarded")
running = True

class IngestionServicer(isac_pb2_grpc.IngestionServiceServicer):
    def __init__(self):
        self.preproc_channel = grpc.insecure_channel(PREPROC_TARGET)
        self.preproc_stub = isac_pb2_grpc.PreprocessingServiceStub(self.preproc_channel)

    def ForwardFrame(self, request, context):
        frames_received.inc()
        in_flight.inc()
        frame = isac_pb2.CSIFrame(
            sequence=request.sequence,
            timestamp_ns=request.timestamp_ns,
            num_subcarriers=request.num_subcarriers,
            amplitudes=request.amplitudes,
            phases=request.phases,
            ground_truth=request.ground_truth,
        )
        start = time.time()
        self.preproc_stub.ProcessFrame(frame)
        elapsed_ms = (time.time() - start) * 1000
        forward_latency.observe(elapsed_ms)
        frames_forwarded.inc()
        in_flight.dec()
        return isac_pb2.Ack(ok=True)

def main():
    start_http_server(METRICS_PORT)
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    isac_pb2_grpc.add_IngestionServiceServicer_to_server(IngestionServicer(), server)
    server.add_insecure_port(f"0.0.0.0:{LISTEN_PORT}")
    server.start()
    print(f"[ingestion] Listening on :{LISTEN_PORT}, forwarding to {PREPROC_TARGET}")
    try:
        while running:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    server.stop(0)
    print("[ingestion] Shutting down")

if __name__ == "__main__":
    main()
