.PHONY: start stop test check-docker help

CLUSTER_NAME := ai-lab
NAMESPACE := ai
DASH_NS := kubernetes-dashboard

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

check-docker: ## Check if Docker is running
	@echo "==> Checking Docker status..."
	@docker ps >/dev/null 2>&1 && echo "Docker: RUNNING" || { echo "Docker: NOT RUNNING"; exit 1; }

start: ## Start the AI Lab k3d cluster and services
	@echo "==> Checking Docker..."
	@docker ps >/dev/null 2>&1 || { \
		echo "Docker is not running. Attempting to start..."; \
		sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || { echo "ERROR: Could not start Docker. Please start it manually."; exit 1; }; \
		sleep 3; \
		docker ps >/dev/null 2>&1 || { echo "ERROR: Docker still not running."; exit 1; }; \
		echo "Docker started successfully."; \
	}
	@echo "==> Starting k3d cluster: $(CLUSTER_NAME)"
	@k3d cluster start $(CLUSTER_NAME) 2>/dev/null || { \
		echo "Cluster not found. Creating: $(CLUSTER_NAME)"; \
		k3d cluster create --config k3d-config.yaml; \
	}
	@echo "==> Verifying kubectl can reach the cluster..."
	@kubectl get nodes >/dev/null
	@echo "==> Waiting for kube-system core pods..."
	@kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=180s >/dev/null 2>&1 || true
	@kubectl -n kube-system wait --for=condition=Ready pod -l app.kubernetes.io/name=traefik --timeout=180s >/dev/null 2>&1 || true
	@echo "==> Waiting for Keycloak to be ready..."
	@kubectl -n $(NAMESPACE) wait --for=condition=Ready pod -l app=keycloak --timeout=120s >/dev/null 2>&1 || true
	@echo "==> Waiting for Kubernetes Dashboard..."
	@kubectl -n $(DASH_NS) wait --for=condition=Ready pod -l k8s-app=kubernetes-dashboard --timeout=60s >/dev/null 2>&1 || true
	@echo "==> Current pods in '$(NAMESPACE)' namespace:"
	@kubectl -n $(NAMESPACE) get pods -o wide || true
	@echo ""
	@echo "==> Pods in '$(DASH_NS)' namespace:"
	@kubectl -n $(DASH_NS) get pods || true
	@echo ""
	@echo "==> Services in '$(NAMESPACE)' namespace:"
	@kubectl -n $(NAMESPACE) get svc || true
	@echo ""
	@echo "==> Useful URLs:"
	@echo "OpenWebUI:   http://openwebui.local:3100"
	@echo "Keycloak:    http://keycloak.local:3100"
	@echo "LiteLLM:     http://litellm.local:3100"
	@echo "Langfuse:    http://langfuse.local:3100"
	@echo "Dashboard:   http://dashboard.local:3100"
	@echo ""
	@echo "==> Keycloak Admin: http://keycloak.local:3100/admin (admin/admin123)"
	@echo ""
	@echo "==> Dashboard token (for login):"
	@kubectl -n $(DASH_NS) create token kubernetes-dashboard 2>/dev/null || echo "Dashboard not installed"

stop: ## Stop the AI Lab k3d cluster
	@echo "==> Checking Docker..."
	@docker ps >/dev/null 2>&1 || { echo "Docker is not running. Nothing to stop."; exit 0; }
	@echo "==> Stopping k3d cluster: $(CLUSTER_NAME)"
	@k3d cluster stop $(CLUSTER_NAME) 2>/dev/null || { echo "Cluster '$(CLUSTER_NAME)' not found or already stopped."; exit 0; }
	@echo "==> Cluster stopped."

test: ## Run tests to verify cluster and services are healthy
	@echo "==> Testing Docker..."
	@docker ps >/dev/null 2>&1 && echo "Docker: OK" || echo "Docker: FAILED"
	@echo "==> Testing k3d cluster..."
	@k3d cluster list | grep -q $(CLUSTER_NAME) && echo "Cluster exists: OK" || echo "Cluster: NOT FOUND"
	@echo "==> Testing kubectl connectivity..."
	@kubectl get nodes >/dev/null 2>&1 && echo "Kubectl: OK" || echo "Kubectl: FAILED"
	@echo "==> Testing pods in $(NAMESPACE) namespace..."
	@kubectl -n $(NAMESPACE) get pods 2>/dev/null || echo "No pods found in $(NAMESPACE)"
	@echo "==> Testing services in $(NAMESPACE) namespace..."
	@kubectl -n $(NAMESPACE) get svc 2>/dev/null || echo "No services found in $(NAMESPACE)"

