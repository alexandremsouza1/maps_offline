#!/bin/bash
# =============================================================
# deploy.sh — OSRM completo com Keycloak + Kong no K3s
# Uso: ./deploy.sh
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
# CONFIGURAÇÕES — edite antes de rodar
# =============================================================
DATA_URL="https://seusite.com.br/osrm/osrm-data.tar.gz"
DOMAIN_API="api.seudominio.com.br"
DOMAIN_AUTH="auth.seudominio.com.br"
DOMAIN_MAP="map.seudominio.com.br"
# =============================================================

kubectl get nodes &>/dev/null || error "kubectl não configurado."

info "Node status:"
kubectl get nodes

# Substitui domínios e URLs nos manifests
sed -i "s|https://seusite.com.br/osrm/osrm-data.tar.gz|${DATA_URL}|g" 01-secrets.yaml
sed -i "s|api.seudominio.com.br|${DOMAIN_API}|g" 08-ingress.yaml
sed -i "s|auth.seudominio.com.br|${DOMAIN_AUTH}|g" 08-ingress.yaml
sed -i "s|map.seudominio.com.br|${DOMAIN_MAP}|g" 08-ingress.yaml

step "1/7 — Namespace e Secrets"
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-secrets.yaml
kubectl apply -f 02-pvcs.yaml
kubectl apply -f 03-configmaps.yaml

step "2/7 — PostgreSQL"
kubectl apply -f 04-postgres.yaml
info "Aguardando PostgreSQL..."
kubectl wait --for=condition=ready pod -l app=postgres-keycloak -n osrm --timeout=120s
kubectl wait --for=condition=ready pod -l app=postgres-kong -n osrm --timeout=120s

step "3/7 — Keycloak"
kubectl apply -f 05-keycloak.yaml
info "Aguardando Keycloak (pode demorar ~2min)..."
kubectl wait --for=condition=ready pod -l app=keycloak -n osrm --timeout=180s

step "4/7 — Kong (migrations + gateway)"
kubectl apply -f 06-kong.yaml
info "Aguardando migrations do Kong..."
kubectl wait --for=condition=complete job/kong-migrations -n osrm --timeout=120s
info "Aguardando Kong..."
kubectl wait --for=condition=ready pod -l app=kong -n osrm --timeout=120s

step "5/7 — Download dos dados OSRM"
kubectl apply -f 07-osrm.yaml
info "Aguardando download (pode demorar bastante dependendo do arquivo)..."
kubectl wait --for=condition=complete job/osrm-data-loader -n osrm --timeout=3600s \
  || error "Download falhou. Logs: kubectl logs -n osrm job/osrm-data-loader"
info "Aguardando OSRM backend..."
kubectl wait --for=condition=ready pod -l app=osrm-backend -n osrm --timeout=120s

step "6/7 — Ingress"
kubectl apply -f 08-ingress.yaml

step "7/7 — Configurando Kong (planos e plugins)"
kubectl port-forward -n osrm svc/kong-admin-svc 8001:8001 &
PF_PID=$!
sleep 5
chmod +x kong-setup.sh && ./kong-setup.sh
kill $PF_PID 2>/dev/null || true

echo ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Deploy concluído com sucesso!   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
echo "  API:       http://${DOMAIN_API}"
echo "  Auth:      http://${DOMAIN_AUTH}"
echo "  Mapa:      http://${DOMAIN_MAP}"
echo ""
echo "Próximos passos:"
echo "  1. Acesse http://${DOMAIN_AUTH} e configure o realm 'osrm' no Keycloak"
echo "  2. Crie os roles: plan-free, plan-basic, plan-pro"
echo "  3. Integre com seu sistema de pagamento (ex: Stripe, Pagar.me)"
echo ""
kubectl get all -n osrm
