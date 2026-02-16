#!/usr/bin/env bash
#
# AI Lab - Docker Compose Setup
# ==============================
# Simple one-command setup using Docker Compose
#
# Usage: ./start-docker.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "========================================="
echo "       AI Lab - Docker Compose Setup"
echo "========================================="
echo ""

# Check Docker
if ! docker info &>/dev/null; then
    echo "ERROR: Docker is not running. Please start Docker first."
    exit 1
fi

# Create .env if not exists
if [[ ! -f .env ]]; then
    echo "Creating .env file with random secrets..."
    cat > .env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p)
NEXTAUTH_SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
SALT=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
LITELLM_MASTER_KEY=sk-$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
LANGFUSE_PUBLIC_KEY=
LANGFUSE_SECRET_KEY=
EOF
    echo -e "${GREEN}Created .env with random secrets${NC}"
fi

# Start services
echo ""
echo "Starting services..."
docker compose up -d

# Wait for services to be healthy
echo ""
echo "Waiting for services to start..."
sleep 10

# Pull Ollama model
echo ""
echo "Pulling Ollama model (llama3.2:1b)..."
docker exec ai-lab-ollama ollama pull llama3.2:1b || {
    echo -e "${YELLOW}Model pull started in background. May take a few minutes.${NC}"
}

# Print summary
echo ""
echo "========================================="
echo -e "${GREEN}AI Lab is running!${NC}"
echo "========================================="
echo ""
echo "Service URLs:"
echo "  Open WebUI:  http://localhost:8080"
echo "  LiteLLM:     http://localhost:4000"
echo "  Langfuse:    http://localhost:3000"
echo ""
echo "Commands:"
echo "  docker compose logs -f      # View logs"
echo "  docker compose stop         # Stop services"
echo "  docker compose down         # Stop and remove containers"
echo "  docker compose down -v      # Stop and DELETE all data"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "1. Open http://localhost:3000 (Langfuse)"
echo "2. Create account and project"
echo "3. Get API keys from Project Settings"
echo "4. Add keys to .env file"
echo "5. Run: docker compose restart litellm"
echo ""
