import os
import time
import threading
from collections import deque
from concurrent import futures

import grpc
from prometheus_client import start_http_server, Counter, Histogram

from proto import isac_pb2
from proto import isac_pb2_grpc

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "50054"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8004"))

# Sensing latency here is single-digit ms; default prometheus_client buckets top out
# at 10ms and dump everything above into +Inf, which breaks histogram_quantile.
LATENCY_BUCKETS_MS = (0.5, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 250, 500, 1000, 2000)

results_stored = Counter("output_results_stored", "Detection results stored")
# Raw = server_clock - phone_clock(timestamp_ns). NOT corrected for clock skew between
# the phone and this node — see ClockSyncService below and simulator_clock_offset_ms.
# Grafana subtracts the offset gauge from this to get a skew-corrected e2e figure.
stream_latency = Histogram("output_end_to_end_latency_raw_ms",
                            "End-to-end latency from emission to result, uncorrected for phone/server clock skew",
                            buckets=LATENCY_BUCKETS_MS)
running = True

class OutputServicer(isac_pb2_grpc.OutputServiceServicer):
    def __init__(self):
        self.results = deque(maxlen=1000)
        self.lock = threading.Lock()

    def StoreResult(self, request, context):
        now_ns = time.time_ns()
        end_to_end_ms = (now_ns - request.timestamp_ns) / 1e6
        with self.lock:
            self.results.append(request)
        results_stored.inc()
        stream_latency.observe(end_to_end_ms)
        return isac_pb2.Empty()

    def GetResultStream(self, request, context):
        last_seq = -1
        while running:
            with self.lock:
                to_send = [r for r in self.results if r.sequence > last_seq]
            for r in to_send:
                last_seq = r.sequence
                yield r
            time.sleep(0.01)

class ClockSyncServicer(isac_pb2_grpc.ClockSyncServiceServicer):
    def Probe(self, request, context):
        recv_ns = time.time_ns()
        response = isac_pb2.ClockProbe(
            client_send_ns=request.client_send_ns,
            server_recv_ns=recv_ns,
            server_send_ns=time.time_ns(),
        )
        return response

def main():
    start_http_server(METRICS_PORT)
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    isac_pb2_grpc.add_OutputServiceServicer_to_server(OutputServicer(), server)
    isac_pb2_grpc.add_ClockSyncServiceServicer_to_server(ClockSyncServicer(), server)
    server.add_insecure_port(f"0.0.0.0:{LISTEN_PORT}")
    server.start()
    print(f"[output] Listening on :{LISTEN_PORT}")
    try:
        while running:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    server.stop(0)
    print("[output] Shutting down")

if __name__ == "__main__":
    main()
