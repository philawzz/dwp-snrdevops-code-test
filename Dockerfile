# syntax=docker/dockerfile:1

# ── Stage 1: build ────────────────────────────────────────────────────────────
# Use a full Python image only for installing dependencies (build tools available).
FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea AS builder

# Install build dependencies needed to compile any C-extension packages.
# Pinned to a single RUN to keep the layer clean; removed after install via slim base.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy only the dependency manifest first – maximises Docker layer cache reuse.
# This layer is only invalidated when requirements.txt changes, not on app code changes.
COPY app/requirements.txt .

# Install into an isolated prefix so we can copy just the packages to the runtime stage.
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# ── Stage 2: runtime ──────────────────────────────────────────────────────────
# Minimal slim image – no compiler, no build tools, smaller attack surface.
FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea AS runtime

# Create a non-root user and group to run the application.
# Running as root inside a container is a significant security risk.
RUN groupadd --gid 1001 appgroup \
    && useradd --uid 1001 --gid appgroup --no-create-home appuser

WORKDIR /app

# Copy installed packages from the builder stage only – not the build toolchain.
COPY --from=builder /install /usr/local

# Copy application source code.
COPY app/ .

# Drop to the non-root user for all subsequent commands and at runtime.
USER appuser

# Document the port the application listens on (informational; does not publish it).
EXPOSE 8080

# Health check so container runtimes (and Kubernetes liveness probes) can verify
# the app is responding without needing an external probe definition.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz')"

# Run gunicorn as the application server.
# --workers: 2x CPU + 1 is a common starting point; kept at 2 for this single-core image.
# --access-logfile -: send access logs to stdout so they are captured by the container runtime.
# --error-logfile -: send error logs to stderr.
CMD ["gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "2", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
