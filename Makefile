.PHONY: all codegen cloud-init edge-container edgemesh keadm-token join-edge label-edge onboard-edge offboard-edge \
	namespace build-images deploy validate smoke-test clean \
	logs-simulator logs-ingestion logs-preprocessing logs-inference logs-output logs-prometheus logs-grafana \
	port-forward-prometheus port-forward-grafana port-forward-dashboard dashboard-url

# --- cluster config (override on the command line, e.g. `make deploy REGISTRY=192.168.1.50:5000`) ---
# CONTEXT      kubectl context of the CLOUD cluster running cloudcore (kind: kind-isac).
# EDGE_NODE_NAME  the edgecore node name (see scripts/join-edge.sh).
# REGISTRY     image namespace/registry. Default is a public Docker Hub namespace: images are
#              public, so edge devices pull them over TLS with NO insecure-registry config.
#              For a private/LAN registry instead, override (e.g. REGISTRY=100.64.5.120:5000)
#              and run scripts/setup-edge-registry.sh on each edge device.
# CLOUDCORE_IP the address edge nodes dial for CloudHub (e.g. the Tailscale IP 100.64.5.120).
CONTEXT ?= kind-isac
EDGE_NODE_NAME ?= laptop-edge
REGISTRY ?= gambhir
CLOUDCORE_IP ?=

# The kubeadm cloud cluster, cloudcore, and each edgecore join are one-time host-level
# steps (need root, run on specific hosts). `cloud-init` / `join-edge` wrap them; they are
# NOT part of `all`, which only (re)deploys the app onto an already-running KubeEdge cluster.
all: namespace build-images deploy

# 1. Generate protobuf code
codegen:
	cd services && ./codegen.sh

# 2. Stand up the KubeEdge cloud control plane as an isolated kind cluster running cloudcore
# (cloudStream + dynamicController), and patch kube-proxy + kindnet off edge nodes. Sudo-free,
# no host changes. Set CLOUDCORE_IP to the address edges dial (e.g. your Tailscale IP).
cloud-init:
	ADVERTISE_IP=$(CLOUDCORE_IP) ./scripts/cloud-init.sh

# Bring up a CO-LOCATED test edge on THIS host (privileged kindest/node container) + onboard
# it. For validating the pipeline on one box. Real remote device -> use join-edge.sh instead.
edge-container:
	ADVERTISE_IP=$(CLOUDCORE_IP) ./scripts/edge-container.sh $(EDGE_NODE_NAME)

# 3. Install EdgeMesh (per-node agent) so the edge hot-path can resolve the cross-node
# `output` service. The node-local hops use localhost and do NOT depend on this.
edgemesh:
	CONTEXT=$(CONTEXT) ./scripts/edgemesh-install.sh

# Print a join token for edge nodes (kind cloud kubeconfig).
keadm-token:
	keadm gettoken --kube-config $$HOME/.kube/config

# 4. Join an edge device (run ON the edge device, not here — this just prints the command).
join-edge:
	@echo "Run this ON the edge device:"
	@echo "  sudo ./scripts/join-edge.sh $(CLOUDCORE_IP) $(EDGE_NODE_NAME) <token> $(REGISTRY)   # Linux (needs root + keadm)"
	@echo "  ./scripts/join-edge.sh $(CLOUDCORE_IP) $(EDGE_NODE_NAME) <token> $(REGISTRY)        # macOS (needs Docker Desktop)"

# 5. Label an edge node so the edge DaemonSets schedule onto it. `onboard-edge` is the
# fuller flow (label + wait for the whole hot-path to come up).
label-edge:
	kubectl --context $(CONTEXT) label node $(EDGE_NODE_NAME) isac-edge=true --overwrite

onboard-edge:
	CONTEXT=$(CONTEXT) EDGE_NODE_NAME=$(EDGE_NODE_NAME) ./scripts/onboard-edge.sh $(EDGE_NODE_NAME)

offboard-edge:
	kubectl --context $(CONTEXT) label node $(EDGE_NODE_NAME) isac-edge- || true
	@echo "Node $(EDGE_NODE_NAME) unlabeled; edge pods will be removed from it."

# 6. Create namespaces
namespace:
	kubectl --context $(CONTEXT) apply -f cluster/manifests/01-namespace.yaml

# 7. Multi-arch build + push. Every node pulls from a registry reachable over the LAN.
build-images: codegen
	@echo "Building + pushing multi-arch images to $(REGISTRY)..."
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-simulator:latest -f simulator/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-ingestion:latest -f ingestion/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-preprocessing:latest -f preprocessing/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-inference:latest -f inference/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-output:latest -f output/Dockerfile --push .

# 8. Deploy all manifests, then point them at $(REGISTRY). No 07-network-policies (Cilium
# is gone under KubeEdge). Edge DaemonSets stay 0 pods until a node is labeled isac-edge=true.
deploy:
	kubectl --context $(CONTEXT) apply -f cluster/manifests/02-simulator.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/03-ingestion.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/04-preprocessing.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/05-inference.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/06-output.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/08-monitoring-rbac.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/09-prometheus.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/10-grafana.yaml
	kubectl --context $(CONTEXT) set image daemonset/simulator simulator=$(REGISTRY)/isac-simulator:latest -n isac-sensing
	kubectl --context $(CONTEXT) set image daemonset/ingestion ingestion=$(REGISTRY)/isac-ingestion:latest -n isac-sensing
	kubectl --context $(CONTEXT) set image daemonset/preprocessing preprocessing=$(REGISTRY)/isac-preprocessing:latest -n isac-sensing
	kubectl --context $(CONTEXT) set image daemonset/inference inference=$(REGISTRY)/isac-inference:latest -n isac-sensing
	kubectl --context $(CONTEXT) set image deployment/output output=$(REGISTRY)/isac-output:latest -n isac-sensing
	@echo "--- Waiting for cloud-side pods (edge pods need a labeled node first) ---"
	kubectl --context $(CONTEXT) wait --for=condition=ready pod -l app=output -n isac-sensing --timeout=120s || true
	kubectl --context $(CONTEXT) wait --for=condition=ready pod -l app=prometheus -n isac-monitoring --timeout=120s || true
	kubectl --context $(CONTEXT) wait --for=condition=ready pod -l app=grafana -n isac-monitoring --timeout=120s || true
	kubectl --context $(CONTEXT) get pods -n isac-sensing -o wide
	kubectl --context $(CONTEXT) get pods -n isac-monitoring -o wide

# 9. Check placement + node roles.
validate:
	@echo "=== Pod placement ==="
	kubectl --context $(CONTEXT) get pods -n isac-sensing -o wide
	@echo ""
	@echo "=== output fan-in Service (NodePort 30054) + dashboard ==="
	kubectl --context $(CONTEXT) get svc -n isac-sensing
	@echo ""
	@echo "=== Monitoring ==="
	kubectl --context $(CONTEXT) get pods,svc -n isac-monitoring
	@echo ""
	@echo "=== Nodes, arch, edge label/role ==="
	kubectl --context $(CONTEXT) get nodes -o wide --show-labels | grep -E 'isac-edge|node-role.kubernetes.io/edge|ARCH' || true

# Throwaway pod on an edge node, before trusting it with real services.
smoke-test:
	kubectl --context $(CONTEXT) run edge-smoke --rm -it --restart=Never \
	  --image=busybox --overrides='{"spec":{"nodeSelector":{"isac-edge":"true"},"tolerations":[{"key":"node-role.kubernetes.io/edge","operator":"Exists","effect":"NoSchedule"}]}}' \
	  -- echo "edge node reachable"

# 10. Logs (edge pod logs require cloudStream/edgeStream enabled — see cloud-init.sh)
logs-simulator:
	kubectl --context $(CONTEXT) logs -n isac-sensing -l app=simulator --tail=50
logs-ingestion:
	kubectl --context $(CONTEXT) logs -n isac-sensing -l app=ingestion --tail=50
logs-preprocessing:
	kubectl --context $(CONTEXT) logs -n isac-sensing -l app=preprocessing --tail=50
logs-inference:
	kubectl --context $(CONTEXT) logs -n isac-sensing -l app=inference --tail=50
logs-output:
	kubectl --context $(CONTEXT) logs -n isac-sensing -l app=output --tail=50
logs-prometheus:
	kubectl --context $(CONTEXT) logs -n isac-monitoring -l app=prometheus --tail=50
logs-grafana:
	kubectl --context $(CONTEXT) logs -n isac-monitoring -l app=grafana --tail=50

# 11. UI access
port-forward-prometheus:
	kubectl --context $(CONTEXT) port-forward --address 0.0.0.0 -n isac-monitoring svc/prometheus 9090:9090
port-forward-grafana:
	kubectl --context $(CONTEXT) port-forward --address 0.0.0.0 -n isac-monitoring svc/grafana 3000:3000
port-forward-dashboard:
	@echo "Fleet dashboard -> http://localhost:8080/"
	kubectl --context $(CONTEXT) port-forward --address 0.0.0.0 -n isac-sensing svc/dashboard 8080:8080

dashboard-url:
	@echo "Fleet dashboard is ClusterIP (unauthenticated) — use: make port-forward-dashboard"
	@echo "output fan-in NodePort fallback: <cloud-ip>:$$(kubectl --context $(CONTEXT) -n isac-sensing get svc output -o jsonpath='{.spec.ports[0].nodePort}')"

# 12. Tear down the app (not the cluster/cloudcore — those are real infra; uninstall with
# `keadm reset` on the respective hosts if you actually want to tear KubeEdge down).
clean:
	kubectl --context $(CONTEXT) delete namespace isac-sensing --ignore-not-found
	kubectl --context $(CONTEXT) delete namespace isac-monitoring --ignore-not-found
	rm -f services/proto/isac_pb2.py services/proto/isac_pb2_grpc.py
