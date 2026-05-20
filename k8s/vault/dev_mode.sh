#!/bin/bash
# Vault demo — runs via docker exec (no host vault CLI needed).
# Requires: docker compose up -d  (from observability/ dir)
# Run from repo root: bash k8s/vault/dev_mode.sh

set -euo pipefail

CONTAINER="tch-practice-vault-1"
# Helper: run vault commands inside the container
V() { docker exec -e VAULT_TOKEN=root -e VAULT_ADDR=http://127.0.0.1:8200 "$CONTAINER" vault "$@"; }

echo "Checking Vault container..."
if ! docker ps --format "{{.Names}}" | grep -q "^${CONTAINER}$"; then
    echo "ERROR: $CONTAINER is not running. Start it first:"
    echo "  cd observability && docker compose up -d"
    exit 1
fi
echo "Vault is up. Running demo..."

# ── 1. KV Secrets ────────────────────────────────────────────────────────────
echo ""
echo "==[1/3] KV Secrets — static payment credentials =="
V secrets enable -path=secret kv-v2 2>/dev/null || true

V kv put secret/payment-app \
  db_password="super-secret-prod-pw" \
  api_key="tch-api-key-abc123" \
  jwt_secret="jwt-signing-key-xyz" \
  stripe_key="sk_live_placeholder"

echo ""
echo "Reading full secret:"
V kv get secret/payment-app

echo ""
echo "Fetch single field (how an app reads it at startup):"
V kv get -field=db_password secret/payment-app

# ── 2. Dynamic PostgreSQL credentials ─────────────────────────────────────────
echo ""
echo "==[2/3] Dynamic DB Credentials — unique per instance, auto-expire =="
V secrets enable database 2>/dev/null || true

V write database/config/payments-db \
  plugin_name=postgresql-database-plugin \
  "connection_url=postgresql://{{username}}:{{password}}@postgres:5432/payments?sslmode=disable" \
  allowed_roles="payment-app-role" \
  username="vault" \
  password="vaultpassword"

V write database/roles/payment-app-role \
  db_name=payments-db \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

echo ""
echo "Credential #1 (unique username, 1h TTL):"
V read database/creds/payment-app-role

echo ""
echo "Credential #2 (different username, same role — blast radius isolation):"
V read database/creds/payment-app-role

# ── 3. Interview talking points ───────────────────────────────────────────────
echo ""
echo "==[3/3] Interview Talking Points =="
echo "  · Each pod gets a UNIQUE rotating DB credential — no shared passwords"
echo "  · Auto-expire after 1h — no manual rotation runbooks"
echo "  · In K8s: Vault Agent Injector reads pod annotations,"
echo "    writes secrets to /vault/secrets/ (tmpfs, never touches disk)"
echo "    See: k8s/vault/annotated-deployment.yaml"
echo "  · For IRSA: no static AWS keys — pod IAM role via service account"
echo "  · SOC2 audit: every secret read is logged in Vault audit log"
