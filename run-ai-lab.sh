#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="ai-lab"
NAMESPACE="ai"
DASH_NS="kubernetes-dashboard"

echo "==> Starting Docker sanity check..."
docker ps >/dev/null 2>&1 || {
  echo "ERROR: Docker is not running (or not reachable from this shell). Start Docker Desktop first."
  exit 1
}

echo "==> Starting k3d cluster: ${CLUSTER_NAME}"
k3d cluster start "${CLUSTER_NAME}" >/dev/null 2>&1 || {
  echo "Cluster not found. Creating: ${CLUSTER_NAME}"
  k3d cluster create "${CLUSTER_NAME}" -p "3100:30510@server:0"
}

echo "==> Verifying kubectl can reach the cluster..."
kubectl get nodes >/dev/null

echo "==> Waiting for kube-system core pods..."
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=180s >/dev/null 2>&1 || true
kubectl -n kube-system wait --for=condition=Ready pod -l app.kubernetes.io/name=traefik --timeout=180s >/dev/null 2>&1 || true

echo "==> Current pods in '${NAMESPACE}' namespace:"
kubectl -n "${NAMESPACE}" get pods -o wide || true

echo ""
echo "==> Services in '${NAMESPACE}' namespace:"
kubectl -n "${NAMESPACE}" get svc || true

echo ""
echo "==> Useful URLs (from your previous setup):"
echo "OpenWebUI:   http://openwebui.local:3100"
echo "LiteLLM:     (internal svc) http://litellm.ai.svc.cluster.local:4000"
echo "Langfuse:    (if exposed)   http://langfuse.local:3100"
echo ""
echo "==> Kubernetes Dashboard (recommended local secure access):"
echo "Run: kubectl -n ${DASH_NS} port-forward svc/kubernetes-dashboard 8443:443"
echo "Then open: https://localhost:8443"
echo ""

# Optional: auto-start dashboard port-forward
read -r -p "Start Kubernetes Dashboard port-forward now? (y/n): " ans
if [[ "${ans}" =~ ^[Yy]$ ]]; then
  echo "Starting Dashboard port-forward on https://localhost:8443 ..."
  echo "(Press Ctrl+C to stop port-forward)"
  kubectl -n "${DASH_NS}" port-forward svc/kubernetes-dashboard 8443:443
fi

