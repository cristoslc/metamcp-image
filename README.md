# metamcp-image

MetaMCP image built from **unmodified upstream source**
([metatool-ai/metamcp](https://github.com/metatool-ai/metamcp)) at the
commit pinned in `Dockerfile` (`ARG METAMCP_SOURCE_SHA`), plus Chromium
system deps baked into the runner stage. Pushed by GitHub Actions to
`ghcr.io/cristoslc/metamcp`.

## Why this repo exists

Upstream fixed the SSR crash (`sessionStorage is not defined` in
`DbOAuthClientProvider`, PR #300, merge commit `ecf354a8e8`, 2026-06-14)
but never published a GHCR image containing it — `:latest` still points at
the v2.4.22-era index digest and every v2.5.x tag has no images. We build
unmodified source ourselves, on a native amd64 GitHub runner (local builds
segfault under arm64 emulation).

## Canonical source

The canonical Dockerfile lives in the **private Homelab repo** at
`services/ai-chatbot/metamcp/Dockerfile` (RUNBOOK-016 Path B). This vendored
copy drives CI and must be kept identical. No secrets live here — the
Dockerfile contains only pinned-SHA build steps.

## Operator flow (per RUNBOOK-016)

1. Bump `METAMCP_SOURCE_SHA` in `Dockerfile` (both copies) and commit.
2. Actions → **Build and push MetaMCP image** → Run workflow.
3. Record the linux/amd64 manifest digest from the job summary.
4. Bump the digest in Homelab `services/ai-chatbot/metamcp/docker-compose.yml`
   and redeploy cx33 (`docker compose pull metamcp && docker compose up -d`).

## Expiry clause

Revert to the upstream digest-bump fast path when upstream publishes GHCR
images containing the needed fixes again (see RUNBOOK-016 Path B).