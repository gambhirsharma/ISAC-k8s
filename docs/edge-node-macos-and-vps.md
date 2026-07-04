# Edge node setup notes — macOS (Apple Silicon) test box + real remote edge (VPS)

Session notes: bugs found/fixed in the edge-join scripts, how to run the whole
cloud+edge stack locally on an M1 Mac for testing, and how to join a *real*
remote machine (e.g. a VPS) as an edge node afterward.

> **Joining the Mac itself as an edge node?** You don't need Lima for that —
> `join-edge.sh` now auto-detects macOS and runs the edge node as a Docker
> container instead (see [below](#joining-a-mac-as-an-edge-node-no-lima)).
> Lima is only needed for the *other* case covered in this doc: running the
> whole **cloud** side (kind cluster + cloudcore) on the Mac for local testing.

## Bugs found + fixed this session

- **`join-edge.sh`**: had no upfront tool/reachability check, wasn't idempotent
  (would try to re-join a device that's already joined), duplicated the
  registry-config logic from `setup-edge-registry.sh`. Fixed: added a preflight
  checklist (OS/arch/curl/tar/systemctl/containerd/keadm + TCP reachability to
  `cloudcore-ip:10000`, skippable with `SKIP_NET_CHECK=1`), an early exit if
  `edgecore` is already active, and now calls `setup-edge-registry.sh` instead
  of inlining the same containerd config.
- **`metaServer` never enabled on `keadm join`** (`join-edge.sh`,
  `edge-container.sh`) despite `edgemesh-install.sh`'s comment saying it's a
  prereq for EdgeMesh. Added `--set modules.metaServer.enable=true` to both.
- **`CONTEXT` default mismatch**: `onboard-edge.sh` and `edgemesh-install.sh`
  defaulted to `kubeadm-isac` (leftover from an earlier plan draft), while
  everything else (Makefile/README/`cloud-init.sh`) uses `kind-isac`. Fixed
  both defaults to `kind-isac`.
- **`cloud-init.sh` hardcoded `linux/amd64`** when downloading kubectl/kind/keadm,
  so it would fetch the wrong-arch binary on any arm64 host (Apple Silicon VM,
  Raspberry Pi, AWS Graviton, etc). Fixed to auto-detect `ARCH` the same way
  `join-edge.sh`/`setup-edge-cni.sh` already do.

## Joining a Mac as an edge node (no Lima)

`keadm`/`edgecore` ship Linux-only binaries (no darwin build) and `edgecore`
itself needs containerd + systemd cgroups — none of which macOS's kernel has.
Rather than a full Lima VM, `join-edge.sh` now detects `Darwin` and runs the
edge node as a privileged `kindest/node` Docker container (systemd + containerd
built in) on top of Docker Desktop's own Linux VM — the same trick
`edge-container.sh` already uses for co-located test edges, just pointed at a
real remote `cloudcore` instead. No root/sudo, no separate VM tool to install.

```bash
# On the Mac — just needs Docker Desktop running
./scripts/join-edge.sh <cloudcore-ip> <node-name> <token> [registry]
```

This launches a container named `isac-edge-<node-name>`, preps it (sudo shim,
disables the unused kubelet, drops the same minimal CNI `setup-edge-cni.sh`
installs on real Linux devices), installs `keadm` if missing, and runs
`keadm join`. Safe to re-run — skips instead of re-joining if `edgecore` is
already active in that container.

```bash
docker exec isac-edge-<node-name> systemctl status edgecore   # check status
docker exec isac-edge-<node-name> journalctl -u edgecore -f   # live logs
docker rm -f isac-edge-<node-name>                             # remove it
```

Onboard from the cloud side exactly as with a real device:
`make onboard-edge EDGE_NODE_NAME=<node-name>`.

## Running the whole stack locally on an M1 MacBook Air

The scripts assume Linux (`systemctl`, `apt-get`/`dnf`/`pacman`, Linux ELF
binaries) — macOS can't run them natively. Fix: run everything inside one
arm64 Ubuntu Linux VM via [Lima](https://github.com/lima-vm/lima), which ships
a ready-made Docker template.

```bash
# On the Mac host
brew install lima
limactl start template://docker --name isac --cpus 4 --memory 6 --disk 30
limactl shell isac

# --- everything below runs INSIDE the VM ---
sudo apt-get update && sudo apt-get install -y git make curl
git clone https://github.com/gambhirsharma/ISAC-k8s.git
cd ISAC-k8s
docker ps                                   # sanity check

VM_IP=$(hostname -I | awk '{print $1}')
make cloud-init CLOUDCORE_IP=$VM_IP         # kind cluster + cloudcore

docker login
make build-images REGISTRY=<your-dockerhub-username>
make namespace
make deploy REGISTRY=<your-dockerhub-username>

make edge-container CLOUDCORE_IP=$VM_IP EDGE_NODE_NAME=m1-edge   # co-located test edge
make validate
```

`limactl stop isac` / `limactl start isac` pauses/resumes the whole VM without
redoing setup.

## Joining a real remote edge node (e.g. a VPS)

`edge-container.sh` above is only a same-box simulation. A VPS is a real,
separate machine — use `join-edge.sh` on it directly, the same as any physical
edge device. The only extra requirement vs. the local test: the VPS needs a
network path to reach `cloudcore-ip:10000`. Since the cloud (the Lima VM on
the Mac) is behind home-network NAT, use Tailscale (or another mesh VPN) to
bridge the two — this is what `ADVERTISE_IP` is designed for throughout the
repo.

1. **Put the cloud on a stable, VPS-reachable IP.** `ADVERTISE_IP` is baked into
   cloudcore's cert/token at init time, so if the cloud was inited with the
   VM's local IP, redo it with a Tailscale IP:
   ```bash
   # inside the Lima VM
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   TS_IP=$(tailscale ip -4)

   kind delete cluster --name isac          # only if cloud-init already ran with the old IP
   make cloud-init CLOUDCORE_IP=$TS_IP
   make namespace
   make deploy REGISTRY=<your-dockerhub-username>
   ```

2. **Join the VPS to the same tailnet:**
   ```bash
   # on the VPS
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   ```

3. **Get a join token** (inside the Lima VM, cloud side):
   ```bash
   make keadm-token
   ```

4. **Join from the VPS** (real device path — root, self-contained):
   ```bash
   git clone https://github.com/gambhirsharma/ISAC-k8s.git
   cd ISAC-k8s
   sudo ./scripts/join-edge.sh $TS_IP <vps-node-name> <token>
   ```
   This runs the new preflight checklist, installs containerd/keadm/CNI if
   missing, then `keadm join`. Safe to re-run — skips instead of re-joining if
   `edgecore` is already active on that box.

5. **Onboard from the cloud side** (Lima VM):
   ```bash
   make onboard-edge EDGE_NODE_NAME=<vps-node-name>
   ```

### Checking the edge node's status

From the cloud side (Lima VM), not the VPS:
```bash
kubectl --context kind-isac get nodes -o wide            # VPS node should show Ready
kubectl --context kind-isac describe node <vps-node-name>
kubectl --context kind-isac -n isac-sensing get pods -o wide --field-selector spec.nodeName=<vps-node-name>
make validate                                             # placement + labels overview
```
From the VPS itself:
```bash
sudo systemctl status edgecore                            # should be active (running)
sudo journalctl -u edgecore -f                             # live logs if something's off
```
