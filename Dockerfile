# MetaMCP image: Umbrella-IT-Group fork + Chromium system deps.
#
# Path D (RUNBOOK-016): the Umbrella fork (ghcr.io/umbrella-it-group/metamcp)
# is the primary MetaMCP image — it carries the OAuth fixes upstream never
# published (journaled 0014 migration, client_secret_basic exchange,
# reverse-proxy DCR, RFC issuer, consent screen, SSR-safe provider).
# It does NOT bake Chromium's OS deps, which the embedded @playwright/mcp
# STDIO server needs (browser_navigate fails with loader errors otherwise).
# This Dockerfile is a thin extension: Umbrella base + the exact apt set
# our earlier builds verified via `ldd chrome` (0 missing).
#
# The /ms-playwright browser lives in a NAMED VOLUME installed at deploy
# time (deploy_metamcp_stack) — the volume holds the browser revision,
# this image holds the system libs.
#
# Base pinned to the linux/amd64 manifest digest per RUNBOOK-016 pin
# discipline (the index digest is not immutable; the attestation manifest
# is Platform: unknown/unknown). Resolved 2026-09-22:
#   docker buildx imagetools inspect ghcr.io/umbrella-it-group/metamcp:latest
#   → linux/amd64 = ed1de394a5f4f6415e33ad094d51858a3804349171d27985b1779fdd4f015af9
FROM ghcr.io/umbrella-it-group/metamcp@sha256:ed1de394a5f4f6415e33ad094d51858a3804349171d27985b1779fdd4f015af9

USER root
# The base may ship a stale deb.nodesource.com repo whose SHA1 GPG key is
# rejected on Debian 13 (trixie), failing `apt-get update`. Remove it and
# its apt preferences before installing the Chromium deps.
RUN rm -f /etc/apt/sources.list.d/nodesource.list \
      /etc/apt/preferences.d/nodejs /etc/apt/preferences.d/nsolid \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libnspr4 \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    libpango-1.0-0 \
    libcairo2 \
    libx11-xcb1 \
    libxcb1 \
    libxext6 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*
