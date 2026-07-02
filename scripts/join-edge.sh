#!/usr/bin/env bash
# Join THIS device to the KubeEdge cluster as an edge node (edgecore).
# Run ON the edge device (root). Replaces the old `k3s agent ...` join.
#
#   sudo ./scripts/join-edge.sh <cloudcore-ip> <node-name> <token> [registry]
#
# Prereqs on the edge device: containerd installed, keadm installed
# (https://kubeedge.io/docs/setup/install-with-keadm), and the device on the same LAN as
# the cloud host. Get <token> from `make keadm-token` on the cloud host.
set -euo pipefail

CLOUDCORE_IP="${1:-}"
NODE="${2:-}"
TOKEN="${3:-}"
REGISTRY="${4:-}"
CLOUDHUB_PORT="${CLOUDHUB_PORT:-10000}"

if [[ -z "$CLOUDCORE_IP" || -z "$NODE" || -z "$TOKEN" ]]; then
  echo "usage: sudo $0 <cloudcore-ip> <node-name> <token> [registry]" >&2
  exit 2
fi
command -v keadm >/dev/null || { echo "ERROR: keadm not installed on this device." >&2; exit 1; }

# Mark the registry insecure for containerd (edge pulls images over plain HTTP on the LAN).
# k3s used /etc/rancher/k3s/registries.yaml; edgecore uses containerd's own config.
if [[ -n "$REGISTRY" ]]; then
  echo ">> Configuring containerd insecure registry: $REGISTRY"
  CONF=/etc/containerd/config.toml
  if ! grep -q "$REGISTRY" "$CONF" 2>/dev/null; then
    cat >>"$CONF" <<EOF

[plugins."io.containerd.grpc.v1.cri".registry.mirrors."$REGISTRY"]
  endpoint = ["http://$REGISTRY"]
EOF
    systemctl restart containerd
  fi
fi

echo ">> keadm join -> cloudcore $CLOUDCORE_IP:$CLOUDHUB_PORT as node '$NODE'"
# edgeStream pairs with cloudStream for kubectl logs/exec; metaServer is required by EdgeMesh.
keadm join \
  --cloudcore-ipport="$CLOUDCORE_IP:$CLOUDHUB_PORT" \
  --token="$TOKEN" \
  --edgenode-name="$NODE" \
  --set modules.edgeStream.enable=true \
  --set modules.metaManager.metaServer.enable=true

echo ""
echo ">> Joined. On the CLOUD host, confirm and onboard:"
echo "     kubectl get nodes -o wide            # '$NODE' should be Ready"
echo "     make onboard-edge EDGE_NODE_NAME=$NODE"
