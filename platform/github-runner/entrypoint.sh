#!/usr/bin/env bash
# Registers the runner once (the registration token is single-use and expires
# after an hour), then runs it. Restarting the container keeps the registration.
set -euo pipefail
cd /home/runner/actions-runner

if [[ ! -f .runner ]]; then
  : "${RUNNER_URL:?set RUNNER_URL}" "${RUNNER_TOKEN:?set RUNNER_TOKEN}"
  ./config.sh --unattended --replace \
    --url "$RUNNER_URL" --token "$RUNNER_TOKEN" \
    --name "${RUNNER_NAME:-local-eks-runner}" \
    --labels local-eks-platform \
    --work _work
fi
unset RUNNER_TOKEN

exec ./run.sh
