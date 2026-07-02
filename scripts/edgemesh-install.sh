#!/usr/bin/env bash
# Install EdgeMesh — the per-node agent that gives edge nodes service discovery + DNS and
# proxies the one cross-node hop this design has: the edge hot-path's `output:50054` fan-in
# (StoreResult + clock-sync Probe). The node-LOCAL hops (simulator->ingestion->preproc->
# inference) use localhost and do NOT depend on EdgeMesh.
#
# Prereqs (from cloud-init.sh): cloudcore installed with dynamicController enabled, and each
# edgecore joined with metaServer enabled (see join-edge.sh). Root/cloud host, run once.
#
# Docs: https://edgemesh.netlify.app/guide/  (this is the helm path; pin a chart version)
set -euo pipefail

CONTEXT="${CONTEXT:-kubeadm-isac}"
# PSK secures the EdgeMesh P2P tunnel — generate once and keep it stable across the fleet.
PSK="${EDGEMESH_PSK:-}"
# The API server address edgemesh-agent uses to reach k8s metadata (usually the cloud IP).
RELAY_NODES="${EDGEMESH_RELAY_NODES:-}"

if [[ -z "$PSK" ]]; then
  echo "ERROR: set EDGEMESH_PSK=<shared secret> (e.g. \`openssl rand -base64 32\`)." >&2
  exit 2
fi
command -v helm >/dev/null || { echo "ERROR: helm not installed." >&2; exit 1; }

echo ">> Labeling nodes for EdgeMesh (agent runs on cloud + every edge node)"
# EdgeMesh selects nodes by this label; apply to all nodes that should get an agent.
for n in $(kubectl --context "$CONTEXT" get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kubectl --context "$CONTEXT" label node "$n" edgemesh.io/edge-node=true --overwrite || true
done

echo ">> Installing edgemesh-agent via helm"
helm repo add edgemesh https://edgemesh.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install edgemesh edgemesh/edgemesh \
  --kube-context "$CONTEXT" \
  --namespace kubeedge \
  --create-namespace \
  --set agent.psk="$PSK" \
  ${RELAY_NODES:+--set agent.relayNodes="$RELAY_NODES"} \
  --wait --timeout 10m

echo ">> Verifying edgemesh-agent DaemonSet"
kubectl --context "$CONTEXT" -n kubeedge get pods -l app=edgemesh-agent -o wide

echo ""
echo ">> EdgeMesh installed. Edge pods (with dnsPolicy ClusterFirstWithHostNet) can now"
echo "   resolve 'output' cross-node. If resolution is flaky, fall back to the NodePort:"
echo "   set OUTPUT_SERVICE / CLOCK_SYNC_TARGET to <cloud-ip>:30054 on the edge DaemonSets."
