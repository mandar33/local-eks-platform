#!/usr/bin/env bash
# Wires up the Zot registry (k8s-manifests/environments/dev/registry/).
# Run after scripts/bootstrap-vault.sh. Safe to re-run.
#
#   scripts/setup-registry.sh          everything below, in order
#   scripts/setup-registry.sh vault    create the push login in Vault (kv/registry/*)
#   scripts/setup-registry.sh nodes    let the kind nodes pull localhost:5001/* from Zot
#   scripts/setup-registry.sh port     expose Zot on localhost:5001 (older clusters only)
#   scripts/setup-registry.sh login    docker login localhost:5001, password read from Vault
#
# The push password is random, stored only in Vault, and handed to
# `docker login` on stdin. Zot gets just its bcrypt hash.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLUSTER="${CLUSTER:-dev-cluster}"
REGISTRY="localhost:5001"
NODE_PORT=30500
PUSH_USER="pusher"
SOCAT_IMAGE="alpine/socat:1.8.1.3"

setup_vault() {
  log "Storing the registry push login in Vault"
  load_root_token
  require_unsealed

  local mounts
  mounts="$(vault_run secrets list -format=json)"
  [[ "$mounts" == *'"kv/"'* ]] || vault_run secrets enable -path=kv kv-v2

  if vault_run kv get -mount=kv registry/pusher >/dev/null 2>&1; then
    echo "kv/registry/pusher already exists; keeping it."
  else
    local password hash
    password="$(random_secret)"
    # bcrypt the password in a throwaway pod; the password goes in on stdin.
    hash="$(printf '%s\n' "$password" | k run zot-htpasswd -n registry --rm -i --quiet \
      --restart=Never --image=httpd:2.4-alpine --command -- htpasswd -niBC 12 "$PUSH_USER" | tr -d '\r' | grep "^$PUSH_USER:")"
    printf '{"data":{"username":"%s","password":"%s"}}' "$PUSH_USER" "$password" |
      vault_cmd write kv/data/registry/pusher - >/dev/null
    printf '{"data":{"htpasswd":"%s"}}' "$hash" |
      vault_cmd write kv/data/registry/htpasswd - >/dev/null
    unset password hash
    echo "Created kv/registry/pusher and kv/registry/htpasswd."
  fi

  # Zot's ServiceAccount may read only the htpasswd hash, never the password.
  vault_cmd policy write zot - >/dev/null <<'HCL'
path "kv/data/registry/htpasswd" {
  capabilities = ["read"]
}
HCL
  vault_run write auth/kubernetes/role/zot \
    bound_service_account_names=zot \
    bound_service_account_namespaces=registry \
    audience=vault \
    token_policies=zot \
    token_ttl=1h >/dev/null
  echo "Vault role 'zot' can read the htpasswd hash."
}

setup_nodes() {
  log "Pointing the kind nodes' containerd at Zot"
  echo "Waiting for Zot's TLS certificate (created by the registry-dev Argo CD app)..."
  k wait certificate/zot-tls -n registry --for=condition=Ready --timeout=300s >/dev/null
  local ca
  ca="$(k get secret registry-ca -n registry -o jsonpath='{.data.ca\.crt}' | base64 -d)"

  local dir="/etc/containerd/certs.d/$REGISTRY"
  local node
  for node in $(kind get nodes --name "$CLUSTER"); do
    docker exec "$node" mkdir -p "$dir"
    printf '%s\n' "$ca" | docker exec -i "$node" sh -c "cat > '$dir/ca.crt'"
    docker exec -i "$node" sh -c "cat > '$dir/hosts.toml'" <<EOF
server = "https://$REGISTRY"

[host."https://$CLUSTER-control-plane:$NODE_PORT"]
  capabilities = ["pull", "resolve"]
  ca = "$dir/ca.crt"
EOF
    if ! docker exec "$node" grep -q 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml; then
      docker exec "$node" sh -c 'printf "\n[plugins.\"io.containerd.grpc.v1.cri\".registry]\n  config_path = \"/etc/containerd/certs.d\"\n" >> /etc/containerd/config.toml && systemctl restart containerd'
      echo "$node: enabled registry mirrors and restarted containerd"
    else
      echo "$node: mirror config updated"
    fi
  done
}

setup_port() {
  log "Exposing Zot on $REGISTRY"
  if curl -sk -o /dev/null "https://$REGISTRY/v2/"; then
    echo "$REGISTRY already answers (kind-config.yaml maps it on new clusters)."
    return
  fi
  # Clusters created before kind-config.yaml mapped port 5001 need a small
  # TCP relay on the kind network. TLS passes straight through it.
  docker rm -f zot-proxy >/dev/null 2>&1 || true
  docker run -d --name zot-proxy --restart unless-stopped --network kind \
    -p "127.0.0.1:5001:5001" "$SOCAT_IMAGE" \
    tcp-listen:5001,fork,reuseaddr "tcp-connect:$CLUSTER-control-plane:$NODE_PORT" >/dev/null
  echo "Started zot-proxy: $REGISTRY -> $CLUSTER-control-plane:$NODE_PORT"
}

docker_login() {
  log "Logging Docker in to $REGISTRY"
  load_root_token
  require_unsealed
  vault_run kv get -mount=kv -field=password registry/pusher |
    docker login "$REGISTRY" --username "$PUSH_USER" --password-stdin
}

case "${1:-all}" in
  vault) setup_vault ;;
  nodes) setup_nodes ;;
  port)  setup_port ;;
  login) docker_login ;;
  all)   setup_vault; setup_nodes; setup_port; docker_login ;;
  *)     echo "usage: $0 [vault|nodes|port|login]" >&2; exit 2 ;;
esac
