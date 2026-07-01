#!/usr/bin/env bash
# Onboard an edge node into the ISAC fleet.
#
# Prereq (done once, outside this script — see README "Join an edge node"):
#   the device has already joined the k3s cluster as an agent, e.g.
#     k3s agent --server https://<server-ip>:6443 --token <token> \
#       --node-name <NODE> --node-label kubernetes.io/arch=<arch>
#   and shows up in `kubectl get nodes` as Ready.
#
# This script does the ISAC-specific onboarding: label the node so the edge
# DaemonSets (simulator, ingestion, preprocessing, inference) schedule onto it,
# then wait for that node's whole hot-path to come up and start reporting to the
# central collector. No per-service manifests to apply per node — the DaemonSets
# already exist cluster-wide; the label is the single switch that turns a node on.
set -euo pipefail

NODE="${1:-${EDGE_NODE_NAME:-}}"
CONTEXT="${CONTEXT:-k3s-isac}"
NS="${NS:-isac-sensing}"
TIMEOUT="${TIMEOUT:-180s}"
EDGE_DS="simulator ingestion preprocessing inference"

if [[ -z "$NODE" ]]; then
  echo "usage: $0 <node-name>   (or EDGE_NODE_NAME=<node> $0)" >&2
  exit 2
fi

kc() { kubectl --context "$CONTEXT" "$@"; }

echo ">> Onboarding edge node '$NODE' (context=$CONTEXT)"

if ! kc get node "$NODE" >/dev/null 2>&1; then
  echo "ERROR: node '$NODE' not found. Join it as a k3s agent first (see README)." >&2
  exit 1
fi

echo ">> Node found. Current status:"
kc get node "$NODE" -o wide --no-headers

echo ">> Labeling node isac-edge=true (this triggers the edge DaemonSets to schedule)"
kc label node "$NODE" isac-edge=true --overwrite

echo ">> Waiting for edge pods to be Ready on '$NODE' (timeout=$TIMEOUT)"
for app in $EDGE_DS; do
  # rollout status on a DaemonSet waits for its desired pods (incl. the new node's) to be ready
  if kc -n "$NS" rollout status daemonset/"$app" --timeout="$TIMEOUT"; then
    echo "   [ok] $app"
  else
    echo "   [warn] $app not ready within $TIMEOUT — check: kubectl -n $NS get pods -o wide | grep $NODE" >&2
  fi
done

echo ">> Edge pods on '$NODE':"
kc -n "$NS" get pods -o wide --field-selector spec.nodeName="$NODE"

NODEPORT="$(kc -n "$NS" get svc dashboard -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo 30080)"
SERVER_IP="$(kc get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
echo ""
echo ">> Done. '$NODE' is now an ISAC edge node generating data into the fleet."
echo "   Dashboard (edge-node count + logs): http://<any-node-ip>:${NODEPORT}/"
echo "   Or: kubectl --context $CONTEXT -n $NS port-forward svc/dashboard 8080:8080  ->  http://localhost:8080/"
echo "   It should appear as an online node within ~${TIMEOUT%s}s once inference starts sending results."
