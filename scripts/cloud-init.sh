#!/usr/bin/env bash
# Stand up the KubeEdge CLOUD control plane on this host.
#
# Assumes a kubeadm single-node cluster is ALREADY running here and reachable via
# `kubectl --context $CONTEXT` (the control-plane node untainted so it also runs
# output/prometheus/grafana). This script installs cloudcore on top and wires the two
# KubeEdge features the ISAC design depends on:
#   - cloudStream   -> `kubectl logs`/`exec` against edge pods (paired with edgeStream on edge)
#   - dynamicController -> lets EdgeMesh serve k8s metadata to edge nodes
# then patches the kubeadm kube-proxy DaemonSet off edge nodes (it can't run there).
#
# Root, cloud host only. Set CLOUDCORE_IP to the LAN/public IP edge devices will dial.
set -euo pipefail

CONTEXT="${CONTEXT:-kubeadm-isac}"
CLOUDCORE_IP="${CLOUDCORE_IP:-}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/kubernetes/admin.conf}"

if [[ -z "$CLOUDCORE_IP" ]]; then
  echo "ERROR: set CLOUDCORE_IP=<cloud host LAN/public IP that edges will dial>" >&2
  exit 2
fi
command -v keadm >/dev/null || { echo "ERROR: keadm not installed. See https://kubeedge.io/docs/setup/install-with-keadm" >&2; exit 1; }

echo ">> Verifying kubeadm cluster is reachable (context=$CONTEXT)"
kubectl --context "$CONTEXT" get nodes >/dev/null

echo ">> keadm init: installing cloudcore, advertising $CLOUDCORE_IP"
# cloudStream + dynamicController are off by default — enable both. --advertise-address is
# the address baked into the token/cert that edges connect back to.
keadm init \
  --advertise-address="$CLOUDCORE_IP" \
  --kube-config="$KUBECONFIG_PATH" \
  --set cloudCore.modules.cloudStream.enable=true \
  --set cloudCore.modules.dynamicController.enable=true

echo ">> Patching kube-proxy DaemonSet to NOT schedule on edge nodes"
# edgecore has no kube-proxy; the kubeadm one would crash-loop on edge nodes otherwise.
kubectl --context "$CONTEXT" -n kube-system patch daemonset kube-proxy --type=strategic -p \
  '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/edge","operator":"DoesNotExist"}]}]}}}}}}}' || true

echo ""
echo ">> Cloud control plane ready."
echo "   Next:"
echo "     make edgemesh CONTEXT=$CONTEXT          # install the EdgeMesh agent"
echo "     make keadm-token                        # print a join token for edge devices"
echo "     (on each edge) sudo ./scripts/join-edge.sh $CLOUDCORE_IP <node> <token> <registry>"
