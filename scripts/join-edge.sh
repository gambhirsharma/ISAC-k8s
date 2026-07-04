#!/usr/bin/env bash
# Join THIS device to the KubeEdge cluster as an edge node (edgecore).
# Run ON the edge device. Linux: as root. macOS: no root needed (uses Docker instead).
# Replaces the old `k3s agent ...` join.
#
#   sudo ./scripts/join-edge.sh <cloudcore-ip> <node-name> <token> [registry]   # Linux
#   ./scripts/join-edge.sh <cloudcore-ip> <node-name> <token> [registry]       # macOS
#
# Self-contained: runs a preflight tool check, installs whatever's missing (containerd,
# keadm, CNI), points containerd at the (insecure) image registry if given, then `keadm
# join`. Safe to re-run: if this node is already joined, it reports status and exits
# instead of re-joining. Get <token> from `keadm gettoken` on the cloud host.
#
# macOS: edgecore/keadm ship Linux-only binaries and need containerd + systemd cgroups,
# which macOS doesn't have — there's no native install path. Instead of a separate Lima
# VM, this runs the edge node as a privileged `kindest/node` container (ships systemd +
# containerd) on top of Docker Desktop's own Linux VM. No root/sudo needed on macOS.
#
# Skip the reachability preflight (e.g. cloudcore isn't up yet) with SKIP_NET_CHECK=1.
set -euo pipefail

CLOUDCORE_IP="${1:-}"
NODE="${2:-}"
TOKEN="${3:-}"
REGISTRY="${4:-}"
CLOUDHUB_PORT="${CLOUDHUB_PORT:-10000}"
KUBEEDGE_VERSION="${KUBEEDGE_VERSION:-v1.23.0}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
RUNTIME_ENDPOINT="${RUNTIME_ENDPOINT:-unix:///run/containerd/containerd.sock}"
SKIP_NET_CHECK="${SKIP_NET_CHECK:-0}"
DIR="$(cd "$(dirname "$0")" && pwd)"
OS="$(uname -s)"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.32.5@sha256:e3b2327e3a5ab8c76f5ece68936e4cafaa82edf58486b769727ab0b3b97a5b0d}"
POD_SUBNET="${POD_SUBNET:-10.244.1.0/24}"

if [[ -z "$CLOUDCORE_IP" || -z "$NODE" || -z "$TOKEN" ]]; then
  echo "usage: $0 <cloudcore-ip> <node-name> <token> [registry]" >&2
  echo "  Linux: run as root (sudo). macOS: runs the edge node in a Docker container instead." >&2
  exit 2
fi

check() { # check <label> <pass?>
  if [[ "$2" == 1 ]]; then printf '   [ok]   %s\n' "$1"; else printf '   [miss] %s\n' "$1"; ok=0; fi
}

reachability_check() {
  [[ "$SKIP_NET_CHECK" == 1 ]] && return 0
  if (exec 3<>"/dev/tcp/$CLOUDCORE_IP/$CLOUDHUB_PORT") 2>/dev/null; then
    exec 3>&- 3<&-
    check "reachable: $CLOUDCORE_IP:$CLOUDHUB_PORT" 1
  else
    check "reachable: $CLOUDCORE_IP:$CLOUDHUB_PORT" 0
    echo "ERROR: can't reach cloudcore at $CLOUDCORE_IP:$CLOUDHUB_PORT (check network/tailnet, or set SKIP_NET_CHECK=1)." >&2
    exit 1
  fi
}

# ============================= macOS path =============================
# Same container trick as scripts/edge-container.sh, but pointed at a real
# remote cloudcore (CLOUDCORE_IP/TOKEN from argv) instead of a co-located kind
# cluster, and driven entirely through `docker exec` (no sudo on the host).
join_macos() {
  echo ">> Preflight checks (macOS: edge node runs in a Docker container)"
  ok=1
  check "OS: Darwin" 1
  [[ "$ARCH" == amd64 || "$ARCH" == arm64 ]] && check "arch: $ARCH supported" 1 || check "arch: $ARCH supported" 0
  command -v docker >/dev/null 2>&1 && check "docker" 1 || check "docker (required — install Docker Desktop)" 0
  docker info >/dev/null 2>&1 && check "docker daemon running" 1 || check "docker daemon running (start Docker Desktop)" 0
  [[ "$ok" == 1 ]] || { echo "ERROR: missing required tool(s) above. Fix and re-run." >&2; exit 1; }
  reachability_check

  CTR="isac-edge-${NODE}"
  if docker exec "$CTR" systemctl is-active --quiet edgecore 2>/dev/null; then
    echo ">> edgecore is already running in container '$CTR'. Skipping join."
    echo "   To rejoin fresh: docker rm -f $CTR && $0 $CLOUDCORE_IP $NODE <token> $REGISTRY"
    exit 0
  fi

  echo ">> Launching edge host container '$CTR' (systemd + containerd, kindest/node)"
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  modmount=(); [[ -d /lib/modules ]] && modmount=(-v /lib/modules:/lib/modules:ro)
  docker run -d --privileged --name "$CTR" --hostname "$NODE" \
    "${modmount[@]}" --tmpfs /run --tmpfs /tmp -v /var \
    "$NODE_IMAGE" >/dev/null
  for i in $(seq 1 30); do
    docker exec "$CTR" bash -c 'systemctl is-active containerd' 2>/dev/null | grep -qx active && break; sleep 1
  done

  echo ">> Preparing edge host (sudo shim, disable kubelet, CNI)"
  # keadm join shells out to `sudo systemctl ...`; the container is already root and has no sudo.
  docker exec "$CTR" bash -c '
    printf "#!/bin/sh\nexec \"\$@\"\n" > /usr/bin/sudo && chmod +x /usr/bin/sudo
    systemctl disable --now kubelet 2>/dev/null || true'
  # /tmp is a fresh --tmpfs that systemd's own tmp.mount can remount mid-boot, racing with
  # (and silently discarding) anything docker-cp'd there. /root isn't tmpfs; use it instead.
  docker cp "$DIR/setup-edge-cni.sh" "$CTR:/root/setup-edge-cni.sh"
  docker exec -e ARCH="$ARCH" -e POD_SUBNET="$POD_SUBNET" "$CTR" bash /root/setup-edge-cni.sh

  if [[ -n "$REGISTRY" ]]; then
    docker cp "$DIR/setup-edge-registry.sh" "$CTR:/root/setup-edge-registry.sh"
    docker exec "$CTR" bash /root/setup-edge-registry.sh "$REGISTRY"
  fi

  if ! docker exec "$CTR" bash -c 'command -v keadm >/dev/null'; then
    echo ">> Installing keadm $KUBEEDGE_VERSION ($ARCH) in container"
    docker exec "$CTR" bash -c "
      curl -sLo /root/k.tgz https://github.com/kubeedge/kubeedge/releases/download/${KUBEEDGE_VERSION}/keadm-${KUBEEDGE_VERSION}-linux-${ARCH}.tar.gz
      tar xzf /root/k.tgz -C /root && cp \"\$(find /root -name keadm -type f | head -1)\" /usr/local/bin/keadm && chmod +x /usr/local/bin/keadm"
  fi

  echo ">> keadm join -> cloudcore $CLOUDCORE_IP:$CLOUDHUB_PORT as node '$NODE'"
  docker exec "$CTR" keadm join \
    --cloudcore-ipport="$CLOUDCORE_IP:$CLOUDHUB_PORT" \
    --token="$TOKEN" \
    --edgenode-name="$NODE" \
    --kubeedge-version="$KUBEEDGE_VERSION" \
    --remote-runtime-endpoint="$RUNTIME_ENDPOINT" \
    --cgroupdriver=systemd \
    --set modules.edgeStream.enable=true \
    --set modules.metaServer.enable=true
  docker exec "$CTR" bash -c 'systemctl enable --now edgecore 2>/dev/null; systemctl is-active edgecore'

  echo ""
  echo ">> Joined (container '$CTR'). On the CLOUD host, confirm and onboard:"
  echo "     kubectl --context kind-isac get nodes -o wide     # '$NODE' should be Ready"
  echo "     make onboard-edge CONTEXT=kind-isac EDGE_NODE_NAME=$NODE"
  echo "   Status:  docker exec $CTR systemctl status edgecore"
  echo "   Logs:    docker exec $CTR journalctl -u edgecore -f"
  echo "   Remove:  docker rm -f $CTR"
}

if [[ "$OS" == Darwin ]]; then
  join_macos
  exit 0
fi

[[ "$OS" == Linux ]] || { echo "ERROR: unsupported OS '$OS' (supported: Linux, macOS)." >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

# --- already joined? don't fight a live edgecore; report and stop. ---
if systemctl is-active --quiet edgecore 2>/dev/null; then
  echo ">> edgecore is already running on this device. Skipping join."
  echo "   To rejoin fresh: sudo keadm reset && sudo $0 $CLOUDCORE_IP $NODE <token> $REGISTRY"
  exit 0
fi

# --- preflight: report what's present/missing before touching anything ---
echo ">> Preflight checks"
ok=1
check "OS: Linux" 1
[[ "$ARCH" == amd64 || "$ARCH" == arm64 ]] && check "arch: $ARCH supported" 1 || check "arch: $ARCH supported" 0
command -v curl >/dev/null 2>&1 && check "curl" 1 || check "curl (required)" 0
command -v tar >/dev/null 2>&1 && check "tar" 1 || check "tar (required)" 0
command -v systemctl >/dev/null 2>&1 && check "systemctl" 1 || check "systemctl (required)" 0
command -v containerd >/dev/null 2>&1 && check "containerd (will use existing)" 1 || check "containerd (will auto-install)" 1
command -v keadm >/dev/null 2>&1 && check "keadm (will use existing)" 1 || check "keadm (will auto-install)" 1
[[ "$ok" == 1 ]] || { echo "ERROR: missing required tool(s) above and no way to auto-install. Fix and re-run." >&2; exit 1; }

reachability_check

# --- containerd (edgecore's CRI runtime): install if missing, best-effort per distro ---
if ! command -v containerd >/dev/null; then
  echo ">> Installing containerd"
  if   command -v pacman >/dev/null; then pacman -Sy --noconfirm containerd
  elif command -v apt-get >/dev/null; then apt-get update && apt-get install -y containerd
  elif command -v dnf    >/dev/null; then dnf install -y containerd
  elif command -v zypper >/dev/null; then zypper install -y containerd
  else echo "ERROR: no known package manager; install containerd manually." >&2; exit 1
  fi
fi
systemctl enable --now containerd
systemctl is-active --quiet containerd || { echo "ERROR: containerd failed to start." >&2; exit 1; }

# --- keadm ---
if ! command -v keadm >/dev/null; then
  echo ">> Installing keadm $KUBEEDGE_VERSION ($ARCH)"
  tmp=$(mktemp -d)
  curl -sLo "$tmp/keadm.tgz" "https://github.com/kubeedge/kubeedge/releases/download/${KUBEEDGE_VERSION}/keadm-${KUBEEDGE_VERSION}-linux-${ARCH}.tar.gz"
  tar xzf "$tmp/keadm.tgz" -C "$tmp"
  cp "$(find "$tmp" -name keadm -type f | head -1)" /usr/local/bin/keadm
  chmod +x /usr/local/bin/keadm
fi

# --- containerd: mark the registry insecure (edge pulls images over plain HTTP on the LAN) ---
if [[ -n "$REGISTRY" ]]; then
  "$DIR/setup-edge-registry.sh" "$REGISTRY"
fi

# CNI must exist before edgecore starts, or edged reports the node NotReady.
echo ">> Setting up edge CNI (so the node reports Ready)"
ARCH="$ARCH" "$DIR/setup-edge-cni.sh"

echo ">> keadm join -> cloudcore $CLOUDCORE_IP:$CLOUDHUB_PORT as node '$NODE'"
# edgeStream pairs with cloudStream for `kubectl logs`/`exec` from the cloud.
# metaServer pairs with EdgeMesh (see edgemesh-install.sh) for cross-node service discovery.
keadm join \
  --cloudcore-ipport="$CLOUDCORE_IP:$CLOUDHUB_PORT" \
  --token="$TOKEN" \
  --edgenode-name="$NODE" \
  --kubeedge-version="$KUBEEDGE_VERSION" \
  --remote-runtime-endpoint="$RUNTIME_ENDPOINT" \
  --cgroupdriver=systemd \
  --set modules.edgeStream.enable=true \
  --set modules.metaServer.enable=true

echo ""
echo ">> Joined. On the CLOUD host, confirm and onboard:"
echo "     kubectl --context kind-isac get nodes -o wide     # '$NODE' should be Ready"
echo "     make onboard-edge CONTEXT=kind-isac EDGE_NODE_NAME=$NODE"
