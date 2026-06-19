#!/bin/bash
# packaging/wsl/start.sh — WSL host-side docker run wrapper.
#
# This is the SAME shape as the eventual /home/pi/farm/<robot>/start.sh on
# the Pi. The script resolves its own directory so bind mounts are computed
# relative to wherever the script lives — drop the whole folder anywhere and
# it just works. (Pi deploy: rsync this folder to /home/pi/farm/<name>/, then
# edit fleet.env for Pi-specific values: GATEWAY_HOST=0.0.0.0, etc.)
#
# Pi launch path: /etc/rc.local invokes `<deploy-dir>/start.sh &`.
# WSL launch path: run by hand from a terminal.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ----------------------------------------------------------------------------
# Load deploy-local env (gitignored). All defaults are set below — the env
# file just OVERRIDES, so an empty file is a valid (lowest-config) deploy.
# ----------------------------------------------------------------------------
if [ -f "$SCRIPT_DIR/fleet.env" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$SCRIPT_DIR/fleet.env"
    set +a
fi

# Image + container identity
IMAGE_TAG=${IMAGE_TAG:-fleet-mcfarland:wsl}
CONTAINER_NAME=${CONTAINER_NAME:-fleet}

# Where bind-mounted data + secrets live on the host.
DATA_DIR=${DATA_DIR:-$SCRIPT_DIR/var}
SECRETS_DIR=${SECRETS_DIR:-$SCRIPT_DIR/secrets}

# Runtime env passed into the container. WSL defaults; Pi will set
# GATEWAY_HOST=0.0.0.0 so the dashboard is reachable from the LAN.
GATEWAY_HOST=${GATEWAY_HOST:-127.0.0.1}
GATEWAY_PORT=${GATEWAY_PORT:-8080}
FARM_SOIL_INSTANCE=${FARM_SOIL_INSTANCE:-lacima01}
RANCHO_WATER_INSTANCE=${RANCHO_WATER_INSTANCE:-main}
ZENOH_LOCATOR=${ZENOH_LOCATOR:-tcp/127.0.0.1:7447}

# Restart policy. unless-stopped means docker brings it back on host reboot
# and on any non-`docker stop` exit (covers our supervisor's crash-and-exit).
RESTART_POLICY=${RESTART_POLICY:-unless-stopped}

# Network mode.
#   host   — share host network namespace (works on Linux Docker — Pi target).
#   bridge — port-published. Required on Docker Desktop (Mac / Windows /
#            WSL with Docker Desktop), where --network=host does NOT actually
#            share the host namespace and external clients can't reach
#            container ports.
# When bridge: gateway MUST bind 0.0.0.0 inside the container to be reachable
# via the published port (overrides any GATEWAY_HOST=127.0.0.1 default).
NETWORK_MODE=${NETWORK_MODE:-bridge}

if [ "$NETWORK_MODE" = "host" ]; then
    NETWORK_FLAGS=(--network host)
else
    NETWORK_FLAGS=(-p "$GATEWAY_PORT":"$GATEWAY_PORT" -p 7447:7447)
    GATEWAY_HOST=0.0.0.0
fi

mkdir -p "$DATA_DIR" "$SECRETS_DIR"

# ----------------------------------------------------------------------------
# Replace any stale container with this name (idempotent restart of script).
# ----------------------------------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "==> removing existing container: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" >/dev/null
fi

DASHBOARD_REACHABLE_AT=$(if [ "$NETWORK_MODE" = "host" ]; then echo "$GATEWAY_HOST"; else echo "127.0.0.1"; fi)
echo "==> launching $CONTAINER_NAME from $IMAGE_TAG"
echo "    network : $NETWORK_MODE"
echo "    data    : $DATA_DIR"
echo "    secrets : $SECRETS_DIR"
echo "    dashboard: http://$DASHBOARD_REACHABLE_AT:$GATEWAY_PORT/"

exec docker run -d \
    --name "$CONTAINER_NAME" \
    "${NETWORK_FLAGS[@]}" \
    --restart "$RESTART_POLICY" \
    --log-driver json-file \
    --log-opt max-size=20m \
    --log-opt max-file=5 \
    -v "$DATA_DIR":/var/fleet \
    -v "$SECRETS_DIR":/secrets:ro \
    -e GATEWAY_HOST="$GATEWAY_HOST" \
    -e GATEWAY_PORT="$GATEWAY_PORT" \
    -e ZENOH_LOCATOR="$ZENOH_LOCATOR" \
    -e FARM_SOIL_INSTANCE="$FARM_SOIL_INSTANCE" \
    -e RANCHO_WATER_INSTANCE="$RANCHO_WATER_INSTANCE" \
    "$IMAGE_TAG"

# Docker log cap: max 5 rotated files of 20 MB each = 100 MB hard cap on
# `docker logs fleet` output. At the steady-state chatter rate of this
# stack (mostly heartbeat pings), 100 MB lasts weeks. Separate from the
# supervisor.log on the bind mount (which caps at 100 JSON entries via
# the rotation built into /app/start.sh).
