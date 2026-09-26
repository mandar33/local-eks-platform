#!/usr/bin/env bash
# Sets up CI with GitHub Actions and a self-hosted runner in Docker.
# Run after bootstrap-vault.sh and setup-registry.sh, with `gh` logged in as
# the repo owner. Safe to re-run: it replaces the runner container.
#
#   scripts/setup-ci.sh            everything below
#   scripts/setup-ci.sh repo       repo safety settings + the "dev" approval environment
#   scripts/setup-ci.sh runner     (re)build and (re)start the runner container
#
# What the runner gets, and nothing more:
#   - a Vault token that can only read kv/registry/pusher (to push to Zot)
#   - a kubeconfig for ServiceAccount ci-promoter (read Freight, create Promotions)
# Both are copied into the container; they're never written to the repo, to
# GitHub secrets, or left on disk.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="${REPO:-mandar33/local-eks-platform}"
RUNNER_IMAGE="local-eks-runner:2.337.0"
RUNNER_NAME="local-eks-runner"
CLUSTER_API="https://dev-cluster-control-plane:6443"

setup_repo() {
  log "Repo settings for a self-hosted runner on a public repo"
  # The workflow never runs on pull requests; as a second layer, any outside
  # contributor's workflow run needs the owner's approval.
  gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" \
    -f approval_policy=all_external_contributors >/dev/null
  echo "Outside contributors' workflow runs need approval."

  # "dev" environment: the promote job waits here until you approve it.
  local me
  me="$(gh api user --jq .id)"
  gh api -X PUT "repos/$REPO/environments/dev" --input - >/dev/null <<EOF
{"reviewers": [{"type": "User", "id": $me}], "prevent_self_review": false}
EOF
  echo "Environment 'dev' requires your approval before promoting."
}

setup_runner() {
  log "Building the runner image"
  local ctx="$REPO_ROOT/platform/github-runner"
  command -v cygpath >/dev/null 2>&1 && ctx="$(cygpath -w "$ctx")"
  docker build -q -t "$RUNNER_IMAGE" "$ctx" >/dev/null
  echo "Built $RUNNER_IMAGE."

  log "Creating the runner's credentials"
  load_root_token
  require_unsealed
  vault_cmd policy write ci-registry - >/dev/null <<'HCL'
path "kv/data/registry/pusher" {
  capabilities = ["read"]
}
HCL
  local vault_token
  vault_token="$(vault_run token create -policy=ci-registry -ttl=720h -explicit-max-ttl=720h \
    -display-name=github-runner -field=token | tr -d '\r')"
  echo "Vault token (read kv/registry/pusher only, valid 30 days)."

  local sa_token ca
  for _ in $(seq 1 30); do
    sa_token="$(k get secret ci-promoter-token -n local-eks-platform -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)"
    [[ -n "$sa_token" ]] && break
    sleep 2
  done
  [[ -n "$sa_token" ]] || { echo "ci-promoter-token not found; is the kargo-dev app synced?" >&2; exit 1; }
  ca="$(k get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 | tr -d '\n')"

  local kubeconfig
  kubeconfig="apiVersion: v1
kind: Config
clusters:
- name: dev-cluster
  cluster:
    server: $CLUSTER_API
    certificate-authority-data: $ca
users:
- name: ci-promoter
  user:
    token: $sa_token
contexts:
- name: ci
  context:
    cluster: dev-cluster
    user: ci-promoter
    namespace: local-eks-platform
current-context: ci"

  log "Registering and starting the runner"
  local reg_token
  reg_token="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)"
  docker rm -f github-runner >/dev/null 2>&1 || true
  docker run -d --name github-runner --restart unless-stopped --network kind     -v /var/run/docker.sock:/var/run/docker.sock     -e RUNNER_URL="https://github.com/$REPO" -e RUNNER_TOKEN="$reg_token" -e RUNNER_NAME="$RUNNER_NAME"     "$RUNNER_IMAGE" >/dev/null
  unset reg_token

  # Written as the runner user over stdin: owned by it, mode 600, never on disk here.
  printf '%s' "$vault_token" | docker exec -i github-runner sh -c 'umask 077; cat > /home/runner/.ci/vault-token'
  printf '%s
' "$kubeconfig" | docker exec -i github-runner sh -c 'umask 077; cat > /home/runner/.ci/kubeconfig'
  unset vault_token sa_token kubeconfig

  for _ in $(seq 1 30); do
    docker logs github-runner 2>&1 | grep -q "Listening for Jobs" && break
    sleep 2
  done
  docker logs github-runner 2>&1 | grep -E "Runner successfully added|Listening for Jobs" || {
    echo "The runner didn't come up; see: docker logs github-runner" >&2; exit 1; }
}

case "${1:-all}" in
  repo)   setup_repo ;;
  runner) setup_runner ;;
  all)    setup_repo; setup_runner ;;
  *)      echo "usage: $0 [repo|runner]" >&2; exit 2 ;;
esac
