#!/usr/bin/env bash
# Stand up the ISAC CLOUD control plane as an isolated kind cluster running cloudcore.
#
# kind gives a real Kubernetes (apiserver/etcd/scheduler) inside Docker — no host changes,
# no kubeadm, no swap/containerd edits (so it coexists with anything else on the box).
# Edge devices join cloudcore over a websocket, so they never touch this cluster's network.
#
# Sudo-free: installs kind/kubectl/keadm into ~/.local/bin if missing and uses your Docker.
#
#   ADVERTISE_IP=<ip edges dial>  ./scripts/cloud-init.sh
#
# ADVERTISE_IP is baked into cloudcore's cert/token — the address edge devices connect back
# to (e.g. a Tailscale IP). cloudcore's ports are published ONLY on that IP (see the kind
# config), so nothing is exposed on a public interface.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-isac}"
CONTEXT="kind-${CLUSTER_NAME}"
ADVERTISE_IP="${ADVERTISE_IP:-}"
KUBEEDGE_VERSION="${KUBEEDGE_VERSION:-v1.23.0}"
KIND_VERSION="${KIND_VERSION:-v0.32.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.32.13}"
# KubeEdge 1.23 supports k8s <=1.32; this kind node image is k8s v1.32.5.
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.32.5@sha256:e3b2327e3a5ab8c76f5ece68936e4cafaa82edf58486b769727ab0b3b97a5b0d}"
# Optional insecure image registry to trust inside kind (host:port). Leave empty when using
# public images (e.g. Docker Hub) — then kind pulls over TLS with no extra config.
REGISTRY="${REGISTRY:-}"
BINDIR="${BINDIR:-$HOME/.local/bin}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[[ -n "$ADVERTISE_IP" ]] || { echo "ERROR: set ADVERTISE_IP=<ip edges will dial> (e.g. your Tailscale IP)." >&2; exit 2; }
command -v docker >/dev/null || { echo "ERROR: docker required." >&2; exit 1; }

mkdir -p "$BINDIR"; export PATH="$BINDIR:$PATH"
need() { command -v "$1" >/dev/null; }

if ! need kubectl; then
  echo ">> Installing kubectl $KUBECTL_VERSION -> $BINDIR"
  curl -sLo "$BINDIR/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; chmod +x "$BINDIR/kubectl"
fi
if ! need kind; then
  echo ">> Installing kind $KIND_VERSION -> $BINDIR"
  curl -sLo "$BINDIR/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"; chmod +x "$BINDIR/kind"
fi
if ! need keadm; then
  echo ">> Installing keadm $KUBEEDGE_VERSION -> $BINDIR"
  tmp=$(mktemp -d); curl -sLo "$tmp/k.tgz" "https://github.com/kubeedge/kubeedge/releases/download/${KUBEEDGE_VERSION}/keadm-${KUBEEDGE_VERSION}-linux-amd64.tar.gz"
  tar xzf "$tmp/k.tgz" -C "$tmp"; cp "$(find "$tmp" -name keadm -type f | head -1)" "$BINDIR/keadm"; chmod +x "$BINDIR/keadm"; rm -rf "$tmp"
fi

# --- kind cluster ---
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo ">> kind cluster '$CLUSTER_NAME' already exists, reusing"
else
  echo ">> Creating kind cluster '$CLUSTER_NAME' (cloudcore ports published on $ADVERTISE_IP)"
  # Render the committed kind config with this ADVERTISE_IP (it templates the listenAddress).
  rendered=$(mktemp)
  sed "s/100\.64\.5\.120/${ADVERTISE_IP}/g" "$REPO_ROOT/cluster/kind-cloud-config.yaml" > "$rendered"
  kind create cluster --name "$CLUSTER_NAME" --image "$NODE_IMAGE" --config "$rendered" --wait 90s
  rm -f "$rendered"
fi

# --- optional: trust an insecure registry inside kind ---
if [[ -n "$REGISTRY" ]]; then
  echo ">> Configuring kind containerd for insecure registry $REGISTRY"
  node="${CLUSTER_NAME}-control-plane"
  docker exec "$node" bash -c "
    mkdir -p /etc/containerd/certs.d/$REGISTRY
    printf 'server = \"http://$REGISTRY\"\n[host.\"http://$REGISTRY\"]\n  capabilities = [\"pull\", \"resolve\"]\n  skip_verify = true\n' > /etc/containerd/certs.d/$REGISTRY/hosts.toml
    grep -q certs.d /etc/containerd/config.toml || printf '\n[plugins.\"io.containerd.grpc.v1.cri\".registry]\n  config_path = \"/etc/containerd/certs.d\"\n' >> /etc/containerd/config.toml
    systemctl restart containerd"
  kubectl --context "$CONTEXT" -n kubeedge rollout status deploy/cloudcore --timeout=120s 2>/dev/null || true
fi

# --- cloudcore ---
echo ">> keadm init: cloudcore $KUBEEDGE_VERSION advertising $ADVERTISE_IP"
keadm init \
  --advertise-address="$ADVERTISE_IP" \
  --kube-config="$HOME/.kube/config" \
  --kubeedge-version="$KUBEEDGE_VERSION" \
  --set cloudCore.modules.cloudStream.enable=true \
  --set cloudCore.modules.dynamicController.enable=true
kubectl --context "$CONTEXT" -n kubeedge rollout status deploy/cloudcore --timeout=180s

# --- fix kubectl logs/exec against edge pods ---
# edged always reports the node's DaemonEndpoints.KubeletEndpoint port as 10350, no matter what
# edged.tailoredKubeletConfig.readOnlyPort is set to (kubeedge/kubeedge#4952). Meanwhile cloudcore's
# iptables-manager self-assigns a *different*, incrementing tunnel port on every restart
# (10350 -> 10351 -> 10352..., kubeedge/kubeedge#4810) and DNATs *that* port to its stream server —
# so apiserver's direct dial to <node-ip>:10350 gets "connection refused" the moment cloudcore has
# restarted even once. cloudcore runs hostNetwork on this node, so its stream server is always
# reachable at 127.0.0.1:10003 here regardless of that drift; add a static redirect for the port
# edged actually reports, independent of whatever port iptables-manager thinks it owns.
echo ">> Fixing kubectl logs/exec tunnel (works around kubeedge/kubeedge#4952 + #4810)"
node="${CLUSTER_NAME}-control-plane"
docker exec "$node" sh -c '
  iptables-legacy -t nat -C OUTPUT -p tcp --dport 10350 -j DNAT --to-destination 127.0.0.1:10003 2>/dev/null ||
  iptables-legacy -t nat -I OUTPUT 1 -p tcp --dport 10350 -j DNAT --to-destination 127.0.0.1:10003
'

# --- keep kube-proxy + kindnet (kind's CNI) OFF edge nodes; they only run on kind's Docker nodes ---
echo ">> Patching kube-proxy + kindnet off edge nodes"
for ds in kube-proxy kindnet; do
  kubectl --context "$CONTEXT" -n kube-system patch daemonset "$ds" --type=strategic -p \
    '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/edge","operator":"DoesNotExist"}]}]}}}}}}}' 2>/dev/null || true
done

echo ""
echo ">> Cloud ready (context=$CONTEXT). Next:"
echo "     make keadm-token                                   # print an edge join token"
echo "     ./scripts/edge-container.sh <node-name>            # co-located test edge on THIS host"
echo "     (real device) sudo ./scripts/join-edge.sh $ADVERTISE_IP <node> <token>"
echo "     make deploy CONTEXT=$CONTEXT REGISTRY=<ns>         # deploy the pipeline"
