#!/usr/bin/env bash
# Ask Flipt about the enable-new-schema flag, the same way frontend-api does.
#
#   scripts/flag.sh 1              is the flag on for user 1?
#   scripts/flag.sh 2 beta         ...for user 2, who is on the "beta" plan?
#   scripts/flag.sh users          users 1 to 8 at once
#
# Flipt is only reachable inside the cluster, so this runs curl from a small
# pod called flag-check (created the first time, reused after).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FLAG="${FLAG:-enable-new-schema}"
URL="http://flipt.default.svc.cluster.local:8080/evaluate/v1/boolean"

ensure_pod() {
  if ! k get pod flag-check -n default >/dev/null 2>&1; then
    k run flag-check -n default --image=curlimages/curl --restart=Never --command -- sleep 86400 >/dev/null
  fi
  k wait pod/flag-check -n default --for=condition=Ready --timeout=120s >/dev/null
}

ask() {
  local user="$1" plan="${2:-}" context="{}" answer enabled reason
  [[ -n "$plan" ]] && context="{\"plan\":\"$plan\"}"
  answer="$(k exec -n default flag-check -c flag-check -- curl -s -X POST "$URL" \
    -H 'Content-Type: application/json' \
    -d "{\"namespaceKey\":\"default\",\"flagKey\":\"$FLAG\",\"entityId\":\"$user\",\"context\":$context}")"
  enabled="$(grep -oE '"enabled": ?(true|false)' <<<"$answer" | grep -oE 'true|false' || true)"
  reason="$(grep -oE '"reason": ?"[A-Z_]+"' <<<"$answer" | grep -oE '[A-Z_]{3,}' || true)"
  if [[ -z "$enabled" ]]; then
    echo "user $user: no answer from Flipt: $answer" >&2
    return 1
  fi
  case "$reason" in
    DEFAULT_EVALUATION_REASON) reason="no rule matched, so the flag's default" ;;
    MATCH_EVALUATION_REASON)   reason="a rollout rule matched" ;;
  esac
  printf 'user %-3s %-10s %-4s (%s)\n' "$user" "${plan:+[$plan]}" "$([[ $enabled == true ]] && echo ON || echo off)" "$reason"
}

ensure_pod
case "${1:-}" in
  "")    echo "usage: $0 <user-id> [plan] | users" >&2; exit 2 ;;
  users) for u in 1 2 3 4 5 6 7 8; do ask "$u"; done ;;
  *)     ask "$1" "${2:-}" ;;
esac
