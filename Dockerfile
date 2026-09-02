# syntax=docker/dockerfile:1
#
# deepseek-harness (dsh) — self-hosted runtime image.
#
# All decisions below were reached out-of-tree (this file is NOT tracked upstream;
# the official repo is consumed via `git pull --rebase` on a local `docker` branch):
#   * Multi-stage build: builder compiles everything (incl. the landlock-run native
#     addon); runtime is node:22-slim + pnpm + git, running as a non-root user.
#   * Sandbox: rely on Landlock. Under Docker >= 24 / kernel >= 5.13 the default
#     seccomp profile already allows landlock_create_ruleset/landlock_restrict_self,
#     so bwrap (which needs CLONE_NEWNS + CAP_SYS_ADMIN and is blocked by default
#     seccomp) probes fail and dsh transparently falls back to Landlock. No cap_add,
#     no --security-opt. On older hosts the sandbox fails CLOSED (loud, safe) — that
#     is the intended behaviour, not a silent downgrade.
#   * Full $DSH_HOME persistence: secrets/credentials/config/plugins live in the
#     mounted volume; the entrypoint auto-reconciles plugin deps on dsh version drift.
#   * Runtime plugin install requires pnpm + network to the npm registry; the
#     profile's pnpm-workspace.yaml (with allowBuilds for git-dep prepare scripts)
#     is part of the persisted volume.
#   * Web front door = nginx: the web profile's dsh binds 127.0.0.1:3080 only;
#     nginx listens on 3081 and proxies everything back to it, rewriting
#     Host/Origin to the loopback authority so dsh's /api browser-trust fence
#     always classifies proxied traffic as a local 127.0.0.1 client (see
#     nginx.conf for the deliberate security trade-off).
#
# Build (from repo root). The builder needs a source commit to label client
# artifacts (scripts/client-build-environment.ts normally runs `git rev-parse HEAD`,
# but .git is excluded from the build context — so we inject it instead). Pass the
# real value, or let the placeholder stand (it only labels the UI, never affects behaviour):
#   docker build -f Dockerfile -t dsh:local \
#     --build-arg DSH_CLIENT_COMMIT_HASH=$(git rev-parse HEAD) .
# Run (interactive one-shot, not the default web service):
#   docker run --rm -it -v "$PWD/dsh-data:/home/dsh/.dsh" dsh:local headless "do a thing"
# The default `web` profile runs dsh + nginx in one container; reach it on the
# nginx port (see compose.yml for the host mapping):
#
# NOTE: target platform is linux/amd64 (landlock-run is published for linux-x64/arm64;
# build on the matching arch). Use `docker buildx build --platform linux/amd64 ...` if needed.

# ---------------------------------------------------------------------------
# Builder: install workspace deps, compile native addon, build lib/ + web frontend
# ---------------------------------------------------------------------------
FROM node:22-bookworm AS builder

# Source commit injected at build time (see header). 7-40 hex; placeholder is valid.
ARG DSH_CLIENT_COMMIT_HASH=0000000

# Title
ARG DSH_CLIENT_TITLE=DSH Local Build

# Extra loopback hostnames for the /api Host fence (comma-separated; empty = none).
# See patch/packages/client/connection/src/loopback-hostname.ts.
ARG DSH_CLIENT_LOOPBACK_HOSTS=

# Pin pnpm to the version the repo declares (packageManager: pnpm@11.7.0).
ENV PNPM_HOME=/usr/local/pnpm
RUN corepack enable && corepack prepare pnpm@11.7.0 --activate
RUN pnpm config set registry https://registry.npmmirror.com

# Toolchain for the node-addon-landlock-run native build + git for plugin prepare scripts.
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ git ca-certificates musl-tools \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the repo (the deepseek-harness submodule; .dockerignore keeps node_modules/lib out).
COPY deepseek-harness/ ./

# Patch the code
COPY ./patch/ ./

# Frozen install keeps the build reproducible against pnpm-lock.yaml.
RUN pnpm install --frozen-lockfile

# 编译 Landlock 启动器（静态 musl）。仓库不提交预编译二进制，缺这一步
# 容器内 landlock-run 缺失，dsh 会 fail-closed 拒绝执行命令。
RUN pnpm --filter @deepseek-ai/node-addon-landlock-run-workspace run build:native

# Ensure any native addons (landlock-run) are compiled for this platform.
RUN pnpm rebuild

# Build every package (emits apps/cli/lib/bin.js) and the web frontend served by `dsh web`.
# DSH_CLIENT_COMMIT_HASH is set so the build does not need a .git checkout to run
# `git rev-parse HEAD`; the placeholder value only labels client artifacts.
ENV DSH_CLIENT_COMMIT_HASH=${DSH_CLIENT_COMMIT_HASH}
ENV DSH_CLIENT_TITLE=${DSH_CLIENT_TITLE}
ENV DSH_CLIENT_LOOPBACK_HOSTS=${DSH_CLIENT_LOOPBACK_HOSTS}
RUN pnpm run build
RUN pnpm run build:web

# ---------------------------------------------------------------------------
# Runtime: slim, non-root, pnpm present for runtime plugin reconcile
# ---------------------------------------------------------------------------
FROM node:22-slim AS runtime

ENV PNPM_HOME=/usr/local/pnpm
ENV HOME=/home/dsh
ENV DSH_HOME=/home/dsh/.dsh
# Keep the pnpm store inside the volume so rebuilds reuse it across container recreations.
ENV PNPM_STORE_DIR=/home/dsh/.dsh/.pnpm-store

RUN corepack enable && corepack prepare pnpm@11.7.0 --activate

# git: needed when profiles install git-dependency plugins (pnpm>=10 blocks prepare until allowBuilds).
# gosu: entrypoint drops from root (which owns/chowns the mounted volume) to the unprivileged user.
# nginx: the reverse-proxy front door for the web profile (see nginx.conf).
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  git gosu ca-certificates python3 python3-pip build-essential nginx \
  curl wget openssh-client iputils-ping traceroute \
  procps htop lsof \
  jq rsync zip unzip \
  less vim tree \
  && rm -rf /var/lib/apt/lists/*

# Non-root user. Fixed UID so host-side backups of the bind mount map cleanly.
RUN userdel -r node && useradd -m -u 1000 -g 100 -s /bin/sh dsh

WORKDIR /app

# Built artifacts + installed deps from the builder (workspace symlinks stay under /app).
COPY --from=builder /app /app

# 让 dsh 作为裸命令可用（/usr/local/bin 在默认 PATH 中）
RUN ln -s /app/apps/cli/lib/bin.js /usr/local/bin/dsh \
  && chmod +x /app/apps/cli/lib/bin.js

COPY entrypoint.sh /app/entrypoint.sh
COPY dsh-recover.js /app/dsh-recover.js
COPY nginx.conf /etc/nginx/nginx.conf
RUN chmod +x /app/entrypoint.sh

# Only nginx's port (3081) is reachable from outside; dsh itself stays bound to
# 127.0.0.1:3080 inside the container and is never exported directly.
EXPOSE 3081

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD sh -c 'code=$(curl -o /dev/null -s -w "%{http_code}" http://127.0.0.1:3081/ 2>/dev/null) || true; if [ -z "$code" ] || [ "$code" -ge 500 ]; then exit 1; else exit 0; fi'

# Entrypoint starts as root (chowns the volume, runs nginx) then launches the
# web profile's dsh as `dsh` via gosu. Other profiles stay single-process.
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["web"]
