---
title: Edge node
layout: default
parent: Architecture
nav_order: 3
description: "How a KubeEdge edge node runs the whole detection hot-path, and how labeling schedules it."
---

# Edge node

An **edge node** is the unit of the fleet. Each one runs the entire detection hot-path
(`simulator → ingestion → preprocessing → inference`) locally and reports only finished detections to
the cloud. This page covers what an edge node *is* under KubeEdge, how workloads land on it, and how
it stays useful when the cloud link drops.

![KubeEdge topology](../assets/kubeedge-diagram.png)

## What runs on an edge node

Instead of a full Kubernetes node agent, an edge node runs **edgecore**:

| Component | Role |
|---|---|
| `edged` | A lightweight kubelet — pulls images (via containerd) and runs the pods. |
| `edgehub` | Websocket client that connects out to the cloud's `CloudHub`. |
| `metamanager` | Local metadata store — the source of **edge autonomy** (see below). |
| `edgeStream` | The edge end of the `kubectl logs`/`exec` tunnel (pairs with cloud `CloudStream`). |

edgecore is **~70 MB idle** with **no kube-proxy and no etcd** — that lightness, plus autonomy, is
the whole reason for choosing KubeEdge over a full node agent. The trade-off is that the two things
a normal pod relies on — kube-proxy Service routing and cluster DNS — aren't there, which the
[networking design](networking) works around.

## Why the whole hot-path is on the node

Originally `inference` was central, so **every frame** crossed the network and the central node was a
per-frame bottleneck. The current design colocates `simulator → ingestion → preprocessing →
inference` on each edge node, so:

- All four stages talk over `localhost` — **sub-millisecond, no network** for the busy hops.
- Only the low-rate `DetectionResult` leaves the node.
- Adding nodes scales linearly — the cloud only ever sees the fan-in, never raw frames.

This is the core latency + scalability win, and it's independent of the runtime choice.

## How workloads land: DaemonSets + a label

The four hot-path services are **DaemonSets**, not Deployments. A DaemonSet runs exactly one pod per
matching node — which is precisely the "add a node → it runs the pipeline" behavior, with no custom
controller. Each pod spec has three KubeEdge-specific pieces (from
[`02-simulator.yaml`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/cluster/manifests/02-simulator.yaml)
and siblings):

```yaml
nodeSelector:
  isac-edge: "true"                       # the on-switch: only labeled nodes get the pipeline
tolerations:
  - key: node-role.kubernetes.io/edge     # tolerate the edge node-role taint
    operator: Exists
    effect: NoSchedule
hostNetwork: true                          # so stages reach each other over localhost
dnsPolicy: ClusterFirstWithHostNet         # keep cluster DNS so EdgeMesh can resolve `output`
```

`hostNetwork: true` is what makes `localhost:50052` mean "*this node's* preprocessing" — because a
DaemonSet guarantees exactly one such pod per node. The pods also carry CPU/memory requests+limits, so
"the resources the workload needs" travel with the workload.

**Labeling is the single switch.** `kubectl label node <n> isac-edge=true` schedules the whole
pipeline; removing the label drains it. That's what `make onboard-edge` / `offboard-edge` do — see
[Deployment](../deployment).

### Node identity via the downward API

`inference` (and `simulator`) read their own node name through the downward API into
`EDGE_NODE_NAME`:

```yaml
env:
  - name: EDGE_NODE_NAME
    valueFrom:
      fieldRef:
        fieldPath: spec.nodeName
```

Since the hot-path is colocated, inference's own node name **is** the frame's origin edge node. It
gets stamped onto every `DetectionResult.edge_node`, which is how the collector groups and counts live
nodes.

## Edge autonomy

Because `metamanager` keeps a local metadata store, an edge node's hot-path **keeps running if the
cloud link drops** — pods aren't evicted, detection continues, and results resume fanning in when the
link returns. This is the property a flapping node agent lacks, and it's a listed item on the
[verification checklist](../deployment#verification-checklist): kill the cloud link, confirm the edge
pods stay up.

## Two flavours of edge node

- **A real device/VM** — join it with
  [`scripts/join-edge.sh`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/scripts/join-edge.sh)
  (installs containerd + keadm + a minimal CNI, then `keadm join`).
- **A co-located test edge** — a privileged `kindest/node` container on the cloud host, via
  [`scripts/edge-container.sh`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/scripts/edge-container.sh).
  Great for validating the pipeline on one box; it uses the kind node's internal IP for a co-located
  fast-path fan-in.

Both paths converge on the same thing: a node that shows up `Ready`, gets labeled, and starts
reporting. Details in [Deployment](../deployment).

## A CNI must exist first

Even though the hot-path pods are `hostNetwork` (and don't need pod networking), `edged` reports the
node **NotReady** until a CNI is present. `join-edge.sh` installs a minimal CNI
([`setup-edge-cni.sh`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/scripts/setup-edge-cni.sh))
before starting edgecore; the co-located container uses a `ptp` CNI that ships in `kindest/node`.
