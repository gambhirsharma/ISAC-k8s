import os
import json
import time
import threading
from collections import deque
from concurrent import futures
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import grpc
from prometheus_client import start_http_server, Counter, Gauge, Histogram

from proto import isac_pb2
from proto import isac_pb2_grpc

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "50054"))
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8004"))
# Custom web dashboard (edge-node count + searchable log view). Separate from the
# Prometheus metrics port so scraping and the human UI don't share a server.
DASHBOARD_PORT = int(os.environ.get("DASHBOARD_PORT", "8080"))
# An edge node counts as "connected" if a result from it arrived within this window.
# Fan-in is result-driven: no results => the node's whole hot path is down or gone.
NODE_TIMEOUT_S = float(os.environ.get("NODE_TIMEOUT_S", "15"))
LOG_BUFFER_SIZE = int(os.environ.get("LOG_BUFFER_SIZE", "2000"))

# Sensing latency here is single-digit ms; default prometheus_client buckets top out
# at 10ms and dump everything above into +Inf, which breaks histogram_quantile.
LATENCY_BUCKETS_MS = (0.5, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 250, 500, 1000, 2000)

results_stored = Counter("output_results_stored", "Detection results stored", ["edge_node"])
# Raw = server_clock - phone_clock(timestamp_ns). NOT corrected for clock skew between
# the edge node and this node — see ClockSyncService and simulator_clock_offset_ms.
# Labeled by edge_node: under KubeEdge the cloud can't scrape edge pod IPs, so ALL latency
# observability flows through this fan-in — this is the per-node e2e latency source.
stream_latency = Histogram("output_end_to_end_latency_raw_ms",
                            "End-to-end latency from emission to result, uncorrected for edge/server clock skew",
                            ["edge_node"], buckets=LATENCY_BUCKETS_MS)
# Per-node, per-stage local processing latency, reconstructed from the *_latency_ns fields
# each DetectionResult already carries. Replaces scraping the edge pods' own histograms
# (impossible cloud->edge under KubeEdge). stage in {ingestion,preprocessing,inference}.
stage_latency = Histogram("output_stage_latency_ms",
                          "Per-edge-node, per-stage local processing latency (from the fan-in stream)",
                          ["edge_node", "stage"], buckets=LATENCY_BUCKETS_MS)
edge_nodes_connected = Gauge("output_edge_nodes_connected", "Edge nodes seen within NODE_TIMEOUT_S")
running = True


class Collector:
    """Central fan-in point for every edge node's DetectionResult stream.

    Holds a rolling log (for the dashboard's log view) and per-edge-node
    aggregates (for the connected-count + per-node cards). One lock guards both.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.log = deque(maxlen=LOG_BUFFER_SIZE)   # newest appended at the right
        self.results = deque(maxlen=1000)          # kept for GetResultStream consumers
        self.nodes = {}                            # edge_node -> aggregate dict

    def record(self, request, end_to_end_ms):
        now_ns = time.time_ns()
        node = request.edge_node or "unknown"
        entry = {
            "recv_ns": now_ns,
            "node": node,
            "sequence": request.sequence,
            "object_detected": bool(request.object_detected),
            "confidence": round(request.confidence, 4),
            "e2e_latency_ms": round(end_to_end_ms, 3),
            "ingestion_latency_ms": round(request.ingestion_latency_ns / 1e6, 3),
            "preprocessing_latency_ms": round(request.preprocessing_latency_ns / 1e6, 3),
            "inference_latency_ms": round(request.inference_latency_ns / 1e6, 3),
        }
        with self.lock:
            self.log.append(entry)
            self.results.append(request)
            n = self.nodes.get(node)
            if n is None:
                n = {"frames": 0, "detections": 0, "last_seen_ns": now_ns,
                     "first_seen_ns": now_ns, "e2e_sum_ms": 0.0}
                self.nodes[node] = n
            n["frames"] += 1
            if entry["object_detected"]:
                n["detections"] += 1
            n["e2e_sum_ms"] += end_to_end_ms
            n["last_seen_ns"] = now_ns

    def snapshot_nodes(self):
        now_ns = time.time_ns()
        out = []
        connected = 0
        with self.lock:
            for name, n in sorted(self.nodes.items()):
                age_s = (now_ns - n["last_seen_ns"]) / 1e9
                online = age_s <= NODE_TIMEOUT_S
                if online:
                    connected += 1
                frames = n["frames"]
                out.append({
                    "node": name,
                    "online": online,
                    "last_seen_s_ago": round(age_s, 1),
                    "frames": frames,
                    "detections": n["detections"],
                    "detection_rate": round(n["detections"] / frames, 4) if frames else 0.0,
                    "avg_e2e_ms": round(n["e2e_sum_ms"] / frames, 3) if frames else 0.0,
                    "uptime_s": round((now_ns - n["first_seen_ns"]) / 1e9, 1),
                })
        return connected, out

    def recent_logs(self, node=None, q=None, limit=200):
        q = (q or "").lower()
        with self.lock:
            items = list(self.log)
        # newest first for display
        items.reverse()
        filtered = []
        for e in items:
            if node and e["node"] != node:
                continue
            if q and q not in json.dumps(e).lower():
                continue
            filtered.append(e)
            if len(filtered) >= limit:
                break
        return filtered

    def stream_since(self, last_seq):
        with self.lock:
            return [r for r in self.results if r.sequence > last_seq]


COLLECTOR = Collector()


class OutputServicer(isac_pb2_grpc.OutputServiceServicer):
    def StoreResult(self, request, context):
        now_ns = time.time_ns()
        end_to_end_ms = (now_ns - request.timestamp_ns) / 1e6
        node = request.edge_node or "unknown"
        COLLECTOR.record(request, end_to_end_ms)
        results_stored.labels(edge_node=node).inc()
        stream_latency.labels(edge_node=node).observe(end_to_end_ms)
        # Per-stage latencies ride the result (populated on the edge). Observing them here is
        # the whole edge-latency observability story under KubeEdge — no cloud->edge scrape.
        stage_latency.labels(edge_node=node, stage="ingestion").observe(request.ingestion_latency_ns / 1e6)
        stage_latency.labels(edge_node=node, stage="preprocessing").observe(request.preprocessing_latency_ns / 1e6)
        stage_latency.labels(edge_node=node, stage="inference").observe(request.inference_latency_ns / 1e6)
        return isac_pb2.Empty()

    def GetResultStream(self, request, context):
        last_seq = -1
        while running:
            for r in COLLECTOR.stream_since(last_seq):
                last_seq = r.sequence
                yield r
            time.sleep(0.01)


class ClockSyncServicer(isac_pb2_grpc.ClockSyncServiceServicer):
    def Probe(self, request, context):
        recv_ns = time.time_ns()
        return isac_pb2.ClockProbe(
            client_send_ns=request.client_send_ns,
            server_recv_ns=recv_ns,
            server_send_ns=time.time_ns(),
        )


def connected_gauge_loop():
    """Keep output_edge_nodes_connected fresh even between scrapes/results so a
    node going quiet is reflected without waiting for the next StoreResult."""
    while running:
        connected, _ = COLLECTOR.snapshot_nodes()
        edge_nodes_connected.set(connected)
        time.sleep(2)


# --- Dashboard (stdlib only, no extra deps) ---------------------------------

DASHBOARD_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>ISAC edge fleet</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;
         background:#0d1117; color:#c9d1d9; }
  header { padding:16px 20px; border-bottom:1px solid #21262d; display:flex;
           align-items:baseline; gap:16px; flex-wrap:wrap; }
  h1 { font-size:16px; margin:0; color:#f0f6fc; }
  .count { font-size:28px; font-weight:700; color:#3fb950; }
  .count.zero { color:#f85149; }
  .muted { color:#8b949e; }
  main { padding:20px; max-width:1100px; margin:0 auto; }
  h2 { font-size:13px; text-transform:uppercase; letter-spacing:.05em; color:#8b949e; margin:24px 0 10px; }
  .cards { display:grid; grid-template-columns:repeat(auto-fill,minmax(220px,1fr)); gap:12px; }
  .card { border:1px solid #21262d; border-radius:8px; padding:12px; background:#161b22; }
  .card .node { font-weight:700; color:#f0f6fc; word-break:break-all; }
  .dot { display:inline-block; width:8px; height:8px; border-radius:50%; margin-right:6px; }
  .dot.on { background:#3fb950; } .dot.off { background:#f85149; }
  .kv { display:flex; justify-content:space-between; color:#8b949e; }
  .kv b { color:#c9d1d9; font-weight:600; }
  .controls { display:flex; gap:8px; margin-bottom:10px; flex-wrap:wrap; }
  input,select { background:#0d1117; border:1px solid #30363d; color:#c9d1d9;
                 padding:6px 10px; border-radius:6px; font:inherit; }
  input#q { flex:1; min-width:180px; }
  .log-wrap { overflow-x:auto; border:1px solid #21262d; border-radius:8px; }
  table { border-collapse:collapse; width:100%; font-size:12.5px; }
  th,td { text-align:left; padding:6px 10px; border-bottom:1px solid #21262d; white-space:nowrap; }
  th { color:#8b949e; position:sticky; top:0; background:#161b22; }
  tr:hover td { background:#161b22; }
  .yes { color:#3fb950; } .no { color:#8b949e; }
</style></head><body>
<header>
  <h1>ISAC edge fleet</h1>
  <div><span id="count" class="count">–</span> <span class="muted">edge nodes connected</span></div>
  <div class="muted" id="updated"></div>
</header>
<main>
  <h2>Edge nodes</h2>
  <div id="cards" class="cards"></div>
  <h2>Detection log</h2>
  <div class="controls">
    <input id="q" placeholder="search logs (node, seq, detected…)">
    <select id="nodeFilter"><option value="">all nodes</option></select>
  </div>
  <div class="log-wrap"><table>
    <thead><tr><th>recv</th><th>edge node</th><th>seq</th><th>detected</th>
      <th>conf</th><th>e2e ms</th><th>ingest</th><th>preproc</th><th>infer</th></tr></thead>
    <tbody id="logs"></tbody>
  </table></div>
</main>
<script>
const fmtTime = ns => new Date(ns/1e6).toLocaleTimeString();
async function refresh() {
  const [nodes, logs] = await Promise.all([
    fetch('/api/nodes').then(r=>r.json()),
    fetch('/api/logs?limit=200&node='+encodeURIComponent(nf.value)+'&q='+encodeURIComponent(q.value)).then(r=>r.json())
  ]);
  const c = document.getElementById('count');
  c.textContent = nodes.connected; c.className = 'count' + (nodes.connected===0?' zero':'');
  document.getElementById('updated').textContent = 'updated ' + new Date().toLocaleTimeString();
  document.getElementById('cards').innerHTML = nodes.nodes.map(n => `
    <div class="card">
      <div class="node"><span class="dot ${n.online?'on':'off'}"></span>${n.node}</div>
      <div class="kv"><span>status</span><b>${n.online?'online':(n.last_seen_s_ago+'s ago')}</b></div>
      <div class="kv"><span>frames</span><b>${n.frames.toLocaleString()}</b></div>
      <div class="kv"><span>detections</span><b>${n.detections.toLocaleString()} (${(n.detection_rate*100).toFixed(1)}%)</b></div>
      <div class="kv"><span>avg e2e</span><b>${n.avg_e2e_ms} ms</b></div>
      <div class="kv"><span>uptime</span><b>${n.uptime_s}s</b></div>
    </div>`).join('') || '<div class="muted">no edge nodes have reported yet</div>';
  const opts = new Set(nodes.nodes.map(n=>n.node));
  for (const o of opts) if (![...nf.options].some(x=>x.value===o))
    nf.appendChild(Object.assign(document.createElement('option'),{value:o,textContent:o}));
  document.getElementById('logs').innerHTML = logs.map(e => `
    <tr><td>${fmtTime(e.recv_ns)}</td><td>${e.node}</td><td>${e.sequence}</td>
      <td class="${e.object_detected?'yes':'no'}">${e.object_detected?'YES':'no'}</td>
      <td>${e.confidence}</td><td>${e.e2e_latency_ms}</td>
      <td>${e.ingestion_latency_ms}</td><td>${e.preprocessing_latency_ms}</td>
      <td>${e.inference_latency_ms}</td></tr>`).join('');
}
const q = document.getElementById('q'), nf = document.getElementById('nodeFilter');
q.addEventListener('input', refresh); nf.addEventListener('change', refresh);
refresh(); setInterval(refresh, 2000);
</script>
</body></html>"""


class DashboardHandler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        payload = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urlparse(self.path)
        path, qs = parsed.path, parse_qs(parsed.query)
        if path == "/" or path == "/index.html":
            self._send(200, DASHBOARD_HTML, "text/html; charset=utf-8")
        elif path == "/api/nodes":
            connected, nodes = COLLECTOR.snapshot_nodes()
            self._send(200, json.dumps({"connected": connected, "nodes": nodes}))
        elif path == "/api/logs":
            node = qs.get("node", [None])[0] or None
            q = qs.get("q", [None])[0] or None
            try:
                limit = min(int(qs.get("limit", ["200"])[0]), 1000)
            except ValueError:
                limit = 200
            self._send(200, json.dumps(COLLECTOR.recent_logs(node=node, q=q, limit=limit)))
        elif path == "/healthz":
            self._send(200, "ok", "text/plain")
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, *args):
        pass  # silence per-request stderr noise


def dashboard_loop():
    server = ThreadingHTTPServer(("0.0.0.0", DASHBOARD_PORT), DashboardHandler)
    print(f"[output] Dashboard on :{DASHBOARD_PORT}")
    server.serve_forever()


def main():
    start_http_server(METRICS_PORT)
    threading.Thread(target=connected_gauge_loop, daemon=True).start()
    threading.Thread(target=dashboard_loop, daemon=True).start()
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    isac_pb2_grpc.add_OutputServiceServicer_to_server(OutputServicer(), server)
    isac_pb2_grpc.add_ClockSyncServiceServicer_to_server(ClockSyncServicer(), server)
    server.add_insecure_port(f"0.0.0.0:{LISTEN_PORT}")
    server.start()
    print(f"[output] Collector listening on :{LISTEN_PORT}")
    try:
        while running:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    server.stop(0)
    print("[output] Shutting down")


if __name__ == "__main__":
    main()
