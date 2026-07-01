> **Status: fixes applied.** C1–C5, H1–H2, M1, M4–M7, M9, L1 addressed in code/manifests — see [README.md § Latency-review fixes](README.md#latency-review-fixes) for what changed and where. M3 (dropped frame still Acked upstream) left as-is — intentional per the project's no-buffering/drop-don't-fail design, already surfaced via `preprocessing_frames_dropped_total`. H3/H4/M2/M8 are validity/infra limitations not fixable in code — tracked as open in the README section.

# ISAC-k8s System Review — Latency Focus

**Scope:** 5-stage gRPC ISAC sensing pipeline (`simulator → ingestion → preprocessing → inference → output`) on a single k3s cluster, with an Android phone (Termux, `isac-edge=true`) as a real edge worker running the first three stages and a central server running the last two. **Evaluation criterion: end-to-end sensing latency across the WiFi edge hop.**

**Reviewer:** code + manifest audit of `services/*.py`, `services/proto/isac.proto`, `cluster/manifests/01..10`, `README.md`.

---

## 1. Verdict

As built, this system **cannot produce a trustworthy edge-sensing latency number**, for two independent structural reasons:

1. **The headline metric is clock-skew-dominated.** End-to-end latency is `server_clock_now − phone_clock_emit_timestamp` (`output.py:26-27`). The two endpoints are independently-clocked machines. At a single-digit-millisecond signal, the phone↔server NTP offset (tens of ms, typical) is larger than the thing being measured and can even produce negative latencies. The README's mitigation — a manual `date` check — has second-level resolution and cannot validate a millisecond number.

2. **The pipeline is a single synchronous, nested, blocking call chain with no buffering.** One frame's *entire* round trip must complete before the simulator emits the next frame. So the "100 Hz" rate is aspirational — actual throughput is capped at `1 / round_trip_latency`, and a single WiFi hiccup stalls the whole pipeline (up to ~1.7 s via the retry path) including the producer.

Add to that: the per-stage latency histograms are **nested/cumulative, not isolated**, so the one quantity the experiment exists to measure — the WiFi-hop cost — is **not directly measured anywhere**, and the latency histograms **clip at 10 ms**, so exactly the tail that matters is invisible.

The k3s/phone architecture and the placement split are basically correct. The problem is the measurement design, not the deployment.

---

## 2. Architecture at a glance — the critical path

```
 PHONE (isac-edge=true)                         │  SERVER (central)
                                                │
 simulator ──ForwardFrame(CSIFrame)──► ingestion│
   (blocks)                             (blocks)│
                                           │    │
                                  ProcessFrame   │
                                           ▼    │
                                     preprocessing
                                       (blocks)  │
                                           │  Detect (═══ WiFi RTT ═══►) inference
                                           │    │                          (blocks)
                                           │    │                             │ StoreResult
                                           │    │                             ▼
                                           │    │                          output
                                           │    │                     [e2e latency measured HERE]
                                           ◄════ WiFi return leg ◄══════════┘
```

Every arrow is a **blocking unary gRPC call**. Nesting (verified in source):

- `simulator.simulate_live` → `stub.ForwardFrame(frame)` blocks for an `Ack` (`simulator.py:62`).
- `ingestion.ForwardFrame` → `self.preproc_stub.ProcessFrame(frame)` blocks, *then* returns `Ack` (`ingestion.py:39-44`).
- `preprocessing.ProcessFrame` → `self._detect_with_retry(...)` blocks on `inference.Detect`, *then* returns (`preprocessing.py:62-66`).
- `inference.Detect` → `self.output_stub.StoreResult(result)` blocks, *then* returns (`inference.py:47-48`).
- `output.StoreResult` computes latency, returns `Empty` (`output.py:25-32`).

**Consequence:** `simulator`'s `ForwardFrame` does not return until `output` has stored the result *and* the response has unwound all the way back over the WiFi return leg. The simulator's pacing sleep uses that full duration as `elapsed` (`simulator.py:61-73`), so the emit rate silently collapses to the reciprocal of the round-trip latency. There is no pipelining — one frame in flight, ever.

---

## 3. Critical / high findings (latency)

### C1 — Clock skew corrupts the end-to-end metric  ·  `output.py:26-27`  ·  **critical**
`end_to_end_ms = (time.time_ns() − request.timestamp_ns) / 1e6`. `timestamp_ns` is stamped on the **phone** (`simulator.py:25`); `now_ns` is read on the **server** where `StoreResult` runs. Measured value = true latency **+ (phone→server clock offset)**. That offset (typically tens of ms over WiFi NTP, and drifting with thermal/Doze) dwarfs a ~few-ms latency and can go negative. This is the single number the whole experiment reports (Grafana Panel 6), and it is not valid.
**Fix:** measure latency with a single clock. Either (a) round-trip: stamp emit-time on the phone, echo it back to the phone and measure the delta there against the *same* clock; or (b) run PTP/chrony hard-sync between the two hosts and record the residual offset as an error bar. Loopback baseline has no skew, so baseline-vs-phone deltas are apples-to-oranges until this is fixed.

### C2 — Fully synchronous blocking chain caps throughput at 1/latency  ·  all `*.py`  ·  **critical**
Nested blocking calls (§2) + single-threaded simulator + no buffering ⇒ exactly one frame in flight. Achievable rate = `1 / round_trip_ms`. If the round trip (two WiFi crossings + compute) exceeds 10 ms, the 100 Hz target is unreachable and `simulator_emit_rate_hz` silently reports the degraded rate as if it were the design point. The `ThreadPoolExecutor(max_workers=4)` on every server (`*.py`) is dead capacity — concurrency is always 1 under this producer.
**Fix:** decouple the producer from the sink. Make `ingestion.ForwardFrame` return `Ack` *immediately* after enqueue and forward asynchronously (fire-and-forget / bounded queue), or convert the transport to gRPC streaming so frames pipeline. Then the emit rate reflects the load you intend, and latency is measured per-frame independently of throughput.

### C3 — WiFi-hop latency is never measured in isolation  ·  `ingestion.py:38-41`, `preprocessing.py:64-65`, `inference.py:36-37`  ·  **high**
The per-stage histograms wrap *downstream blocking calls*, so they are cumulative, not per-stage:
- `ingestion_forward_latency_ms` ≈ everything from preprocessing down (incl. WiFi + inference + output).
- `preprocessing_process_latency_ms` ≈ WiFi + inference + output.
- `inference_latency_ms` = only the local `detect()` threshold math (microseconds), excludes `StoreResult`.

You cannot subtract these to recover the WiFi RTT cleanly, and Grafana Panels 2/4/5 read as "per-stage" but are nested — misleading. The experiment's core quantity (cost of the phone↔server hop) has no metric.
**Fix:** time the `inference_stub.Detect(...)` call *specifically* in `preprocessing.py` into its own histogram (`preprocessing_inference_rpc_latency_ms`). That is the WiFi round trip + inference compute; subtract the tiny `inference_latency_ms` to get the network cost. Add it as a first-class Grafana panel.

### C4 — Retry path stalls the entire pipeline for up to ~1.7 s  ·  `preprocessing.py:36-46`  ·  **high**
`INFERENCE_TIMEOUT_S=0.5`, `MAX_RETRIES=2` (→ 3 attempts), `BACKOFF=0.1`. Worst case per frame: `0.5 + 0.1 + 0.5 + 0.1 + 0.5 = 1.7 s`, all of it blocking the synchronous chain — so the **producer emits zero frames** during a single frame's retry storm. Every WiFi glitch becomes a multi-hundred-ms-to-1.7s p99 spike and a throughput cliff. Worse, `_connect()` rebuilds the channel on *every* failure including `DEADLINE_EXCEEDED` (`preprocessing.py:42`), so a mere timeout triggers a fresh TCP+HTTP/2 handshake over WiFi — adding latency instead of removing it.
**Fix:** shrink the timeout toward the frame budget (e.g. 20–50 ms), drop retries to ≤1 or 0 in the hot path (this is a no-buffering, drop-on-fail design anyway — retrying a stale sensing frame has no value), and only reconnect on `UNAVAILABLE`, never on `DEADLINE_EXCEEDED`.

### C5 — Histogram buckets clip at 10 ms — the tail is unmeasurable  ·  all `Histogram(...)` in `*.py`  ·  **high**
No custom buckets, so `prometheus_client` defaults apply: `(.005 … 2.5, 5, 7.5, 10, +Inf)`. All latencies are observed in **milliseconds** (`elapsed_ms`), so every observation above 10 ms lands in `+Inf`. `histogram_quantile` cannot interpolate inside `+Inf`, so p95/p99 (Panel 6) are pinned/garbage the moment latency exceeds 10 ms — which is precisely when the WiFi hop or a retry makes things interesting. Resolution around the ~4 ms baseline is also coarse (only a 2.5/5 ms boundary).
**Fix:** set explicit millisecond buckets on every latency histogram, e.g. `buckets=(0.5,1,2,3,5,8,13,21,34,55,89,144,250,500,1000,2000)`. Without this, no percentile on this dashboard is trustworthy under load.

---

## 4. Full findings table (ranked by latency impact)

| # | Sev | Category | Issue | Latency impact | Fix location |
|---|-----|----------|-------|----------------|--------------|
| C1 | critical | correctness | E2E latency = server clock − phone clock; unsynced | Headline metric invalid, can go negative | `output.py:26` |
| C2 | critical | latency/arch | Synchronous nested blocking chain, no buffering | Throughput = 1/latency; 100 Hz unreachable | all `*.py` |
| C3 | high | observability | Per-stage histograms are nested/cumulative | WiFi-hop cost not isolable; panels mislead | `ingestion/preprocessing/inference.py` |
| C4 | high | latency | Retry path (up to 1.7 s) blocks producer; reconnect on timeout | Huge p99 spikes + throughput cliffs per WiFi glitch | `preprocessing.py:36-46` |
| C5 | high | observability | Default histogram buckets clip at 10 ms | p95/p99 garbage above 10 ms | all `Histogram(...)` |
| H1 | high | correctness | Measured "e2e" captures only the phone→server request leg, not the WiFi return leg | Understates true round trip; mismatches the throughput limiter | `output.py:25-31` |
| H2 | medium | observability | Per-stage latency fields in proto never populated | `ingestion_latency_ns`/`preprocessing_latency_ns` always 0; no attribution | `inference.py:38-44` vs `isac.proto:46-54` |
| H3 | medium | validity | Phone generates synthetic CSI in software — it is not sensing | Measures compute-relocation-over-WiFi, not ISAC sensing | `simulator.py:24-42` |
| H4 | medium | validity | Baseline is same-host loopback; phone run has 2 clocks + real NIC | Baseline-vs-phone delta confounds skew, serialization, thermal | `README.md` "Current status" |
| M1 | medium | observability | No accuracy metric vs `ground_truth`; field dropped at preprocessing | Cannot tell if detector detects anything; sensing quality unmeasured | `isac.proto:37-44`, `output.py`/`inference.py` |
| M2 | medium | architecture | Cross-node gRPC via ClusterIP over Cilium/flannel VXLAN | Encapsulation overhead on the WiFi hop, unmeasured | `preprocessing.py:13` → `inference` Service |
| M3 | low | correctness | Dropped frame returns `Ack ok=true` upstream | A drop looks like success; only counter reconciliation reveals it | `preprocessing.py:45,66` → `ingestion.py:44` |
| M4 | low | correctness | `inference_latency` excludes `StoreResult`; observed in `ns/1e6` into default buckets | Sub-ms values crammed into smallest bucket, poor resolution | `inference.py:37,46-48` |
| M5 | low | latency | `phases[]` computed, serialized (~512 B/frame each way), never used downstream | Wasted payload on the WiFi hop | `simulator.py:27,41` vs `preprocessing.py:50-53` |
| M6 | low | correctness | `preprocessing` reads `self.inference_stub` without the lock it reconnects under | Latent race if concurrency >1 (currently serial, so dormant) | `preprocessing.py:36-46` |
| M7 | low | architecture | No liveness/readiness probes; lazy gRPC connect | First frames hit retry path during rollout; startup latency spike | `cluster/manifests/02-06` |
| M8 | low | validity | Synthetic CSI is IID Gaussian — no temporal correlation, Doppler, multipath | Latency conclusions partly transferable; sensing conclusions not | `simulator.py:24-34` |
| M9 | low | observability | 5 s scrape vs 100 Hz aliases `ingestion_in_flight` gauge | Sub-second in-flight spikes invisible | `09-prometheus.yaml:8`, `ingestion.py:19` |
| L1 | low | dead code | `SimulatorService.StreamFrames` + `simulator` Service (:50050) unused | None (cleanup) | `isac.proto:4-6`, `02-simulator.yaml:41-53` |

---

## 5. Observability gaps (the experiment lives or dies here)

- **No WiFi-hop metric** (C3). The one number the project exists to produce is not directly measured.
- **Buckets clip the tail** (C5). Every percentile is untrustworthy above 10 ms.
- **Nested histograms presented as per-stage** (C3/H2). Panels 2/4/5 invite wrong conclusions.
- **No accuracy/confusion metric** (M1). `ground_truth` is carried on `CSIFrame` but `PreprocessedFrame` drops it (`isac.proto:37-44`), so `inference` never sees it. For a *sensing* system, detection quality is unmeasured — only latency/throughput are.
- **No node-level signal to separate network from phone thermal throttling.** README acknowledges this is the key confound but ships no CPU-temp/CPU-throttle metric. Add `node-exporter` (or a Termux thermal reader) so a latency spike can be attributed to WiFi vs. the phone throttling.

---

## 6. Experiment validity

- **The phone is not a sensor here.** It runs a software Gaussian generator (`simulator.py:24-42`); the "object" is injected in code. This is a valid spike for *"what does relocating pipeline compute to a phone across WiFi cost in latency"* — it is **not** an ISAC sensing measurement. State that framing explicitly, or feed real CSI (from a Wi-Fi CSI tool / SDR) to make the sensing claim.
- **Baseline is not a clean control** (H4). The ~4 ms loopback baseline has one clock and no real NIC serialization; the phone run adds a second clock (C1), a real WiFi NIC, and thermal variance simultaneously. The measured delta mixes all of them — you cannot attribute it to "the WiFi hop."
- **No statistical rigor.** Single run, no warmup/steady-state, no repetition, no confidence interval, and (per C5) an unreliable tail. A credible latency claim needs: fixed offered load, discard warmup, N repeated runs, report p50/p95/p99 with CIs and the measured clock-offset error bar.

---

## 7. Prioritized fixes (latency payoff / effort)

1. **Fix the clock (C1, H1).** Convert e2e to a single-clock round-trip measurement on the phone, or hard-sync + record residual offset. *Nothing else on the dashboard is trustworthy until this is done.* — High payoff, low effort.
2. **Custom ms histogram buckets (C5).** One-line change per histogram; instantly makes percentiles meaningful. — High payoff, trivial effort.
3. **Isolate the WiFi-hop metric (C3).** Time the `Detect` RPC in `preprocessing.py` into its own histogram + Grafana panel. — High payoff, low effort.
4. **Tame the retry path (C4).** Timeout → tens of ms, retries → 0–1, reconnect only on `UNAVAILABLE`. — High payoff (kills p99 spikes), low effort.
5. **Decouple producer from sink (C2).** Immediate `Ack` + bounded async forward, or gRPC streaming. — Highest architectural payoff, medium effort.
6. **Add node thermal/CPU metrics + accuracy metric (M1, §5).** Separate network from throttling; make "sensing" measurable. — Medium payoff, medium effort.
7. Housekeeping: drop unused `phases` from the wire (M5), add probes (M7), lock the stub read (M6), delete dead `SimulatorService`/simulator Service (L1).

---

## 8. Gate — fix before trusting *any* latency number

Do **all** of these before reporting a single figure:

1. **C1** — single-clock latency measurement (else the number is noise).
2. **C5** — millisecond buckets (else p95/p99 are clipped).
3. **C3** — a dedicated WiFi-hop histogram (else you are not measuring the experiment's subject).
4. **C4** — bounded, fast-fail inference calls (else the tail is dominated by retry storms, not the network).
5. Record and publish the **measured clock offset** and the **offered vs. achieved frame rate** alongside every latency figure.

Until this gate passes, treat Grafana Panel 6 as a demo, not data.
