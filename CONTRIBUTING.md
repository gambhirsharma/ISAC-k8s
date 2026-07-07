# Contributing to ISAC-k8s

Thanks for looking at this project. It's a research/learning-scale system, not a production
project with a large maintainer team — but issues, fixes, and design discussion are welcome.

## Before you start

Read the docs first, especially if you're touching the pipeline or edge/cloud split:

- [Architecture overview](https://gambhirsharma.github.io/ISAC-k8s/architecture) — the cloud/edge
  seam, the three load-bearing design decisions, and per-topic deep-dives.
- [Deployment & operations](https://gambhirsharma.github.io/ISAC-k8s/deployment) — how to stand up
  the cluster and add an edge node.
- [`kubeedge-migration-plan.md`](kubeedge-migration-plan.md) and
  [`edge-fleet-plan.md`](edge-fleet-plan.md) — locked design decisions and the reasoning behind
  them. If your change conflicts with something documented there, open an issue to discuss first.

## Dev loop

```bash
make cloud-init CLOUDCORE_IP=<ip>          # cloud control plane (kind + KubeEdge)
make build-images REGISTRY=<you>           # build + push service images (regenerates gRPC code)
make namespace CONTEXT=kind-isac
make deploy    CONTEXT=kind-isac REGISTRY=<you>
make edge-container CONTEXT=kind-isac CLOUDCORE_IP=<ip> EDGE_NODE_NAME=edge-test  # local test edge
```

Other useful targets: `make validate` (manifest checks), `make smoke-test`, `make logs-<service>`,
`make port-forward-dashboard` / `make port-forward-grafana`. Run `make help`-style `grep '^[a-z-]*:' Makefile`
or just read the Makefile — every target is a short, commented block.

## Changing the gRPC contract

The `.proto` contract lives under `services/proto/`. After editing it, run `make codegen` (or
`make build-images`, which calls it) to regenerate the generated stubs — don't hand-edit generated
code.

## Pull requests

- Keep PRs scoped to one change; explain the *why* in the description, not just the what.
- If you touch latency-sensitive code (the hot-path, clock sync, async hand-offs), mention it
  explicitly — see [Latency & clock sync](https://gambhirsharma.github.io/ISAC-k8s/architecture/latency)
  for what "correct" means here.
- If you change cluster manifests, run `make validate` before pushing.
- No CI test suite runs automatically yet — describe how you tested a change (e.g. which `make`
  targets you ran, against a real or co-located test edge).

## Reporting issues

Open a GitHub issue with: what you ran, what you expected, what happened, and relevant `make
logs-<service>` output. For anything KubeEdge/networking related, note whether the edge is on the
same LAN, behind Tailscale/WireGuard, or on a WAN — this changes which failure modes are likely.

## License

By contributing, you agree your contributions are licensed under the project's [MIT License](LICENSE).
