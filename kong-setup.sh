#!/bin/bash
# =============================================================
# kong-setup.sh — Configura o Kong com planos Free/Básico/Pro
#
# Pré-requisito: Kong já rodando
# Uso: ./kong-setup.sh
# =============================================================

set -e

KONG_ADMIN="http://localhost:8001"
KEYCLOAK_URL="http://keycloak-svc:8080/realms/osrm"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Port-forward para o Admin do Kong (rode em outro terminal antes)
# kubectl port-forward -n osrm svc/kong-admin-svc 8001:8001

info "Verificando Kong..."
curl -sf "${KONG_ADMIN}/status" > /dev/null || { echo "Kong não acessível. Rode: kubectl port-forward -n osrm svc/kong-admin-svc 8001:8001"; exit 1; }

# =============================================================
# 1. SERVICE — aponta para o OSRM backend
# =============================================================
info "Criando service OSRM no Kong..."
curl -sf -X POST "${KONG_ADMIN}/services" \
  -d name=osrm-api \
  -d url=http://osrm-backend-svc:5000 | jq .

# =============================================================
# 2. ROUTES — endpoints da API
# =============================================================
info "Criando rotas..."

for ENDPOINT in route table nearest match trip tile; do
  curl -sf -X POST "${KONG_ADMIN}/services/osrm-api/routes" \
    -d "name=osrm-${ENDPOINT}" \
    -d "paths[]=/v1/${ENDPOINT}" \
    -d "strip_path=false" | jq .name
done

info "Rotas criadas!"

# =============================================================
# 3. PLUGIN — JWT (valida tokens do Keycloak)
# =============================================================
info "Habilitando plugin JWT..."
curl -sf -X POST "${KONG_ADMIN}/services/osrm-api/plugins" \
  -d name=jwt \
  -d config.claims_to_verify=exp | jq .

# =============================================================
# 4. PLUGIN — Key Auth (API Keys)
# =============================================================
info "Habilitando plugin Key Auth..."
curl -sf -X POST "${KONG_ADMIN}/services/osrm-api/plugins" \
  -d name=key-auth \
  -d config.key_names[]=X-API-Key \
  -d config.key_in_header=true \
  -d config.key_in_query=true | jq .

# =============================================================
# 5. CONSUMERS — um por plano
# =============================================================
info "Criando consumers por plano..."

# Plano Free
curl -sf -X POST "${KONG_ADMIN}/consumers" \
  -d username=plan-free \
  -d custom_id=plan-free | jq .username

# Plano Básico
curl -sf -X POST "${KONG_ADMIN}/consumers" \
  -d username=plan-basic \
  -d custom_id=plan-basic | jq .username

# Plano Pro
curl -sf -X POST "${KONG_ADMIN}/consumers" \
  -d username=plan-pro \
  -d custom_id=plan-pro | jq .username

# =============================================================
# 6. RATE LIMITING por plano
# =============================================================
info "Configurando rate limiting..."

# Free: 10 req/min
curl -sf -X POST "${KONG_ADMIN}/consumers/plan-free/plugins" \
  -d name=rate-limiting \
  -d config.minute=10 \
  -d config.policy=local | jq .

# Básico: 60 req/min
curl -sf -X POST "${KONG_ADMIN}/consumers/plan-basic/plugins" \
  -d name=rate-limiting \
  -d config.minute=60 \
  -d config.policy=local | jq .

# Pro: sem limite (10.000/min como teto de segurança)
curl -sf -X POST "${KONG_ADMIN}/consumers/plan-pro/plugins" \
  -d name=rate-limiting \
  -d config.minute=10000 \
  -d config.policy=local | jq .

# =============================================================
# 7. ACL — controle de região por plano
# =============================================================
info "Configurando ACL de regiões..."

# Grupos de acesso
for GROUP in region-state region-southeast region-brazil; do
  curl -sf -X POST "${KONG_ADMIN}/plugins" \
    -d name=acl \
    -d config.allow[]=${GROUP} > /dev/null
done

# Free: só 1 estado
curl -sf -X POST "${KONG_ADMIN}/consumers/plan-free/acls" \
  -d group=region-state | jq .

# Básico: região (ex: Sudeste)
curl -sf -X POST "${KONG_ADMIN}/consumers/plan-basic/acls" \
  -d group=region-state | jq .
curl -sf -X POST "${KONG_ADMIN}/consumers/plan-basic/acls" \
  -d group=region-southeast | jq .

# Pro: Brasil inteiro
curl -sf -X POST "${KONG_ADMIN}/consumers/plan-pro/acls" \
  -d group=region-state | jq .
curl -sf -X POST "${KONG_ADMIN}/consumers/plan-pro/acls" \
  -d group=region-southeast | jq .
curl -sf -X POST "${KONG_ADMIN}/consumers/plan-pro/acls" \
  -d group=region-brazil | jq .

# =============================================================
# 8. PLUGIN — Request Counter (métricas de uso)
# =============================================================
info "Habilitando Prometheus metrics..."
curl -sf -X POST "${KONG_ADMIN}/plugins" \
  -d name=prometheus | jq .

info "=== Kong configurado com sucesso! ==="
echo ""
echo "Planos disponíveis:"
echo "  FREE   — 10 req/min  | 1 estado"
echo "  BÁSICO — 60 req/min  | Região"
echo "  PRO    — Ilimitado   | Brasil"
echo ""
warn "Próximo passo: configure o Keycloak em auth.seudominio.com.br"
warn "Crie o realm 'osrm' e os roles: plan-free, plan-basic, plan-pro"
