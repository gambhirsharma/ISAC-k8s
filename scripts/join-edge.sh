#!/usr/bin/env bash
# Join THIS device to the KubeEdge cluster as an edge node (edgecore).
# Run ON the edge device as root. Replaces the old `k3s agent ...` join.
#
#   sudo ./scripts/join-edge.sh <cloudcore-ip> <node-name> <token> [registry]
#
# Self-contained: installs keadm if missing, points containerd at the (insecure) image
# registry, then `keadm join`. Prereqs: Linux amd64/arm64, containerd installed + running,
# and the device able to reach <cloudcore-ip> (e.g. on the same Tailscale tailnet).
# Get <token> from `keadm gettoken` on the cloud host.
set -euo pipefail

CLOUDCORE_IP="${1:-}"
NODE="${2:-}"
TOKEN="${3:-}"
REGISTRY="${4:-}"
CLOUDHUB_PORT="${CLOUDHUB_PORT:-10000}"
KUBEEDGE_VERSION="${KUBEEDGE_VERSION:-v1.23.0}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
RUNTIME_ENDPOINT="${RUNTIME_ENDPOINT:-unix:///run/containerd/containerd.sock}"

if [[ -z "$CLOUDCORE_IP" || -z "$NODE" || -z "$TOKEN" ]]; then
  echo "usage: sudo $0 <cloudcore-ip> <node-name> <token> [registry]" >&2
  exit 2
fi
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
systemctl is-active --quiet containerd || { echo "ERROR: containerd not running. Install + start it first." >&2; exit 1; }

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
  echo ">> Configuring containerd insecure registry: $REGISTRY"
  CONF=/etc/containerd/config.toml
  mkdir -p /etc/containerd
  if [[ ! -f "$CONF" ]]; then
    containerd config default >"$CONF"
    # Match edgecore's --cgroupdriver=systemd (containerd default is cgroupfs).
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONF"
  fi
  # containerd reads per-registry config from certs.d when config_path is set.
  if ! grep -q 'certs.d' "$CONF"; then
    cat >>"$CONF" <<EOF

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
EOF
  fi
  mkdir -p "/etc/containerd/certs.d/$REGISTRY"
  cat >"/etc/containerd/certs.d/$REGISTRY/hosts.toml" <<EOF
server = "http://$REGISTRY"
[host."http://$REGISTRY"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
  systemctl restart containerd
fi

echo ">> keadm join -> cloudcore $CLOUDCORE_IP:$CLOUDHUB_PORT as node '$NODE'"
# edgeStream pairs with cloudStream for `kubectl logs`/`exec` from the cloud.
keadm join \
  --cloudcore-ipport="$CLOUDCORE_IP:$CLOUDHUB_PORT" \
  --token="$TOKEN" \
  --edgenode-name="$NODE" \
  --kubeedge-version="$KUBEEDGE_VERSION" \
  --remote-runtime-endpoint="$RUNTIME_ENDPOINT" \
  --cgroupdriver=systemd \
  --set modules.edgeStream.enable=true

echo ""
echo ">> Joined. On the CLOUD host, confirm and onboard:"
echo "     kubectl --context kind-isac get nodes -o wide     # '$NODE' should be Ready"
echo "     make onboard-edge CONTEXT=kind-isac EDGE_NODE_NAME=$NODE"
