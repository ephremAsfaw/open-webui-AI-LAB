# AI Lab - Local Development Environment

A complete local AI development environment running on Kubernetes (k3d) with:

- **Ollama** - Local LLM runner (llama3.2)
- **LiteLLM** - OpenAI-compatible API proxy with observability
- **Open WebUI** - ChatGPT-like web interface
- **Langfuse** - LLM tracing and analytics
- **Kubernetes Dashboard** - Cluster management UI

## Prerequisites

Before starting, install these tools:

| Tool    | Installation                                                                       |
| ------- | ---------------------------------------------------------------------------------- |
| Docker  | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/)                  |
| k3d     | `curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \| bash`     |
| kubectl | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/)          |
| helm    | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |

### Quick Install (Ubuntu/Debian)

```bash
# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker

# k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## Quick Start

### 1. Clone the Repository

```bash
git clone <repository-url>
cd AiLab
```

### 2. Run Setup Script

```bash
chmod +x setup.sh
./setup.sh
```

The script will:

- Check prerequisites
- Add entries to `/etc/hosts` (requires sudo)
- Create data directories for persistence
- Generate unique credentials
- Create the k3d cluster
- Deploy all services
- Pull the llama3.2:1b model

Setup takes approximately 5-10 minutes.

### 3. Access Services

| Service    | URL                         |
| ---------- | --------------------------- |
| Open WebUI | http://openwebui.local:3100 |
| LiteLLM    | http://litellm.local:3100   |
| Langfuse   | http://langfuse.local:3100  |
| Dashboard  | http://dashboard.local:3100 |

## Post-Setup: Configure Langfuse Tracing

To enable LLM tracing in Langfuse:

1. **Create Langfuse Account**
   - Open http://langfuse.local:3100
   - Sign up with email/password

2. **Create Project**
   - Click "New Project"
   - Name it (e.g., "AiLab")

3. **Generate API Keys**
   - Go to Project Settings → API Keys
   - Click "Create new API keys"
   - Copy the Public Key and Secret Key

4. **Update LiteLLM Configuration**

   ```bash
   # Edit the values file
   nano charts/litellm/values.yaml

   # Update these lines:
   LANGFUSE_PUBLIC_KEY: "pk-lf-your-public-key"
   LANGFUSE_SECRET_KEY: "sk-lf-your-secret-key"
   ```

5. **Apply Changes**
   ```bash
   helm upgrade litellm ./charts/litellm -n ai
   ```

Now all LLM conversations will be traced in Langfuse!

## Daily Usage

### Start the Environment

```bash
make start
```

### Stop the Environment

```bash
make stop
```

**Important:** Use `make stop` to pause the cluster. Never use `docker system prune` while the cluster exists - it will delete your data!

### Check Status

```bash
make test
```

### View All Commands

```bash
make help
```

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│                     k3d Cluster (ai-lab)                   │
├───────────────────────────────────────────────────────────┤
│                                                           │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐   │
│  │  Open WebUI │───▶│   LiteLLM   │───▶│   Ollama    │   │
│  │   :8080     │    │    :4000    │    │   :11434    │   │
│  └─────────────┘    └──────┬──────┘    └─────────────┘   │
│                            │                              │
│                            ▼                              │
│  ┌─────────────┐    ┌─────────────┐                      │
│  │ PostgreSQL  │◀───│  Langfuse   │                      │
│  │   :5432     │    │   :3000     │                      │
│  └─────────────┘    └─────────────┘                      │
│                                                           │
├───────────────────────────────────────────────────────────┤
│  nginx ingress (NodePort 30510 → Host 3100)               │
└───────────────────────────────────────────────────────────┘
         │
         ▼
    Host Machine (localhost:3100)
```

## Data Persistence

All data is stored in `./data/` directory on your host machine:

```
data/
├── postgres/    # PostgreSQL database
├── ollama/      # Downloaded LLM models
├── openwebui/   # Chat history, user data
└── langfuse/    # (future use)
```

This data persists across cluster restarts. To completely reset:

```bash
make stop
k3d cluster delete ai-lab
rm -rf data/
./setup.sh
```

## Credentials

Credentials are auto-generated during setup and saved to `.credentials`:

```bash
cat .credentials
```

Contains:

- `LITELLM_MASTER_KEY` - API key for LiteLLM
- `POSTGRES_PASSWORD` - PostgreSQL admin password
- `LANGFUSE_DB_PASSWORD` - Langfuse database password

## Troubleshooting

### Pods not starting

```bash
# Check pod status
kubectl get pods -n ai

# View logs
kubectl logs -n ai -l app=<service-name>

# Describe pod for events
kubectl describe pod -n ai <pod-name>
```

### 502 Bad Gateway

```bash
# Check ingress controller
kubectl get pods -n ingress-nginx

# Restart ingress
kubectl rollout restart deployment -n ingress-nginx ingress-nginx-controller
```

### Database connection issues

```bash
# Check PostgreSQL
kubectl logs -n ai langfuse-db-postgresql-0

# Restart PostgreSQL
kubectl rollout restart statefulset -n ai langfuse-db-postgresql
```

### Reset everything

```bash
k3d cluster delete ai-lab
rm -rf data/
./setup.sh
```

## Adding More Models

```bash
# Pull additional models
kubectl exec -n ai deploy/ollama -- ollama pull mistral
kubectl exec -n ai deploy/ollama -- ollama pull codellama

# Then add to charts/litellm/values.yaml and upgrade
helm upgrade litellm ./charts/litellm -n ai
```

## Hardware Requirements

| Resource | Minimum | Recommended |
| -------- | ------- | ----------- |
| RAM      | 8 GB    | 16 GB       |
| CPU      | 4 cores | 8 cores     |
| Disk     | 20 GB   | 50 GB       |

The llama3.2:1b model is optimized for CPU inference. For better performance with larger models, consider a machine with more RAM or a GPU.

## File Structure

```
AiLab/
├── setup.sh              # Main setup script
├── Makefile              # Daily operations (start/stop/test)
├── k3d-config.yaml       # k3d cluster configuration
├── .credentials          # Generated API keys (gitignored)
├── data/                 # Persistent data (gitignored)
├── charts/
│   ├── litellm/          # LiteLLM Helm chart
│   └── openwebui/        # Open WebUI Helm chart
├── storage-class.yaml    # Kubernetes storage class
├── persistent-volumes.yaml
├── postgres-values.yaml
├── langfuse.yaml
├── ollama.yaml
├── ingress-ai.yaml
└── dashboard-ingress.yml
```

## License

MIT
