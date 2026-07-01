# ISAC-Inspired Edge Sensing Platform using Mobile Edge Nodes and Kubernetes

## 1. Project Overview

### Goal

Build an **ISAC-inspired edge sensing platform** where a mobile device (smartphone) acts as an edge sensor node that performs local preprocessing and sends processed sensing/network features to a central Kubernetes cluster for low-latency analytics and AI processing.

The system aims to emulate future **6G Integrated Sensing and Communication (ISAC)** and **Edge Intelligence** architectures.

---

## 2. Problem Statement

Traditional cloud-based sensing systems suffer from:

* High network latency
* Excessive bandwidth consumption
* Privacy concerns
* Limited scalability

This project proposes a **cloud-edge collaborative architecture** where:

* Sensors collect data locally
* Edge nodes perform preprocessing
* Kubernetes orchestrates workloads
* Only extracted features are transmitted to the cloud cluster

This reduces:

* End-to-end latency
* Network traffic
* Cloud processing requirements

while improving:

* Responsiveness
* Scalability
* Resource efficiency

---

# 3. System Architecture

```text
                    ┌────────────────────┐
                    │     Smartphone     │
                    │    Edge Sensor     │
                    └─────────┬──────────┘
                              │
                              │
                    Sensor Collection
                              │
                              ▼
                    ┌────────────────────┐
                    │ Edge Processing    │
                    │ Container          │
                    │ (Feature Extract)  │
                    └─────────┬──────────┘
                              │
                    MQTT/gRPC Stream
                              │
                              ▼
                    ┌────────────────────┐
                    │ KubeEdge EdgeCore  │
                    └─────────┬──────────┘
                              │
                              ▼
                 ┌──────────────────────────┐
                 │ Main K3s Cluster         │
                 │                          │
                 │ Kafka / MQTT Broker      │
                 │ Feature Processing       │
                 │ AI Inference             │
                 │ Analytics                │
                 │ Storage                  │
                 └──────────┬───────────────┘
                            │
                            ▼
                    Grafana Dashboard
```

---

# 4. Research Objective

The objectives are:

1. Build a mobile edge sensing framework.
2. Integrate mobile edge nodes with Kubernetes.
3. Reduce transmission overhead.
4. Evaluate edge-cloud collaborative processing.
5. Measure latency improvements.
6. Demonstrate a future 6G ISAC architecture.

---

# 5. Why This Architecture?

Instead of:

```text
Sensor
   ↓
Cloud
   ↓
Processing
```

we implement:

```text
Sensor
   ↓
Edge Processing
   ↓
Cloud Processing
```

Advantages:

* Lower latency
* Lower bandwidth consumption
* Improved scalability
* Better privacy
* Edge autonomy
* Future 6G compatibility

---

# 6. System Components

## Edge Side

### Hardware

* Android smartphone
* Optional:

  * Raspberry Pi
  * NVIDIA Jetson
  * Mini PC

### Sensors

* Accelerometer
* Gyroscope
* GPS
* Network latency
* Message size
* Throughput
* Bandwidth
* Packet loss
* Signal strength

---

## Edge Software

### Option A (Recommended)

Use:

* Android application
* MQTT client
* Local feature extraction

### Option B

Experimental:

* K3s agent
* Container runtime
* Phone as Kubernetes node

---

# 7. Kubernetes Architecture

## Control Plane

```bash
Ubuntu Server
K3s Server
```

Components:

* API server
* scheduler
* controller manager
* etcd/sqlite

---

## Edge Framework

Use:

* KubeEdge

Components:

### Cloud

* CloudCore
* CloudHub
* EdgeController

### Edge

* EdgeCore
* EventBus
* DeviceTwin
* MetaManager

---

# 8. Communication Layer

Possible protocols:

## MQTT

Advantages:

* lightweight
* low latency
* pub/sub
* IoT optimized

Topic structure:

```text
sensor/phone01/network
sensor/phone01/location
sensor/phone01/isac
```

---

## gRPC Streaming

Advantages:

* binary protocol
* low overhead
* high throughput
* bidirectional

---

# 9. Edge Processing Pipeline

Raw data:

```text
message size
data rate
bandwidth
latency
GPS
accelerometer
gyroscope
```

Processing:

```text
collect
    ↓
filter
    ↓
normalize
    ↓
aggregate
    ↓
feature extraction
    ↓
compress
    ↓
transmit
```

Example:

```json
{
    "timestamp": 12345,
    "latency": 5,
    "bandwidth": 100,
    "throughput": 200,
    "packet_loss": 0.1
}
```

---

# 10. Cluster Processing

The central cluster performs:

## Feature Analytics

* statistical analysis
* anomaly detection
* forecasting

---

## AI Processing

Possible models:

* Random Forest
* XGBoost
* LSTM
* Transformer
* CNN

Applications:

* QoS prediction
* traffic prediction
* network optimization
* edge scheduling
* sensing classification

---

# 11. Storage Layer

Use:

## Time-series

* TimescaleDB

or

* InfluxDB

---

## Analytical

* ClickHouse

---

## Cache

* Redis

---

# 12. Monitoring Stack

Deploy:

```text
Prometheus
       ↓
Grafana
```

Metrics:

* CPU
* memory
* network
* bandwidth
* latency
* packet loss
* edge utilization
* processing delay

---

# 13. Latency Evaluation

Measure:

## Baseline

```text
Phone
   ↓
Cloud
   ↓
Processing
```

Measure:

```
T_baseline
```

---

## Proposed

```text
Phone
   ↓
Edge processing
   ↓
Cloud
```

Measure:

```
T_edge
```

Compute:

```text
Latency Reduction

R = (T_baseline - T_edge)/T_baseline
```

---

# 14. Kubernetes Deployment

Create namespaces:

```bash
kubectl create ns edge
kubectl create ns analytics
kubectl create ns monitoring
```

Deploy:

```text
mqtt
kafka
redis
feature-service
ai-service
database
grafana
prometheus
```

---

# 15. Proposed Repository Structure

```text
project/

├── android-app/
│
├── edge-agent/
│
├── mqtt/
│
├── k8s/
│
│   ├── kafka/
│   ├── redis/
│   ├── ai/
│   ├── monitoring/
│
├── analytics/
│
├── ml/
│
├── dashboards/
│
├── datasets/
│
└── docs/
```

---

# 16. Development Roadmap

## Phase 1

Build:

* K3s cluster
* MQTT broker
* Grafana
* Prometheus

Duration:

```
2 weeks
```

---

## Phase 2

Build Android sensor collector.

Collect:

* latency
* bandwidth
* throughput
* GPS
* sensor data

Duration:

```
2 weeks
```

---

## Phase 3

Implement edge feature extraction.

Duration:

```
2 weeks
```

---

## Phase 4

Connect edge node to KubeEdge.

Duration:

```
2 weeks
```

---

## Phase 5

Implement analytics pipeline.

Duration:

```
3 weeks
```

---

## Phase 6

Implement AI models.

Duration:

```
3 weeks
```

---

## Phase 7

Perform experiments.

Metrics:

* latency
* throughput
* CPU
* bandwidth reduction
* accuracy

Duration:

```
2 weeks
```

---

# 17. Expected Results

Expected improvements:

| Metric      | Traditional | Proposed |
| ----------- | ----------- | -------- |
| Latency     | High        | Low      |
| Bandwidth   | High        | Reduced  |
| Cloud CPU   | High        | Reduced  |
| Privacy     | Low         | Improved |
| Scalability | Medium      | High     |

---

# 18. Future Extensions

Future 6G ISAC integration:

* IQ samples
* CSI extraction
* beamforming data
* range-doppler maps
* edge federated learning
* distributed edge AI
* edge scheduling optimization
* digital twins
* multi-edge orchestration

---

# 19. Technology Stack

| Layer      | Technology  |
| ---------- | ----------- |
| Sensor     | Android     |
| Edge       | KubeEdge    |
| Kubernetes | K3s         |
| Messaging  | MQTT/Kafka  |
| API        | gRPC        |
| Database   | TimescaleDB |
| Cache      | Redis       |
| AI         | PyTorch     |
| Monitoring | Prometheus  |
| Dashboard  | Grafana     |

---

# 20. Final Architecture

```text
Phone Sensor
      ↓
Local Feature Extraction
      ↓
MQTT/gRPC
      ↓
KubeEdge
      ↓
K3s Cluster
      ↓
Kafka
      ↓
Feature Processing
      ↓
AI Inference
      ↓
Database
      ↓
Grafana
```

This architecture represents a cloud-native edge intelligence platform inspired by future 6G ISAC systems.

