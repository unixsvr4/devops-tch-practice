### HashiCorp Vault — Local Practice

# Run Vault in dev mode locally (Docker)
docker run --cap-add=IPC_LOCK \
  -e VAULT_DEV_ROOT_TOKEN_ID=root \
  -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  -p 8200:8200 \
  vault:latest

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

# Enable the KV secrets engine
vault secrets enable -path=secret kv-v2

# Write a secret
vault kv put secret/payment-app db_password="supersecret" api_key="abc123"

# Read it back
vault kv get secret/payment-app
vault kv get -field=db_password secret/payment-app

# Enable dynamic secrets for PostgreSQL
vault secrets enable database
vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@localhost:5432/mydb" \
  allowed_roles="app-role" \
  username="vault" \
  password="vaultpassword"

vault write database/roles/app-role \
  db_name=postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

# Generate a dynamic credential (expires in 1h)
vault read database/creds/app-role
# Returns: username=v-app-role-xyz, password=A1B2C3...  ← rotates automatically
