# Self-hosted GitHub Actions runner for this repo, run as a Docker container on
# the laptop (scripts/setup-ci.sh). It builds images through the host's Docker,
# pushes them to Zot, and asks Kargo to promote. Every download is pinned by
# version and checked against a SHA-256.
FROM ubuntu:24.04

ARG RUNNER_VERSION=2.337.0
ARG RUNNER_SHA256=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613
ARG DOCKER_VERSION=29.8.1
ARG DOCKER_SHA256=d8db66739d2e28d4933786d73e918d9be643a67fbd835db1bf740d650a259e70
ARG BUILDX_VERSION=v0.37.1
ARG BUILDX_SHA256=9447199cdb435f25880548343c128a4b6650e8891ee598905d8d29d39a8e359b
ARG KUBECTL_VERSION=v1.35.9
ARG KUBECTL_SHA256=3cfeaf80be482b435b0aa214aff6e0b2c312ee23c0ff20810c75517b6004c6eb

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq libicu74 \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI + buildx plugin (the daemon is the host's, via the mounted socket)
RUN curl -fsSLo /tmp/docker.tgz https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz \
 && echo "${DOCKER_SHA256}  /tmp/docker.tgz" | sha256sum -c - \
 && tar -xzf /tmp/docker.tgz -C /tmp && mv /tmp/docker/docker /usr/local/bin/docker && rm -rf /tmp/docker* \
 && mkdir -p /usr/local/lib/docker/cli-plugins \
 && curl -fsSLo /usr/local/lib/docker/cli-plugins/docker-buildx https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64 \
 && echo "${BUILDX_SHA256}  /usr/local/lib/docker/cli-plugins/docker-buildx" | sha256sum -c - \
 && chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx

# kubectl within one minor version of the clusters (v1.34)
RUN curl -fsSLo /usr/local/bin/kubectl https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl \
 && echo "${KUBECTL_SHA256}  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod +x /usr/local/bin/kubectl

# The runner itself, as a non-root user. Group 0 lets it use the mounted Docker
# socket (root:root 660 on Docker Desktop). Docker socket access is effectively
# admin access to Docker: that is this runner's trust boundary.
RUN useradd -m -u 1001 -G 0 runner
USER runner
WORKDIR /home/runner/actions-runner
RUN curl -fsSLo runner.tgz https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
 && echo "${RUNNER_SHA256}  runner.tgz" | sha256sum -c - \
 && tar -xzf runner.tgz && rm runner.tgz \
 && mkdir -p /home/runner/.ci

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
ENTRYPOINT ["bash", "/home/runner/entrypoint.sh"]
