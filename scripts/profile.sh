#!/usr/bin/env bash
# Switch which prod the platform runs. dev, staging and the shared services
# stay as they are.
#
#   scripts/profile.sh            show the active profile
#   scripts/profile.sh bigtech    prod = cells prod-a1, prod-a2 (region A) and
#                                 prod-b1 (region B), released in waves
#   scripts/profile.sh small      prod = one copy in region B, 2 replicas + canary
#
# Changes one line in k8s-manifests/argocd/profile.yaml, commits and pushes it
# (Argo CD removes the old prod and deploys the new one), then restarts
# global-lb with the matching config. See notes/environments-design.md.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FILE="k8s-manifests/argocd/profile.yaml"
cd "$REPO_ROOT"
current="$(sed -n 's#^ *path: k8s-manifests/profiles/##p' "$FILE")"
target="${1:-}"

if [[ -z "$target" ]]; then
  echo "Active profile: $current"
  exit 0
fi
if [[ ! -f "k8s-manifests/profiles/$target/apps.yaml" ]]; then
  echo "usage: $0 [bigtech|small]   (no profile named '$target')" >&2
  exit 2
fi
if [[ "$target" == "$current" ]]; then
  echo "Profile $target is already active."
  exit 0
fi
if ! git diff --quiet -- "$FILE" || ! git diff --cached --quiet -- "$FILE"; then
  echo "$FILE has uncommitted changes; commit or revert them first." >&2
  exit 1
fi

# On Windows, git in Git Bash can't verify GitHub's certificate when antivirus
# scans HTTPS; the Windows certificate store (schannel) can.
git_() { if [[ "$(uname -s)" == MINGW* ]]; then git -c http.sslBackend=schannel "$@"; else git "$@"; fi; }

log "Switching prod from $current to $target"
git_ pull -q --rebase --autostash
sed -i "s#^\( *path: k8s-manifests/profiles/\).*#\1$target#" "$FILE"
git add "$FILE"
git commit -q -m "profile: $target"
git_ push -q
echo "Committed and pushed 'profile: $target'."

# Ask Argo CD to look now instead of in a few minutes.
k annotate application root profile -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null || true

PROFILE="$target" bash "$REPO_ROOT/scripts/setup-region.sh" lb

cat <<EOF

Argo CD is switching prod now (about a minute). Watch it with:
  kubectl get applications -n argocd -w
The new prod runs the image tags in its values files. Kargo's new prod stage(s)
start without history; promote the next release as usual:
EOF
case "$target" in
  bigtech) echo "  scripts/promote.sh prod-a1 <version>   (prod-a2 and prod-b1 follow after 10 minutes each)" ;;
  small)   echo "  scripts/promote.sh prod <version>" ;;
esac
