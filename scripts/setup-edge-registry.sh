#!/usr/bin/env bash
# Point this edge device's containerd at an insecure (plain-HTTP) image registry.
# Run ON the edge device as root. Safe to re-run.
#
#   sudo ./scripts/setup-edge-registry.sh <registry>     # e.g. 100.64.5.120:5000
#
# containerd reads per-registry config from /etc/containerd/certs.d when config_path is set,
# so this ensures config.toml has config_path and drops a hosts.toml marking the registry
# insecure. Restarts containerd. Fixes ImagePullBackOff pulling isac-* images on the edge.
set -euo pipefail

REGISTRY="${1:-}"
[[ -n "$REGISTRY" ]] || { echo "usage: sudo $0 <registry-host:port>" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

CONF=/etc/containerd/config.toml
mkdir -p /etc/containerd
if [[ ! -f "$CONF" ]]; then
  containerd config default >"$CONF"
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONF"   # match edgecore systemd cgroups
fi
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

echo ">> Restarting containerd (insecure registry: $REGISTRY)"
systemctl restart containerd
echo ">> Done. edgecore will retry the failed image pulls automatically."
