# MetaMCP image BUILT FROM UNMODIFIED UPSTREAM SOURCE, pushed to
# ghcr.io/cristoslc/metamcp, and digest-pinned in metamcp/docker-compose.yml.
#
# Why build from source: upstream fixed our SSR crash ("sessionStorage is
# not defined" in DbOAuthClientProvider, breaking the mcp-servers/[uuid]
# page and OAuth reconnects) in PR #300 — merged 2026-06-14 as commit
# ecf354a8e8, which also carries PR #295 (server-side token exchange).
# Upstream NEVER published a GHCR image containing it: :latest still
# resolves to the v2.4.22-era index digest 6d5e0cba... and every v2.5.x tag
# has no images (verified 2026-09-21 via `docker buildx imagetools inspect`
# — "not found"). Only the merge chain contains the fix, so we build it
# ourselves, unmodified.
# Why unmodified: the moment we patch source files, we own a fork — merge
# conflicts on every re-pin, silent divergence, no upstream review. The
# Chromium deps in the runner stage are the ONLY delta from upstream's
# build (system libs baked into the rootfs; a volume/init container cannot
# inject /usr/lib). See
# docs/runbook/Active/(RUNBOOK-016)-AI-Chatbot-Stack-Upgrades/ for the
# fork-trigger policy and the expiry clause (revert to the upstream
# digest-bump fast path once upstream publishes images with the fixes).
#
# Source pin: METAMCP_SOURCE_SHA is an exact upstream commit. Started at
# ecf354a8e8 (Merge PR #300 SSR-safe OAuth provider, carrying #295); bumped
# 2026-09-21 to ff4ff2de9d (ai-dev tip) because that pin ships a broken
# oauth.repo cleanupExpired — `isNotNull(...).not()` crashes drizzle every
# 5 minutes (the correct form is isNull(), fixed in e29ce8f9f6 "bug
# fixes") — AND ships the 0014_oauth_refresh_token migration UNJOURNALED
# (journal still ends at 0013 in the ecf pin; fixed in 5f868084b3), so the
# runner's `pnpm install --prod` + drizzle journal skipped the
# refresh_token columns entirely. ff4ff2de9d (ai-dev tip, 2026-06-22)
# contains e29ce8f9f6 (both fixes) + 5f868084b3 (journal fix) + only a
# README edit on top; ai-dev carries 96 more unvetted commits on top, so
# this is the newest commit whose delta from ecf354a8e8 we have reviewed.
# Bump only by re-verifying the fix is present (grep the tree for the
# sessionStorage guard) and re-auditing the delta.
#
# Build steps mirror upstream's own Dockerfile at the pinned SHA (fetched
# 2026-09-21; identical to the default-branch version): uv:debian base,
# Node 20 + pnpm 10.12.0, `pnpm install --frozen-lockfile`, `pnpm build`
# (turbo: frontend + backend), then the runner assembly and
# `pnpm install --prod`. The only build-time deviation from upstream is
# the git clone (upstream COPYs from the repo working tree).

# Base pinned to the linux/amd64 MANIFEST digest of ghcr.io/astral-sh/uv:debian
# (per AGENTS.md IaC rule 6 / RUNBOOK-016 pin discipline — the index digest
# is not immutable). Resolved 2026-09-21:
#   docker buildx imagetools inspect ghcr.io/astral-sh/uv:debian
#   → linux/amd64 manifest = sha256:98d2a442cb4612eaf817783471383e073d51f34178e3bbcbbea829ee5d736ad9
FROM ghcr.io/astral-sh/uv:debian@sha256:98d2a442cb4612eaf817783471383e073d51f34178e3bbcbbea829ee5d736ad9 AS base

ARG METAMCP_SOURCE_SHA=ff4ff2de9d25453c52dcc7be32680b30700a6012

# Install Node.js and pnpm directly (mirrors upstream Dockerfile)
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm@10.12.0 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Fetch upstream source at the pinned SHA — UNMODIFIED, no local patches.
FROM base AS source
ARG METAMCP_SOURCE_SHA
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && git init /tmp/src \
    && git -C /tmp/src remote add origin https://github.com/metatool-ai/metamcp.git \
    && git -C /tmp/src fetch --depth 1 origin "${METAMCP_SOURCE_SHA}" \
    && git -C /tmp/src checkout FETCH_HEAD

# Install dependencies only when needed
FROM base AS deps
WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED 1

# Copy root package files (from the pinned upstream source)
COPY --from=source /tmp/src/package.json /tmp/src/pnpm-lock.yaml /tmp/src/pnpm-workspace.yaml ./
COPY --from=source /tmp/src/turbo.json ./

# Copy package.json files from all workspaces
COPY --from=source /tmp/src/apps/frontend/package.json ./apps/frontend/
COPY --from=source /tmp/src/apps/backend/package.json ./apps/backend/
COPY --from=source /tmp/src/packages/eslint-config/package.json ./packages/eslint-config/
COPY --from=source /tmp/src/packages/trpc/package.json ./packages/trpc/
COPY --from=source /tmp/src/packages/typescript-config/package.json ./packages/typescript-config/
COPY --from=source /tmp/src/packages/zod-types/package.json ./packages/zod-types/

# Install dependencies
RUN pnpm install --frozen-lockfile

# Builder stage
FROM base AS builder
WORKDIR /app

# Copy node_modules from deps stage (per-workspace node_modules included —
# workspace-local bins like packages/zod-types' tsup live there)
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/apps/frontend/node_modules ./apps/frontend/node_modules
COPY --from=deps /app/apps/backend/node_modules ./apps/backend/node_modules
COPY --from=deps /app/packages ./packages

# Copy source code (pinned upstream tree, unmodified)
COPY --from=source /tmp/src ./

# Build all packages and apps
RUN pnpm build

RUN sed -i -e "s/30000/600000/" \
    "node_modules/.pnpm/next@15.5.12_react-dom@19.2.4_react@19.2.4__react@19.2.4/node_modules/next/dist/server/lib/router-utils/proxy-request.js" \
    "node_modules/.pnpm/next@15.5.12_react-dom@19.2.4_react@19.2.4__react@19.2.4/node_modules/next/dist/esm/server/lib/router-utils/proxy-request.js"

# Production runner stage
FROM base AS runner
WORKDIR /app

# OCI image labels
LABEL org.opencontainers.image.source="https://github.com/metatool-ai/metamcp"
LABEL org.opencontainers.image.description="MetaMCP - aggregates MCP servers into a unified MetaMCP (unmodified upstream source @ pinned SHA + Chromium deps)"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.title="MetaMCP"

# Install curl for health checks
RUN apt-get update && apt-get install -y curl postgresql-client && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user with proper home directory
RUN addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 --home /home/nextjs nextjs \
    && mkdir -p /home/nextjs/.cache/node/corepack /home/nextjs/.cache/uv \
    && chown -R nextjs:nodejs /home/nextjs

# Chromium system deps (OUR layer — the only delta from upstream). The
# embedded @playwright/mcp STDIO server spawns headless Chromium from the
# /ms-playwright volume; its OS deps must be baked into the rootfs.
# Remove the stale nodesource repo first: its SHA1 GPG key is rejected on
# Debian 13 (trixie), breaking `apt-get update`.
USER root
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

# Copy built applications
COPY --from=builder --chown=nextjs:nodejs /app/apps/frontend/.next ./apps/frontend/.next
COPY --from=builder --chown=nextjs:nodejs /app/apps/frontend/package.json ./apps/frontend/
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/dist ./apps/backend/dist
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/package.json ./apps/backend/
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/drizzle ./apps/backend/drizzle
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/drizzle.config.ts ./apps/backend/

# Copy built packages
COPY --from=builder --chown=nextjs:nodejs /app/packages ./packages
COPY --from=builder --chown=nextjs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nextjs:nodejs /app/package.json ./
COPY --from=builder --chown=nextjs:nodejs /app/pnpm-workspace.yaml ./

# Install production dependencies only
RUN CI=true pnpm install --prod

# Install drizzle-kit locally in backend for migrations (entrypoint runs
# `pnpm exec drizzle-kit migrate` from apps/backend). A bare `pnpm add`
# at the runner stage rewrites the lockfile and trips pnpm's
# included-deps-conflict guard, npm chokes on workspace:*, and
# --ignore-workspace drops the @repo/* workspace deps the backend
# package.json references. Upstream needs drizzle-kit runnable from
# apps/backend at runtime; fetch just the package with pnpm into a
# scratch dir and link its dist into the backend's node_modules.
RUN cd /tmp && CI=true pnpm add --ignore-workspace drizzle-kit@0.31.9 \
    && mkdir -p /app/apps/backend/node_modules/drizzle-kit \
    && cp -r /tmp/node_modules/drizzle-kit/. /app/apps/backend/node_modules/drizzle-kit/ \
    && cp -r /tmp/node_modules/.bin/drizzle-kit /app/apps/backend/node_modules/.bin/ 2>/dev/null || true \
    && /app/apps/backend/node_modules/drizzle-kit/bin.cjs --version

# Copy startup script
COPY --from=source --chown=nextjs:nodejs /tmp/src/docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

USER nextjs

# Expose frontend port (Next.js)
EXPOSE 12008

# Health check
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:12008/health || exit 1

# Start both backend and frontend
CMD ["./docker-entrypoint.sh"]