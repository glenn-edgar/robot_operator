#!/usr/bin/env bash
# run.sh — launcher for the notification service (layer 60).
#
# Optional env: ZENOH_LOCATOR        (default tcp/127.0.0.1:7447)
#               SERVICE_ID           (default notification-1)
#               NOTIFY_USERNAME      (default fleet_design)
# Required env: DISCORD_WEBHOOK_URL  (or in secrets/discord.env)
#
# Mirrors persistence/run.sh + application_gateway/run.sh shape.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VENDOR_LUA=$REPO_ROOT/vendor/lua

# Source the gitignored secrets file if present (overrides env defaults).
if [ -f "$SCRIPT_DIR/secrets/discord.env" ]; then
    set -a
    . "$SCRIPT_DIR/secrets/discord.env"
    set +a
fi

# LuaJIT-compatible cjson — must precede the user's Lua-5.4-ABI luarocks copy.
: "${LUA_CPATH:=/usr/local/lib/lua/5.1/?.so;;}"
export LUA_CPATH

export LUA_PATH="$VENDOR_LUA/?.lua;$SCRIPT_DIR/lib/?.lua;$SCRIPT_DIR/?.lua;;"

# TODO Pi/container deploy: replace bench LD_LIBRARY_PATH with vendor/lib-*.
if [ -z "${LD_LIBRARY_PATH:-}" ]; then
    DEFAULT_ZENOH_LIB=$HOME/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh
    DEFAULT_PICO_LIB=$HOME/src/zenoh-pico/lib-combined
    export LD_LIBRARY_PATH="$DEFAULT_ZENOH_LIB:$DEFAULT_PICO_LIB"
fi

exec luajit "$SCRIPT_DIR/main.lua" "$@"
