.PHONY: all codegen cilium label-edge namespace build-images deploy validate smoke-test clean \
	logs-simulator logs-ingestion logs-preprocessing logs-inference logs-output logs-prometheus logs-grafana \
	port-forward-prometheus port-forward-grafana

# --- cluster config (override on the command line, e.g. `make deploy REGISTRY=192.168.1.50:5000`) ---
# REGISTRY defaults to localhost:5000 which ONLY resolves on the box running the
# registry container — fine for single-node dev, but any additional node (edge or
# otherwise) needs this overridden to an address reachable from every node (we use
# the server's public IP, 88.99.249.172:5000, with insecure-registry trust configured
# in both /etc/docker/daemon.json and /etc/rancher/k3s/registries.yaml on the server).
CONTEXT ?= k3s-isac
EDGE_NODE_NAME ?= android-edge-01
REGISTRY ?= localhost:5000

# The k3s server + phone agent join are external, one-time steps (see README) —
# not scriptable here since they run on remote hosts this Makefile doesn't control.
all: cilium label-edge namespace build-images deploy

# 1. Generate protobuf code
codegen:
	cd services && ./codegen.sh

# 2. Install Cilium on the k3s cluster (skip this + 07-network-policies.yaml
# if you took the flannel fallback — see README)
cilium: codegen
	helm repo add cilium https://helm.cilium.io/
	helm upgrade --install cilium cilium/cilium \
	  --kube-context $(CONTEXT) \
	  --namespace kube-system \
	  --values cluster/cilium-values.yaml \
	  --wait \
	  --timeout 15m
	kubectl --context $(CONTEXT) wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s
	@echo "--- Verifying Cilium status ---"
	kubectl --context $(CONTEXT) -n kube-system exec ds/cilium -- cilium status --brief

# 3. Label the phone's k3s node (join it first with `k3s agent ... --node-name $(EDGE_NODE_NAME)`)
label-edge:
	kubectl --context $(CONTEXT) label node $(EDGE_NODE_NAME) isac-edge=true --overwrite

# 4. Create namespace
namespace:
	kubectl --context $(CONTEXT) apply -f cluster/manifests/01-namespace.yaml

# 5. Multi-arch build + push. k3s has no `kind load docker-image` equivalent —
# every node (server + phone) pulls from a registry reachable over the LAN.
build-images: codegen
	@echo "Building + pushing multi-arch images to $(REGISTRY)..."
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-simulator:latest -f simulator/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-ingestion:latest -f ingestion/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-preprocessing:latest -f preprocessing/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-inference:latest -f inference/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-output:latest -f output/Dockerfile --push .

# 6. Deploy all manifests, then point them at $(REGISTRY) — manifests themselves
# stay registry-agnostic (`isac-*:latest`), this is the one place REGISTRY is wired in.
deploy:
	kubectl --context $(CONTEXT) apply -f cluster/manifests/02-simulator.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/03-ingestion.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/04-preprocessing.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/05-inference.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/06-output.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/07-network-policies.yaml || true
	kubectl --context $(CONTEXT) apply -f cluster/manifests/08-monitoring-rbac.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/09-prometheus.yaml
	kubectl --context $(CONTEXT) apply -f cluster/manifests/10-grafana.yaml
	kubectl --context $(CONTEXT) set image deployment/simulator simulator=$(REGISTRY)/isac-simulator:latest -n isac-sensing
	kubectl --context $(CONTEXT) set image daemonset/ingestion ingestion=$(REGISTRY)/isac-ingestion:latest -n isac-sensing
	kubectl --context $(CONTEXT) set image deployment/preprocessing preprocessing=$(REGISTRY)/isac-preprocessing:latest -n isac-sensing
	kubectl --context $(CONTEXT) set image deployment/inference inference=$(REGISTRY)/isac-inference:latest -n isac-sensing
	kubectl --context $(CONTEXT) set image deployment/output output=$(REGISTRY)/isac-output:latest -n isac-sensing
	@echo "--- Waiting for all pods to be ready (phone node may be slow) ---"
	kubectl --context $(CONTEXT) wait --for=condition=ready pod -l app=simulator -n isac-sensing --timeout=180s || true
	kubectl --context $(CONTEXT) wait --for=condition=ready pod -l app=preprocessing -n isac-sensing --timeout=180s || true
	kubectl --context $(CONTEXT) wait --for=condition=ready pod -l app=inference -n isac-sensing --timeout=120s || true
	kubectl --context $(CONTEXT) wait --for=condition=ready pod -l app=output -n isac-sensing --timeout=120s || true
	kubectl --context $(CONTEXT) wait --for=condition=ready pod -l app=prometheus -n isac-monitoring --timeout=120s || true
	kubectl --context $(CONTEXT) wait --for=condition=ready pod -l app=grafana -n isac-monitoring --timeout=120s || true
	@echo "Waiting for ingestion DaemonSet..."
	@sleep 5
	kubectl --context $(CONTEXT) get pods -n isac-sensing -o wide
	kubectl --context $(CONTEXT) get pods -n isac-monitoring -o wide

# 7. Check placement: simulator/ingestion/preprocessing on the phone, inference/output elsewhere
validate:
	@echo "=== Pod placement ==="
	kubectl --context $(CONTEXT) get pods -n isac-sensing -o wide
	@echo ""
	@echo "=== Services ==="
	kubectl --context $(CONTEXT) get svc -n isac-sensing
	@echo ""
	@echo "=== Monitoring (isac-monitoring ns) ==="
	kubectl --context $(CONTEXT) get pods,svc -n isac-monitoring
	@echo ""
	@echo "=== Nodes, arch, edge label ==="
	kubectl --context $(CONTEXT) get nodes -o wide --show-labels | grep -E 'isac-edge|ARCH'

# Throwaway pod on the phone, before trusting it with real services (see README Phase 6)
smoke-test:
	kubectl --context $(CONTEXT) run edge-smoke --rm -it --restart=Never \
	  --image=busybox --overrides='{"spec":{"nodeSelector":{"isac-edge":"true"}}}' \
	  -- echo "phone node reachable"

# 8. Show logs
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

# 9. Monitoring UI access
port-forward-prometheus:
	kubectl --context $(CONTEXT) port-forward -n isac-monitoring svc/prometheus 9090:9090

port-forward-grafana:
	kubectl --context $(CONTEXT) port-forward -n isac-monitoring svc/grafana 3000:3000

# Tear down the pipeline (not the cluster itself — k3s runs on real hosts,
# uninstall via k3s-uninstall.sh / k3s-agent-uninstall.sh on those hosts if needed)
clean:
	kubectl --context $(CONTEXT) delete namespace isac-sensing --ignore-not-found
	kubectl --context $(CONTEXT) delete namespace isac-monitoring --ignore-not-found
	rm -f services/proto/isac_pb2.py services/proto/isac_pb2_grpc.py
