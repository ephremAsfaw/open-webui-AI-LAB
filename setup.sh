#!/usr/bin/env bash
#
# AI Lab Setup Script
# ====================
# This script sets up a complete local AI development environment with:
# - Ollama (local LLM runner)
# - LiteLLM (OpenAI-compatible proxy)
# - Open WebUI (ChatGPT-like interface)
# - Langfuse (LLM observability/tracing)
# - Kubernetes Dashboard
#
# Usage: ./setup.sh
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="ai-lab"
NAMESPACE="ai"
DASH_NS="kubernetes-dashboard"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"

# Helper functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_command() {
    if command -v "$1" &> /dev/null; then
        log_success "$1 is installed"
        return 0
    else
        log_error "$1 is not installed"
        return 1
    fi
}

generate_key() {
    # Generate a secure random key
    openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p
}

# =============================================================================
# STEP 1: Check Prerequisites
# =============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local failed=0
    
    check_command docker || failed=1
    check_command k3d || failed=1
    check_command kubectl || failed=1
    check_command helm || failed=1
    
    if [[ $failed -eq 1 ]]; then
        echo ""
        log_error "Missing prerequisites. Please install them first:"
        echo "  - Docker: https://docs.docker.com/get-docker/"
        echo "  - k3d: curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
        echo "  - kubectl: https://kubernetes.io/docs/tasks/tools/"
        echo "  - helm: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    
    # Check if Docker is running
    if ! docker info &>/dev/null; then
        log_warn "Docker is not running. Attempting to start..."
        sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || {
            log_error "Could not start Docker. Please start it manually."
            exit 1
        }
        sleep 3
    fi
    log_success "Docker is running"
    
    echo ""
}

# =============================================================================
# STEP 2: Setup /etc/hosts
# =============================================================================
setup_hosts() {
    log_info "Checking /etc/hosts entries..."
    
    local hosts=("openwebui.local" "litellm.local" "langfuse.local" "dashboard.local")
    local missing=()
    
    for host in "${hosts[@]}"; do
        if ! grep -q "$host" /etc/hosts; then
            missing+=("$host")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing hosts entries. Adding them (requires sudo)..."
        echo ""
        echo "127.0.0.1 ${missing[*]}" | sudo tee -a /etc/hosts
        log_success "Added hosts entries"
    else
        log_success "All hosts entries present"
    fi
    echo ""
}

# =============================================================================
# STEP 3: Create Data Directories
# =============================================================================
create_directories() {
    log_info "Creating data directories..."
    
    mkdir -p "${DATA_DIR}/postgres"
    mkdir -p "${DATA_DIR}/ollama"
    mkdir -p "${DATA_DIR}/openwebui"
    mkdir -p "${DATA_DIR}/langfuse"
    
    # Set permissions for PostgreSQL
    chmod 777 "${DATA_DIR}/postgres"
    
    log_success "Data directories created at ${DATA_DIR}"
    echo ""
}

# =============================================================================
# STEP 4: Generate Configuration
# =============================================================================
generate_config() {
    log_info "Generating configuration files..."
    
    # Generate unique keys for this installation
    local LITELLM_KEY="sk-$(generate_key)"
    local POSTGRES_PASSWORD="$(generate_key | head -c 16)"
    local LANGFUSE_PASSWORD="$(generate_key | head -c 16)"
    local NEXTAUTH_SECRET="$(generate_key)"
    local SALT="$(generate_key)"
    
    # Save credentials to a file
    cat > "${SCRIPT_DIR}/.credentials" <<EOF
# AI Lab Credentials - Generated $(date)
# Keep this file secure!

LITELLM_MASTER_KEY=${LITELLM_KEY}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
LANGFUSE_DB_PASSWORD=${LANGFUSE_PASSWORD}
NEXTAUTH_SECRET=${NEXTAUTH_SECRET}
SALT=${SALT}

# Service URLs
OPENWEBUI_URL=http://openwebui.local:3100
LITELLM_URL=http://litellm.local:3100
LANGFUSE_URL=http://langfuse.local:3100
DASHBOARD_URL=http://dashboard.local:3100
EOF
    chmod 600 "${SCRIPT_DIR}/.credentials"
    
    # Generate k3d-config.yaml
    cat > "${SCRIPT_DIR}/k3d-config.yaml" <<EOF
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: ${CLUSTER_NAME}
servers: 1
agents: 0
ports:
  - port: 3100:30510
    nodeFilters:
      - server:0
volumes:
  - volume: ${DATA_DIR}/postgres:/data/postgres
    nodeFilters:
      - server:0
  - volume: ${DATA_DIR}/openwebui:/data/openwebui
    nodeFilters:
      - server:0
  - volume: ${DATA_DIR}/ollama:/data/ollama
    nodeFilters:
      - server:0
  - volume: ${DATA_DIR}/langfuse:/data/langfuse
    nodeFilters:
      - server:0
options:
  k3s:
    extraArgs:
      - arg: --disable=traefik
        nodeFilters:
          - server:0
EOF

    # Generate postgres-values.yaml
    cat > "${SCRIPT_DIR}/postgres-values.yaml" <<EOF
auth:
  postgresPassword: ${POSTGRES_PASSWORD}
  username: langfuse
  password: ${LANGFUSE_PASSWORD}
  database: langfuse

primary:
  persistence:
    enabled: true
    existingClaim: postgres-pvc
EOF

    # Generate langfuse.yaml
    cat > "${SCRIPT_DIR}/langfuse.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: langfuse-secret
  namespace: ai
type: Opaque
stringData:
  NEXTAUTH_SECRET: "${NEXTAUTH_SECRET}"
  SALT: "${SALT}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: langfuse
  namespace: ai
spec:
  replicas: 1
  selector:
    matchLabels:
      app: langfuse
  template:
    metadata:
      labels:
        app: langfuse
    spec:
      containers:
        - name: langfuse
          image: ghcr.io/langfuse/langfuse:2
          ports:
            - containerPort: 3000
          env:
            - name: DATABASE_URL
              value: "postgresql://langfuse:${LANGFUSE_PASSWORD}@langfuse-db-postgresql.ai.svc.cluster.local:5432/langfuse"
            - name: NEXTAUTH_URL
              value: "http://langfuse.local:3100"
            - name: NEXTAUTH_SECRET
              valueFrom:
                secretKeyRef:
                  name: langfuse-secret
                  key: NEXTAUTH_SECRET
            - name: SALT
              valueFrom:
                secretKeyRef:
                  name: langfuse-secret
                  key: SALT
---
apiVersion: v1
kind: Service
metadata:
  name: langfuse
  namespace: ai
spec:
  selector:
    app: langfuse
  ports:
    - name: http
      port: 3000
      targetPort: 3000
EOF

    # Update LiteLLM values
    cat > "${SCRIPT_DIR}/charts/litellm/values.yaml" <<EOF
image:
  repository: docker.litellm.ai/berriai/litellm
  tag: main-latest

service:
  type: ClusterIP
  port: 4000

env:
  LITELLM_MASTER_KEY: "${LITELLM_KEY}"
  LITELLM_ENABLE_ADMIN_UI: "true"
  DATABASE_URL: "postgresql://postgres:${POSTGRES_PASSWORD}@langfuse-db-postgresql.ai.svc.cluster.local:5432/litellm"

  # Langfuse keys - update these after creating a project in Langfuse
  LANGFUSE_PUBLIC_KEY: "UPDATE_ME"
  LANGFUSE_SECRET_KEY: "UPDATE_ME"
  LANGFUSE_HOST: "http://langfuse.ai.svc.cluster.local:3000"

configYaml: |
  litellm_settings:
    callbacks: ["langfuse"]

  model_list:
    - model_name: llama3.2
      litellm_params:
        model: ollama/llama3.2:1b
        api_base: http://ollama.ai.svc.cluster.local:11434
    - model_name: llama3.2-3b
      litellm_params:
        model: ollama/llama3.2:latest
        api_base: http://ollama.ai.svc.cluster.local:11434
EOF

    # Update OpenWebUI values
    cat > "${SCRIPT_DIR}/charts/openwebui/values.yaml" <<EOF
image:
  repository: ghcr.io/open-webui/open-webui
  tag: main

service:
  type: ClusterIP
  port: 8080

persistence:
  enabled: true
  size: 5Gi
  storageClassName: hostpath
  volumeName: openwebui-pv

env:
  OPENAI_API_BASE_URL: "http://litellm.ai.svc.cluster.local:4000/v1"
  OPENAI_API_KEY: "${LITELLM_KEY}"
  ENABLE_FORWARD_USER_INFO_HEADERS: "True"
  ENABLE_OLLAMA_API: "False"
EOF

    log_success "Configuration files generated"
    log_info "Credentials saved to ${SCRIPT_DIR}/.credentials"
    echo ""
}

# =============================================================================
# STEP 5: Create Kubernetes Cluster
# =============================================================================
create_cluster() {
    log_info "Creating k3d cluster..."
    
    # Check if cluster already exists
    if k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
        log_warn "Cluster '${CLUSTER_NAME}' already exists"
        read -p "Delete and recreate? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            k3d cluster delete "${CLUSTER_NAME}"
        else
            log_info "Using existing cluster"
            k3d cluster start "${CLUSTER_NAME}" 2>/dev/null || true
            return 0
        fi
    fi
    
    k3d cluster create --config "${SCRIPT_DIR}/k3d-config.yaml"
    log_success "Cluster created"
    
    # Wait for cluster to be ready
    log_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s
    log_success "Cluster is ready"
    echo ""
}

# =============================================================================
# STEP 6: Deploy Services
# =============================================================================
deploy_services() {
    log_info "Deploying services..."
    
    # Create namespaces
    kubectl create namespace "${NAMESPACE}" 2>/dev/null || true
    kubectl create namespace "${DASH_NS}" 2>/dev/null || true
    
    # Apply storage
    log_info "Setting up storage..."
    kubectl apply -f "${SCRIPT_DIR}/storage-class.yaml"
    kubectl apply -f "${SCRIPT_DIR}/persistent-volumes.yaml"
    
    # Install nginx ingress
    log_info "Installing nginx ingress controller..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update ingress-nginx 2>/dev/null || true
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx --create-namespace \
        --set controller.service.type=NodePort \
        --set controller.service.nodePorts.http=30510 \
        --wait --timeout 3m
    
    # Install PostgreSQL
    log_info "Installing PostgreSQL..."
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm upgrade --install langfuse-db bitnami/postgresql -n "${NAMESPACE}" \
        -f "${SCRIPT_DIR}/postgres-values.yaml" \
        --wait --timeout 5m
    
    # Create LiteLLM database
    log_info "Creating LiteLLM database..."
    source "${SCRIPT_DIR}/.credentials"
    kubectl -n "${NAMESPACE}" exec langfuse-db-postgresql-0 -- \
        env PGPASSWORD="${POSTGRES_PASSWORD}" psql -U postgres -c "CREATE DATABASE litellm;" 2>/dev/null || true
    
    # Deploy Langfuse
    log_info "Deploying Langfuse..."
    kubectl apply -f "${SCRIPT_DIR}/langfuse.yaml"
    
    # Deploy Ollama
    log_info "Deploying Ollama..."
    kubectl apply -f "${SCRIPT_DIR}/ollama.yaml"
    
    # Install LiteLLM
    log_info "Installing LiteLLM..."
    helm upgrade --install litellm "${SCRIPT_DIR}/charts/litellm" -n "${NAMESPACE}"
    
    # Install Open WebUI
    log_info "Installing Open WebUI..."
    helm upgrade --install openwebui "${SCRIPT_DIR}/charts/openwebui" -n "${NAMESPACE}"
    
    # Deploy Kubernetes Dashboard
    log_info "Deploying Kubernetes Dashboard..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml 2>/dev/null || true
    kubectl create clusterrolebinding dashboard-admin \
        --clusterrole=cluster-admin \
        --serviceaccount=kubernetes-dashboard:kubernetes-dashboard 2>/dev/null || true
    
    # Configure dashboard for HTTP access
    kubectl -n "${DASH_NS}" patch deployment kubernetes-dashboard --type='json' \
        -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["--namespace=kubernetes-dashboard", "--enable-insecure-login", "--enable-skip-login", "--insecure-bind-address=0.0.0.0"]}]' 2>/dev/null || true
    kubectl -n "${DASH_NS}" patch svc kubernetes-dashboard --type='json' \
        -p='[{"op": "replace", "path": "/spec/ports/0/port", "value": 80}, {"op": "replace", "path": "/spec/ports/0/targetPort", "value": 9090}]' 2>/dev/null || true
    
    # Apply ingresses
    log_info "Applying ingresses..."
    kubectl apply -f "${SCRIPT_DIR}/ingress-ai.yaml"
    kubectl apply -f "${SCRIPT_DIR}/dashboard-ingress.yml"
    
    log_success "All services deployed"
    echo ""
}

# =============================================================================
# STEP 7: Wait for Services and Pull Model
# =============================================================================
finalize() {
    log_info "Waiting for all pods to be ready..."
    
    # Wait for pods
    sleep 10
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app=ollama --timeout=300s 2>/dev/null || true
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app=langfuse --timeout=180s 2>/dev/null || true
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app=litellm --timeout=180s 2>/dev/null || true
    kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app=openwebui --timeout=180s 2>/dev/null || true
    
    # Pull the LLM model
    log_info "Pulling Ollama model (llama3.2:1b - this may take a few minutes)..."
    kubectl -n "${NAMESPACE}" exec deploy/ollama -- ollama pull llama3.2:1b 2>/dev/null || {
        log_warn "Model pull failed or still in progress. You can pull it manually later."
    }
    
    echo ""
    log_success "Setup complete!"
    echo ""
}

# =============================================================================
# STEP 8: Print Summary
# =============================================================================
print_summary() {
    echo "=============================================="
    echo -e "${GREEN}AI Lab Setup Complete!${NC}"
    echo "=============================================="
    echo ""
    echo "Service URLs:"
    echo "  Open WebUI:  http://openwebui.local:3100"
    echo "  LiteLLM:     http://litellm.local:3100"
    echo "  Langfuse:    http://langfuse.local:3100"
    echo "  Dashboard:   http://dashboard.local:3100"
    echo ""
    echo "Credentials saved to: ${SCRIPT_DIR}/.credentials"
    echo ""
    echo "Quick Commands:"
    echo "  make start     - Start the cluster"
    echo "  make stop      - Stop the cluster"
    echo "  make test      - Test cluster health"
    echo "  make dashboard - Port-forward dashboard"
    echo ""
    echo "Current pod status:"
    kubectl get pods -n "${NAMESPACE}"
    echo ""
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo "1. Open http://langfuse.local:3100 and create an account"
    echo "2. Create a new project (e.g., 'AiLab')"
    echo "3. Generate API keys in Project Settings > API Keys"
    echo "4. Update charts/litellm/values.yaml with your Langfuse keys"
    echo "5. Run: helm upgrade litellm ./charts/litellm -n ai"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo ""
    echo "==========================================="
    echo "       AI Lab Local Environment Setup"
    echo "==========================================="
    echo ""
    
    check_prerequisites
    setup_hosts
    create_directories
    generate_config
    create_cluster
    deploy_services
    finalize
    print_summary
}

# Run main function
main "$@"
