#!/usr/bin/env bash
# Stores the GitHub token Kargo uses to commit image-tag promotions.
# The token goes into Vault (kv/kargo/github) and nowhere else. The Vault
# Secrets Operator copies it into the local-eks-platform namespace for Kargo.
#
# Create a *fine-grained* token first (GitHub > Settings > Developer settings >
# Fine-grained tokens):
#   Repository access: only mandar33/local-eks-platform
#   Permissions:       Contents: Read and write
#   Expiration:        as short as you're comfortable with
#
#   scripts/set-kargo-git-token.sh     prompts for the token (input hidden)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_URL="${REPO_URL:-https://github.com/mandar33/local-eks-platform.git}"
GITHUB_USER="${GITHUB_USER:-mandar33}"

load_root_token
require_unsealed

read -rsp "GitHub fine-grained token for $REPO_URL: " TOKEN; echo
[[ -n "$TOKEN" ]] || { echo "No token entered." >&2; exit 1; }

printf '{"data":{"repoURL":"%s","username":"%s","password":"%s"}}' "$REPO_URL" "$GITHUB_USER" "$TOKEN" |
  vault_cmd write kv/data/kargo/github - >/dev/null
unset TOKEN
echo "Saved to Vault at kv/kargo/github."

vault_cmd policy write kargo-git - >/dev/null <<'HCL'
path "kv/data/kargo/github" {
  capabilities = ["read"]
}
HCL
vault_run write auth/kubernetes/role/kargo-git \
  bound_service_account_names=kargo-git \
  bound_service_account_namespaces=local-eks-platform \
  audience=vault \
  token_policies=kargo-git \
  token_ttl=1h >/dev/null
echo "Vault role 'kargo-git' can read it. The Secret appears in local-eks-platform within a minute."
