#!/usr/bin/env bash
#
# AI Lab Deployment Script
# ========================
# Deploys all AI Lab services to the k3d cluster.
# Requires: kubectl, helm, envsubst
# Prerequisites: k3d cluster running (use 'make start')
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="ai"
DASH_NS="kubernetes-dashboard"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}==>${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Load credentials
CREDENTIALS_FILE="${SCRIPT_DIR}/.credentials"
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    log_error "Credentials file not found: $CREDENTIALS_FILE
    
Copy .credentials.example to .credentials and fill in values:
  cp .credentials.example .credentials"
fi

# shellcheck source=/dev/null
source "$CREDENTIALS_FILE"

# Export for envsubst
export POSTGRES_PASSWORD LITELLM_MASTER_KEY LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY
export KEYCLOAK_ADMIN_USER KEYCLOAK_ADMIN_PASSWORD KC_DB_PASSWORD OAUTH_CLIENT_SECRET KEYCLOAK_TEST_USER_PASSWORD

log_info "Creating namespaces..."
kubectl create namespace "${NAMESPACE}" 2>/dev/null || true
kubectl create namespace "${DASH_NS}" 2>/dev/null || true

log_info "Applying storage class and persistent volumes..."
kubectl apply -f storage-class.yaml
kubectl apply -f persistent-volumes.yaml

log_info "Installing nginx ingress controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update ingress-nginx 2>/dev/null || true
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30510

log_info "Installing PostgreSQL..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
envsubst < postgres-values.yaml | helm upgrade --install langfuse-db bitnami/postgresql -n "${NAMESPACE}" -f -

log_info "Waiting for PostgreSQL to be ready..."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/name=postgresql --timeout=180s || true

log_info "Creating databases..."
kubectl -n "${NAMESPACE}" exec langfuse-db-postgresql-0 -- \
  env PGPASSWORD="${POSTGRES_PASSWORD}" psql -U postgres -c "CREATE DATABASE litellm;" 2>/dev/null || true
kubectl -n "${NAMESPACE}" exec langfuse-db-postgresql-0 -- \
  env PGPASSWORD="${POSTGRES_PASSWORD}" psql -U postgres -c "CREATE DATABASE keycloak;" 2>/dev/null || true

log_info "Deploying Keycloak..."
envsubst < keycloak.yaml | kubectl apply -f -

log_info "Deploying Langfuse..."
kubectl apply -f langfuse.yaml

log_info "Deploying Ollama..."
kubectl apply -f ollama.yaml

log_info "Installing LiteLLM..."
envsubst < charts/litellm/values.yaml > /tmp/litellm-values.yaml
helm upgrade --install litellm ./charts/litellm -n "${NAMESPACE}" -f /tmp/litellm-values.yaml

log_info "Installing Open WebUI..."
envsubst < charts/openwebui/values.yaml > /tmp/openwebui-values.yaml
helm upgrade --install openwebui ./charts/openwebui -n "${NAMESPACE}" -f /tmp/openwebui-values.yaml

log_info "Deploying Kubernetes Dashboard..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml 2>/dev/null || true
kubectl create clusterrolebinding dashboard-admin --clusterrole=cluster-admin \
  --serviceaccount=kubernetes-dashboard:kubernetes-dashboard 2>/dev/null || true

log_info "Applying ingresses..."
kubectl apply -f ingress-ai.yaml
kubectl apply -f dashboard-ingress.yml

log_info "Waiting for pods to start..."
sleep 10
kubectl get pods -n "${NAMESPACE}"

echo ""
log_info "Pulling Ollama model (this may take a few minutes)..."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app=ollama --timeout=300s || true
kubectl -n "${NAMESPACE}" exec deploy/ollama -- ollama pull llama3.2:1b || echo "Model pull will complete in background"

# Cleanup temp files
rm -f /tmp/litellm-values.yaml /tmp/openwebui-values.yaml

echo ""
echo "========================================"
echo "        Deployment Complete!"
echo "========================================"
echo ""
echo "URLs:"
echo "  OpenWebUI:  http://openwebui.local:3100"
echo "  Keycloak:   http://keycloak.local:3100"
echo "  Langfuse:   http://langfuse.local:3100"
echo "  LiteLLM:    http://litellm.local:3100"
echo "  Dashboard:  http://dashboard.local:3100"
echo ""
echo "Keycloak Admin:"
echo "  URL:      http://keycloak.local:3100/admin"
echo "  User:     ${KEYCLOAK_ADMIN_USER}"
echo ""
echo "Default AI Lab User:"
echo "  Email:    admin@ailab.local"
echo "  Password: (set in Keycloak)"
echo "  Password: admin123"
