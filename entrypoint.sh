#!/bin/sh
# dsh container entrypoint.
#
# Two roles:
#   1. Root (default) — own the mounted $DSH_HOME (and HOME) so the unprivileged
#      user can write credentials/config/plugins into it, then launch:
#        * web profile (the default `web`): dsh as the `dsh` user behind the
#          bundled nginx reverse proxy. dsh stays on 127.0.0.1:3080; nginx owns
#          the exported port 3081 and rewrites Host/Origin to loopback so the
#          /api browser-trust fence always classifies proxied traffic as a
#          local 127.0.0.1 client (see nginx.conf).
#        * any other profile (e.g. `headless "job"`): re-exec as `dsh` and run
#          the single foreground process, preserving the one-shot behaviour.
#   2. As `dsh` — on dsh version drift, re-resolve each persisted profile's
#      plugin dependencies against the new core; then exec the requested profile.

set -eu

DSH_USER=dsh
DSH_UID=1000
DSH_GID=100
DSH_BIN=/app/apps/cli/lib/bin.js
DSH_PKG=/app/apps/cli/package.json
DSH_RECOVER=/app/dsh-recover.js

# ---------------------------------------------------------------------------
# Phase 1 — root: own the volume, then launch the requested profile.
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
  mkdir -p "$DSH_HOME" "$HOME"
  # chown -R "$DSH_UID:$DSH_GID" "$DSH_HOME" "$HOME"

  # The web profile (the default) runs dsh + nginx in this container. Accept
  # both the `web` alias and the equivalent `--profile web` form.
  if [ "$#" -eq 0 ] || [ "$1" = "web" ] || { [ "$1" = "--profile" ] && [ "${2:-}" = "web" ]; }; then
    # Fail loud on a broken proxy config before anything else starts.
    nginx -t
    # dsh first so it has a head start on binding 127.0.0.1:3080.
    gosu "$DSH_USER" "$0" "$@" &
    DSH_PID=$!
    nginx -g 'daemon off;' &
    NGINX_PID=$!
    # Forward TERM/INT to both children; dsh owns the graceful teardown.
    trap 'kill -TERM "$DSH_PID" "$NGINX_PID" 2>/dev/null || true' TERM INT
    status=0
    wait "$DSH_PID" || status=$?
    kill -TERM "$NGINX_PID" 2>/dev/null || true
    wait "$NGINX_PID" 2>/dev/null || true
    exit "$status"
  fi

  # Other profiles stay single-process.
  exec gosu "$DSH_USER" "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Phase 2 — unprivileged: reconcile on version drift, then launch.
# ---------------------------------------------------------------------------
mkdir -p "$DSH_HOME"

# Version baked into the image (apps/cli/package.json version, e.g. 0.1.0-rc.8).
DSH_VER="$(node -p "require('$DSH_PKG').version" 2>/dev/null || echo unknown)"

if [ ! -f "$DSH_HOME/.dsh-version" ] || [ "$(cat "$DSH_HOME/.dsh-version" 2>/dev/null)" != "$DSH_VER" ]; then
  if [ -d "$DSH_HOME/profiles" ]; then
    for profile_dir in "$DSH_HOME"/profiles/*/; do
      [ -d "$profile_dir" ] || continue
      echo "dsh: reconciling plugins in $profile_dir"
      # Reproducible from the profile's pinned package.json (user data in the volume).
      # The profile's pnpm-workspace.yaml (allowBuilds) must live in the volume too.
      ( cd "$profile_dir" && pnpm install ) \
        || echo "dsh: WARN plugin reconcile failed in $profile_dir (run 'dsh plugin --profile <name> add <pkg>' manually)"
    done
  fi
  echo "$DSH_VER" > "$DSH_HOME/.dsh-version"
fi

# Default to the Web UI profile when no subcommand is supplied.
if [ "$#" -eq 0 ]; then
  set -- web
fi

# Inside a container there is no desktop to hand the page to, so the web
# profile must never try to open a browser.
if [ "$1" = "web" ]; then
  case " $* " in
    *' --no-open '*) ;;
    *) set -- "$@" --no-open ;;
  esac
fi

exec node "$DSH_RECOVER" "$@"
