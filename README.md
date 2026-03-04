# OSRM + Keycloak + Kong no K3s — Guia Completo

## Arquitetura

```
Cliente
   │
   ▼
Traefik (K3s Ingress)
   │
   ├── api.seudominio.com.br
   │       │
   │       ▼
   │   Kong API Gateway
   │   ├── Valida JWT / API Key
   │   ├── Rate Limiting por plano
   │   ├── ACL por região
   │   └── Métricas (Prometheus)
   │       │
   │       ▼
   │   OSRM Backend
   │
   ├── auth.seudominio.com.br
   │       └── Keycloak (login, planos, tokens)
   │               └── PostgreSQL
   │
   └── map.seudominio.com.br
           └── OSRM Frontend
```

---

## Planos

| Plano | Req/min | Região | Preço sugerido |
|-------|---------|--------|----------------|
| **Free** | 10 | 1 estado | Grátis |
| **Básico** | 60 | Sudeste | R$ 49/mês |
| **Pro** | Ilimitado | Brasil | R$ 149/mês |

---

## Requisitos

- VPS Hostinger **KVM 4** (4 vCPU / 16GB RAM)
- Ubuntu 22.04
- K3s instalado
- Arquivos OSRM processados localmente e hospedados

---

## Passo 1 — Instalar K3s

```bash
ssh root@IP_DA_VPS

apt update && apt upgrade -y

# Instala K3s
curl -sfL https://get.k3s.io | sh -

# Verifica
kubectl get nodes
```

---

## Passo 2 — Configurar kubectl local

```bash
scp root@IP_DA_VPS:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i 's/127.0.0.1/IP_DA_VPS/g' ~/.kube/config
kubectl get nodes
```

---

## Passo 3 — Editar variáveis

Antes do deploy, edite o `deploy.sh`:

```bash
DATA_URL="https://seusite.com.br/osrm/osrm-data.tar.gz"
DOMAIN_API="api.seudominio.com.br"
DOMAIN_AUTH="auth.seudominio.com.br"
DOMAIN_MAP="map.seudominio.com.br"
```

E troque as senhas em `01-secrets.yaml`:
```yaml
KEYCLOAK_ADMIN_PASSWORD: "SuaSenhaForte!"
POSTGRES_PASSWORD: "SuaSenhaForte!"
KONG_PG_PASSWORD: "SuaSenhaForte!"
```

---

## Passo 4 — Deploy

```bash
chmod +x deploy.sh kong-setup.sh
./deploy.sh
```

---

## Passo 5 — Configurar Keycloak

1. Acesse `http://auth.seudominio.com.br`
2. Login com as credenciais do `01-secrets.yaml`
3. Crie um novo **Realm** chamado `osrm`
4. Crie os **Roles**: `plan-free`, `plan-basic`, `plan-pro`
5. Para cada novo cliente pagante:
   - Crie um **User**
   - Atribua o **Role** do plano correspondente
   - O cliente usa o token JWT gerado pelo Keycloak para chamar a API

---

## Passo 6 — Usar a API

### Com JWT (login via Keycloak)
```bash
# 1. Obtém o token
TOKEN=$(curl -sf -X POST \
  "http://auth.seudominio.com.br/realms/osrm/protocol/openid-connect/token" \
  -d client_id=osrm-client \
  -d username=usuario@email.com \
  -d password=senha \
  -d grant_type=password | jq -r .access_token)

# 2. Chama a API
curl -H "Authorization: Bearer ${TOKEN}" \
  "http://api.seudominio.com.br/v1/route/driving/-46.6333,-23.5505;-43.1729,-22.9068"
```

### Com API Key
```bash
curl -H "X-API-Key: chave-do-cliente" \
  "http://api.seudominio.com.br/v1/route/driving/-46.6333,-23.5505;-43.1729,-22.9068"
```

---

## Consumo de RAM estimado (KVM 4 / 16GB)

| Serviço | RAM |
|---|---|
| OSRM backend | ~6–8 GB |
| Keycloak | ~512 MB |
| PostgreSQL (Keycloak) | ~256 MB |
| Kong | ~256 MB |
| PostgreSQL (Kong) | ~256 MB |
| K3s overhead | ~512 MB |
| **Total** | **~8–10 GB** |

Sobram ~6GB de folga no KVM 4. ✅

---

## Comandos úteis

```bash
# Ver todos os recursos
kubectl get all -n osrm

# Logs do Kong
kubectl logs -n osrm deployment/kong -f

# Logs do Keycloak
kubectl logs -n osrm deployment/keycloak -f

# Logs do OSRM
kubectl logs -n osrm deployment/osrm-backend -f

# Uso de RAM/CPU
kubectl top pods -n osrm

# Acessar Kong Admin localmente
kubectl port-forward -n osrm svc/kong-admin-svc 8001:8001

# Reiniciar um serviço
kubectl rollout restart deployment/osrm-backend -n osrm
```

---

## Integração com pagamento

Quando um cliente assinar um plano (via Stripe, Pagar.me, etc.):

1. Seu backend cria o usuário no Keycloak via API:
```bash
curl -X POST "http://auth.seudominio.com.br/admin/realms/osrm/users" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "cliente@email.com",
    "enabled": true,
    "realmRoles": ["plan-basic"]
  }'
```

2. Cria uma API Key no Kong:
```bash
curl -X POST "http://localhost:8001/consumers/plan-basic/key-auth" \
  -d key=chave-unica-do-cliente
```

3. Quando o plano vencer, desabilita o usuário no Keycloak e remove a API Key no Kong.
