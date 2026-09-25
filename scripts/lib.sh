# Shared helpers for the scripts in this directory. Source it; don't run it.
#
# KUBECTL lets you swap the kubectl command, for example to run through the
# kind control-plane container when a local proxy blocks the API server:
#   KUBECTL="docker exec -i dev-cluster-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf"

# Git Bash rewrites arguments that look like /unix/paths; we pass many to
# containers, so turn that off.
export MSYS_NO_PATHCONV=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-$HOME/.local-eks-platform}"
INIT_FILE="$STATE_DIR/vault-init.json"
KUBECTL="${KUBECTL:-kubectl}"

# Word-splitting of $KUBECTL is intended.
# shellcheck disable=SC2086
k() { $KUBECTL "$@"; }

log() { printf '\n==> %s\n' "$*"; }

random_secret() { head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32; }

json_field() { sed -n "s/.*\"$1\": *\"\{0,1\}\([^\",]*\)\"\{0,1\}.*/\1/p" | head -n1; }

# Run `vault` inside the pod. The token goes in as the first stdin line;
# anything piped into this function follows it (for `vault ... -`).
vault_cmd() {
  { printf '%s\n' "${ROOT_TOKEN:-}"; cat; } |
    k exec -i -n vault vault-0 -- sh -c \
      'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' vault "$@"
}
vault_run() { vault_cmd "$@" </dev/null; }

vault_status() { k exec -n vault vault-0 -- vault status -format=json 2>/dev/null || true; }

load_root_token() {
  [[ -f "$INIT_FILE" ]] || { echo "Missing $INIT_FILE. Run scripts/bootstrap-vault.sh first." >&2; exit 1; }
  ROOT_TOKEN="$(json_field root_token <"$INIT_FILE")"
}

require_unsealed() {
  if [[ "$(vault_status | json_field sealed)" != "false" ]]; then
    echo "Vault is sealed or unreachable. Run scripts/bootstrap-vault.sh unseal first." >&2
    exit 1
  fi
}
