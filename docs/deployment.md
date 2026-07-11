---
title: Deployment & operations
layout: default
nav_order: 3
description: "Stand up the cloud, join an edge node, deploy the pipeline, and view the fleet."
---

# Deployment & operations

Everything below the node/network layer is identical to the eventual 6G deployment — only the
`simulator` is later replaced by a real sensor feed. This page walks the full bring-up. All commands
run through the [`Makefile`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/Makefile).

## Topology

- **Cloud** — a **kind** cluster (real k8s in Docker) on any Linux host, running `cloudcore` +
  `output`/Prometheus/Grafana. Isolated: no host changes, coexists with other workloads.
- **Edge** — either a real Linux device/VM running edgecore, or a co-located test edge container on
  the same host.
- Edges reach `cloudcore` over a chosen network — a **Tailscale** IP is the clean default (encrypted,
  no public exposure, works across networks).

## 1. Cloud control plane (once)

Needs only Docker (kind/kubectl/keadm auto-install to `~/.local/bin`, sudo-free):

```bash
make cloud-init CLOUDCORE_IP=<ip edges will dial, e.g. your Tailscale IP>
```

[`cloud-init.sh`](https://github.com/gambhirsharma/ISAC-k8s/blob/main/scripts/cloud-init.sh) creates
the kind cluster (cloudcore ports published **only** on `CLOUDCORE_IP`), runs `keadm init` with
`cloudStream` (kubectl logs/exec to edge) and `dynamicController` (EdgeMesh) enabled, fixes the
logs/exec tunnel, and patches kube-proxy + kindnet off edge nodes. Context becomes `kind-isac`.

## 2. Images + pipeline (once)

Default `REGISTRY` is the public Docker Hub namespace `gambhir` (images public → edges pull over TLS
with no insecure-registry config). Override for your own namespace or a private/LAN registry.

```bash
make build-images REGISTRY=gambhir              # docker buildx --push, multi-arch amd64+arm64
make namespace   CONTEXT=kind-isac
make deploy      CONTEXT=kind-isac REGISTRY=gambhir
```

Edge DaemonSets stay at **0 pods** until a node is labeled `isac-edge=true` — that's expected.

## 3a. Add a real edge device (Linux VM/host)

One command on the device installs containerd (if missing), keadm, a minimal CNI, then joins:

```bash
make keadm-token                                            # on the cloud host
sudo ./scripts/join-edge.sh <CLOUDCORE_IP> <node> <token>  # on the edge device
```

Public Docker Hub images → omit the registry arg. Private/LAN registry → pass it as a 4th arg. Then
onboard from the cloud host:

```bash
make onboard-edge CONTEXT=kind-isac EDGE_NODE_NAME=<node>  # label + wait for the hot-path
```

## 3b. Or a co-located test edge (same host, no extra device)

One command builds a privileged `kindest/node` container, joins it, and onboards it:

```bash
make edge-container CONTEXT=kind-isac CLOUDCORE_IP=<ip> EDGE_NODE_NAME=edge-hetzner
```

Great for validating the pipeline on one box — it uses the kind node's internal IP for a co-located
fast-path fan-in. Remove it with:

```bash
docker rm -f isac-edge-<node> && kubectl --context kind-isac delete node <node>
```

## 4. View the fleet

```bash
make port-forward-dashboard CONTEXT=kind-isac   # -> http://localhost:8080/  (nodes + per-node latency + log)
make port-forward-grafana   CONTEXT=kind-isac   # -> http://localhost:3000/  (fleet latency dashboards, admin/admin)
make port-forward-prometheus CONTEXT=kind-isac  # -> http://localhost:9090/
```

The dashboard shows the live edge-node count, per-node cards (frames, detections, avg e2e latency
corrected + raw, clock offset, uptime), and a searchable detection log. It's a ClusterIP
(unauthenticated) — reach it via `port-forward`, not a node port. Remove a node:
`make offboard-edge CONTEXT=kind-isac EDGE_NODE_NAME=<node>`.

## Makefile reference

| Target | Does |
|---|---|
| `cloud-init` | kind cluster + cloudcore + edge-node patches |
| `edge-container` | co-located test edge (build + join + onboard) |
| `keadm-token` | print an edge join token |
| `join-edge` | print the on-device join command |
| `onboard-edge` / `offboard-edge` | label / unlabel a node (schedule / drain the pipeline) |
| `edgemesh` | install EdgeMesh (needs `EDGEMESH_PSK`) |
| `codegen` | regenerate the proto stubs |
| `build-images` | multi-arch buildx + push to `REGISTRY` |
| `deploy` / `clean` | helm upgrade --install charts/isac-sensing + charts/isac-monitoring (namespaces auto-created) / helm uninstall |
| `validate` | show pod placement, Services, node roles/arch |
| `smoke-test` | throwaway busybox pod on an edge node |
| `logs-*` | tail each service's logs (edge logs need the stream tunnel) |
| `port-forward-*` | dashboard / Grafana / Prometheus |

## Verification checklist

- `kubectl --context kind-isac get nodes -o wide` — edge nodes `Ready`, carry
  `node-role.kubernetes.io/edge`, correct arch.
- **Edge autonomy:** kill the cloud link → edge hot-path pods keep running (the KubeEdge advantage);
  results resume fanning in when the link returns.
- `kubectl --context kind-isac get pods -n isac-sensing -o wide` — hot-path pods on each edge node;
  `output` on the cloud node.
- `kubectl --context kind-isac logs -n isac-sensing -l app=inference` — works (stream tunnel).
- Dashboard shows every edge node online with per-node avg e2e latency.
- Grafana: fleet-wide + per-node e2e and per-stage latency show continuous data.
- Onboard a 2nd edge node → appears within seconds, no per-node manifests.

## Tear down

`make clean` removes the app namespaces (not the cluster/cloudcore — those are real infra). To tear
KubeEdge down fully, run `keadm reset` on the respective hosts.

## Known risks

- **kind cloud** is a single-node, non-HA dev control plane — fine for this spike/portfolio.
- **EdgeMesh** is the most failure-prone new piece; the `:30054` NodePort fallback de-risks the
  critical fan-in hop. → [Networking](architecture/networking)
- **Version skew:** keadm/KubeEdge must match the kind node's k8s minor (KubeEdge 1.23 → k8s ≤1.32;
  pinned to node image v1.32.5).
- `insecure_channel` (no TLS) + insecure registry are acceptable only on a trusted LAN — keep edges
  behind WireGuard/Tailscale on untrusted networks.
