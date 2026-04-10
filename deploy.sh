#!/bin/bash

# =============================================================

# deploy.sh — Deploy local (Docker Desktop K8s)

# Keycloak + Kong + OSRM externo

# =============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

# =============================================================

# CONFIG

# =============================================================

OSRM_HOST="host.docker.internal"   # OSRM rodando na sua máquina
OSRM_PORT="3484"

# =============================================================

kubectl get nodes &>/dev/null || error "kubectl não configurado."

info "Cluster:"
kubectl get nodes

# =============================================================

# 1. Namespace + base

# =============================================================

step "1/5 — Namespace + base"
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-secrets.yaml
kubectl apply -f 02-pvcs.yaml
kubectl apply -f 03-configmaps.yaml

# =============================================================

# 2. PostgreSQL

# =============================================================

step "2/5 — PostgreSQL"
kubectl apply -f 04-postgres.yaml

info "Aguardando PostgreSQL..."
kubectl wait --for=condition=ready pod -l app=postgres-keycloak -n osrm --timeout=180s
kubectl wait --for=condition=ready pod -l app=postgres-kong -n osrm --timeout=180s

# =============================================================

# 3. Keycloak

# =============================================================

step "3/5 — Keycloak"
kubectl apply -f 05-keycloak.yaml

info "Aguardando Keycloak..."
kubectl wait --for=condition=ready pod -l app=keycloak -n osrm --timeout=300s

# =============================================================

# 4. Kong

# =============================================================

step "4/5 — Kong"
#kubectl apply -f 06-kong.yaml
kubectl apply -f 06-kong.yaml

info "Aguardando migrations..."
kubectl wait --for=condition=complete job/kong-migrations -n osrm --timeout=180s

info "Aguardando Kong..."
kubectl wait --for=condition=ready pod -l app=kong -n osrm --timeout=180s

# =============================================================

# 5. Configurar Kong (OSRM externo)

# =============================================================

step "5/5 — Configurando Kong com OSRM externo"

info "Abrindo port-forward do Kong Admin..."
kubectl port-forward -n osrm svc/kong-admin-svc 8001:8001 >/dev/null 2>&1 &
PF_PID=$!

sleep 5

info "Rodando setup do Kong..."
chmod +x kong-setup.sh
./kong-setup.sh ${OSRM_HOST}

kill $PF_PID 2>/dev/null || true

# =============================================================

# FINAL

# =============================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Deploy concluído (modo local) 🚀   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""

echo "Acessar Kong (proxy):"
echo "  kubectl port-forward -n osrm svc/kong-proxy 8000:80"
echo ""
echo "Depois testar:"
echo "  curl -H "X-API-Key: test-api-key-example" \"
echo "  http://localhost:8000/v1/route/..."

echo ""
kubectl get pods -n osrm
