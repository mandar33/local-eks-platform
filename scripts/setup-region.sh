#!/usr/bin/env bash
# Connects a second region (kind cluster region-b) to region A (dev-cluster).
# Run after kind-config-region-b.yaml is up with Istio installed. Safe to re-run.
#
#   scripts/setup-region.sh          everything below, in order
#   scripts/setup-region.sh argocd   register region-b with region A's Argo CD
#   scripts/setup-region.sh vault    let region-b's crud-api log in to Vault
#   scripts/setup-region.sh database region-b's own Postgres, managed by Vault
#   scripts/setup-region.sh lb       start the global load balancer on localhost:7080
#
# KUBECTL talks to region A, KUBECTL_B to region B (see scripts/lib.sh).
# The tokens created here are stored only in Kubernetes Secrets and Vault.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGION="${REGION:-region-b}"
KUBECTL_B="${KUBECTL_B:-kubectl --context kind-$REGION}"
REGION_API="https://$REGION-control-plane:6443"
LB_IMAGE="nginx:1.29-alpine"

# shellcheck disable=SC2086
kb() { $KUBECTL_B "$@"; }

# A long-lived ServiceAccount token in region B, created only once.
region_b_token() {
  local sa="$1" binding="$2" role="$3"
  kb get serviceaccount "$sa" -n kube-system >/dev/null 2>&1 || kb create serviceaccount "$sa" -n kube-system >/dev/null
  kb get clusterrolebinding "$binding" >/dev/null 2>&1 ||
    kb create clusterrolebinding "$binding" --clusterrole="$role" --serviceaccount="kube-system:$sa" >/dev/null
  kb apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $sa-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: $sa
type: kubernetes.io/service-account-token
EOF
  local token=""
  for _ in $(seq 1 20); do
    token="$(kb get secret "$sa-token" -n kube-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)"
    [[ -n "$token" ]] && break
    sleep 1
  done
  printf '%s' "$token"
}

region_b_ca_b64() { kb get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 | tr -d '\n'; }

setup_argocd() {
  log "Registering $REGION with Argo CD in region A"
  local token ca
  token="$(region_b_token argocd-manager argocd-manager cluster-admin)"
  ca="$(region_b_ca_b64)"
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$REGION
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: $REGION
  server: $REGION_API
  config: |
    {"bearerToken": "$token", "tlsClientConfig": {"caData": "$ca"}}
EOF
  unset token
  echo "Argo CD can now deploy to '$REGION' ($REGION_API)."
}

setup_vault() {
  log "Letting $REGION's workloads log in to Vault (auth mount kubernetes-$REGION)"
  load_root_token
  require_unsealed
  local auths reviewer ca_pem
  auths="$(vault_run auth list -format=json)"
  [[ "$auths" == *"\"kubernetes-$REGION/\""* ]] || vault_run auth enable -path="kubernetes-$REGION" kubernetes

  # Vault asks region B's API server to verify tokens, using this reviewer.
  reviewer="$(region_b_token vault-token-reviewer vault-token-reviewer system:auth-delegator)"
  ca_pem="$(kb get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}')"
  newline_escape() { sed -e ':a;N;$!ba;s/\n/\\n/g'; }
  printf '{"kubernetes_host":"%s","kubernetes_ca_cert":"%s","token_reviewer_jwt":"%s","disable_local_ca_jwt":true}' \
    "$REGION_API" "$(printf '%s' "$ca_pem" | newline_escape)" "$reviewer" |
    vault_cmd write "auth/kubernetes-$REGION/config" - >/dev/null
  unset reviewer

  write_region_role
}

# crud-api in the region logs in here and may read only the region's own
# database (see setup_database).
write_region_role() {
  vault_run write "auth/kubernetes-$REGION/role/crud-api" \
    bound_service_account_names=crud-api \
    bound_service_account_namespaces=default \
    audience=vault \
    token_policies="crud-api-$REGION" \
    token_ttl=1h >/dev/null
  echo "Vault role kubernetes-$REGION/crud-api issues read-only users for $REGION's own database."
}

# The region's own Postgres (Argo CD app region-b-postgres) and Vault's
# connection to it, through NodePort 30432 on the kind Docker network.
setup_database() {
  log "Connecting Vault to $REGION's own Postgres"
  load_root_token
  require_unsealed
  local conn="crud-$REGION-postgres" pw
  kb create namespace data --dry-run=client -o yaml | kb apply -f - >/dev/null
  if ! kb get secret postgres-admin -n data >/dev/null 2>&1; then
    kb create secret generic postgres-admin -n data --from-literal=password="$(random_secret)" >/dev/null
    kb label secret postgres-admin -n data app.kubernetes.io/managed-by=setup-region >/dev/null
    echo "Created data/postgres-admin in $REGION."
  fi

  echo "Waiting for postgres-0 in $REGION (deployed by the region-b-postgres Argo CD app)..."
  for _ in $(seq 1 60); do
    [[ "$(kb get pod postgres-0 -n data -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] && break
    sleep 5
  done
  kb wait pod/postgres-0 -n data --for=condition=Ready --timeout=10s >/dev/null

  if ! vault_run read "database/config/$conn" >/dev/null 2>&1; then
    pw="$(kb get secret postgres-admin -n data -o jsonpath='{.data.password}' | base64 -d)"
    printf '{"plugin_name":"postgresql-database-plugin","connection_url":"postgresql://{{username}}:{{password}}@%s-control-plane:30432/crud?sslmode=disable","username":"postgres","password":"%s","allowed_roles":["crud-api-%s"],"password_authentication":"scram-sha-256"}' \
      "$REGION" "$pw" "$REGION" | vault_cmd write "database/config/$conn" - >/dev/null
    unset pw
    vault_run write -f "database/rotate-root/$conn" >/dev/null
    echo "Connected Vault to $REGION's Postgres and rotated its admin password."
  fi

  vault_cmd write "database/roles/crud-api-$REGION" - >/dev/null <<JSON
{
  "db_name": "$conn",
  "creation_statements": [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT ON users_v1, users_v2 TO \"{{name}}\";"
  ],
  "default_ttl": "1h",
  "max_ttl": "24h"
}
JSON
  vault_cmd policy write "crud-api-$REGION" - >/dev/null <<HCL
path "database/creds/crud-api-$REGION" {
  capabilities = ["read"]
}
HCL
  write_region_role

  # A Vault token keeps the policies it was issued with; make the operator
  # in $REGION log in again so it picks up crud-api-$REGION.
  kb rollout restart deploy/vault-secrets-operator-controller-manager -n vault-secrets-operator-system >/dev/null
  echo "Vault issues $REGION's DB users at database/creds/crud-api-$REGION."
}

setup_lb() {
  log "Starting the global load balancer on localhost:7080"
  docker rm -f global-lb >/dev/null 2>&1 || true
  docker create --name global-lb --restart unless-stopped --network kind \
    -p 127.0.0.1:7080:7080 "$LB_IMAGE" >/dev/null
  local conf="$REPO_ROOT/platform/global-lb/nginx.conf"
  # Docker for Windows needs a Windows path (Git Bash path conversion is off).
  command -v cygpath >/dev/null 2>&1 && conf="$(cygpath -w "$conf")"
  docker cp "$conf" global-lb:/etc/nginx/nginx.conf
  docker start global-lb >/dev/null
  echo "http://localhost:7080 spreads requests across both regions and fails over."
}

case "${1:-all}" in
  argocd) setup_argocd ;;
  vault)  setup_vault ;;
  database) setup_database ;;
  lb)     setup_lb ;;
  all)    setup_argocd; setup_vault; setup_database; setup_lb ;;
  *)      echo "usage: $0 [argocd|vault|database|lb]" >&2; exit 2 ;;
esac
