#!/usr/bin/env bash
# Installs Vault + the Vault Secrets Operator and wires up dynamic Postgres
# credentials for crud-api. Safe to re-run.
#
#   scripts/bootstrap-vault.sh           install, init, unseal, configure
#   scripts/bootstrap-vault.sh unseal    unseal only (Vault seals on every restart)
#   scripts/bootstrap-vault.sh roles     (re)write the app login roles only
#   scripts/bootstrap-vault.sh databases a database per namespace in ENVIRONMENTS
#                                        (dev, staging, prod cells) + Vault access
#
# No secret is ever written to this repo:
# - The Vault unseal key and root token go to $STATE_DIR/vault-init.json
#   (default ~/.local-eks-platform, mode 600).
# - The Postgres admin password is random, stored only in the postgres-admin
#   Secret, and handed to Vault, which immediately rotates it. After that, only
#   Vault knows the admin password.
# - Secrets reach `vault` over stdin, never as command-line arguments.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
VAULT_CHART_VERSION="0.34.1"
VSO_CHART_VERSION="1.6.0"

unseal() {
  local status
  status="$(vault_status)"
  if [[ "$(json_field initialized <<<"$status")" != "true" ]]; then
    echo "Vault is not initialised yet; run without arguments first." >&2
    exit 1
  fi
  if [[ "$(json_field sealed <<<"$status")" == "true" ]]; then
    [[ -f "$INIT_FILE" ]] || { echo "Missing $INIT_FILE; cannot unseal." >&2; exit 1; }
    local key
    key="$(sed -n '/"unseal_keys_b64"/{n;s/.*"\([^"]*\)".*/\1/p;}' "$INIT_FILE")"
    printf '%s\n' "$key" | k exec -i -n vault vault-0 -- sh -c 'read -r K; vault operator unseal "$K" >/dev/null'
    echo "Vault unsealed."
    # While Vault was sealed the operator's Vault login went stale, and it can
    # stop renewing leases without recovering. A restart makes it log in again
    # and re-issue any credentials that expired in the meantime.
    if k get deploy vault-secrets-operator-controller-manager -n vault-secrets-operator-system >/dev/null 2>&1; then
      k rollout restart deploy/vault-secrets-operator-controller-manager -n vault-secrets-operator-system >/dev/null
      echo "Restarted the Vault Secrets Operator so it re-authenticates."
    fi
  else
    echo "Vault is already unsealed."
  fi
}

wait_for_pod_running() {
  local ns="$1" pod="$2"
  for _ in $(seq 1 60); do
    [[ "$(k get pod -n "$ns" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]] && return 0
    sleep 5
  done
  echo "Timed out waiting for $ns/$pod" >&2
  exit 1
}

# Which namespaces' crud-api may log in to Vault for DB credentials.
write_app_roles() {
  # Retired login roles: crud-api in default (before the dev namespace) and
  # crud-api-cells (the Crossplane cells). Nothing may log in with them.
  vault_run delete auth/kubernetes/role/crud-api >/dev/null
  vault_run delete auth/kubernetes/role/crud-api-cells >/dev/null

  # One role per namespace in ENVIRONMENTS (below), reading only that
  # namespace's database. A policy change reaches the Vault Secrets Operator
  # only when it logs in again: restart it (as `unseal` does) after a change.
  local env
  for env in "${ENVIRONMENTS[@]}"; do
    vault_run write "auth/kubernetes/role/crud-api-$env"       bound_service_account_names=crud-api       bound_service_account_namespaces="$env"       audience=vault       token_policies="crud-api-$env"       token_ttl=1h >/dev/null
  done
  echo "Vault roles written: crud-api-<ns> for: ${ENVIRONMENTS[*]}."
}

# Region A namespaces with their own database: the environments, then the
# prod cells in region A (bigtech profile). Region B's cell uses region B's
# own Postgres (scripts/setup-region.sh database).
ENVIRONMENTS=(dev staging prod-a1 prod-a2)

# psql as the postgres superuser over the pod's local socket (trusted inside
# the container only; from the network, Postgres requires a password).
psql_admin() { k exec -i -n data postgres-0 -- psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

# For each environment: database crud_<env> with the same tables and seed
# data as crud, a login vault_<env> that Vault uses to create short-lived
# users there (its password is rotated at once, so only Vault knows it), a
# Vault DB role crud-api-<env> and a policy that can read only that role.
setup_env_databases() {
  local env db admin conn password
  for env in "${ENVIRONMENTS[@]}"; do
    db="crud_${env//-/_}" admin="vault_${env//-/_}" conn="crud-$env-postgres"

    psql_admin -d postgres >/dev/null <<SQL
SELECT 'CREATE DATABASE $db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')\gexec
SQL
    psql_admin -d "$db" <<'SQL'
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS users_v1 (id INT PRIMARY KEY, standard_data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS users_v2 (id INT PRIMARY KEY, experimental_data JSONB NOT NULL);
INSERT INTO users_v1 VALUES
  (1, 'Alice (v1 schema)'),
  (2, 'Bob (v1 schema)')
ON CONFLICT DO NOTHING;
INSERT INTO users_v2 VALUES
  (1, '{"name": "Alice", "schema": "v2", "tier": "gold"}'),
  (2, '{"name": "Bob", "schema": "v2", "tier": "silver"}')
ON CONFLICT DO NOTHING;
SQL

    if ! vault_run read "database/config/$conn" >/dev/null 2>&1; then
      password="$(random_secret)"
      psql_admin -d "$db" <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$admin') THEN
    CREATE ROLE $admin LOGIN CREATEROLE;
  END IF;
END \$\$;
ALTER ROLE $admin PASSWORD '$password';
GRANT SELECT ON users_v1, users_v2 TO $admin WITH GRANT OPTION;
SQL
      printf '{"plugin_name":"postgresql-database-plugin","connection_url":"postgresql://{{username}}:{{password}}@postgres.data.svc.cluster.local:5432/%s?sslmode=disable","username":"%s","password":"%s","allowed_roles":["crud-api-%s"],"password_authentication":"scram-sha-256"}' \
        "$db" "$admin" "$password" "$env" | vault_cmd write "database/config/$conn" - >/dev/null
      unset password
      vault_run write -f "database/rotate-root/$conn" >/dev/null
      echo "Connected Vault to $db as $admin and rotated its password."
    fi

    vault_cmd write "database/roles/crud-api-$env" - >/dev/null <<JSON
{
  "db_name": "$conn",
  "creation_statements": [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT ON users_v1, users_v2 TO \"{{name}}\";"
  ],
  "revocation_statements": [
    "REVOKE SELECT ON users_v1, users_v2 FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";"
  ],
  "default_ttl": "1h",
  "max_ttl": "24h"
}
JSON
    vault_cmd policy write "crud-api-$env" - >/dev/null <<HCL
path "database/creds/crud-api-$env" {
  capabilities = ["read"]
}
HCL
    echo "Database $db ready; Vault issues its users at database/creds/crud-api-$env."
  done
}

if [[ "${1:-}" == "unseal" ]]; then
  unseal
  exit 0
fi

if [[ "${1:-}" == "roles" ]]; then
  load_root_token
  require_unsealed
  write_app_roles
  exit 0
fi

if [[ "${1:-}" == "databases" ]]; then
  load_root_token
  require_unsealed
  setup_env_databases
  write_app_roles
  exit 0
fi

log "Installing Vault and the Vault Secrets Operator"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null
# No --wait: a sealed Vault never reports Ready.
helm upgrade --install vault hashicorp/vault --version "$VAULT_CHART_VERSION" \
  -n vault --create-namespace -f "$REPO_ROOT/platform/vault/vault-values.yaml"
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --version "$VSO_CHART_VERSION" -n vault-secrets-operator-system --create-namespace --wait
wait_for_pod_running vault vault-0

log "Initialising Vault"
if [[ "$(vault_status | json_field initialized)" != "true" ]]; then
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  (umask 077; k exec -n vault vault-0 -- vault operator init \
    -key-shares=1 -key-threshold=1 -format=json >"$INIT_FILE")
  echo "Unseal key and root token saved to $INIT_FILE. Keep this file private."
else
  echo "Already initialised."
fi
unseal
load_root_token

log "Creating the Postgres admin password (only if missing)"
k create namespace data --dry-run=client -o yaml | k apply -f - >/dev/null
if ! k get secret postgres-admin -n data >/dev/null 2>&1; then
  k create secret generic postgres-admin -n data \
    --from-literal=password="$(random_secret)" >/dev/null
  k label secret postgres-admin -n data app.kubernetes.io/managed-by=bootstrap-vault >/dev/null
  echo "Created data/postgres-admin."
else
  echo "data/postgres-admin already exists."
fi

log "Waiting for Postgres (deployed by the postgres-dev Argo CD app)"
wait_for_pod_running data postgres-0
k wait pod/postgres-0 -n data --for=condition=Ready --timeout=300s >/dev/null

log "Configuring Vault"
mounts="$(vault_run secrets list -format=json)"
[[ "$mounts" == *'"database/"'* ]] || vault_run secrets enable database
auths="$(vault_run auth list -format=json)"
[[ "$auths" == *'"kubernetes/"'* ]] || vault_run auth enable kubernetes
vault_run write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null

# Connect Vault to Postgres once, then rotate the admin password so that
# only Vault knows it. Re-running skips this step.
if ! vault_run read database/config/crud-postgres >/dev/null 2>&1; then
  PG_ADMIN_PASSWORD="$(k get secret postgres-admin -n data -o jsonpath='{.data.password}' | base64 -d)"
  printf '{"plugin_name":"postgresql-database-plugin","connection_url":"postgresql://{{username}}:{{password}}@postgres.data.svc.cluster.local:5432/crud?sslmode=disable","username":"postgres","password":"%s","allowed_roles":["crud-api"],"password_authentication":"scram-sha-256"}' \
    "$PG_ADMIN_PASSWORD" | vault_cmd write database/config/crud-postgres - >/dev/null
  unset PG_ADMIN_PASSWORD
  vault_run write -f database/rotate-root/crud-postgres >/dev/null
  echo "Connected Vault to Postgres and rotated the admin password."
fi

# crud-api gets read-only users that expire after 1h (renewable up to 24h).
vault_cmd write database/roles/crud-api - >/dev/null <<'JSON'
{
  "db_name": "crud-postgres",
  "creation_statements": [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT ON users_v1, users_v2 TO \"{{name}}\";"
  ],
  "default_ttl": "1h",
  "max_ttl": "24h"
}
JSON

vault_cmd policy write crud-api - >/dev/null <<'HCL'
path "database/creds/crud-api" {
  capabilities = ["read"]
}
HCL

log "A database per environment"
setup_env_databases
write_app_roles

log "Done"
cat <<EOF
Vault is issuing Postgres credentials for crud-api.
  Check the Secret VSO created:   kubectl get secret crud-db -n dev
  Vault UI:                       kubectl port-forward -n vault svc/vault 8200:8200
                                  then http://localhost:8200 (root token in $INIT_FILE)
  After a cluster restart, run:   scripts/bootstrap-vault.sh unseal
EOF
