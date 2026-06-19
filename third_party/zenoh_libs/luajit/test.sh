#!/bin/bash
# test.sh — run all LuaJIT zenoh tests.
#
# Spins up a temporary zenohd container, runs the three test scripts,
# and tears the container down on exit.

set -e

ZENOH_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$ZENOH_DIR"

# zenoh-pico's libzenohpico.so lives wherever you built it. Default to
# the local source build used in the C tree. Override with ZENOH_PICO_HOME.
: "${ZENOH_PICO_HOME:=$HOME/src/zenoh-pico}"
ZENOH_PICO_LIB="$ZENOH_PICO_HOME/lib-combined"

# .so search path: our zenoh libs sit in this dir; zenoh-pico is alongside.
export LD_LIBRARY_PATH="$ZENOH_DIR:$ZENOH_PICO_LIB:$LD_LIBRARY_PATH"

# Optional: spin up the test container if it isn't already there.
CONTAINER_NAME="${ZENOH_TEST_CONTAINER:-zenoh-test}"
TEST_PORT="${ZENOH_TEST_PORT:-17447}"
export ZENOH_LOCATOR="udp/127.0.0.1:${TEST_PORT}"

started_container=0
if ! docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q .; then
    echo "Starting zenohd test container (${CONTAINER_NAME}:${TEST_PORT})..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER_NAME" \
        -p "${TEST_PORT}":7447/tcp -p "${TEST_PORT}":7447/udp \
        eclipse/zenoh:latest \
        --listen tcp/0.0.0.0:7447 \
        --listen udp/0.0.0.0:7447 >/dev/null
    started_container=1
    sleep 2
fi

cleanup() {
    if [ "$started_container" = "1" ]; then
        echo "Stopping zenohd test container..."
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

failed=0

echo
luajit test/test_zenoh_token.lua  || failed=$((failed + 1))
echo
luajit test/test_zenoh_pubsub.lua || failed=$((failed + 1))
echo
luajit test/test_zenoh_rpc.lua    || failed=$((failed + 1))

echo
if [ "$failed" = "0" ]; then
    echo "ALL LuaJIT zenoh tests passed."
    exit 0
else
    echo "$failed test script(s) FAILED."
    exit 1
fi
