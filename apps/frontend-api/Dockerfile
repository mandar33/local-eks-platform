# Build stage: Chainguard's -dev image has pip; dependencies go into a venv.
FROM cgr.dev/chainguard/python:latest-dev@sha256:eb0d45dfc69fecb471d2eaee7a8eea281bf860578ef44cb85db1bfa8165c47fe AS build
WORKDIR /app
RUN python -m venv /app/venv
COPY requirements.txt .
RUN /app/venv/bin/pip install --no-cache-dir -r requirements.txt
# pip is only needed to build; removing it drops its bundled packages (and their CVEs).
RUN /app/venv/bin/python -m pip uninstall -y pip

# Runtime stage: Python only. No shell, no package manager, runs as non-root (65532).
FROM cgr.dev/chainguard/python:latest@sha256:565af762d7f3efedc4e60d7ac7815e41588211d3f5757be33d8303e915ee6c72
WORKDIR /app
COPY --from=build /app/venv /app/venv
COPY main.py .
# Port must match containerPort / targetPort in the base-api chart.
EXPOSE 8000
ENTRYPOINT ["/app/venv/bin/uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
