#!/usr/bin/env bash
# Bring up a CO-LOCATED test edge node on THIS host as a privileged container, join it to
# the kind cloud via KubeEdge, and onboard it (label + schedule the pipeline).
#
# This is for validating the pipeline on one box without a separate device. It uses the
# `kindest/node` image (ships systemd + containerd) as a stand-in Linux "edge host".
# For a REAL remote edge, use scripts/join-edge.sh on that device instead.
#
#   ADVERTISE_IP=<cloudcore ip>  ./scripts/edge-container.sh [node-name]
#
# Sudo-free (uses your Docker). Auto-fetches a join token from the local cloud.
set -euo pipefail

NODE_NAME="${1:-edge-hetzner}"
CLUSTER_NAME="${CLUSTER_NAME:-isac}"
CONTEXT="kind-${CLUSTER_NAME}"
CLOUD_NODE="${CLUSTER_NAME}-control-plane"
ADVERTISE_IP="${ADVERTISE_IP:-}"           # cloudcore address the edge dials (e.g. Tailscale IP)
KUBEEDGE_VERSION="${KUBEEDGE_VERSION:-v1.23.0}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.32.5@sha256:e3b2327e3a5ab8c76f5ece68936e4cafaa82edf58486b769727ab0b3b97a5b0d}"
POD_SUBNET="${POD_SUBNET:-10.244.2.0/24}"
# Co-located optimization: point the fan-in at the kind node's internal IP (skips the
# Tailscale-loopback + docker-proxy detour a NodePort-on-host would add). ON by default for
# this test edge; a real remote edge would use the Tailscale IP + NodePort instead.
COLOCATED_FAST="${COLOCATED_FAST:-1}"
BINDIR="${BINDIR:-$HOME/.local/bin}"; export PATH="$BINDIR:$PATH"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[[ -n "$ADVERTISE_IP" ]] || { echo "ERROR: set ADVERTISE_IP=<cloudcore ip the edge dials>." >&2; exit 2; }
command -v docker >/dev/null || { echo "ERROR: docker required." >&2; exit 1; }
command -v keadm  >/dev/null || { echo "ERROR: keadm required (run cloud-init.sh first)." >&2; exit 1; }
CTR="isac-edge-${NODE_NAME}"

TOKEN="${TOKEN:-$(keadm gettoken --kube-config "$HOME/.kube/config" 2>/dev/null)}"
[[ -n "$TOKEN" ]] || { echo "ERROR: could not get a join token (is the cloud up?)." >&2; exit 1; }

echo ">> Launching edge host container '$CTR' (systemd + containerd, /var on a real volume)"
docker rm -f "$CTR" >/dev/null 2>&1 || true
docker run -d --privileged --name "$CTR" --hostname "$NODE_NAME" \
  --network kind \
  -v /lib/modules:/lib/modules:ro \
  --tmpfs /run --tmpfs /tmp -v /var \
  "$NODE_IMAGE" >/dev/null
# wait for containerd inside
for i in $(seq 1 30); do
  docker exec "$CTR" bash -c 'systemctl is-active containerd' 2>/dev/null | grep -qx active && break; sleep 1
done

echo ">> Preparing edge host (sudo shim, disable kubelet, CNI, keadm)"
docker exec "$CTR" bash -c '
  # keadm join calls `sudo systemctl ...`; there is no sudo in the container (already root).
  printf "#!/bin/sh\nexec \"\$@\"\n" > /usr/bin/sudo && chmod +x /usr/bin/sudo
  systemctl disable --now kubelet 2>/dev/null || true   # kindest/node kubelet unused; edgecore is the agent
  mkdir -p /etc/cni/net.d
  # kindest/node ships ptp (no bridge); ptp satisfies edged readiness. Hot-path pods are hostNetwork.
  cat > /etc/cni/net.d/10-edgecni.conflist <<EOF
{ "cniVersion":"1.0.0","name":"edgecni","plugins":[
  {"type":"ptp","ipMasq":true,"ipam":{"type":"host-local","subnet":"'"$POD_SUBNET"'","routes":[{"dst":"0.0.0.0/0"}]}},
  {"type":"portmap","capabilities":{"portMappings":true}},
  {"type":"loopback"} ] }
EOF
  if ! command -v keadm >/dev/null; then
    curl -sLo /tmp/k.tgz https://github.com/kubeedge/kubeedge/releases/download/'"$KUBEEDGE_VERSION"'/keadm-'"$KUBEEDGE_VERSION"'-linux-amd64.tar.gz
    tar xzf /tmp/k.tgz -C /tmp && cp "$(find /tmp -name keadm -type f|head -1)" /usr/local/bin/keadm && chmod +x /usr/local/bin/keadm
  fi'

echo ">> keadm join -> $ADVERTISE_IP:10000 as '$NODE_NAME'"
docker exec "$CTR" keadm join \
  --cloudcore-ipport="$ADVERTISE_IP:10000" \
  --token="$TOKEN" \
  --edgenode-name="$NODE_NAME" \
  --kubeedge-version="$KUBEEDGE_VERSION" \
  --remote-runtime-endpoint=unix:///run/containerd/containerd.sock \
  --cgroupdriver=systemd \
  --set modules.edgeStream.enable=true
# keadm starts edgecore via the sudo shim; ensure it's up
docker exec "$CTR" bash -c 'systemctl enable --now edgecore 2>/dev/null; systemctl is-active edgecore'

echo ">> Waiting for node '$NODE_NAME' to register Ready"
for i in $(seq 1 30); do
  kubectl --context "$CONTEXT" get node "$NODE_NAME" 2>/dev/null | grep -q ' Ready ' && break; sleep 2
done
kubectl --context "$CONTEXT" get node "$NODE_NAME" -o wide

# If this node name was used before, KubeEdge leaves its old DaemonSet pods in etcd (not GC'd
# on node delete). They block the fresh edgecore from getting pods it actually runs — clear them.
kubectl --context "$CONTEXT" -n isac-sensing delete pod \
  --field-selector spec.nodeName="$NODE_NAME" --force --grace-period=0 2>/dev/null || true

if [[ "$COLOCATED_FAST" == "1" ]]; then
  CLOUD_IP=$(kubectl --context "$CONTEXT" get node "$CLOUD_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  echo ">> Co-located fast path: fan-in -> ${CLOUD_IP}:30054 (kind node internal, no Tailscale/docker-proxy)"
  kubectl --context "$CONTEXT" -n isac-sensing set env daemonset/inference OUTPUT_SERVICE="${CLOUD_IP}:30054" >/dev/null
  kubectl --context "$CONTEXT" -n isac-sensing set env daemonset/simulator CLOCK_SYNC_TARGET="${CLOUD_IP}:30054" >/dev/null
fi

echo ">> Onboarding (label isac-edge=true + wait for the hot-path)"
CONTEXT="$CONTEXT" EDGE_NODE_NAME="$NODE_NAME" "$REPO_ROOT/scripts/onboard-edge.sh" "$NODE_NAME" || true

echo ""
echo ">> Done. '$NODE_NAME' is a co-located edge in the fleet."
echo "   Dashboard: make port-forward-dashboard CONTEXT=$CONTEXT  ->  http://localhost:8080/"
echo "   Remove:    docker rm -f $CTR ; kubectl --context $CONTEXT delete node $NODE_NAME"
