#!/usr/bin/env bash
# Installs Vault + the Vault Secrets Operator and wires up dynamic Postgres
# credentials for crud-api. Safe to re-run.
#
#   scripts/bootstrap-vault.sh           install, init, unseal, configure
#   scripts/bootstrap-vault.sh unseal    unseal only (Vault seals on every restart)
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

if [[ "${1:-}" == "unseal" ]]; then
  unseal
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

vault_run write auth/kubernetes/role/crud-api \
  bound_service_account_names=crud-api \
  bound_service_account_namespaces=default \
  audience=vault \
  token_policies=crud-api \
  token_ttl=1h >/dev/null

log "Done"
cat <<EOF
Vault is issuing Postgres credentials for crud-api.
  Check the Secret VSO created:   kubectl get secret crud-db -n default
  Vault UI:                       kubectl port-forward -n vault svc/vault 8200:8200
                                  then http://localhost:8200 (root token in $INIT_FILE)
  After a cluster restart, run:   scripts/bootstrap-vault.sh unseal
EOF
