#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="ai-lab"
NAMESPACE="ai"
DASH_NS="kubernetes-dashboard"

echo "==> Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" 2>/dev/null || true
kubectl create namespace "${DASH_NS}" 2>/dev/null || true

echo "==> Applying storage class and persistent volumes..."
kubectl apply -f storage-class.yaml
kubectl apply -f persistent-volumes.yaml

echo "==> Installing nginx ingress controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update ingress-nginx 2>/dev/null || true
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30510

echo "==> Installing PostgreSQL..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm upgrade --install langfuse-db bitnami/postgresql -n "${NAMESPACE}" \
  -f postgres-values.yaml

echo "==> Waiting for PostgreSQL to be ready..."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/name=postgresql --timeout=180s || true

echo "==> Creating LiteLLM database..."
kubectl -n "${NAMESPACE}" exec langfuse-db-postgresql-0 -- env PGPASSWORD=FROREJ4fhH psql -U postgres -c "CREATE DATABASE litellm;" 2>/dev/null || true

echo "==> Deploying Langfuse..."
kubectl apply -f langfuse.yaml

echo "==> Deploying Ollama..."
kubectl apply -f ollama.yaml

echo "==> Installing LiteLLM..."
helm upgrade --install litellm ./charts/litellm -n "${NAMESPACE}"

echo "==> Installing Open WebUI..."
helm upgrade --install openwebui ./charts/openwebui -n "${NAMESPACE}"

echo "==> Deploying Kubernetes Dashboard..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml 2>/dev/null || true
kubectl create clusterrolebinding dashboard-admin --clusterrole=cluster-admin --serviceaccount=kubernetes-dashboard:kubernetes-dashboard 2>/dev/null || true

echo "==> Applying ingresses..."
kubectl apply -f ingress-ai.yaml
kubectl apply -f dashboard-ingress.yml

echo "==> Waiting for pods to start..."
sleep 10
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "==> Pulling Ollama model (this may take a few minutes)..."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app=ollama --timeout=300s || true
kubectl -n "${NAMESPACE}" exec deploy/ollama -- ollama pull llama3.2:1b || echo "Model pull will complete in background"

echo ""
echo "==> Deployment complete!"
echo "URLs:"
echo "  OpenWebUI:  http://openwebui.local:3100"
echo "  Langfuse:   http://langfuse.local:3100"
echo "  LiteLLM:    http://litellm.local:3100"
echo "  Dashboard:  http://dashboard.local:3100"
