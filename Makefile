.PHONY: all codegen proto kind-up cilium label-edge namespace build-images load-images deploy validate clean port-forward-prometheus port-forward-grafana logs-prometheus logs-grafana \
	k3s-context k3s-cilium label-edge-k3s edge-namespace build-images-multiarch edge-deploy edge-validate edge-smoke-test edge-clean

# --- k3s edge cluster config (override on the command line, e.g. `make edge-deploy EDGE_NODE_NAME=my-phone`) ---
K3S_CONTEXT ?= k3s-isac
EDGE_NODE_NAME ?= android-edge-01
REGISTRY ?= localhost:5000

all: kind-up cilium label-edge namespace build-images load-images deploy

# 1. Generate protobuf code
codegen:
	cd services && ./codegen.sh

# 2. Create kind cluster
kind-up:
	kind create cluster --config cluster/kind-config.yaml --name isac
	kubectl cluster-info --context kind-isac

# 3. Install Cilium
cilium: codegen
	helm repo add cilium https://helm.cilium.io/
	helm upgrade --install cilium cilium/cilium \
	  --namespace kube-system \
	  --values cluster/cilium-values.yaml \
	  --wait \
	  --timeout 15m
	kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s
	@echo "--- Verifying Cilium status ---"
	kubectl -n kube-system exec ds/cilium -- cilium status --brief

# 4. Label edge node
label-edge:
	kubectl label node isac-worker isac-edge=true --overwrite

# 5. Create namespace
namespace:
	kubectl apply -f cluster/manifests/01-namespace.yaml

# 6. Build Docker images
build-images:
	@echo "Building simulator image..."
	cd services && docker build -t isac-simulator:latest -f simulator/Dockerfile .
	@echo "Building ingestion image..."
	cd services && docker build -t isac-ingestion:latest -f ingestion/Dockerfile .
	@echo "Building preprocessing image..."
	cd services && docker build -t isac-preprocessing:latest -f preprocessing/Dockerfile .
	@echo "Building inference image..."
	cd services && docker build -t isac-inference:latest -f inference/Dockerfile .
	@echo "Building output image..."
	cd services && docker build -t isac-output:latest -f output/Dockerfile .

# 7. Load images into kind
load-images:
	kind load docker-image isac-simulator:latest --name isac
	kind load docker-image isac-ingestion:latest --name isac
	kind load docker-image isac-preprocessing:latest --name isac
	kind load docker-image isac-inference:latest --name isac
	kind load docker-image isac-output:latest --name isac

# 8. Deploy all manifests
deploy:
	kubectl apply -f cluster/manifests/02-simulator.yaml
	kubectl apply -f cluster/manifests/03-ingestion.yaml
	kubectl apply -f cluster/manifests/04-preprocessing.yaml
	kubectl apply -f cluster/manifests/05-inference.yaml
	kubectl apply -f cluster/manifests/06-output.yaml
	kubectl apply -f cluster/manifests/07-network-policies.yaml
	kubectl apply -f cluster/manifests/08-monitoring-rbac.yaml
	kubectl apply -f cluster/manifests/09-prometheus.yaml
	kubectl apply -f cluster/manifests/10-grafana.yaml
	@echo "--- Waiting for all pods to be ready ---"
	kubectl wait --for=condition=ready pod -l app=simulator -n isac-sensing --timeout=120s || true
	kubectl wait --for=condition=ready pod -l app=preprocessing -n isac-sensing --timeout=120s || true
	kubectl wait --for=condition=ready pod -l app=inference -n isac-sensing --timeout=120s || true
	kubectl wait --for=condition=ready pod -l app=output -n isac-sensing --timeout=120s || true
	kubectl wait --for=condition=ready pod -l app=prometheus -n isac-sensing --timeout=120s || true
	kubectl wait --for=condition=ready pod -l app=grafana -n isac-sensing --timeout=120s || true
	# DaemonSet doesn't have condition=ready for the controller, wait for individual pod
	@echo "Waiting for ingestion DaemonSet..."
	@sleep 5
	kubectl get pods -n isac-sensing -o wide

# 9. Check placement
validate:
	@echo "=== Pod placement ==="
	kubectl get pods -n isac-sensing -o wide
	@echo ""
	@echo "=== Services ==="
	kubectl get svc -n isac-sensing
	@echo ""
	@echo "=== Nodes & labels ==="
	kubectl get nodes --show-labels | grep isac-edge

# 10. Show logs
logs-simulator:
	kubectl logs -n isac-sensing -l app=simulator --tail=50

logs-ingestion:
	kubectl logs -n isac-sensing -l app=ingestion --tail=50

logs-preprocessing:
	kubectl logs -n isac-sensing -l app=preprocessing --tail=50

logs-inference:
	kubectl logs -n isac-sensing -l app=inference --tail=50

logs-output:
	kubectl logs -n isac-sensing -l app=output --tail=50

logs-prometheus:
	kubectl logs -n isac-sensing -l app=prometheus --tail=50

logs-grafana:
	kubectl logs -n isac-sensing -l app=grafana --tail=50

# 11. Monitoring UI access
port-forward-prometheus:
	kubectl port-forward -n isac-sensing svc/prometheus 9090:9090

port-forward-grafana:
	kubectl port-forward -n isac-sensing svc/grafana 3000:3000

# Clean up
clean:
	kind delete cluster --name isac || true
	docker rmi isac-simulator:latest isac-ingestion:latest isac-preprocessing:latest isac-inference:latest isac-output:latest 2>/dev/null || true
	rm -f services/proto/isac_pb2.py services/proto/isac_pb2_grpc.py

# =====================================================================
# k3s edge cluster targets — phone as a real k3s node. Separate cluster
# and context from KIND; nothing above this line touches K3S_CONTEXT.
# =====================================================================

# Sanity check the context exists before running anything against it
k3s-context:
	kubectl config get-contexts $(K3S_CONTEXT)

# Install Cilium on the k3s cluster (skip this + 07-network-policies.yaml
# if you took the flannel fallback from the plan)
k3s-cilium: codegen
	helm repo add cilium https://helm.cilium.io/
	helm upgrade --install cilium cilium/cilium \
	  --kube-context $(K3S_CONTEXT) \
	  --namespace kube-system \
	  --values cluster/cilium-values.yaml \
	  --wait \
	  --timeout 15m
	kubectl --context $(K3S_CONTEXT) wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s

# Label the phone's k3s node (join it first with `k3s agent ... --node-name $(EDGE_NODE_NAME)`)
label-edge-k3s:
	kubectl --context $(K3S_CONTEXT) label node $(EDGE_NODE_NAME) isac-edge=true --overwrite

edge-namespace:
	kubectl --context $(K3S_CONTEXT) apply -f cluster/manifests/01-namespace.yaml

# Multi-arch build + push (k3s has no `kind load docker-image` — needs a
# registry reachable from the phone, e.g. one on the k3s server host)
build-images-multiarch: codegen
	@echo "Building + pushing multi-arch images to $(REGISTRY)..."
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-simulator:latest -f simulator/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-ingestion:latest -f ingestion/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-preprocessing:latest -f preprocessing/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-inference:latest -f inference/Dockerfile --push .
	cd services && docker buildx build --platform linux/amd64,linux/arm64 -t $(REGISTRY)/isac-output:latest -f output/Dockerfile --push .

# Deploy the full pipeline to the k3s cluster (phone must already be Ready — see Phase 6)
edge-deploy:
	kubectl --context $(K3S_CONTEXT) apply -f cluster/manifests/02-simulator.yaml
	kubectl --context $(K3S_CONTEXT) apply -f cluster/manifests/03-ingestion.yaml
	kubectl --context $(K3S_CONTEXT) apply -f cluster/manifests/04-preprocessing.yaml
	kubectl --context $(K3S_CONTEXT) apply -f cluster/manifests/05-inference.yaml
	kubectl --context $(K3S_CONTEXT) apply -f cluster/manifests/06-output.yaml
	kubectl --context $(K3S_CONTEXT) apply -f cluster/manifests/07-network-policies.yaml || true
	kubectl --context $(K3S_CONTEXT) apply -f cluster/manifests/08-monitoring-rbac.yaml
	kubectl --context $(K3S_CONTEXT) apply -f cluster/manifests/09-prometheus.yaml
	kubectl --context $(K3S_CONTEXT) apply -f cluster/manifests/10-grafana.yaml
	@echo "--- Waiting for pods (phone node may be slower than KIND) ---"
	kubectl --context $(K3S_CONTEXT) wait --for=condition=ready pod -l app=simulator -n isac-sensing --timeout=180s || true
	kubectl --context $(K3S_CONTEXT) wait --for=condition=ready pod -l app=preprocessing -n isac-sensing --timeout=180s || true
	kubectl --context $(K3S_CONTEXT) wait --for=condition=ready pod -l app=inference -n isac-sensing --timeout=120s || true
	kubectl --context $(K3S_CONTEXT) wait --for=condition=ready pod -l app=output -n isac-sensing --timeout=120s || true
	kubectl --context $(K3S_CONTEXT) get pods -n isac-sensing -o wide

# Check placement: simulator/ingestion/preprocessing on the phone, inference/output central
edge-validate:
	@echo "=== Pod placement ==="
	kubectl --context $(K3S_CONTEXT) get pods -n isac-sensing -o wide
	@echo ""
	@echo "=== Nodes, arch, edge label ==="
	kubectl --context $(K3S_CONTEXT) get nodes -o wide --show-labels | grep -E 'isac-edge|ARCH'

# Phase 6 step 3: throwaway pod on the phone before trusting it with real services
edge-smoke-test:
	kubectl --context $(K3S_CONTEXT) run edge-smoke --rm -it --restart=Never \
	  --image=busybox --overrides='{"spec":{"nodeSelector":{"isac-edge":"true"}}}' \
	  -- echo "phone node reachable"

edge-clean:
	kubectl --context $(K3S_CONTEXT) delete namespace isac-sensing --ignore-not-found
