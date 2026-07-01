# ISAC distributed sensing pipeline on Kubernetes — design notes

## Goal
Build a distributed system on Kubernetes that ingests ISAC (Integrated Sensing and
Communication) data and processes it to detect whether an object is present or not,
with the lowest achievable latency from data acquisition to detection output.

## Current status
No real RF hardware yet — starting from **simulated ISAC data** and designing the
pipeline so it transfers unchanged when a real SDR / WiFi-CSI-capable NIC is added
later.

## Data representation
- Use **CSI (Channel State Information)** — amplitude/phase per subcarrier — rather
  than raw IQ samples. CSI is already a compact feature vector (tens of KB/s per
  stream vs. potentially 100s of Mbps for raw IQ), and it's what an object-presence
  model actually needs.
- Simulate a multipath channel (Rayleigh/Rician fading) with two states:
  - **object absent**: baseline channel
  - **object present**: reflection perturbs specific subcarriers' amplitude/phase
- Options for the simulator: Sionna (NVIDIA's differentiable link-level simulator,
  more realistic) or a simpler numpy/scipy Rician fading generator.
- Emit `(csi_frame, object_present: bool)` pairs with realistic ground truth since
  it's synthetic — also lets you inject controlled noise to stress-test the detector.
- Target update rate: realistic WiFi CSI rates are roughly 1–10 ms per subcarrier
  group; pick something like 100 Hz so latency numbers mean something later.

## Pipeline architecture

```
CSI simulator (outside cluster, "node zero")
        |  gRPC stream
        v
Ingestion agent  ──┐
        |          │  colocated on the same node
        v          │  via node/pod affinity
Preprocessing    ──┤  (avoids cross-node network hops
        |          │   for every sample window)
        v          │
Inference        ──┘
        |
        v
Output (streamed: object present / absent)
```

- **Simulator** stands in for the future radio front-end and should be treated
  exactly like real hardware would be, so the architecture doesn't change later.
- **Ingestion agent**: small Go service, deployed as a **DaemonSet**, with
  `hostNetwork: true` — bypasses the CNI overlay for this hop. When real hardware
  arrives, this is also where SR-IOV VF passthrough / Multus would plug in for
  direct NIC/SDR access.
- **Preprocessing**: denoising, subcarrier selection / feature extraction.
- **Inference**: lightweight CNN or LSTM over the CSI amplitude/phase sequence to
  classify object present/absent. A cheap fallback for coarse detection: variance/
  amplitude-change thresholding across subcarriers in a sliding window (near-zero
  compute cost).
- **Output**: gRPC/WebSocket stream to a downstream consumer, plus Prometheus
  metrics for monitoring.

## Key latency decisions

1. **Don't rely on default Kubernetes networking for the hot path.** Default CNI
   (kube-proxy + iptables/IPVS) adds latency and jitter that matters for a
   sensing pipeline.
2. **Switch the CNI to Cilium.** Cilium replaces kube-proxy's iptables path with
   an eBPF datapath — cuts per-packet latency/jitter for any cross-pod traffic.
   Also doubles as practical eBPF experience relevant to ongoing thesis interest.
3. **Colocate ingestion + preprocessing + inference on the same node** via
   `podAffinity` with `topologyKey: kubernetes.io/hostname`. Communicate over
   local gRPC rather than crossing the pod network.
4. **Ship features, not raw samples.** Extracting CSI (or doing any raw-IQ
   processing) as close to the source as possible and only forwarding compact
   feature vectors into the cluster removes most of the bandwidth/latency problem
   before it starts.
5. **Skip a message broker (Kafka/Redpanda) on the hot path.** Disk-commit and
   consumer-poll overhead isn't worth it for a point-to-point live pipeline —
   use direct gRPC streaming instead. Reintroduce a broker only if replay or
   multiple consumers become a requirement.
6. **GPU/accelerator scheduling** (when the model needs it): use the NVIDIA
   device plugin, and keep inference pods node-local to where the CSI stream
   lands rather than shipping features across the cluster to find a GPU.
7. **For real hardware later**: do raw capture / CSI extraction outside K8s
   networking entirely — bare metal or `hostNetwork` pod with SR-IOV VF
   passthrough, Multus if the node also needs a normal cluster-facing interface.
   If the SDR data arrives over Ethernet (e.g. USRP over 10GbE/UHD), consider an
   XDP program with AF_XDP to redirect packets to a user-space ring buffer,
   ahead of any K8s networking layer.

## Measuring latency
- Instrument each pipeline stage with timestamps in the message; export
  per-stage latency histograms via Prometheus.
- Use `bpftrace` to trace socket-to-socket latency directly for validation —
  gives real numbers to check design decisions against before real hardware
  is introduced.

## Build order
1. CSI simulator (Python/numpy or Sionna) emitting `(csi_frame, label)` over gRPC.
2. Go-based ingestion service, DaemonSet, `hostNetwork: true`.
3. Swap CNI to Cilium.
4. Preprocessing + inference services, pod-affinity colocated, local gRPC.
5. Output stage (streamed result) + Prometheus/bpftrace instrumentation.
6. Later: swap simulator for real SDR/WiFi-CSI source — only step 1 changes.
