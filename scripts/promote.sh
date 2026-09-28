#!/usr/bin/env bash
# Promote a release (frontend-api + crud-api, same version) to a Kargo stage.
#
#   scripts/promote.sh staging 1.2.8
#   scripts/promote.sh prod-a1 1.2.8     prod, wave 1 (the canary cell)
#
# Stages go in this order, and Kargo refuses to skip one:
#   dev -> staging -> prod-a1 -> prod-a2 -> prod-b1
# CI promotes to dev for you after your approval on GitHub. prod-a2 and
# prod-b1 promote themselves after 10 minutes in the wave before (Kargo
# ProjectConfig); promote.sh can still push them early by hand.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=local-eks-platform
STAGE="${1:-}" VERSION="${2:-}"
if [[ -z "$STAGE" || -z "$VERSION" ]]; then
  echo "usage: $0 <stage> <version>     stages: dev staging prod-a1 prod-a2 prod-b1" >&2
  exit 2
fi

# The Freight whose two images both carry this version.
freight="$(k get freight -n "$NS" \
  -o jsonpath="{range .items[*]}{.metadata.name}{' '}{.alias}{' '}{.images[*].tag}{'\n'}{end}" |
  awk -v v="$VERSION" 'NF == 4 && $3 == v && $4 == v { print $1, $2; exit }')"
if [[ -z "$freight" ]]; then
  echo "No Freight with frontend-api and crud-api both at $VERSION." >&2
  echo "Versions Kargo knows about:" >&2
  k get freight -n "$NS" -o jsonpath="{range .items[*]}{'  '}{.images[*].tag}{'\n'}{end}" | sort -u >&2
  exit 1
fi
name="${freight%% *}" alias="${freight##* }"
echo "Promoting $VERSION (Freight $alias) to $STAGE..."

promotion="$(k create -o name -f - <<EOF
apiVersion: kargo.akuity.io/v1alpha1
kind: Promotion
metadata:
  generateName: $STAGE-
  namespace: $NS
spec:
  stage: $STAGE
  freight: $name
EOF
)" || exit 1

for _ in $(seq 1 60); do
  phase="$(k get "$promotion" -n "$NS" -o jsonpath='{.status.phase}')"
  case "$phase" in
    Succeeded)
      echo "Done: $STAGE now runs frontend-api and crud-api $VERSION."
      echo "Kargo committed it to Git; run 'git pull' before your next commit."
      exit 0 ;;
    Failed|Errored|Aborted)
      echo "Promotion $phase: $(k get "$promotion" -n "$NS" -o jsonpath='{.status.message}')" >&2
      exit 1 ;;
  esac
  sleep 5
done
echo "Still running after 5 minutes: kubectl get $promotion -n $NS" >&2
exit 1
