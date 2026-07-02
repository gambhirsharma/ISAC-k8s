---
title: Networking
layout: default
parent: Architecture
nav_order: 4
description: "Per-hop routing under KubeEdge: localhost for the hot-path, EdgeMesh/NodePort for the fan-in."
---

# Networking

Networking is the single biggest thing KubeEdge changes, because edge nodes have **no kube-proxy and
no cluster DNS**. A normal k8s app leans on both (`Service` names resolve via DNS; kube-proxy routes
ClusterIPs). Neither exists on the edge. So the design routes **deliberately, per hop** — there are
only two kinds of hop, and they're solved differently.

## Hop 1 — the node-local hot-path: `localhost`

`simulator → ingestion → preprocessing → inference` all run on the same node as DaemonSets with
`hostNetwork: true`. Each stage points at the next over `localhost:<port>`:

| From | Env var | To |
|---|---|---|
| simulator | `INGESTION_SERVICE` | `localhost:50051` |
| ingestion | `PREPROCESSING_SERVICE` | `localhost:50052` |
| preprocessing | `INFERENCE_SERVICE` | `localhost:50053` |

Because a DaemonSet places exactly one pod per node and `hostNetwork` shares the node's network
namespace, `localhost:50052` is **always this node's** preprocessing. No Service, no kube-proxy, no
cross-node smear, sub-millisecond. (The earlier k3s design used `internalTrafficPolicy: Local`
Services to pin traffic node-local — that's a kube-proxy feature and is gone here.)

## Hop 2 — the cross-node fan-in: EdgeMesh, NodePort fallback

The one hop that leaves the node is `inference → output` (plus the `simulator → output` clock-sync
probe). There are two ways to resolve `output` across the boundary:

### EdgeMesh (the KubeEdge-native path)

**EdgeMesh** is KubeEdge's service mesh — a per-node `edgemesh-agent` DaemonSet that restores Service
discovery + DNS on the edge and proxies edge↔cloud traffic. With it installed, edge pods carry
`dnsPolicy: ClusterFirstWithHostNet` and simply resolve `output:50054`. It requires cloudcore's
`dynamicController` (enabled in `cloud-init.sh`) and is installed via
[`scripts/edgemesh-install.sh`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/scripts/edgemesh-install.sh)
(helm; a PSK secures its P2P tunnel).

### NodePort `:30054` (the reliable fallback)

`output` is exposed as a **NodePort on `30054`**. Point the edge's `OUTPUT_SERVICE` /
`CLOCK_SYNC_TARGET` at `<cloud-ip>:30054` and the fan-in bypasses EdgeMesh entirely. This
de-risks the most failure-prone new component: the critical data hop works independently of whether
EdgeMesh routing is healthy.

```yaml
# 05-inference.yaml — resolved by EdgeMesh, or override to the NodePort
- name: OUTPUT_SERVICE
  value: "output:50054"
```

EdgeMesh is documented as the intended path; the manifests default to naming `output:50054`, and the
co-located test edge auto-switches to the NodePort fast-path (kind node internal IP) for lower
overhead.

> **EdgeMesh is the most failure-prone new piece.** The `:30054` NodePort fallback exists precisely
> so the fan-in doesn't depend on it.
{: .note }

## The `output` Services

From
[`06-output.yaml`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/cluster/manifests/06-output.yaml):

- **`output`** — `type: NodePort`, `50054 → :30054`. The one Service the edge resolves cross-node.
- **`dashboard`** — `type: ClusterIP`, `:8080`. Deliberately *not* a NodePort: the dashboard is
  unauthenticated, so it must not be reachable from outside the cluster. Reach it via
  `kubectl port-forward` (see [Deployment](../deployment)); for LAN access, front it with an
  authenticated ingress.

## The cloud side: kind + published cloudcore ports

The cloud is a **kind** cluster (real k8s in Docker). `cloudcore` runs `hostNetwork` on the single
node, and the kind config
([`kind-cloud-config.yaml`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/cluster/kind-cloud-config.yaml))
publishes exactly the ports edges need — **only on the advertise IP** (e.g. a Tailscale IP), nothing
on a public interface:

| Port | Purpose |
|---|---|
| `10000` | CloudHub websocket — edgecore's primary connection |
| `10002` | CloudHub HTTPS — token/cert bootstrap during `keadm join` |
| `10003` | CloudStream — `kubectl logs`/`exec` data channel |
| `10004` | CloudStream **tunnelPort** — edgeStream dials this to open its reverse tunnel |
| `30054` | `output` fan-in NodePort fallback |

Edge devices join `cloudcore` over the `10000` websocket — **not** as ordinary k8s nodes — so the
cloud's CNI (kindnet) is irrelevant to them. That's why a kind cluster works as the cloud even with a
physical device as the edge. `cloud-init.sh` also patches `kube-proxy` and `kindnet` **off** edge
nodes so they don't try (and fail) to run there.

## `kubectl logs`/`exec` to edge pods

This needs the **stream tunnel**: `CloudStream` (cloud) + `edgeStream` (edge). Both are enabled in
setup. Publishing the tunnelPort (`10004`) is essential — without it, edgeStream retries forever with
"connection refused" and `kubectl logs` against edge pods fails even though `10003` is reachable.
(App logs also surface in the dashboard; the tunnel is for `kubectl`-level debugging.)

## Security posture

`insecure_channel` (no TLS between services) and, for a private/LAN registry, an insecure registry are
acceptable **only on a trusted network**. Put edges behind **WireGuard/Tailscale** if they ever move
to an untrusted network — which is the recommended default topology anyway.
