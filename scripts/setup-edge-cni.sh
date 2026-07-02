#!/usr/bin/env bash
# Install a minimal CNI on a KubeEdge edge node so edged reports the node Ready.
#
# edgecore's edged gates node-Ready on a CNI being initialized, even though the ISAC
# hot-path pods are all hostNetwork (they never request a pod IP). This drops the official
# containernetworking `bridge` plugin + a trivial conflist to satisfy that check. The
# bridge stays idle in practice. Distro-independent (downloads the CNI release tarball).
#
# Run ON the edge device as root. Safe to re-run (idempotent).
set -euo pipefail

CNI_VERSION="${CNI_VERSION:-v1.6.2}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
# Per-node pod subnet for the (idle) bridge — keep distinct from the cloud's 10.244.0.0/24.
POD_SUBNET="${POD_SUBNET:-10.244.1.0/24}"

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

echo ">> Installing CNI plugins $CNI_VERSION ($ARCH) -> /opt/cni/bin"
mkdir -p /opt/cni/bin
if [[ ! -x /opt/cni/bin/bridge ]]; then
  tmp=$(mktemp -d)
  curl -sSLo "$tmp/cni.tgz" \
    "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"
  tar xzf "$tmp/cni.tgz" -C /opt/cni/bin
  rm -rf "$tmp"
else
  echo "   /opt/cni/bin/bridge already present, skipping download"
fi

echo ">> Writing /etc/cni/net.d/10-edgecni.conflist (subnet $POD_SUBNET)"
mkdir -p /etc/cni/net.d
cat >/etc/cni/net.d/10-edgecni.conflist <<EOF
{
  "cniVersion": "1.0.0",
  "name": "edgecni",
  "plugins": [
    { "type": "bridge", "bridge": "cni0", "isGateway": true, "ipMasq": true,
      "ipam": { "type": "host-local", "subnet": "$POD_SUBNET",
                "routes": [{ "dst": "0.0.0.0/0" }] } },
    { "type": "portmap", "capabilities": { "portMappings": true } },
    { "type": "loopback" }
  ]
}
EOF

if systemctl list-units --type=service 2>/dev/null | grep -q edgecore; then
  echo ">> Restarting edgecore to pick up the CNI"
  systemctl restart edgecore
  echo "   done — node should flip to Ready within ~30s"
else
  echo ">> edgecore service not found yet (fine if running during join)"
fi
