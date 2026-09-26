#!/usr/bin/env bash
# Shows when this platform's credentials and certificates expire.
#
#   scripts/check-expiry.sh
#
# Secrets never leave Vault: the GitHub token is checked from inside the Vault
# pod, and only GitHub's expiry header is printed.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_root_token
require_unsealed

printf '%-34s %-26s %s\n' "WHAT" "EXPIRES (UTC)" "WHEN IT EXPIRES, RUN"

ci="$(vault_run list -format=json auth/token/accessors | tr -d '[]" \r' | tr ',' '\n' | while read -r a; do
  [[ -z "$a" ]] && continue
  info="$(vault_run token lookup -format=json -accessor "$a" 2>/dev/null || true)"
  if [[ "$info" == *'"display_name": "token-github-runner"'* ]]; then
    json_field expire_time <<<"$info"
  fi
done | sort | tail -n1)"
ci="${ci%%.*}"; [[ -n "$ci" ]] && ci="${ci%Z}Z"
printf '%-34s %-26s %s\n' "CI runner's Vault token" "${ci:-not found}" "scripts/setup-ci.sh runner"

gh_exp="$({ printf '%s\n' "$ROOT_TOKEN"; } | k exec -i -n vault vault-0 -- sh -c \
  'read -r VAULT_TOKEN; export VAULT_TOKEN
   P=$(vault kv get -mount=kv -field=password kargo/github 2>/dev/null) || exit 0
   wget -S -q -O /dev/null --header "Authorization: Bearer $P" https://api.github.com/rate_limit 2>&1 \
     | sed -n "s/.*github-authentication-token-expiration: //p"' | tr -d '\r')"
printf '%-34s %-26s %s\n' "Kargo's GitHub token" "${gh_exp:-no expiry reported}" "new token on GitHub, then scripts/set-kargo-git-token.sh"

k get certificate -n registry -o jsonpath='{range .items[*]}{.metadata.name} {.status.notAfter}{"\n"}{end}' |
  while read -r name after; do
    printf '%-34s %-26s %s\n' "Certificate $name" "$after" "nothing: cert-manager renews it"
  done
