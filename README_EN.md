# dsh Self-Hosting Guide

This repository provides a Docker runtime image for [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) (dsh), orchestrated via Docker Compose.

> **Quick start**: `cp .env.example .env` → edit → `./build.sh` → `docker compose -f compose.yml up -d --build`

---

## Table of Contents

- [Quick Start](#quick-start)
- [Building the Image](#building-the-image)
- [Running the Service](#running-the-service)
- [One-Shot Interactive Run](#one-shot-interactive-run)
- [Environment Variables](#environment-variables)
- [nginx Reverse Proxy](#nginx-reverse-proxy)
- [Data Persistence](#data-persistence)
- [License](#license)

---

## Quick Start

```sh
# 1. Copy the environment template and edit as needed
cp .env.example .env

# 2. Build the image (auto-fetches the submodule, injects the commit hash)
./build.sh

# 3. Start the Web service
docker compose -f compose.yml up -d --build
```

Open a browser at `http://<host>:3080` to reach the dsh Web UI.

---

## Building the Image

### Method 1: `build.sh` (recommended)

`build.sh` automatically fetches the latest commit of the `deepseek-harness` submodule and injects its hash as the image label:

```sh
# Default title "DSH Local Build"
./build.sh

# Custom title
./build.sh "My DSH"

# Custom loopback hostnames (comma-separated)
DSH_CLIENT_LOOPBACK_HOSTS="my.example.com" ./build.sh

# Custom image tag
DSH_TAG="dsh:mytag" ./build.sh
```

### Method 2: direct `docker build`

```sh
docker build \
  --build-arg DSH_CLIENT_COMMIT_HASH=$(git rev-parse HEAD) \
  --build-arg DSH_CLIENT_TITLE="My DSH" \
  --build-arg DSH_CLIENT_LOOPBACK_HOSTS="my.example.com" \
  -f Dockerfile -t dsh:local .
```

> **Placeholder hash**: if `DSH_CLIENT_COMMIT_HASH` is not passed, the UI label shows `0000000`. This is purely cosmetic and has no functional impact.

### Pulling upstream updates

This repo keeps out-of-tree Docker files on `main`. After the official submodule updates, simply run `./build.sh` — it automatically fetches the latest `deepseek-harness` commit and rebuilds the image.

Since the out-of-tree files are purely additive, rebasing produces no conflicts.

---

## Running the Service

```sh
# Build and start (detached)
docker compose -f compose.yml up -d --build

# Stop and remove the container
docker compose -f compose.yml down

# Follow the logs
docker compose -f compose.yml logs -f
```

### Key compose.yml settings

| Setting | Notes |
|---------|-------|
| Port mapping `3080:3081` | Host 3080 → nginx 3081 in the container |
| Volume `./dsh-data:/home/dsh` | Persists config, credentials, plugins |
| `restart: unless-stopped` | Auto-restart on crash |
| Default seccomp + Landlock | No `cap_add`, no `--security-opt` |

---

## One-Shot Interactive Run

Run a single command headlessly, bypassing nginx:

```sh
docker run --rm -it -v "$PWD/dsh-data:/home/dsh/.dsh" dsh:local headless "do a thing"
```

---

## Environment Variables

All customization is via environment variables; no personal configuration is committed to the repo.

### Build-time variables (require a rebuild)

| Variable | Default | Notes |
|----------|---------|-------|
| `DSH_CLIENT_TITLE` | `"DSH Local Build"` | UI title |
| `DSH_CLIENT_COMMIT_HASH` | `0000000` | Source commit hash (7–40 hex chars) |
| `DSH_CLIENT_LOOPBACK_HOSTS` | empty | Extra loopback hostnames, comma-separated |

### Runtime variables (no rebuild needed)

| Variable | Default | Notes |
|----------|---------|-------|
| `DSH_SYSLOG_ADDRESS` | empty | syslog UDP address (empty = no forwarding) |
| `DSH_HOME_HOST_PATH` | `./dsh-data` | Host data volume path |

> Full details: [`.env.example`](.env.example).

---

## nginx Reverse Proxy

### Why nginx?

The dsh web profile **only listens on `127.0.0.1:3080` inside the container** and is never exposed directly. nginx is the sole front door, listening on port 3081 and proxying traffic back to dsh.

### Host/Origin rewrite

nginx rewrites the `Host` and `Origin` headers of every request to `127.0.0.1:3080`, so dsh's `/api` trust fence always classifies proxied traffic as a **local loopback client**. This keeps the following working in non-loopback deployments:

- Regular `/api` RPC calls
- Loopback-pinned privileged configuration-plane methods
- `/api` WebSocket downlinks

### Security trade-off (deliberate)

This setup **disables** dsh's DNS-rebinding and cross-site defenses for anything that can reach port 3081. Keep the exported port on a trusted network. dsh itself stays bound to `127.0.0.1` inside the container and is never directly reachable.

### WebSocket / long-lived connections

nginx disables `proxy_buffering` and sets 1-hour read/write timeouts, supporting WebSocket/SSE upgrades and long-lived connections.

---

## Data Persistence

`$DSH_HOME` (`/home/dsh/.dsh` in the container) is bind-mounted to the host's `./dsh-data` directory. The following survives container rebuilds and image updates:

- Configuration files
- API credentials (file mode 0600 / dir 0700)
- Session state
- Installed plugins

> ⚠️ Treat `./dsh-data` as sensitive: back it up and restrict host access to it.

### Auto-reconciliation on version drift

On startup, if the dsh version has changed, the entrypoint automatically re-runs `pnpm install` for each persisted profile's plugin dependencies, keeping plugins compatible with the new core.

---

## License

This project is licensed under the [MIT License](LICENSE). See the LICENSE file for details.