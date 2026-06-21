#!/bin/bash
# packaging_irrigation_analytics/wsl/start.sh — docker-run wrapper for the
# irrigation-analytics fleet container.
#
# Same shape as the Pi-target deploy. Sibling to packaging/wsl/start.sh —
# different image, different container name, different host ports so it can
# coexist with fleet-mcfarland on the same Pi.
#
# Defaults (no fleet.env override needed for a basic WSL run):
#   IMAGE_TAG          nanodatacenter/irrigation-analytics:wsl
#   CONTAINER_NAME     irrigation-analytics
#   GATEWAY_PORT       28080   (host port; dashboard at http://127.0.0.1:28080/)
#   ZENOH_HOST_PORT    27447   (host port; internal container port stays 7447)
#   IRRIGATION_ANALYTICS_INSTANCE  lacima
#   NETWORK_MODE       bridge  (forced 0.0.0.0 inside; Docker Desktop needs this)

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ -f "$SCRIPT_DIR/fleet.env" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$SCRIPT_DIR/fleet.env"
    set +a
fi

IMAGE_TAG=${IMAGE_TAG:-nanodatacenter/irrigation-analytics:wsl}
CONTAINER_NAME=${CONTAINER_NAME:-irrigation-analytics}

DATA_DIR=${DATA_DIR:-$SCRIPT_DIR/var}
SECRETS_DIR=${SECRETS_DIR:-$SCRIPT_DIR/secrets}

GATEWAY_HOST=${GATEWAY_HOST:-127.0.0.1}
GATEWAY_PORT=${GATEWAY_PORT:-28080}
ZENOH_HOST_PORT=${ZENOH_HOST_PORT:-27447}
IRRIGATION_ANALYTICS_INSTANCE=${IRRIGATION_ANALYTICS_INSTANCE:-lacima}
IRRIGATION_CONTROLLER_HOST=${IRRIGATION_CONTROLLER_HOST:-pi@irrigation}
ZENOH_LOCATOR=${ZENOH_LOCATOR:-tcp/127.0.0.1:7447}

RESTART_POLICY=${RESTART_POLICY:-unless-stopped}

# Network mode.
#   bridge — port-published. Required on Docker Desktop (WSL/Mac/Win).
#   host   — Pi production; coexisting with fleet-mcfarland on a single
#            host requires bridge or a non-default zenohd port — see README.
NETWORK_MODE=${NETWORK_MODE:-bridge}

if [ "$NETWORK_MODE" = "host" ]; then
    NETWORK_FLAGS=(--network host)
else
    # Container always listens internally on 7447 + 8080; remap host-side.
    NETWORK_FLAGS=(-p "$GATEWAY_PORT":8080 -p "$ZENOH_HOST_PORT":7447)
    GATEWAY_HOST=0.0.0.0
fi

mkdir -p "$DATA_DIR" "$SECRETS_DIR"

# Warn if SSH staging dir is missing — the robot's popup fetch will fail
# without it (controller_client.lua needs `ssh pi@irrigation` to work).
if [ ! -d "$SECRETS_DIR/ssh" ]; then
    echo "==> WARN: $SECRETS_DIR/ssh/ does not exist."
    echo "    Robot will boot but popup fetch will fail (no key, no host config)."
    echo "    To fix: cp ~/.ssh/{config,id_irrig_146,id_irrig_146.pub,known_hosts} \\"
    echo "                $SECRETS_DIR/ssh/"
    echo "    See packaging_irrigation_analytics/wsl/README.md for the recipe."
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "==> removing existing container: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" >/dev/null
fi

DASHBOARD_REACHABLE_AT=$(if [ "$NETWORK_MODE" = "host" ]; then echo "$GATEWAY_HOST"; else echo "127.0.0.1"; fi)
echo "==> launching $CONTAINER_NAME from $IMAGE_TAG"
echo "    network   : $NETWORK_MODE"
echo "    data      : $DATA_DIR"
echo "    secrets   : $SECRETS_DIR"
echo "    dashboard : http://$DASHBOARD_REACHABLE_AT:$GATEWAY_PORT/"
echo "    zenoh     : tcp://127.0.0.1:$ZENOH_HOST_PORT  (-> 7447 inside)"
echo "    robot     : irrigation_analytics/$IRRIGATION_ANALYTICS_INSTANCE"

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
    -e GATEWAY_PORT=8080 \
    -e ZENOH_LOCATOR="$ZENOH_LOCATOR" \
    -e IRRIGATION_ANALYTICS_INSTANCE="$IRRIGATION_ANALYTICS_INSTANCE" \
    -e IRRIGATION_CONTROLLER_HOST="$IRRIGATION_CONTROLLER_HOST" \
    -e IMAGE_TAG="$IMAGE_TAG" \
    -e DASHBOARD_URL="${DASHBOARD_URL:-http://192.168.1.66:28080/irrigation/alerts}" \
    -e KB3_CURVE_CEILING_OFFSET_GPM="${KB3_CURVE_CEILING_OFFSET_GPM:-0.0}" \
    -e KB3_CURVE_LEAK_DELTA_GPM="${KB3_CURVE_LEAK_DELTA_GPM:-5.0}" \
    -e KB3_CURVE_WARN_DELTA_GPM="${KB3_CURVE_WARN_DELTA_GPM:-2.0}" \
    -e KB1_ARM_KILL="${KB1_ARM_KILL:-0}" \
    -e KB3_ARM_KILL="${KB3_ARM_KILL:-0}" \
    -e SKIP_LIVE="${SKIP_LIVE:-0}" \
    -e FIELD_LOG_ARM="${FIELD_LOG_ARM:-0}" \
    -e KB3_WELL_ARM="${KB3_WELL_ARM:-0}" \
    -e KB4_CURVE_ARM="${KB4_CURVE_ARM:-0}" \
    -e KB1_EQ_KILL_A="${KB1_EQ_KILL_A:-1.8}" \
    "$IMAGE_TAG"
